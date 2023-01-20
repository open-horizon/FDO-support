#!/bin/bash

# Used to start the FDO Owner and RV service the Horizon management hub (IoT platform/owner) needs.
# Defaults/constants
ownerPortDefault='8042'
rvPortDefault='8040'
ocsApiPortDefault='9008'

# These can be passed in via CLI args or env vars
ocsDbDir="${1:-"ocs-db/"}"
ocsApiPort="${2:-${SDO_OCS_API_TLS_PORT:-${SDO_OCS_API_PORT:-$ocsApiPortDefault}}}"  # precedence: arg, or tls port, or non-tls port, or default

workingDir='/home/fdouser'
deviceBinaryDir='pri-fidoiot-v1.1.4'
# These can be passed in via CLI args or env vars
tmp_pass=`head -c 10 /dev/random | base64`
random_pass="apiUser:"$tmp_pass
FDO_API_PWD="${FDO_API_PWD:-$random_pass}"
ownerApiPort="${1:-$ownerPortDefault}"  # precedence: arg, or tls port, or non-tls port, or default
ownerPort=${HZN_FDO_SVC_URL:-$ownerPortDefault}
ownerExternalPort=${FDO_OWNER_EXTERNAL_PORT:-$ownerPort}
rvPort=${FDO_RV_PORT:-$rvPortDefault}
dbPort=${FDO_DB_PORT:-5432}
HZN_FDO_API_URL="http://$FDO_OPS_URL"

#VERBOSE='true'   # let it be set by the container provisioner
FDO_SUPPORT_RELEASE=${FDO_SUPPORT_RELEASE:-https://github.com/secure-device-onboard/release-fidoiot/releases/download/v1.1.4}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat << EndOfMessage
Usage: ${0##*/}

Required environment variables: FDO_API_PWD
EndOfMessage
    exit 1
fi

# Only echo this if VERBOSE is 1 or true
verbose() {
    if [[ "$VERBOSE" == '1' || "$VERBOSE" == 'true' ]]; then
        echo 'Verbose:' "$*"
    fi
}

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

###### MAIN CODE ######
if [[ -z "$FDO_API_PWD" || -z "$HZN_EXCHANGE_URL" || -z "$HZN_FSS_CSSURL" ]]; then  #-z "$HZN_FDO_SVC_URL" ||
    echo "Error: These environment variable must be set to access Owner services APIs: FDO_API_PWD, HZN_EXCHANGE_URL, HZN_FSS_CSSURL"
    exit 0
fi

# Get the other files we need from our git repo, by way of our device binaries tar file
if [[ ! -d $workingDir/$deviceBinaryDir ]]; then
  echo "$workingDir/$deviceBinaryDir DOES NOT EXIST, Run ./getFDO.sh for latest builds"
fi

if [[ ${FDO_API_PWD} != *"apiUser:"* || $FDO_API_PWD == *$'\n'* || $FDO_API_PWD == *'|'* ]]; then
    # newlines and vertical bars aren't allowed in the pw, because they cause the sed cmds below to fail
    echo "Error: FDO_API_PWD must include "apiUser:" as a prefix and not contain newlines or '|'"
    exit 1
fi

if [[ -z "$FDO_DB_USER" || -z "$FDO_DB_PASSWORD" || -z "$FDO_DB_URL" ]]; then
    echo "Error: You must set the database environment variables FDO_DB_USER, FDO_DB_PASSWORD, and FDO_DB_URL"
    exit 0
fi

echo "Using ports: Owner Service: $ownerPort"

# Run key generation script
# Declare an array of string with type
declare -a ScriptArray=("./demo_ca.sh" "./web_csr_req.sh" "./user_csr_req.sh" "./keys_gen.sh")

# Iterate the string array using for loop
for val in ${ScriptArray[@]}; do
   (cd $workingDir/$deviceBinaryDir/scripts && chmod +x $val)
   (cd $workingDir/$deviceBinaryDir/scripts && $val)
done

echo "Running key generation script..."
# Replacing component credentials
(cd $workingDir/$deviceBinaryDir/scripts && chmod 777 secrets/server-key.pem)
(cd $workingDir/$deviceBinaryDir/scripts && cp -r ./secrets/. ../owner/secrets)

#override auto-generated DB username and password with variables
sed -i -e "s/db_user=.*/db_user=$FDO_DB_USER/" $workingDir/$deviceBinaryDir/owner/service.env
sed -i -e "s/db_password=.*/db_password=$FDO_DB_PASSWORD/" $workingDir/$deviceBinaryDir/owner/service.env

##configure hibernate.cfg.xml to use PostgreSQL database
sed -i -e 's/org.mariadb.jdbc.Driver/org.postgresql.Driver/' $workingDir/$deviceBinaryDir/owner/hibernate.cfg.xml
#sed -i -e 's/org.mariadb.jdbc.Driver/org.postgresql.Driver/' $workingDir/$deviceBinaryDir/owner/hibernate.cfg.xml
chk $? 'sed hibernate.cfg.xml driver_class'

#configure web.xml for http support (devolopment)
sed -i -e 's/<transport-guarantee>CONFIDENTIAL<\/transport-guarantee>/<transport-guarantee>NONE<\/transport-guarantee>/' $workingDir/$deviceBinaryDir/owner/WEB-INF/web.xml
sed -i -e 's/<auth-method>CLIENT-CERT<\/auth-method>/<auth-method>DIGEST<\/auth-method>\n<realm-name>Digest Authentication<\/realm-name>/' $workingDir/$deviceBinaryDir/owner/WEB-INF/web.xml

#override JDBC URL. This should be a Postgres DB URL because we default to that dialect below
sed -i -e "s|jdbc:mariadb:\/\/host.docker.internal:3306\/emdb?useSSL=\$(useSSL)|$FDO_DB_URL|" $workingDir/$deviceBinaryDir/owner/service.yml
chk $? 'sed owner/service.yml connection url'
sed -i -e 's/org.hibernate.dialect.MariaDBDialect/org.hibernate.dialect.PostgreSQLDialect/' $workingDir/$deviceBinaryDir/owner/service.yml
chk $? 'sed owner/service.yml dialect'

sed -i -e 's/server.api.user:.*/server.api.user: apiUser/' $workingDir/$deviceBinaryDir/owner/service.yml
chk $? 'sed owner/service.yml server.api.user'
sed -i -e 's/server.api.password: "null"/server.api.password: $(api_password)/' $workingDir/$deviceBinaryDir/owner/service.yml
chk $? 'sed owner/service.yml server.api.password'


sed -i -e '/secrets:/ s/./#&/' $workingDir/$deviceBinaryDir/owner/service.yml
chk $? 'sed owner/service.yml secrets'
sed -i -e '/- db_password/ s/./#&/' $workingDir/$deviceBinaryDir/owner/service.yml
chk $? 'sed owner/service.yml db_password'

#need java installed in order to generate the SSL keystore for HTTPS
# If java 11 isn't installed, do that
if java -version 2>&1 | grep version | grep -q 11.; then
    echo "Found java 11"
else
    echo "Java 11 not found, installing it..."
    apt-get update && apt-get install -y openjdk-11-jre-headless
    chk $? 'installing java 11'
fi

#    echo "Using local testing configuration, because FDO_DEV=$FDO_DEV"
#    #Configuring Owner services for development, If you are running the local
#    #development RV server, then you must disable the port numbers for rv/docker-compose.yml & owner/docker-compose.yml -- DO NOT COMMENT OUT


#Disabling https
sed -i -e '/- org.fidoalliance.fdo.protocol.StandardOwnerSchemeSupplier/ s/./#&/' $workingDir/$deviceBinaryDir/owner/service.yml
chk $? 'sed owner/service.yml'
sed -i -e 's/#- org.fidoalliance.fdo.protocol.HttpOwnerSchemeSupplier/- org.fidoalliance.fdo.protocol.HttpOwnerSchemeSupplier/' $workingDir/$deviceBinaryDir/owner/service.yml
chk $? 'sed owner/service.yml'


#Use internally set PW for Owner services API password
USER_AUTH=$FDO_API_PWD
removeWord="apiUser:"
api_password=${USER_AUTH//$removeWord/}
sed -i -e 's/api_user=.*/api_user=apiUser \napi_password='$api_password'/' $workingDir/$deviceBinaryDir/owner/service.env
sed -i -e 's/user-cert/user_cert/' $workingDir/$deviceBinaryDir/owner/service.env
sed -i -e 's/ssl-ca/ssl_ca/' $workingDir/$deviceBinaryDir/owner/service.env
sed -i -e 's/ssl-cert/ssl_cert/' $workingDir/$deviceBinaryDir/owner/service.env
#Delete owner and rv service db files here if re-running in a test environment
#rm $workingDir/$deviceBinaryDir/owner/app-data/emdb.mv.db && $workingDir/$deviceBinaryDir/rv/app-data/emdb.mv.db



  #Production Environment HTTPS

#        ssl_password=$(cat $workingDir/$deviceBinaryDir/owner/service.env | grep "ssl_password" | awk -F= '{print $2}')
#        #generate SSL cert and put it in a keystore
#        FDO_OWNER_DNS=$(echo "$HZN_FDO_SVC_URL" | awk -F/ '{print $3}' | awk -F: '{print $1}')
#        echo "FDO_OWNER_DNS: ${HZN_FDO_SVC_URL}"
#        keytool -genkeypair -alias ssl -keyalg RSA -keysize 2048 -dname "CN='"${FDO_OWNER_DNS}"'" -keypass ${ssl_password} -validity 100 -storetype PKCS12 -keystore ssl.p12 -storepass ${ssl_password}
#
#        #we must start the owner service, give it the SSL certificate via HTTP, then reboot it in order to enable HTTPS
#        (cd $workingDir/$deviceBinaryDir/owner && docker-compose up --build -d)
#        echo -n "waiting for owner service to boot."
#        httpCode=500
#        while [ $httpCode != 200 ]
#        do
#          echo -n "."
#          sleep 2
#          httpCode=$(curl -I -s -w "%{http_code}" -o /dev/null --digest -u ${USER_AUTH} --location --request GET 'http://localhost:8042/health')
#        done
#        echo ""
#
#        echo "adding SSL certificate to owner service"
#        response=$(curl -s -w "%{http_code}" -D - --digest -u ${USER_AUTH} --location --request POST 'http://localhost:8042/api/v1/certificate?filename=ssl.p12' --header 'Content-Type: text/plain' --data-binary '@ssl.p12')
#        code=$?
#        httpCode=$(tail -n1 <<< "$response")
#        chkHttp $code $httpCode "adding SSL certificate to owner service"
#
#        echo "shutting down owner service"
#        docker stop pri-fdo-owner
#        docker rm pri-fdo-owner
#

#Run the service
echo "Starting owner service..."
(cd $workingDir/$deviceBinaryDir/owner && nohup java -jar aio.jar &)
#(cd $workingDir/$deviceBinaryDir/owner && docker-compose up --build)

echo "Starting ocs-api service..."
./ocs-api/linux/ocs-api $ocsApiPort $ocsDbDir


