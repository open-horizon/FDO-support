#!/bin/bash

# Deletes the private keys and combined publick key associated with the specified key name.

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat << EndOfMessage
Usage: ${0##*/} <org-id> <username> <key-name>

Arguments:
  <org-id> - The Horizon Org ID the user is in.
  <username> - The exchange user running the API that is calling this script.
  <key_name> - The custom key pair name the user chooses.

EndOfMessage
    exit 0
fi

# Make all positional arguments required
if [[ -z "$1" || -z "$2" || -z "$3" ]]; then
    echo "Error: All positional arguments were not specified" >&2
    exit 1
fi

# Positional Arguments for ocs api
HZN_ORG_ID="$1"
LOWER_ORG_ID=$(echo "$HZN_ORG_ID" | tr '[:upper:]' '[:lower:]')
HZN_EXCHANGE_USER="$2"
KEY_NAME="$3"
KEY_NAME=$(echo "$KEY_NAME" | tr '[:upper:]' '[:lower:]')

# Globals
PUBLIC_KEY_DIR=/home/sdouser/ocs/config/db/v1/creds/publicKeys
KEYTOOL=/usr/lib/jvm/openjre-11-manual-installation/bin/keytool
KEYSTORE_FILE=/home/sdouser/ocs/config/db/v1/creds/owner-keystore.p12

#============================FUNCTIONS=================================

# Echo message and exit
fatal() {
    local exitCode=$1
    # the rest of the args are the message
    echo "Error:" ${@:2}
    exit $exitCode
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

#============================MAIN CODE=================================

# Ensure we are not root
if [[ $(whoami) = 'root' ]]; then
    fatal 2 "must be normal user to run ${0##*/}"
fi

# Verify this key exists
if [[ ! -f $PUBLIC_KEY_DIR/${HZN_ORG_ID}/${HZN_EXCHANGE_USER}/${LOWER_ORG_ID}_${KEY_NAME}_public-key.pem ]]; then
    fatal 2 "Public key $KEY_NAME for user $HZN_EXCHANGE_USER not found"
fi

# Grab keystore password from the ocs/ocs.env inside the container
keypwd="$(grep -E '^ *FS_OWNER_KEYSTORE_PASSWORD=' ocs/ocs.env)"
SDO_KEY_PWD=${keypwd#FS_OWNER_KEYSTORE_PASSWORD=}

# Remove private keys from the keystore. Keep going, even if error, so we clean up partial creations
for i in "rsa" "ecdsa256" "ecdsa384"; do
    $KEYTOOL -delete -keystore $KEYSTORE_FILE -storepass "$SDO_KEY_PWD" -alias "${LOWER_ORG_ID}_${KEY_NAME}_$i"
    chk $? "deleting ${LOWER_ORG_ID}_${KEY_NAME}_$i key from ocs/config/db/v1/creds/owner-keystore.p12" 'continue'
done

# Remove the public key
rm -f $PUBLIC_KEY_DIR/${HZN_ORG_ID}/${HZN_EXCHANGE_USER}/${LOWER_ORG_ID}_${KEY_NAME}_public-key.pem
chk $? "deleting $PUBLIC_KEY_DIR/${HZN_ORG_ID}/${HZN_EXCHANGE_USER}/${LOWER_ORG_ID}_${KEY_NAME}_public-key.pem"
