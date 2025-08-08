#!/bin/bash

# On a linux VM, simulate the steps a device manufacturer would do:
#   - Create instructions for device to redirect device to correct RV server = DI (device initialization)
#   - Receive a public key + device serial number in order to create Ownership Voucher
#   - extend the Ownership Voucher to the owner (buyer)
#   - Switch the device into owner mode

# This script starts/uses the Manufacturer services. See the FDO Manufacturer Enablement Guide
# These Manufacturer services are not for production use.

# Supports Fedora 36+ and Ubuntu 2x.04

usage() {
    exitCode=${1:-0}
    cat << EndOfMessage
Usage: ${0##*/} [<rvHttpPort>] [<rvHttpsPort>]

Arguments:
  <owner-pub-key-file>  Device customer/owner public key. This is needed to extend the voucher to the owner. If not specified, it will use default SECP256R1 public key obtained from owner services

Required Environment Variables:
  HZN_EXCHANGE_USER_AUTH: Exchange user's username and password.

Optional Environment Variables:
  FDO_MFG_DB:             Database name for FDO's manufacturing services
  FDO_MFG_DB_URL:         Database path and protocol
  FDO_MFG_DB_PASSWORD:    Database user's password
  FDO_MFG_DB_SSL:         Database connection SSL toggle
  FDO_MFG_DB_USER:        Database user
  FDO_RV_URL:             Usually the development RV server running with the owner services. To use the production RV service, set to http://fdorv.com
  HZN_EXCHANGE_USER_AUTH: API password for service APIs
  HZN_FDO_SVC_URL:        Owner Service url.
  HZN_LISTEN_IP:          External address of Open Horizon's Management Hub.
  HZN_ORG_ID:             Exchange user's organization
  HZN_TRANSPORT:          http or https. Only http is currently supported.
  rvHttpPort:             Rendezvous server http port. If no http present, then set this as the https port
  rvHttpsPort:            Rendezvous server https port


${0##*/} must be run in a directory where it has access to create a few files and directories.
EndOfMessage
    exit $exitCode
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage 0
fi

: ${HZN_EXCHANGE_USER_AUTH:?}   # required


generateToken() { head -c 1024 /dev/urandom | base64 | tr -cd "[:alpha:][:digit:]"  | head -c $1; }


export FDO_MFG_DB=${FDO_MFG_DB:-fdo_mfg}
export FDO_MFG_DB_PASSWORD=${FDO_MFG_DB_PASSWORD:-$(generateToken 30)}
export FDO_MFG_DB_PORT=${FDO_MFG_DB_PORT:-5434}
export FDO_MFG_DB_SSL=${FDO_MFG_DB_SSL:-false}
export FDO_MFG_DB_URL=${FDO_MFG_DB_URL:-jdbc:postgresql://postgres-fdo-mfg-service:5432/$FDO_MFG_DB}
export FDO_MFG_DB_USER=${FDO_MFG_DB_USER:-fdouser}
export FDO_MFG_PORT=${FDO_MFG_PORT:-8039}
export FDO_MFG_SVC_AUTH=${FDO_MFG_SVC_AUTH:-apiUser:$(generateToken 30)}
export FDO_OWN_COMP_SVC_PORT=${FDO_OWN_COMP_SVC_PORT:-9008}
export FDO_RV_URL=${FDO_RV_URL:-http://fdorv.com} # set to the production domain by default. Development domain is Owner's service public key protected as of v1.1.6.
export FIDO_DEVICE_ONBOARD_REL_VER=${FIDO_DEVICE_ONBOARD_REL_VER:-1.1.10} # https://github.com/fido-device-onboard/release-fidoiot/releases
export HZN_DOCK_NET=${HZN_DOCK_NET:-hzn_horizonnet}
#export HZN_EXCHANGE_USER_AUTH=${HZN_EXCHANGE_USER_AUTH:-admin:} # Default to organization admin provided by all-in-1 environment
export HZN_LISTEN_IP=${HZN_LISTEN_IP:-127.0.0.1}
export HZN_FDO_SVC_URL=${HZN_FDO_SVC_URL:-$HZN_LISTEN_IP:$FDO_OWN_COMP_SVC_PORT}
export HZN_ORG_ID=${HZN_ORG_ID:-myorg} # Default to organization admin provided by all-in-1 environment
export HZN_TRANSPORT=${HZN_TRANSPORT:-http}
export EXCHANGE_USER=${EXCHANGE_USER:-$(echo $HZN_EXCHANGE_USER_AUTH | awk -F ":" '{print $1}')}
export EXCHANGE_USER_PASSWORD=${EXCHANGE_USER_PASSWORD:-$(echo $HZN_EXCHANGE_USER_AUTH | awk -F ":" '{print $2}')}
export POSTGRES_HOST_AUTH_METHOD=${POSTGRES_HOST_AUTH_METHOD:-scram-sha-256}
export POSTGRES_IMAGE_TAG=${POSTGRES_IMAGE_TAG:-17}
deviceBinaryDir='pri-fidoiot-v'$FIDO_DEVICE_ONBOARD_REL_VER
rvHttpPort=${1:-80}
rvHttpsPort=${2:-443} #Will change to 8041 when https is enabled
DISTRO=${DISTRO:-$(. /etc/os-release 2>/dev/null;echo $ID $VERSION_ID)}

#If the passed argument is a file, save the file directory path
if [[ -f "$ownerPubKeyFile" ]]; then
  origDir="$PWD"
  #if you passed an owner public key, it will be retrieved from the original directory
  if [[ -f $origDir/$ownerPubKeyFile ]]; then
    ownerPubKeyFile="$origDir/$ownerPubKeyFile"
  fi
fi

# These environment variables can be overridden
FDO_SUPPORT_RELEASE=${FDO_SUPPORT_RELEASE:-https://github.com/fido-device-onboard/release-fidoiot/releases/download/v$FIDO_DEVICE_ONBOARD_REL_VER}
#useNativeClient=${FDO_DEVICE_USE_NATIVE_CLIENT:-false}   # possible values: false (java client), host (TO native on host), docker (TO native in container)
workingDir=fdo

#====================== Functions ======================

# Only echo this if VERBOSE is 1 or true
verbose() {
    if [[ "$VERBOSE" == "1" || "$VERBOSE" == "true" ]]; then
        echo 'verbose:' "$*"
    fi
}

# Check the exit code passed in and exit if non-zero
chk() {
    local exitCode=$1
    local task=$2
    local dontExit=$3   # set to 'continue' to not exit for this error
    if [[ $exitCode == 0 ]]; then return; fi
    echo "Error: exit code $exitCode from: $task"
    if [[ $dontExit != 'continue' ]]; then
        exit $exitCode
    fi
}

# Check both the exit code and http code passed in and exit if non-zero
chkHttp() {
    local exitCode=$1
    local httpCode=$2
    local task=$3
    local dontExit=$4   # set to 'continue' to not exit for this error
    chk $exitCode $task
    if [[ $httpCode == 200 ]]; then return; fi
    echo "Error: http code $httpCode from: $task"
    if [[ $dontExit != 'continue' ]]; then
        exit $httpCode
    fi
}

# Verify that the prereq commands we need are installed
confirmcmds() {
    for c in $*; do
        #echo "checking $c..."
        if ! which $c >/dev/null; then
            echo "Error: $c is not installed but required, exiting"
            exit 2
        fi
    done
}

runCmdQuietly() {
    # all of the args to this function are the cmd and its args
    if [[  "$VERBOSE" == '1' || "$VERBOSE" == 'true' ]]; then
        "$*"
        chk $? "running: $*"
    else
        output=$("$*" 2>&1)
        if [[ $? -ne 0 ]]; then
            echo "Error running $*: $output"
            exit 2
        fi
    fi
}

ensureWeAreRoot() {
    if [[ $(whoami) != 'root' ]]; then
        echo "Error: must be root to run ${0##*/} with these options."
        exit 2
    fi
}

# Is this deb pkg installed
isDebPkgInstalled() {
    local pkgName="$1"
    dpkg-query -s $pkgName 2>&1 | grep -q -E '^Status: .* installed$'
}

# Checks if docker-compose is installed, and if so, if it is at least this minimum version
isDockerComposeAtLeast() {
    : ${1:?}
    local minVersion=$1
    if ! command -v docker-compose >/dev/null 2>&1; then
        return 1   # it is not even installed
    fi
    # docker-compose is installed, check its version
    lowerVersion=$(echo -e "$(docker-compose version --short)\n$minVersion" | sort -V | head -n1)
    if [[ $lowerVersion == "$minVersion" ]]; then
        return 0   # the installed version was >= minVersion
    else
        return 1
    fi
}

# Find 1 of the private IPs of the host
getPrivateIp() {
    if isMacOS; then ipCmd=ifconfig
    else ipCmd='ip address'; fi
    $ipCmd | grep -m 1 -o -E "\sinet (172|10|192.168)[^/\s]*" | awk '{ print $2 }'
}

isUbuntu2x() {
    if [[ "$DISTRO" =~ ubuntu\ 2[0-4]\.* ]]; then
		return 0
	else
		return 1
	fi
}

isFedora() {
  if [[ "$DISTRO" =~ fedora\ ((3[6-9])|([4-9][0-9])|([1-9][0-9]{2,}))$ ]]; then
    return 0
  else
    return 1
  fi
}

isKernelOld() {
  if [[ $(uname -r) =~ ^(([0-4]{1,1}\.)|(5\.[0-9]{1,1}\.)|(5\.1[0-2]{1,1}\.)) ]]; then
    return 0
  else
    return 1
  fi
}

#====================== Main Code ======================

if [[ ${FDO_MFG_SVC_AUTH} != *"apiUser:"* || ${FDO_MFG_SVC_AUTH} == *$'\n'* || ${FDO_MFG_SVC_AUTH} == *'|'* ]]; then
    # newlines and vertical bars aren't allowed in the pw, because they cause the sed cmds below to fail
    echo "Error: FDO_MFG_SVC_AUTH must include 'apiUser:' as a prefix and not contain newlines or '|'"
    exit 1
fi

# Our working directory is /fdo
ensureWeAreRoot
if [[ ! -d "$workingDir" ]]; then
  mkdir -p $workingDir
fi
cd $workingDir || chk $? "creating and switching to $workingDir"
echo "creating and switching to $workingDir"

# Make sure the host has the necessary software: java 11, docker-ce, docker-compose >= 1.21.0
confirmcmds grep curl ping   # these should be in the minimal ubuntu


# If java 11 isn't installed, do that
if java -version 2>&1 | grep version | grep -q '1[7-7]\.'; then
  echo "Found java 17"
else
  echo "Java 17 not found, installing it..."
  if isUbuntu2x; then
    apt-get update && apt-get install -y openjdk-17-jre-headless
  elif isFedora; then
    dnf install -y java-17-openjdk
  else
    echo "Unsupported distribution, exiting" && exit 1
  fi
  chk $? 'installing java 17'
fi

# Deprecated with kernels 5.13.x and newer.
if isKernelOld && (! command haveged --help >/dev/null 2>&1); then
  echo "Haveged is required, installing it"
  if isUbuntu2x; then
    sudo apt-get install -y haveged
    chk $? 'installing haveged'
  fi
fi

# If docker isn't installed, do that
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required, installing it..."
    if isUbuntu2x; then
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
      chk $? 'adding docker repository key'
      add-apt-repository "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
      chk $? 'adding docker repository'
      apt-get install -y docker-ce docker-ce-cli containerd.io
      chk $? 'installing docker'
    elif isFedora; then
      dnf install moby-engine
    fi
fi

# Start a DB container for FDO's manufacturer services
docker run -d \
           -e "POSTGRES_DB=$FDO_MFG_DB" \
           -e "POSTGRES_PASSWORD=$FDO_MFG_DB_PASSWORD" \
           -e "POSTGRES_USER=$FDO_MFG_DB_USER" \
           -e "POSTGRES_HOST_AUTH_METHOD=$POSTGRES_HOST_AUTH_METHOD" \
           -e "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=scram-sha-256" \
           --health-cmd="pg_isready -U $FDO_MFG_DB_USER" \
           --health-interval=15s \
           --health-retries=3 \
           --health-timeout=5s \
           --name postgres-fdo-mfg-service \
           --network="$HZN_DOCK_NET" \
           -p "$FDO_MFG_DB_PORT":5432 \
           postgres:"$POSTGRES_IMAGE_TAG"


# If docker-compose isn't installed, or isn't at least 1.29.2 (when docker-compose.yml version 2.4 was introduced), then install/upgrade it
# For the dependency on 1.29.2 or greater, see: https://docs.docker.com/compose/release-notes/
minVersion=1.29.2
if ! isDockerComposeAtLeast $minVersion; then
    if [[ -f '/usr/bin/docker-compose' ]]; then
        echo "Error: Need at least docker-compose $minVersion. A down-level version is currently installed, preventing us from installing the latest version. Uninstall docker-compose and rerun this script."
        exit 2
    fi
    echo "docker-compose is not installed or not at least version $minVersion, installing/upgrading it..."
    # Install docker-compose from its github repo, because that is the only way to get a recent enough version
    curl --progress-bar -L "https://github.com/docker/compose/releases/$minVersion/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chk $? 'downloading docker-compose'
    chmod +x /usr/local/bin/docker-compose
    chk $? 'making docker-compose executable'
    ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
    chk $? 'linking docker-compose to /usr/bin'
fi

# Get the other files we need from our git repo, by way of our device binaries tar file
if [[ ! -d $deviceBinaryDir ]]; then
echo "$deviceBinaryDir DOES NOT EXIST"
    deviceBinaryTar="$deviceBinaryDir.tar.gz"
    deviceBinaryUrl="$FDO_SUPPORT_RELEASE/$deviceBinaryTar"
    echo "Removing old device binary tar files, and getting and unpacking $deviceBinaryDir ..."
    rm -rf $workingDir/pri-fidoiot-*   # it is important to only have 1 device binary dir, because the device script does a find to locate device.jar

    echo "$deviceBinaryUrl"

    httpCode=$(curl -w "%{http_code}" --progress-bar -L -O  $deviceBinaryUrl)
    chkHttp $? $httpCode "getting $deviceBinaryTar"
    tar -zxf $deviceBinaryTar
fi


# Run key generation script
echo "Running key generation script..."

cd $PWD/$deviceBinaryDir/scripts || exit
chmod +x ./demo_ca.sh ./user_csr_req.sh ./web_csr_req.sh ./keys_gen.sh
./demo_ca.sh && ./user_csr_req.sh && ./web_csr_req.sh && ./keys_gen.sh
mkdir -p ../manufacturer/secrets
cp -r ./secrets/. ../manufacturer/secrets/.
cd ../../ || exit


#Configurations
# override auto-generated DB username and password with variables
sed -i -e "s/db_user=.*/db_user=$FDO_MFG_DB_USER/" $PWD/$deviceBinaryDir/owner/service.env
sed -i -e "s/db_password=.*/db_password=$FDO_MFG_DB_PASSWORD/" $PWD/$deviceBinaryDir/owner/service.env
sed -i -e "s/useSSL=.*/useSSL=$FDO_MFG_DB_SSL/" $PWD/$deviceBinaryDir/owner/service.env

# device/service.yml configuration to point to local manufacturing port
sed -i -e 's/di-url:.*/di-url: '$HZN_TRANSPORT':\/\/'$HZN_LISTEN_IP':'$FDO_MFG_PORT'/' $PWD/$deviceBinaryDir/device/service.yml
chk $? 'sed device/service.yml'

# configure manufacturer/hibernate.cfg.xml to use PostgreSQL database
sed -i -e 's/org.mariadb.jdbc.Driver/org.postgresql.Driver/' $PWD/$deviceBinaryDir/manufacturer/hibernate.cfg.xml
chk $? 'sed manufacturer/hibernate.cfg.xml driver_class'

# manufacturer/service.env
api_user=$(echo "$FDO_MFG_SVC_AUTH" | awk -F: '{print $1}')
api_password=$(echo "$FDO_MFG_SVC_AUTH" | awk -F: '{print $2}')
sed -i -e 's/api_user=.*/api_user="'$api_user'"\napi_password="'$api_password'"/' $PWD/$deviceBinaryDir/manufacturer/service.env
chk $? 'sed manufacturer/service.env api_user'
sed -i -e 's/db_user=.*/db_user="'$FDO_MFG_DB_USER'"/' $PWD/$deviceBinaryDir/manufacturer/service.env
chk $? 'sed manufacturer/service.env db_user'
sed -i -e 's/db_password=.*/db_password="'$FDO_MFG_DB_PASSWORD'"/' $PWD/$deviceBinaryDir/manufacturer/service.env
chk $? 'sed manufacturer/service.env db_password'

# manufacturer/service.yml
sed -i -e 's/org.hibernate.dialect.MariaDBDialect/org.hibernate.dialect.PostgreSQLDialect/' $PWD/$deviceBinaryDir/manufacturer/service.yml
chk $? 'sed manufacturer/service.yml hibernate.dialect'
sed -i -e "s|jdbc:mariadb:\/\/host.docker.internal:3306\/emdb?useSSL=\$(useSSL)|$FDO_MFG_DB_URL|" $PWD/$deviceBinaryDir/manufacturer/service.yml
chk $? 'sed manufacturer/service.yml hibernate.connection.url'
sed -i -e 's/server.api.password: "null"/server.api.password: $(api_password)/' $PWD/$deviceBinaryDir/manufacturer/service.yml
chk $? 'sed manufacturer/service.yml server.api.password'
sed -i -e '/secrets:/ s/./#&/' $PWD/$deviceBinaryDir/manufacturer/service.yml
chk $? 'sed manufacturer/service.yml secrets'
sed -i -e '/- db_password/ s/./#&/' $PWD/$deviceBinaryDir/manufacturer/service.yml
chk $? 'sed manufacturer/service.yml db_password'

# configure manufacturer/WEB-INF/web.xml for http support (development)
sed -i -e 's/<transport-guarantee>CONFIDENTIAL<\/transport-guarantee>/<transport-guarantee>NONE<\/transport-guarantee>/' $PWD/$deviceBinaryDir/manufacturer/WEB-INF/web.xml
sed -i -e 's/<auth-method>CLIENT-CERT<\/auth-method>/<auth-method>DIGEST<\/auth-method>\n<realm-name>Digest Authentication<\/realm-name>/' $PWD/$deviceBinaryDir/manufacturer/WEB-INF/web.xml

echo "Starting manufacturer service..."
sudo chmod 666 /var/run/docker.sock
cd ./$deviceBinaryDir/manufacturer || exit
# Adding container to open horizon docker network.
sed -i -e 's/version:.*/&\n\nnetworks:\n  horizonnet:\n    name: hzn_horizonnet\n    driver: bridge/' ./docker-compose.yml
chk $? 'sed docker-compose.yml network bridge'
sed -i -e 's/restart:.*/&\n    networks:\n      - horizonnet/' ./docker-compose.yml
chk $? 'sed docker-compose.yml network'
docker-compose up --build -d

# get Domain Name from Rendezvous Server URL
FDO_RV_DNS=$(echo "$FDO_RV_URL" | awk -F/ '{print $3}' | awk -F: '{print $1}')
echo "FDO_RV_DNS: ${FDO_RV_DNS}"


echo -n "waiting for manufacturer service to boot."
httpCode=500
while [ $httpCode != 200 ]
do
  echo -n "."
  sleep 2
  httpCode=$(curl -I -s -w "%{http_code}" -o /dev/null --digest -u "$FDO_MFG_SVC_AUTH" --location --request GET "$HZN_TRANSPORT://$HZN_LISTEN_IP:$FDO_MFG_PORT/health")
done
echo ""

echo "setting rendezvous server location to ${FDO_RV_DNS}:${rvHttpPort}"
response=$(curl -s -w "%{http_code}" -D - --digest -u "$FDO_MFG_SVC_AUTH" --location --request POST "$HZN_TRANSPORT://$HZN_LISTEN_IP:$FDO_MFG_PORT/api/v1/rvinfo" --header 'Content-Type: text/plain' --data-raw '[[[5,"'"${FDO_RV_DNS}"'"],[3,"'"${rvHttpPort}"'"],[12,1],[2,"'"${FDO_RV_DNS}"'"],[4,"'"${rvHttpPort}"'"]]]')
code=$?
httpCode=$(tail -n1 <<< "$response")
chkHttp $code $httpCode "setting rendezvous server location"

# device is tied to the organization of defined user.
echo "beginning device initialization"
(cd ../device && java -jar device.jar)

# back to root directory
cd ../../../ || exit 1

echo "getting device info (alias, serial number, UUID)"
response=$(curl -s -w "\\n%{http_code}" --digest -u "$FDO_MFG_SVC_AUTH" --location --request GET "$HZN_TRANSPORT://$HZN_LISTEN_IP:$FDO_MFG_PORT/api/v1/deviceinfo/10000" --header 'Content-Type: text/plain')
code=$?
httpCode=$(tail -n1 <<< "$response")
chkHttp $code $httpCode "getting device info"
serial=$(echo $response | grep -o '"serial_no":"[^"]*' | grep -o '[^"]*$')
echo "serial:$serial"
alias=$(echo $response | grep -o '"alias":"[^"]*' | grep -o '[^"]*$')
echo "alias:$alias"

echo "getting device public key"
httpCode=$(curl -s -w "%{http_code}" -o public_key.pem -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" --location "$HZN_TRANSPORT://$HZN_LISTEN_IP:$FDO_OWN_COMP_SVC_PORT/api/orgs/$HZN_ORG_ID/fdo/certificate/$alias")
chkHttp $? $httpCode "getting device public key"

echo "getting ownership voucher"
httpCode=$(curl -s -w "%{http_code}" --digest -u "$FDO_MFG_SVC_AUTH" --location --request POST "$HZN_TRANSPORT://$HZN_LISTEN_IP:$FDO_MFG_PORT/api/v1/mfg/vouchers/$serial" --header 'Content-Type: text/plain' --data-binary '@public_key.pem' -o owner_voucher.txt)
chkHttp $? $httpCode "getting ownership voucher"

#
## Install systemd service that will run at boot time to complete the FDO process
#cp fdo/fdo_to.service /lib/systemd/system
#chk $? 'copying fdo_to.service to systemd'
#systemctl enable fdo_to.service
#chk $? 'enabling fdo_to.service'
#echo "Systemd service fdo_to.service has been enabled"
## After importing the voucher to fdo-owner-services, if you want to you can initiate the fdo boot process by running: systemctl start fdo_to.service &
## And you can view the output with: journalctl -f --no-tail -u fdo_to.service
