#!/bin/bash

# Used to start the FDO Owner and RV service the Horizon management hub (IoT platform/owner) needs.

# Defaults/constants
ownerPortDefault='8042'
rvPortDefault='8040'

workingDir='fdo'
deviceBinaryDir='pri-fidoiot-v1.1.3'
# These can be passed in via CLI args or env vars
ownerApiPort="${1:-$ownerPortDefault}"  # precedence: arg, or tls port, or non-tls port, or default
ownerPort=${HZN_FDO_SVC_URL:-$ownerPortDefault}
ownerExternalPort=${FDO_OWNER_EXTERNAL_PORT:-$ownerPort}
rvPort=${FDO_RV_PORT:-$rvPortDefault}
#VERBOSE='true'   # let it be set by the container provisioner
FDO_SUPPORT_RELEASE=${FDO_SUPPORT_RELEASE:-https://github.com/secure-device-onboard/release-fidoiot/releases/download/v1.1.3}

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat << EndOfMessage
Usage: ${0##*/}

Required environment variables: HZN_EXCHANGE_USER_AUTH, FDO_RV_PORT
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

if [[ -z "$HZN_EXCHANGE_USER_AUTH" || -z "$FDO_DEV" ]]; then  #-z "$HZN_FDO_SVC_URL" ||
    echo "Error: These environment variable must be set to access Owner services APIs: HZN_EXCHANGE_USER_AUTH, HZN_FDO_SVC_URL, FDO_DEV"
    exit 0
fi

# Get the other files we need from our git repo, by way of our device binaries tar file
if [[ ! -d $workingDir/$deviceBinaryDir ]]; then
  echo "$workingDir/$deviceBinaryDir DOES NOT EXIST, Run ./getFDO.sh for latest builds"
fi

# If docker isn't installed, do that
if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required, installing it..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    chk $? 'adding docker repository key'
    add-apt-repository "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" #makes you press ENTER
    chk $? 'adding docker repository'
    apt-get install -y docker-ce docker-ce-cli containerd.io
    chk $? 'installing docker'
fi

#make sure Docker daemon is running
sudo chmod 666 /var/run/docker.sock
# If haveged isnt installed, install it !

if ! command haveged --help >/dev/null 2>&1; then
    echo "Haveged is required, installing it"
    sudo apt-get install -y haveged
    chk $? 'installing haveged'
fi

# If docker-compose isn't installed, or isn't at least 1.21.0 (when docker-compose.yml version 2.4 was introduced), then install/upgrade it
# For the dependency on 1.21.0 or greater, see: https://docs.docker.com/compose/release-notes/
minVersion=1.21.2
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

if ! command psql --help >/dev/null 2>&1; then
    echo "PostgreSQL is not installed, installing it"
    sudo apt-get install -y postgresql
    chk $? 'installing postgresql'
fi

#zip and unzip are required for editing the manifest file of aio.jar so that it recognizes the postgresql jar
if ! command zip --help >/dev/null 2>&1; then
    echo "zip is not installed, installing it"
    sudo apt-get install -y zip
    chk $? 'installing zip'
fi

if ! command unzip --help >/dev/null 2>&1; then
    echo "unzip is not installed, installing it"
    sudo apt-get install -y unzip
    chk $? 'installing unzip'
fi

#check if database already exists
if ! psql -lqt | cut -d \| -f 1 | grep -qw 'fdo'; then
  #set up database
  echo "Creating PostgreSQL Database"
  sudo -i -u postgres createdb fdo
  echo "Creating PostgreSQL User: fdo"
  sudo -i -u postgres psql -c "CREATE USER fdo WITH PASSWORD 'fdo';"
  echo "Granting Privileges to PostgreSQL User: fdo"
  sudo -i -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE fdo TO fdo;"
fi

#download PostgreSQL JDBC jar
cd $workingDir/$deviceBinaryDir/owner/lib
httpCode=$(curl -w "%{http_code}" --progress-bar -L -O  https://jdbc.postgresql.org/download/postgresql-42.4.2.jar)
chkHttp $? $httpCode "getting $deviceBinaryTar"
httpCode=$(curl -w "%{http_code}" --progress-bar -L -O  https://repo1.maven.org/maven2/org/checkerframework/checker-qual/3.5.0/checker-qual-3.5.0.jar)
cd ../../../..

#edit manifest of aio.jar so that it will find the postgresql jar we just downloaded in the lib directory
unzip $workingDir/$deviceBinaryDir/owner/aio.jar
chk $? 'unzip'
sed -i -e 's/Class-Path:/Class-Path: lib\/postgresql-42.4.2.jar/' META-INF/MANIFEST.MF
chk $? 'sed classpath of aio.jar manifest'
sed -i -e 's/Class-Path:/Class-Path: lib\/checker-qual-3.5.0.jar/' META-INF/MANIFEST.MF
chk $? 'sed classpath of aio.jar manifest'
zip -r $workingDir/$deviceBinaryDir/owner/aio.jar org META-INF
chk $? 're-zip'
#clean-up files
rm -r org META-INF
chk $? 'deleting unzipped files'

#MODIFY postgresql.conf and pg_hba.conf to allow Postgresdb to listen -
sed -i -e 's/# TYPE  DATABASE        USER            ADDRESS                 METHOD/# TYPE  DATABASE        USER            ADDRESS                 METHOD\nhost    all             all             0.0.0.0\/0               md5/' /etc/postgresql/*/main/pg_hba.conf
chk $? 'sed pg_hba.conf'

sed -i -e "s/#listen_addresses =.*/listen_addresses = '*' /" /etc/postgresql/*/main/postgresql.conf
chk $? 'sed postgresql.conf'

#MODIFY /etc/hosts to include host.docker.internal
sed -i -e '1 a127.0.0.1 host.docker.internal' /etc/hosts
sed -i -e '1 a127.0.0.1 localhost' /etc/hosts

#then restart postgres service
sudo systemctl restart postgresql

echo "Using ports: Owner Service: $ownerPort"

# Run key generation script
# Declare an array of string with type
declare -a ScriptArray=("./demo_ca.sh" "./web_csr_req.sh" "./user_csr_req.sh" "./keys_gen.sh")

# Iterate the string array using for loop
for val in ${ScriptArray[@]}; do
   (cd $workingDir/$deviceBinaryDir/scripts && chmod +x $val)
   echo $val
   (cd $workingDir/$deviceBinaryDir/scripts && $val)
done

# CHANGE db_password.txt to fdo

echo "Running key generation script..."
# Replacing component credentials
(cd $workingDir/$deviceBinaryDir/scripts && sudo chmod 777 secrets/server-key.pem)
(cd $workingDir/$deviceBinaryDir/scripts && cp -r ./secrets/. ../owner/secrets)

#override auto-generated DB username and password
sed -i -e 's/db_user=.*/db_user=fdo/' $workingDir/$deviceBinaryDir/owner/service.env
sed -i -e 's/db_password=.*/db_password=fdo/' $workingDir/$deviceBinaryDir/owner/service.env

##configure hibernate.cfg.xml to use PostgreSQL database
sed -i -e 's/org.mariadb.jdbc.Driver/org.postgresql.Driver/' $workingDir/$deviceBinaryDir/owner/hibernate.cfg.xml
#sed -i -e 's/org.mariadb.jdbc.Driver/org.postgresql.Driver/' $workingDir/$deviceBinaryDir/owner/hibernate.cfg.xml
chk $? 'sed hibernate.cfg.xml driver_class'

#configure web.xml for http support (devolopment)
sed -i -e 's/<transport-guarantee>CONFIDENTIAL<\/transport-guarantee>/<transport-guarantee>NONE<\/transport-guarantee>/' $workingDir/$deviceBinaryDir/owner/WEB-INF/web.xml
sed -i -e 's/<auth-method>CLIENT-CERT<\/auth-method>/<auth-method>DIGEST<\/auth-method>\n<realm-name>Digest Authentication<\/realm-name>/' $workingDir/$deviceBinaryDir/owner/WEB-INF/web.xml

sed -i -e 's/jdbc:mariadb:\/\/host.docker.internal:3306\/emdb?useSSL=$(useSSL)/jdbc:postgresql:\/\/host.docker.internal:5432\/fdo/' $workingDir/$deviceBinaryDir/owner/service.yml
chk $? 'sed owner/service.yml connection url'
sed -i -e 's/org.hibernate.dialect.MariaDBDialect/org.hibernate.dialect.PostgreSQLDialect/' $workingDir/$deviceBinaryDir/owner/service.yml
chk $? 'sed owner/service.yml dialect'
sed -i -e 's/server.api.password: "null"/server.api.password: $(api_password)/' $workingDir/$deviceBinaryDir/owner/service.yml
chk $? 'sed owner/service.yml server.api.password'


sed -i -e '/secrets:/ s/./#&/' $workingDir/$deviceBinaryDir/owner/service.yml
chk $? 'sed owner/service.yml secrets'
sed -i -e '/- db_password/ s/./#&/' $workingDir/$deviceBinaryDir/owner/service.yml
chk $? 'sed owner/service.yml db_password'


if [[ "$FDO_DEV" == '1' || "$FDO_DEV" == 'true' ]]; then

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


    #Disabling https for development/testing purposes
    sed -i -e '/- org.fidoalliance.fdo.protocol.StandardOwnerSchemeSupplier/ s/./#&/' $workingDir/$deviceBinaryDir/owner/service.yml
    chk $? 'sed owner/service.yml'
    sed -i -e 's/#- org.fidoalliance.fdo.protocol.HttpOwnerSchemeSupplier/- org.fidoalliance.fdo.protocol.HttpOwnerSchemeSupplier/' $workingDir/$deviceBinaryDir/owner/service.yml
    chk $? 'sed owner/service.yml'


    #Use HZN_EXCHANGE_USER_AUTH for Owner services API password
    USER_AUTH=$HZN_EXCHANGE_USER_AUTH
    removeWord="iamapikey:"
    api_password=${USER_AUTH//$removeWord/}
    sed -i -e 's/api_user=.*/api_user=iamapikey \napi_password='$api_password'/' $workingDir/$deviceBinaryDir/owner/service.env
    sed -i -e 's/user-cert/user_cert/' $workingDir/$deviceBinaryDir/owner/service.env
    sed -i -e 's/ssl-ca/ssl_ca/' $workingDir/$deviceBinaryDir/owner/service.env
    sed -i -e 's/ssl-cert/ssl_cert/' $workingDir/$deviceBinaryDir/owner/service.env
    #Delete owner and rv service db files here if re-running in a test environment
    #rm $workingDir/$deviceBinaryDir/owner/app-data/emdb.mv.db && $workingDir/$deviceBinaryDir/rv/app-data/emdb.mv.db

else

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
    #Comment out network_mode: host for Owner services. Need TLS work
    sed -i -e '/network_mode: host/ s/./#&/' $workingDir/$deviceBinaryDir/owner/docker-compose.yml

fi

#Run the service
echo "Starting owner service..."
#(cd $workingDir/$deviceBinaryDir/owner && java -jar aio.jar)
(cd $workingDir/$deviceBinaryDir/owner && docker-compose up --build)

