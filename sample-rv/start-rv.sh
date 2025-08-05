#!/bin/bash

# Helper function to display usage information
usage() {
    exitCode=${1:-0}
    cat << EndOfMessage
Usage: ${0##*/}

Required Environment Variables:
  FDO_RV_DB:                  Database name for FDO's rendezvous service
  FDO_RV_DB_USER:             Database user for FDO's rendezvous service
  FDO_RV_DB_PASSWORD:         Database password for FDO's rendezvous service
  FDO_RV_DB_PORT:             Database port for FDO's rendezvous service
  POSTGRES_HOST_AUTH_METHOD:  PostgreSQL authentication method
  POSTGRES_IMAGE_TAG:         PostgreSQL image tag version
  HZN_DOCK_NET:               Horizon Docker network name
  FDO_DEVICE_ONBOARD_REL_VER: Release version for FIDO device onboarding
  FDO_RV_SVC_AUTH:            Authentication credentials for the rendezvous service
  FDO_SUPPORT_RELEASE:        FDO support release URL
  FDO_RV_POSTGRES_CONTAINER:  Postgres container name for rendezvous service

${0##*/} must be run in a directory where it has access to create a few files and directories.
EndOfMessage
    exit $exitCode
}

chk() {
  if [ "$1" -ne 0 ]; then
    echo "Error: $2"
    exit "$1"
  fi
}

chk_http() {
  local statusCode=$1
  local httpCode=$2
  local message=$3

  if [ "$statusCode" -ne 0 ]; then
    echo "Failed to get file, HTTP status code: $httpCode. $message"
    exit "$statusCode"
  fi
}

check_root_user() {
  if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
  else
    echo "Running as root."
  fi
}

is_Ubuntu2x() {
  grep -qi 'ubuntu' /etc/os-release
}

is_RHEL() {
  grep -qi 'rhel' /etc/os-release
}

is_Fedora() {
  grep -qi 'fedora' /etc/os-release
}

install_java() {
  echo "Java 17 not found, installing..."

  if is_Ubuntu2x; then
    apt-get update
    apt-get install -y openjdk-17-jre-headless
    chk $? "installing Java 17 on Ubuntu"

  elif is_RHEL || is_Fedora; then
    dnf install -y java-17-openjdk
    chk $? "installing Java 17 on RHEL/Fedora"

  else
    echo "Unsupported OS for Java installation"
    exit 1
  fi

  echo "Java 17 installed successfully"
}

check_and_install_java() {
  java_version=$(java -version 2>&1 | awk -F[\".] '/version/ {print $2}')

  if [[ "$java_version" == "17" ]]; then
    echo "Java 17 is already installed"
  else
    install_java
  fi
}

install_docker() {
  echo "Docker is required, installing it..."

  if is_Ubuntu2x; then
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
    chk $? "installing Docker prerequisites"

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    chk $? "adding Docker GPG key"

    add-apt-repository \
      "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable"
    chk $? "adding Docker repository"

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io
    chk $? "installing Docker on Ubuntu"

  elif is_RHEL; then
    dnf -y install dnf-plugins-core
    chk $? "installing dnf plugins"

    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    chk $? "adding Docker repository"

    dnf install -y docker-ce docker-ce-cli containerd.io
    chk $? "installing Docker on RHEL"

  elif is_Fedora; then
    dnf install -y moby-engine
    chk $? "installing Docker on Fedora"

  else
    echo "Unsupported OS for Docker installation"
    exit 1
  fi

  echo "Docker installed successfully"
}

check_and_install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    install_docker
  else
    echo "Docker is already installed"
  fi
}

create_and_switch_directory() {
  local workingDir="$1"

  # Create the directory if it doesn't exist
  if [[ ! -d "$workingDir" ]]; then
    mkdir -p "$workingDir"
    chk $? "Failed to create directory: $workingDir"
    echo "Directory created: $workingDir"
  fi

  # Get absolute paths to compare
  currentDir="$(realpath "$PWD")"
  targetDir="$(realpath "$workingDir")"

  # Change directory only if not already in it
  if [[ "$currentDir" != "$targetDir" ]]; then
    cd "$workingDir"
    chk $? "Failed to switch to directory: $workingDir"
    echo "Switched to $workingDir"
  else
    echo "Already in $workingDir"
  fi
}

download_and_extract_device_binaries() {
  deviceBinaryTar="$deviceBinaryDir.tar.gz"
  deviceBinaryUrl="$FDO_SUPPORT_RELEASE/$deviceBinaryTar"

  # Check if the device binary directory already exists
  if [[ ! -d $deviceBinaryDir ]]; then
    echo "$deviceBinaryDir DOES NOT EXIST"

    echo "Removing old device binary tar files, and getting and unpacking $deviceBinaryDir ..."

    # Remove old device binary files, ensuring only one binary dir exists
    rm -rf $workingDir/pri-fidoiot-*
    chk $? "removing old device binary files"

    # Download the tar file
    echo "Downloading $deviceBinaryUrl"
    httpCode=$(curl -w "%{http_code}" --progress-bar -L -O $deviceBinaryUrl)
    chk_http $? $httpCode "getting $deviceBinaryTar"

    # Extract the tar file
    echo "Extracting $deviceBinaryTar ..."
    tar -zxf $deviceBinaryTar
    chk $? "extracting $deviceBinaryTar"
  else
    echo "$deviceBinaryDir already exists, skipping download and extraction."
  fi
}

generate_and_copy_keys() {
    echo "Running key generation script..."

    # Navigate to the device binary scripts directory
    cd "$PWD/$deviceBinaryDir/scripts" || { echo "Failed to navigate to $deviceBinaryDir/scripts"; exit 1; }

    # Make scripts executable
    chmod +x ./demo_ca.sh ./user_csr_req.sh ./web_csr_req.sh ./keys_gen.sh
    chk $? "making scripts executable"

    # Run the scripts in sequence
    ./demo_ca.sh && ./user_csr_req.sh && ./web_csr_req.sh && ./keys_gen.sh
    chk $? "running key generation scripts"

    # Create the secrets directory and copy the generated secrets
    mkdir -p ../rv/secrets
    chk $? "creating secrets directory"

    cp -r ./secrets/. ../rv/secrets/.
    chk $? "copying secrets"

    # Return to the previous directory
    cd ../../ || { echo "Failed to return to previous directory"; exit 1; }

    echo "Key generation and secrets copy completed."
}

generateToken() { head -c 1024 /dev/urandom | base64 | tr -cd "[:alpha:][:digit:]"  | head -c $1; }

main() {
    # Set environment variables only if not already set
    export FDO_RV_DB="${FDO_RV_DB:-fdo_rv}"
    export FDO_RV_DB_USER="${FDO_RV_DB_USER:-fdouser}"
    export FDO_RV_DB_PASSWORD="${FDO_RV_DB_PASSWORD:-$(generateToken 30)}"
    export FDO_RV_DB_PORT="${FDO_RV_DB_PORT:-5435}"
    export POSTGRES_HOST_AUTH_METHOD="${POSTGRES_HOST_AUTH_METHOD:-scram-sha-256}"
    export POSTGRES_IMAGE_TAG="${POSTGRES_IMAGE_TAG:-17}"
    export HZN_DOCK_NET="${HZN_DOCK_NET:-hzn_horizonnet}"
    export FIDO_DEVICE_ONBOARD_REL_VER=${FIDO_DEVICE_ONBOARD_REL_VER:-1.1.10} # https://github.com/fido-device-onboard/release-fidoiot/releases
    export FDO_RV_SVC_AUTH=${FDO_RV_SVC_AUTH:-apiUser:$(generateToken 30)}
    export FDO_SUPPORT_RELEASE=${FDO_SUPPORT_RELEASE:-https://github.com/fido-device-onboard/release-fidoiot/releases/download/v$FIDO_DEVICE_ONBOARD_REL_VER}
    export FDO_RV_POSTGRES_CONTAINER="postgres-fdo-rv-service"
    workingDir=fdo
    deviceBinaryDir='pri-fidoiot-v'$FIDO_DEVICE_ONBOARD_REL_VER

    check_root_user
    create_and_switch_directory "$workingDir"
    check_and_install_java
    check_and_install_docker

    # Start a DB container for FDO's rv service
    docker rm -f $FDO_RV_POSTGRES_CONTAINER
    docker run -d \
        -e "POSTGRES_DB=$FDO_RV_DB" \
        -e "POSTGRES_PASSWORD=$FDO_RV_DB_PASSWORD" \
        -e "POSTGRES_USER=$FDO_RV_DB_USER" \
        -e "POSTGRES_HOST_AUTH_METHOD=$POSTGRES_HOST_AUTH_METHOD" \
        -e "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=scram-sha-256" \
        --health-cmd="pg_isready -U $FDO_RV_DB_USER" \
        --health-interval=15s \
        --health-retries=3 \
        --health-timeout=5s \
        --name $FDO_RV_POSTGRES_CONTAINER \
        --network="$HZN_DOCK_NET" \
        -p "$FDO_RV_DB_PORT":5432 \
        postgres:"$POSTGRES_IMAGE_TAG"

    download_and_extract_device_binaries
    generate_and_copy_keys

    api_user=$(echo "$FDO_RV_SVC_AUTH" | awk -F: '{print $1}')
    api_password=$(echo "$FDO_RV_SVC_AUTH" | awk -F: '{print $2}')
    rvServiceYmlPath=$PWD/$deviceBinaryDir/rv/service.yml
    rvServiceEnvPath=$PWD/$deviceBinaryDir/rv/service.env

    # Replace db_user and db_password
    sed -i -e "s/^db_user=.*/db_user=$FDO_RV_DB_USER/" "$rvServiceEnvPath"
    chk $? 'sed rv/service.env db_user'
    sed -i -e "s/^db_password=.*/db_password=$FDO_RV_DB_PASSWORD/" "$rvServiceEnvPath"
    chk $? 'sed rv/service.env db_password'

    # Configure rv/hibernate.cfg.xml to use PostgreSQL driver
    sed -i -e "s/org.mariadb.jdbc.Driver/org.postgresql.Driver/" "$PWD/$deviceBinaryDir/rv/hibernate.cfg.xml"
    chk $? 'sed rv/hibernate.cfg.xml driver_class'

    # Replace hibernate.connection.username and password
    sed -i -e "0,/hibernate.connection.username:/s|hibernate.connection.username:.*|hibernate.connection.username: $FDO_RV_DB_USER|" "$rvServiceYmlPath"
    chk $? 'sed rv/service.yml hibernate.connection.username'
    sed -i -e "0,/hibernate.connection.password:/s|hibernate.connection.password:.*|hibernate.connection.password: $FDO_RV_DB_PASSWORD|" "$rvServiceYmlPath"
    chk $? 'sed rv/service.yml hibernate.connection.password'
  
    # Replace JDBC URL
    sed -i -e "0,/hibernate.connection.url:/s|hibernate.connection.url:.*|hibernate.connection.url: jdbc:postgresql://postgres-fdo-rv-service:5432/fdo_rv|" "$rvServiceYmlPath"
    chk $? 'sed rv/service.yml hibernate.connection.url'

    # Replace API password
    sed -i -e "0,/server.api.password:/s|server.api.password:.*|server.api.password: \"$api_password\"|" "$rvServiceYmlPath"
    chk $? 'sed rv/service.yml server.api.password'

    # Update dialect
    sed -i -e "0,/hibernate.dialect:/s|hibernate.dialect:.*|hibernate.dialect: org.hibernate.dialect.PostgreSQLDialect|" "$rvServiceYmlPath"
    chk $? 'sed rv/service.yml hibernate.dialect'

    # Comment out secrets block
    sed -i -e '/secrets:/ s/^/#/' "$rvServiceYmlPath"
    sed -i -e '/- db_password/ s/^/#/' "$rvServiceYmlPath"

    # Replace port numbers
    sed -i 's/^[[:space:]]*http_port: 8040$/  http_port: 80/' "$rvServiceYmlPath"
    chk $? 'sed rv/service.yml http_port: 8040'
    sed -i 's/^[[:space:]]*https_port: 8041$/  https_port: 443/' "$rvServiceYmlPath"
    chk $? 'sed rv/service.yml https_port: 8041'

    # Uncomment UntrustedRendezvousAcceptFunction (preserve indentation)
    sed -i 's|^\([[:space:]]*\)#- org\.fidoalliance\.fdo\.protocol\.UntrustedRendezvousAcceptFunction|\1- org.fidoalliance.fdo.protocol.UntrustedRendezvousAcceptFunction|' "$rvServiceYmlPath"

    # Comment TrustedRendezvousAcceptFunction (preserve indentation)
    sed -i 's|^\([[:space:]]*\)- org\.fidoalliance\.fdo\.protocol\.db\.TrustedRendezvousAcceptFunction|\1#- org.fidoalliance.fdo.protocol.db.TrustedRendezvousAcceptFunction|' "$rvServiceYmlPath"

    echo "Starting RV service..."
    sudo chmod 666 /var/run/docker.sock
    cd ./$deviceBinaryDir/rv || exit
    # Adding container to open horizon docker network.
    sed -i -e 's/version:.*/&\n\nnetworks:\n  horizonnet:\n    name: hzn_horizonnet\n    driver: bridge/' ./docker-compose.yml
    sed -i -e 's/restart:.*/&\n    networks:\n      - horizonnet/' ./docker-compose.yml
    docker-compose up --build -d
}

# Execute main function
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage 0
fi

main "$@"