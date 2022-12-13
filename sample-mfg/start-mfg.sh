#!/bin/bash

# On a linux VM, simulate the steps a device manufacturer would do:
#   - Create instructions for device to redirect device to correct RV server = DI (device initialization)
#   - Receive a public key + device serial number in order to create Ownership Voucher
#   - extend the Ownership Voucher to the owner (buyer)
#   - Switch the device into owner mode

# This script starts/uses the Manufacturer services. See the Intel FDO Manufacturer Enablement Guide

usage() {
    exitCode=${1:-0}
    cat << EndOfMessage
Usage: ${0##*/} [<rvHttpPort>] [<rvHttpsPort>]

Arguments:
  <owner-pub-key-file>  Device customer/owner public key. This is needed to extend the voucher to the owner. If not specified, it will use default SECP256R1 public key obtained from owner services

Required Environment Variables:
  FDO_RV_URL: usually the development RV server running with the owner services. To use the production RV service, set to http://sdo.lfedge.iol.unh.edu:80
  HZN_EXCHANGE_USER_AUTH: API password for manufacturing service APIs
  HZN_FDO_SVC_URL: Owner Service url.

Optional Environment Variables:
  rvHttpPort: Rendezvous server http port. If no http present, then set this as the https port
  rvHttpsPort: Rendezvous server https port


${0##*/} must be run in a directory where it has access to create a few files and directories.
EndOfMessage
    exit $exitCode
}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage 0
fi

if [[ -z "$HZN_EXCHANGE_USER_AUTH" || -z "$FDO_RV_URL" || -z "$HZN_FDO_SVC_URL" ]]; then
    echo "Error: These environment variable must be set to access Owner services APIs: HZN_EXCHANGE_USER_AUTH, FDO_RV_URL, HZN_FDO_SVC_URL"
    exit 0
fi


deviceBinaryDir='pri-fidoiot-v1.1.1'   # the place we will unpack sdo_device_binaries_1.10_linux_x64.tar.gz to
rvHttpPort=${1:-8040}
rvHttpsPort=${2:-8040} #Will change to 8041 when https is enabled
rvUrl="$FDO_RV_URL"   # the external rv url that the device should reach it at

#If the passed argument is a file, save the file directory path
if [[ -f "$ownerPubKeyFile" ]]; then
  origDir="$PWD"
  #if you passed an owner public key, it will be retrieved from the original directory
  if [[ -f $origDir/$ownerPubKeyFile ]]; then
    ownerPubKeyFile="$origDir/$ownerPubKeyFile"
  fi
fi

# These environment variables can be overridden
FDO_SUPPORT_RELEASE=${FDO_SUPPORT_RELEASE:-https://github.com/secure-device-onboard/release-fidoiot/releases/download/v1.1.1}
useNativeClient=${FDO_DEVICE_USE_NATIVE_CLIENT:-false}   # possible values: false (java client), host (TO native on host), docker (TO native in container)

workingDir=fdo
dbUser='fdo'
dbPw='fdo'
IP_REGEX='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'

#====================== Functions ======================

# Only echo this if VERBOSE is 1 or true
verbose() {
    if [[ "$VERBOSE" == "1" || "$VERBOSE" == "true" ]]; then
        echo 'verbose:' $*
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
        $*
        chk $? "running: $*"
    else
        output=$($* 2>&1)
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
    if [[ $lowerVersion == $minVersion ]]; then
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

#====================== Main Code ======================

# Our working directory is /fdo
ensureWeAreRoot
mkdir -p $workingDir && cd $workingDir
chk $? "creating and switching to $workingDir"
echo "creating and switching to $workingDir"

# Determine whether to use native sdo client, or java client.
# Note: Now that we default useNativeClient, this automatic determination is never used, because you have to request the native docker image before you can use it here.
#if [[ -z "$useNativeClient" ]]; then
#    if [[ "$(systemd-detect-virt 2>/dev/null)" == 'none' ]]; then
#        useNativeClient='host'   # A physical server
#    else
#        useNativeClient='false'   # A VM
#    fi
#    # Also could use these cmds to determine, but there are more acceptable values to check for
#    # lscpu | grep 'Hypervisor vendor:' == non-blank or blank
#    # dmidecode -s system-manufacturer | awk '{print $1}' == Intel(R), IBM. QEMU, innotek (virtual box), VMware
#fi
# else they explicitly set it

# Make sure the host has the necessary software: java 11, docker-ce, docker-compose >= 1.21.0
confirmcmds grep curl ping   # these should be in the minimal ubuntu

    # If java 11 isn't installed, do that
if java -version 2>&1 | grep version | grep -q 11.; then
        echo "Found java 11"
else
        echo "Java 11 not found, installing it..."
        apt-get update && apt-get install -y openjdk-11-jre-headless
        chk $? 'installing java 11'
    fi


if ! command haveged --help >/dev/null 2>&1; then
    echo "Haveged is required, installing it"
    sudo apt-get install -y haveged
    chk $? 'installing haveged'
fi

# If docker isn't installed, do that
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required, installing it..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    chk $? 'adding docker repository key'
    add-apt-repository "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    chk $? 'adding docker repository'
    apt-get install -y docker-ce docker-ce-cli containerd.io
    chk $? 'installing docker'
fi


# If docker-compose isn't installed, or isn't at least 1.21.0 (when docker-compose.yml version 2.4 was introduced), then install/upgrade it
# For the dependency on 1.21.0 or greater, see: https://docs.docker.com/compose/release-notes/
minVersion=1.21.0
if ! isDockerComposeAtLeast $minVersion; then
    if [[ -f '/usr/bin/docker-compose' ]]; then
        echo "Error: Need at least docker-compose $minVersion. A down-level version is currently installed, preventing us from installing the latest version. Uninstall docker-compose and rerun this script."
        exit 2
    fi
    echo "docker-compose is not installed or not at least version $minVersion, installing/upgrading it..."
    # Install docker-compose from its github repo, because that is the only way to get a recent enough version
    curl --progress-bar -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
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

(cd $PWD/$deviceBinaryDir/scripts && ./keys_gen.sh)
# Replacing component credentials
(cd $PWD/$deviceBinaryDir/scripts && cp -r creds/. ../)

#Configurations
#sed -i -e '/network_mode: host/ s/./#&/' $PWD/$deviceBinaryDir/manufacturer/docker-compose.yml
#chk $? 'sed manufacturer/docker-compose.yml'
#Device/service.yml configuration to point to local manufacturing port
sed -i -e 's/di-url:.*/di-url: http:\/\/localhost:8039/' $PWD/$deviceBinaryDir/device/service.yml
chk $? 'sed device/service.yml'


USER_AUTH=$HZN_EXCHANGE_USER_AUTH
removeWord="apiUser:"
api_password=${USER_AUTH//$removeWord/}
sed -i -e 's/api_password=.*/api_password='$api_password'/' $PWD/$deviceBinaryDir/manufacturer/service.env

echo "Starting manufacturer service..."
sudo chmod 666 /var/run/docker.sock
(cd $PWD/$deviceBinaryDir/manufacturer && docker-compose up --build  -d)

#get Domain Name from Rendezvous Server URL
FDO_RV_DNS=$(echo "$FDO_RV_URL" | awk -F/ '{print $3}' | awk -F: '{print $1}')
echo "FDO_RV_DNS: ${FDO_RV_DNS}"


echo -n "waiting for manufacturer service to boot."
httpCode=500
while [ $httpCode != 200 ]
do
  echo -n "."
  sleep 2
  httpCode=$(curl -I -s -w "%{http_code}" -o /dev/null --digest -u ${USER_AUTH} --location --request GET 'http://localhost:8039/health')
done
echo ""

echo "setting rendezvous server location to ${FDO_RV_DNS}:${rvHttpPort}"
response=$(curl -s -w "%{http_code}" -D - --digest -u ${USER_AUTH} --location --request POST 'http://localhost:8039/api/v1/rvinfo' --header 'Content-Type: text/plain' --data-raw '[[[5,"'"${FDO_RV_DNS}"'"],[3,"'"${rvHttpPort}"'"],[12,1],[2,"'"${FDO_RV_DNS}"'"],[4,"'"${rvHttpsPort}"'"]]]')
code=$?
httpCode=$(tail -n1 <<< "$response")
chkHttp $code $httpCode "setting rendezvous server location"

echo "beginning device initialization"
(cd $deviceBinaryDir/device && java -jar device.jar)

echo "getting device info (alias, serial number, UUID)"
response=$(curl -s -w "\\n%{http_code}" --digest -u ${USER_AUTH} --location --request GET 'http://localhost:8039/api/v1/deviceinfo/10000' --header 'Content-Type: text/plain')
code=$?
httpCode=$(tail -n1 <<< "$response")
chkHttp $code $httpCode "getting device info"
serial=$(echo $response | grep -o '"serial_no":"[^"]*' | grep -o '[^"]*$')
echo "serial:$serial"
alias=$(echo $response | grep -o '"alias":"[^"]*' | grep -o '[^"]*$')
echo "alias:$alias"

echo "getting device public key"
httpCode=$(curl -k -s -w "%{http_code}" --digest -u ${USER_AUTH} --location --request GET "$HZN_FDO_SVC_URL/api/v1/certificate?alias=$alias" --header 'Content-Type: text/plain' -o public_key.pem)
chkHttp $? $httpCode "getting device public key"

echo "getting ownership voucher"
httpCode=$(curl -s -w "%{http_code}" --digest -u ${USER_AUTH} --location --request POST "http://localhost:8039/api/v1/mfg/vouchers/$serial" --header 'Content-Type: text/plain' --data-binary '@public_key.pem' -o owner_voucher.txt)
chkHttp $? $httpCode "getting ownership voucher"

#
## Install systemd service that will run at boot time to complete the SDO process
#cp fdo/fdo_to.service /lib/systemd/system
#chk $? 'copying sdo_to.service to systemd'
#systemctl enable sdo_to.service
#chk $? 'enabling sdo_to.service'
#echo "Systemd service sdo_to.service has been enabled"
## After importing the voucher to sdo-owner-services, if you want to you can initiate the sdo boot process by running: systemctl start sdo_to.service &
## And you can view the output with: journalctl -f --no-tail -u sdo_to.service