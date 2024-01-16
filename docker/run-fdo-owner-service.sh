#!/bin/bash

# Run the sdo-owner-services container on the Horizon management hub (IoT platform/owner.

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat << EndOfMessage
Usage: ${0##*/} [<image-version>]
Arguments:
  <image-version>  The image tag to use. Defaults to '1.4.0'
Required environment variables:
  HZN_MGMT_HUB_CERT: the base64 encoded content of the management hub cluster ingress self-signed certificate (can be set to 'N/A' if the mgmt hub does not require a cert). If set, this certificate is given to the edge nodes in the HZN_MGMT_HUB_CERT_PATH variable.

Optional environment variables (that do not usually need to be set):
  CSS_PORT_EXTERNAL:          Docker external port number for the Cloud Sync Service (CSS) container.
  EXCHANGE_INTERNAL_INTERVAL: The number of seconds to wait between attempts to connect to the exchange during startup
  EXCHANGE_INTERNAL_RETRIES:  The maximum number of times to try connecting to the exchange during startup to verify the connection info.
  EXCHANGE_INTERNAL_URL:      Docker internal network path to the Exchange container. Used for authentication and authorization with the Exchange.
  EXCHANGE_PORT_EXTERNAL:     Docker external port number for the Exchange container.
  FDO_DB_URL:                 Docker internal network path to database.
  FDO_GET_PKGS_FROM:          Where to have the edge devices get the horizon packages from. If set to css:, it will be expanded to css:/api/v1/objects/IBM/agent_files. Or it can be set to something like https://github.com/open-horizon/anax/releases/latest/download (which is the default).
  FDO_GET_CFG_FILE_FROM:      Where to have the edge devices get the agent-install.cfg file from. If set to css: (the default), it will be expanded to css:/api/v1/objects/IBM/agent_files/agent-install.cfg. Or it can set to agent-install.cfg, which means using the file that the FDO Owner Service creates.
  FDO_OCS_DB_HOST_DIR:
  FDO_OCS_DB_CONTAINER_DIR:
  FDO_OWN_COMP_SVC_PORT:      Docker external port number for the FDO Owner Companion Service (OCS).
  FDO_OWN_DB:                 Database name for the FDO Owner Service's database.
  FDO_OWN_DB_PASSWORD:        Database user's password for the FDO Owner Service's database. Default is generated.
  FDO_OWN_DB_PORT:            Docker external port number for the FDO Owner Service's database.
  FDO_OWN_DB_SSL:             Database connection SSL toggle. Default is false.
  FDO_OWN_DB_USER:            Database username for the FDO Owner Service's database.
  FDO_OWN_SVC_AUTH:           FDO Owner Service API credentials. Default is generated. Format: apiUser:<password>
  FDO_OWN_SVC_CERT_PATH:      Path that the directory holding the certificate and key files is mounted to within the container. Default is /home/sdouser/ocs-api-dir/keys .
  FDO_OWN_SVC_PORT:           Docker external port number for the FDO Owner Service.
  FDO_RV_VOUCHER_TTL:         Tell the rendezvous server to persist vouchers for this number of seconds. Default is 7200.
  HZN_DOCK_NET:               Docker internal network name of Open Horizon's Management Hub.
  HZN_EXCHANGE_URL:           Host network path to the Exchange. Appended to the agent-install.cfg.
  HZN_FSS_CSSURL:             Host network path to the Cloud Sync Service (CSS). Appended to the agent-install.cfg.
  HZN_LISTEN_IP:              Domain or IP Address of the Open Horizon Management Hub.
  HZN_TRANSPORT:              http or https. Only http is currently supported.
  POSTGRES_IMAGE_TAG:         Postgresql version to pull from Dockerhub.
  VERBOSE:                    set to 1 or 'true' for more verbose output.
EndOfMessage
    exit 1
fi


generateToken() { head -c 1024 /dev/urandom | base64 | tr -cd "[:alpha:][:digit:]"  | head -c $1; }


# Assumes Open Horizon All-in-1 environment
export CSS_PORT_EXTERNAL=${CSS_PORT_EXTERNAL:-9443}
export EXCHANGE_INTERNAL_URL=${EXCHANGE_INTERNAL_URL:-http://exchange-api:8080/v1} # Internal docker network, for this container.
export EXCHANGE_PORT_EXTERNAL=${EXCHANGE_PORT_EXTERNAL:-3090}
export FIDO_DEVICE_ONBOARD_REL_VER=${FIDO_DEVICE_ONBOARD_REL_VER:-1.1.7}
export FDO_OWN_COMP_SVC_PORT=${FDO_OWN_COMP_SVC_PORT:-9008}
export FDO_OWN_SVC_PORT=${FDO_OWN_SVC_PORT:-8042}
export FDO_OWN_DB=${FDO_OWN_DB:-fdo}
export FDO_OWN_DB_PASSWORD=${FDO_OWN_DB_PASSWORD:-$(generateToken 15)}
export FDO_OWN_DB_PORT=${FDO_OWN_DB_PORT:-5433}
export FDO_OWN_DB_SSL=${FDO_OWN_DB_SSL:-false}
export FDO_OWN_DB_USER=${FDO_OWN_DB_USER:-fdouser}
export FDO_OWN_SVC_AUTH=${FDO_OWN_SVC_AUTH:-apiUser:$(generateToken 15)}
export FDO_DB_URL=${FDO_DB_URL:-jdbc:postgresql://postgres-fdo-owner-service:5432/$FDO_OWN_DB}
export POSTGRES_IMAGE_TAG=${POSTGRES_IMAGE_TAG:-13}


export HZN_LISTEN_IP=${HZN_LISTEN_IP:-127.0.0.1}
export HZN_TRANSPORT=${HZN_TRANSPORT:-http}
export HZN_DOCK_NET=${HZN_DOCK_NET:-hzn_horizonnet}
export HZN_EXCHANGE_URL=${HZN_EXCHANGE_URL:-$HZN_TRANSPORT://$HZN_LISTEN_IP:$EXCHANGE_PORT_EXTERNAL/v1} # External URL, for agent-install.cfg
export HZN_FSS_CSSURL=${HZN_FSS_CSSURL:-$HZN_TRANSPORT://$HZN_LISTEN_IP:$CSS_PORT_EXTERNAL}
export HZN_MGMT_HUB_CERT=${HZN_MGMT_HUB_CERT:-$(cat ./agent-install.crt | base64)}

export VERBOSE=${VERBOSE:-false}

EXCHANGE_INTERNAL_CERT="${HZN_MGMT_HUB_CERT:-N/A}"
VERSION="${1:-1.4.0}"

DOCKER_REGISTRY=${DOCKER_REGISTRY:-openhorizon}
FDO_DOCKER_IMAGE=${FDO_DOCKER_IMAGE:-fdo-owner-services}
containerHome=/home/fdouser

FDO_OCS_DB_HOST_DIR=${FDO_OCS_DB_HOST_DIR:-$PWD/ocs-db}  # we are now using a named volume instead of a host dir
 #this is where OCS needs it to be
FDO_OCS_DB_CONTAINER_DIR=${FDO_OCS_DB_CONTAINER_DIR:-$containerHome/ocs/config/db}

FDO_GET_PKGS_FROM=${FDO_GET_PKGS_FROM:-https://github.com/open-horizon/anax/releases/latest/download}
FDO_GET_CFG_FILE_FROM=${FDO_GET_CFG_FILE_FROM:-css:}


# If their mgmt hub doesn't need a self-signed cert, we chose to make them set HZN_MGMT_HUB_CERT to 'N/A' to ensure they didn't just forget to specify this env var
if [[ $HZN_MGMT_HUB_CERT == 'N/A' || $HZN_MGMT_HUB_CERT == 'n/a' ]]; then
    unset HZN_MGMT_HUB_CERT
fi


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

docker run -d \
           -e "POSTGRES_DB=$FDO_OWN_DB" \
           -e "POSTGRES_PASSWORD=$FDO_OWN_DB_PASSWORD" \
           -e "POSTGRES_USER=$FDO_OWN_DB_USER" \
           -e "POSTGRES_HOST_AUTH_METHOD=trust" \
           --health-cmd="pg_isready -U $FDO_OWN_DB_USER" \
           --health-interval=15s \
           --health-retries=3 \
           --health-timeout=5s \
           --name postgres-fdo-owner-service \
           --network="$HZN_DOCK_NET" \
           -p "$FDO_OWN_DB_PORT":5432 \
           postgres:"$POSTGRES_IMAGE_TAG"

# Run the service container --mount "type=volume,src=fdo-ocs-db,dst=$FDO_OCS_DB_CONTAINER_DIR" $privateKeyMount $certKeyMount
# EXCHANGE_INTERNAL_CERT: The base64 encoded certificate that OCS-API should use when contacting the exchange for authentication. Will default to the sdoapi.crt file in the directory specified by FDO_SVC_CERT_HOST_PATH.
# FDO_OCS_SVC_TLS_PORT:   Port number OCS-API should listen on for TLS. Default is the value of FDO_OCS_SVC_PORT. (OCS API does not support TLS and non-TLS simultaneously.) Note: you can not set this to 9009, because OCS listens on that port internally. The TLS port takes precedence, if set.
# FDO_SVC_CERT_HOST_PATH: Path on this host of the directory holding the certificate and key files named sdoapi.crt and sdoapi.key, respectively. Default is for the OCS-API to not support TLS.
docker run -d \
           -e "FDO_DB_PASSWORD=$FDO_OWN_DB_PASSWORD" \
           -e "FDO_OPS_SVC_HOST=$HZN_LISTEN_IP:$FDO_OWN_SVC_PORT" \
           -e "FDO_DB_SSL=$FDO_OWN_DB_SSL" \
           -e "FDO_DB_USER=$FDO_OWN_DB_USER" \
           -e "FDO_DB_URL=$FDO_DB_URL" \
           -e "HZN_FDO_API_URL=$HZN_TRANSPORT://$HZN_LISTEN_IP:$FDO_OWN_SVC_PORT" \
           -e "FDO_API_PWD=$FDO_OWN_SVC_AUTH" \
           -e "FDO_OCS_DB_PATH=$FDO_OCS_DB_CONTAINER_DIR" \
           -e "FDO_OCS_SVC_PORT=$FDO_OWN_COMP_SVC_PORT" \
           -e "FDO_OCS_SVC_TLS_PORT=$FDO_OWN_COMP_SVC_PORT" \
           -e "FDO_SVC_CERT_PATH=$FDO_OWN_SVC_CERT_PATH" \
           -e "FDO_OPS_PORT=$FDO_OWN_SVC_PORT" \
           -e "FDO_OPS_EXTERNAL_PORT=$FDO_OWN_SVC_PORT" \
           -e "HZN_EXCHANGE_URL=$HZN_EXCHANGE_URL" \
           -e "EXCHANGE_INTERNAL_URL=$EXCHANGE_INTERNAL_URL" \
           -e "EXCHANGE_INTERNAL_CERT=$EXCHANGE_INTERNAL_CERT" \
           -e "EXCHANGE_INTERNAL_RETRIES=$EXCHANGE_INTERNAL_RETRIES" \
           -e "EXCHANGE_INTERNAL_INTERVAL=$EXCHANGE_INTERNAL_INTERVAL" \
           -e "HZN_FSS_CSSURL=$HZN_FSS_CSSURL" \
           -e "HZN_MGMT_HUB_CERT=$HZN_MGMT_HUB_CERT" \
           -e "FDO_GET_PKGS_FROM=$FDO_GET_PKGS_FROM" \
           -e "FDO_GET_CFG_FILE_FROM=$FDO_GET_CFG_FILE_FROM" \
           -e "FDO_RV_VOUCHER_TTL=$FDO_RV_VOUCHER_TTL" \
           -e "VERBOSE=$VERBOSE" \
           --mount "type=volume,src=fdo-ocs-db,dst=$FDO_OCS_DB_CONTAINER_DIR" \
           --name "$FDO_DOCKER_IMAGE" \
           --network="$HZN_DOCK_NET" \
           --health-interval=15s \
           --health-retries=3 \
           --health-timeout=5s \
           --health-cmd="curl --fail $HZN_TRANSPORT://$HZN_LISTEN_IP:$FDO_OWN_COMP_SVC_PORT/api/version || exit 1" \
           -p "$FDO_OWN_SVC_PORT":8042 \
           -p "$FDO_OWN_COMP_SVC_PORT":9008 \
           "$DOCKER_REGISTRY/$FDO_DOCKER_IMAGE:$VERSION"
