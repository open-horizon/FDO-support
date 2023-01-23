#!/bin/bash

# Run the sdo-owner-services container on the Horizon management hub (IoT platform/owner.

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat << EndOfMessage
Usage: ${0##*/} [<image-version>]
Arguments:
  <image-version>  The image tag to use. Defaults to '1.10'
Required environment variables:
  HZN_EXCHANGE_URL - the external URL of the exchange (used for authentication delegation and in the configuration of the device)
  HZN_FSS_CSSURL - the external URL of CSS (used in the configuration of the device)
  HZN_MGMT_HUB_CERT - the base64 encoded content of the management hub cluster ingress self-signed certificate (can be set to 'N/A' if the mgmt hub does not require a cert). If set, this certificate is given to the edge nodes in the HZN_MGMT_HUB_CERT_PATH variable.
Recommended environment variables:
  FDO_OCS_SVC_HOST - external hostname or IP that the RV should tell the device to reach OPS at. Defaults to the host's hostname but that is only sufficient if it is resolvable and externally accessible.
Additional environment variables (that do not usually need to be set):
  FDO_RV_PORT - port number RV should listen on *inside* the container. Default is 8040.
  FDO_OPS_PORT - port number OPS should listen on *inside* the container. Default is 8042.
  FDO_OPS_EXTERNAL_PORT - external port number that RV should tell the device to reach OPS at. Defaults to the internal OPS port number.
  FDO_OCS_SVC_PORT - port number OCS-API should listen on for HTTP. Default is 9008.
  FDO_OCS_SVC_TLS_PORT - port number OCS-API should listen on for TLS. Default is the value of FDO_OCS_SVC_PORT. (OCS API does not support TLS and non-TLS simultaneously.) Note: you can not set this to 9009, because OCS listens on that port internally.
  FDO_SVC_CERT_HOST_PATH - path on this host of the directory holding the certificate and key files named sdoapi.crt and sdoapi.key, respectively. Default is for the OCS-API to not support TLS.
  FDO_SVC_CERT_PATH - path that the directory holding the certificate and key files is mounted to within the container. Default is /home/sdouser/ocs-api-dir/keys .
  EXCHANGE_INTERNAL_URL - how OCS-API should contact the exchange for authentication. Will default to HZN_EXCHANGE_URL.
  EXCHANGE_INTERNAL_CERT - the base64 encoded certificate that OCS-API should use when contacting the exchange for authentication. Will default to the sdoapi.crt file in the directory specified by FDO_SVC_CERT_HOST_PATH.
  EXCHANGE_INTERNAL_RETRIES - the maximum number of times to try connecting to the exchange during startup to verify the connection info.
  EXCHANGE_INTERNAL_INTERVAL - the number of seconds to wait between attempts to connect to the exchange during startup
  FDO_GET_PKGS_FROM - where to have the edge devices get the horizon packages from. If set to css:, it will be expanded to css:/api/v1/objects/IBM/agent_files. Or it can be set to something like https://github.com/open-horizon/anax/releases/latest/download (which is the default).
  FDO_GET_CFG_FILE_FROM - where to have the edge devices get the agent-install.cfg file from. If set to css: (the default), it will be expanded to css:/api/v1/objects/IBM/agent_files/agent-install.cfg. Or it can set to agent-install.cfg, which means using the file that the SDO owner services creates.
  FDO_RV_VOUCHER_TTL - tell the rendezvous server to persist vouchers for this number of seconds (default 7200).
  VERBOSE - set to 1 or 'true' for more verbose output.
EndOfMessage
    exit 1
fi

# These env vars are required
if [[ -z "$HZN_EXCHANGE_URL" || -z "$HZN_FSS_CSSURL" || -z "$HZN_MGMT_HUB_CERT" ]]; then
    echo "Error: These environment variable must be set to access Owner services APIs: HZN_EXCHANGE_URL, HZN_FSS_CSSURL, HZN_MGMT_HUB_CERT"
    exit 0
fi
# If their mgmt hub doesn't need a self-signed cert, we chose to make them set HZN_MGMT_HUB_CERT to 'N/A' to ensure they didn't just forget to specify this env var
if [[ $HZN_MGMT_HUB_CERT == 'N/A' || $HZN_MGMT_HUB_CERT == 'n/a' ]]; then
    unset HZN_MGMT_HUB_CERT
fi

if [[ -z "$FDO_DB_USER" || -z "$FDO_DB_PASSWORD" || -z "$FDO_DB_URL" ]]; then
    echo "Error: You must set the database environment variables FDO_DB_USER, FDO_DB_PASSWORD, and FDO_DB_URL"
    exit 0
fi

EXCHANGE_INTERNAL_CERT="${EXCHANGE_INTERNAL_CERT:-$HZN_MGMT_HUB_CERT}"
VERSION="${1:-latest}"


DOCKER_REGISTRY=${DOCKER_REGISTRY:-openhorizon}
FDO_DOCKER_IMAGE=${FDO_DOCKER_IMAGE:-fdo-owner-services}
containerHome=/home/fdouser

#SDO_OCS_DB_HOST_DIR=${SDO_OCS_DB_HOST_DIR:-$PWD/ocs-db}  # we are now using a named volume instead of a host dir
# this is where OCS needs it to be
#SDO_OCS_DB_CONTAINER_DIR=${SDO_OCS_DB_CONTAINER_DIR:-$containerHome/ocs/config/db}

export FDO_OCS_SVC_PORT=${FDO_OCS_SVC_PORT:-9008}
export FDO_OCS_SVC_TLS_PORT=${FDO_OCS_SVC_TLS_PORT:-$FDO_OCS_SVC_PORT}
#export SDO_API_CERT_PATH=${SDO_API_CERT_PATH:-/home/fdouser/ocs-api-dir/keys}   # this is the path *within* the container. Export SDO_API_CERT_HOST_PATH to use a cert/key.
export FDO_RV_PORT=${FDO_RV_PORT:-8040}   # the port RV should listen on *inside* the container
export FDO_OPS_PORT=${FDO_OPS_PORT:-8042}   # the port OPS should listen on *inside* the container. FDO_API_PORT or HZN_FDO_API_URL
export FDO_OPS_EXTERNAL_PORT=${FDO_OPS_EXTERNAL_PORT:-$FDO_OPS_PORT}   # the external port the device should use to contact OPS
export dbPort=${FDO_DB_PORT:-5432}
# Define the OPS hostname the to0scheduler tells RV to direct the booting device to
export FDO_OPS_HOST=${FDO_OPS_HOST:-$(hostname)}   # currently only used for OPS
HZN_FDO_API_URL="http://"$FDO_OPS_HOST":"$FDO_OPS_PORT


FDO_GET_PKGS_FROM=${FDO_GET_PKGS_FROM:-https://github.com/open-horizon/anax/releases/latest/download}
FDO_GET_CFG_FILE_FROM=${FDO_GET_CFG_FILE_FROM:-css:}

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

# If docker isn't installed, do that
if ! command -v docker >/dev/null 2>&1; then
    if [[ $(whoami) != 'root' ]]; then
        echo "Error: docker is not installed, but we are not root, so can not install it for you. Exiting"
        exit 2
    fi
    echo "Docker is required, installing it..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    chk $? 'adding docker repository key'
    add-apt-repository "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    chk $? 'adding docker repository'
    apt-get install -y docker-ce docker-ce-cli containerd.io
    chk $? 'installing docker'
fi

if ! command psql --help >/dev/null 2>&1; then
    echo "PostgreSQL is not installed, installing it"
    sudo apt-get install -y postgresql
    chk $? 'installing postgresql'
fi

#MODIFY postgresql.conf and pg_hba.conf to allow Postgresdb to listen -
#sed -i -e 's/# TYPE  DATABASE        USER            ADDRESS                 METHOD/# TYPE  DATABASE        USER            ADDRESS                 METHOD\nhost    all             all             0.0.0.0\/0               md5/' /etc/postgresql/*/main/pg_hba.conf
#chk $? 'sed pg_hba.conf'
##
#sed -i -e "s/#listen_addresses =.*/listen_addresses = '*' /" /etc/postgresql/*/main/postgresql.conf
#chk $? 'sed postgresql.conf'

# Set the ocs-api port appropriately (the TLS port takes precedence, if set)
portNum=${FDO_OCS_SVC_TLS_PORT:-$FDO_OCS_SVC_PORT}


#For testing purposes
if [[ "$DOCKER_DONTPULL" == '1' || "$DOCKER_DONTPULL" == 'true' ]]; then
    echo "Using local Dockerfile, because DOCKER_DONTPULL=$DOCKER_DONTPULL"
else
# If VERSION is a generic tag like latest, 1.10, or testing we have to make sure we pull the most recent
    docker pull $DOCKER_REGISTRY/$FDO_DOCKER_IMAGE:$VERSION
    chk $? 'Pulling from Docker Hub...'
fi

# Run the service container --mount "type=volume,src=fdo-ocs-db,dst=$FDO_OCS_DB_CONTAINER_DIR" $privateKeyMount $certKeyMount
docker run --name $FDO_DOCKER_IMAGE -d -p $portNum:$portNum -p $FDO_OPS_PORT:$FDO_OPS_PORT -e "FDO_DB_PASSWORD:$FDO_DB_PASSWORD" -e "FDO_DB_USER:$FDO_DB_USER" -e "FDO_DB_URL=$FDO_DB_URL" -e "HZN_FDO_API_URL=$HZN_FDO_API_URL" -e "FDO_API_PWD=$FDO_API_PWD" -e "FDO_OCS_DB_PATH=$FDO_OCS_DB_CONTAINER_DIR" -e "FDO_OCS_SVC_PORT=$FDO_OCS_SVC_PORT" -e "FDO_OCS_SVC_TLS_PORT=$FDO_OCS_SVC_TLS_PORT" -e "FDO_SVC_CERT_PATH=$FDO_SVC_CERT_PATH" -e "FDO_RV_PORT=$FDO_RV_PORT" -e "FDO_OPS_PORT=$FDO_OPS_PORT" -e "FDO_OPS_EXTERNAL_PORT=$FDO_OPS_EXTERNAL_PORT" -e "HZN_EXCHANGE_URL=$HZN_EXCHANGE_URL" -e "EXCHANGE_INTERNAL_URL=$EXCHANGE_INTERNAL_URL" -e "EXCHANGE_INTERNAL_CERT=$EXCHANGE_INTERNAL_CERT" -e "EXCHANGE_INTERNAL_RETRIES=$EXCHANGE_INTERNAL_RETRIES" -e "EXCHANGE_INTERNAL_INTERVAL=$EXCHANGE_INTERNAL_INTERVAL" -e "HZN_FSS_CSSURL=$HZN_FSS_CSSURL" -e "HZN_MGMT_HUB_CERT=$HZN_MGMT_HUB_CERT" -e "FDO_GET_PKGS_FROM=$FDO_GET_PKGS_FROM" -e "FDO_GET_CFG_FILE_FROM=$FDO_GET_CFG_FILE_FROM" -e "FDO_RV_VOUCHER_TTL=$FDO_RV_VOUCHER_TTL" -e "VERBOSE=$VERBOSE" $DOCKER_REGISTRY/$FDO_DOCKER_IMAGE:$VERSION