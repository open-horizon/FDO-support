#!/bin/bash
# This script will automate the process of creating private keys and certificates, and importing those into the master keystore in sdo owner services. Also returns concatenated public keys so each tenant is able to use their own key pairs so that they can securely use SDO.

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat << EndOfMessage
Usage: ${0##*/} <org-id> <key-name> <common-name> <email-name> <company-name> <country-name> <state-name> <locale-name> <username>

Arguments:
  <org-id> - The organizational unit or Horizon Org ID the user is in. Necessary information for keyCertificate generation.
  <key_name> - The custom key pair name the user chooses. Necessary information to keep track of imported keystores into our master keystore.
  <common-name> - The name of the user. Necessary information for keyCertificate generation.
  <email-name> - The user's email. Necessary information for keyCertificate generation.
  <company-name> - The company the user works for. Necessary information for keyCertificate generation.
  <country-name> - The country the user resides in. Necessary information for keyCertificate generation.
  <state-name> - The state the user resides in. Necessary information for keyCertificate generation.
  <locale-name> - The city the user resides in. Necessary information for keyCertificate generation.
  <username> - The exchange user running the API that is calling this script.

EndOfMessage
    exit 0
fi

#Make all positional arguments required. Try to check number of arguments passed? $# -lt 7
if [[ -z "$1" ]] || [[ -z "$2" ]] || [[ -z "$3" ]] || [[ -z "$4" ]] || [[ -z "$5" ]] || [[ -z "$6" ]] || [[ -z "$7" ]] || [[ -z "$8" ]] || [[ -z "$9" ]]; then
    echo "Error: All positional arguments were not specified" >&2
    exit 1
fi


#Grabbing keystore password from the ocs/ocs.env inside the container to use for import
keypwd="$(grep -E '^ *FS_OWNER_KEYSTORE_PASSWORD=' ocs/ocs.env)"
SDO_KEY_PWD=${keypwd#FS_OWNER_KEYSTORE_PASSWORD=}
keyType="all"
gencmd=""
TMP_DIR=$(mktemp -d)

#Positional Arguments for ocs api
HZN_ORG_ID="$1"
ORG_UNIT=$HZN_ORG_ID
LOWER_ORG_UNIT=$(echo "$ORG_UNIT" | tr '[:upper:]' '[:lower:]')
KEY_NAME="$2"
KEY_NAME=$(echo "$KEY_NAME" | tr '[:upper:]' '[:lower:]')
COMMON_NAME="$3"
EMAIL_NAME="$4"
COMPANY_NAME="$5"
COUNTRY_NAME="$6"
STATE_NAME="$7"
LOCALE_NAME="$8"
HZN_EXCHANGE_USER="$9"

#============================FUNCTIONS=================================

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

ensureWeAreUser() {
    if [[ $(whoami) = 'root' ]]; then
        echo "Error: must be normal user to run ${0##*/}"
        exit 2
    fi
}


function getKeyPair() {
  #Check for existance of a specific key . If it isn't found good, if it is found exit 3
  #echo "Checking for private keys and concatenated public key using key name: "${LOWER_ORG_UNIT}_${KEY_NAME}
  if [[ $(/usr/lib/jvm/openjre-11-manual-installation/bin/keytool -list -v -keystore ocs/config/db/v1/creds/owner-keystore.p12 -storepass "${SDO_KEY_PWD}" | grep -E "^Alias name: *${LOWER_ORG_UNIT}_${KEY_NAME}_rsa$") > 0 ]]; then
    echo "Key Name "${LOWER_ORG_UNIT}_${KEY_NAME}" Already Used" 
    /usr/lib/jvm/openjre-11-manual-installation/bin/keytool -list -v -keystore ocs/config/db/v1/creds/owner-keystore.p12 -storepass "${SDO_KEY_PWD}" | grep -E "^Alias name: *${LOWER_ORG_UNIT}_${KEY_NAME}_rsa$" >&2
    exit 3
  fi
  }

function allKeys() {
  for i in "rsa" "ecdsa256" "ecdsa384"; do
    keyType=$i
    genKey
  done
}

#This function will create a private key that is needed to create a private keystore. Encryption keyType passed will decide which command to run for private key creation
function genKey() {
  local privateKey=""${keyType}"private-key.pem"
  local keyCert=""${keyType}"Cert.crt"
  #Check if the folder is already created for the keyType (In case of multiple runs)
  mkdir -p $TMP_DIR/"${keyType}"Key && cd $TMP_DIR/"${keyType}"Key >/dev/null || return
  #Generate a private RSA key.
  if [[ $keyType == "rsa" ]]; then
    #echo -e "Generating an "${keyType}" private key."
    openssl genrsa -out "${keyType}"private-key.pem 2048 >/dev/null
    chk $? 'Generating a rsa private key.'
    keyCertGenerator
  #Generate a private ecdsa (256 or 384) key.
  elif [[ $keyType == "ecdsa256" ]] || [[ $keyType == "ecdsa384" ]]; then
    #echo -e "Generating an "${keyType}" private key."
    local var2=$(echo $keyType | cut -f2 -da)
    openssl ecparam -genkey -name secp"${var2}"r1 -out "${keyType}"private-key.pem >/dev/null
    chk $? 'Generating an ecdsa private key.'
    keyCertGenerator
  fi
}

function keyCertGenerator() {
  if [[ -f $privateKey ]]; then
    echo -e ""${keyType}" private key creation: Successful"
    gencmd="openssl req -x509 -key "$privateKey" -days 3650 -out "$keyCert""
  fi
  #Generate self-signed certificate.
  #You should have these environment variables set as positional arguments.
  #!/usr/bin/env bash

  if [[ $keyType == "rsa" ]] || [ "$(uname)" != "Darwin" ]; then
    (
      echo "$COUNTRY_NAME"
      echo "$STATE_NAME"
      echo "$LOCALE_NAME"
      echo "$COMPANY_NAME"
      echo "$ORG_UNIT"
      echo "$COMMON_NAME"
      echo "$EMAIL_NAME"
    ) | $gencmd >/dev/null 2>&1
    chk $? 'generating rsa certificate'
  fi

  if [[ -f $keyCert ]] && [[ -f "$privateKey" ]]; then
    echo -e ""${keyType}" Private Key and "${keyType}"Key Certificate creation: Successful"
    genPublicKey
    cd ..
  else
    echo ""${keyType}" Private Key and "${keyType}"Key Certificate not found"
    exit 2
  fi
}

function genPublicKey() {
  # This function is ran after the private key and owner certificate has been created. This function will create a public key to correspond with
  # the owner private key/certificate. Generate a public key from the certificate file
  #echo "Generating "${keyType}" public key..."
  openssl x509 -pubkey -noout -in $keyCert >../"${keyType}"pub-key.pem
  chk $? 'Creating public key...'
}

function combineKeys() {
  #This function will concatenate all public keys into one
  if [[ -f "rsapub-key.pem" && -f "ecdsa256pub-key.pem" && -f "ecdsa384pub-key.pem" ]]; then
    #Combine all the public keys into one
    #adding delimiters for SDO 1.9 pub key format
    echo "," >> rsapub-key.pem && echo "," >> ecdsa256pub-key.pem
    #echo "Concatenating Public Key files..."
    for i in "rsapub-key.pem" "ecdsa256pub-key.pem" "ecdsa384pub-key.pem"
      do
        local keyName=$i
        local removeWord="pub-key.pem"
        keyName=${keyName//$removeWord/}
        #adding delimiters for SDO 1.9+ pub key format
        echo ""$keyName":" >key.txt
        cat key.txt $i >> ${LOWER_ORG_UNIT}_${KEY_NAME}_public-key.pem
        chk $? 'Concatenating Public Key files...'
      done
    rm -- ecdsa*.pem rsapub* key.txt
  fi

  # Note: Even tho we store the public key under their user directory, that doesn't mean each user has their own namespace.
  #     Only 1 instance of KEY_NAME is allowed in the org.
  mkdir -p /home/sdouser/ocs/config/db/v1/creds/publicKeys/${ORG_UNIT}/${HZN_EXCHANGE_USER} && mv ${LOWER_ORG_UNIT}_${KEY_NAME}_public-key.pem /home/sdouser/ocs/config/db/v1/creds/publicKeys/${ORG_UNIT}/${HZN_EXCHANGE_USER}/

}

#This function will take the private key and certificate that has been passed in, and use them to generate a keystore pkcs12 file containing both files.
function genKeyStore(){
  #echo $SDO_KEY_PWD
  for i in "rsa" "ecdsa256" "ecdsa384"
      do
        # Convert the keyCertificate and private key into ‘PKCS12’ keystore format:
        cd $TMP_DIR/"$i"Key/ && openssl pkcs12 -export -in "$i"Cert.crt -inkey "$i"private-key.pem -name "${LOWER_ORG_UNIT}_${KEY_NAME}_$i" -out "${KEY_NAME}_$i.p12" -password pass:"$SDO_KEY_PWD"
        chk $? 'Converting private key and cert into keystore'
        cp "${KEY_NAME}_$i.p12" .. && rm -- *
        cd .. && rmdir $TMP_DIR/"$i"Key
      done
}

function insertKeys(){
  #This function will insert all private keystores into the master keystore
  if [[ -f "${KEY_NAME}_$i.p12" ]]; then
    for i in "rsa" "ecdsa256" "ecdsa384"
      do
        #Import custom keystores into the master keystore. /usr/lib/jvm/openjre-11-manual-installation/bin/
        echo "yes" | /usr/lib/jvm/openjre-11-manual-installation/bin/keytool -importkeystore -destkeystore /home/sdouser/ocs/config/db/v1/creds/owner-keystore.p12 -deststorepass "$SDO_KEY_PWD" -srckeystore "${KEY_NAME}_$i.p12" -srcstorepass "$SDO_KEY_PWD" -srcstoretype PKCS12 -alias "${LOWER_ORG_UNIT}_${KEY_NAME}_$i"
        chk $? "Inserting "${LOWER_ORG_UNIT}_${KEY_NAME}_$i.p12" keystore into ocs/config/db/v1/creds/owner-keystore.p12"
      done
    rm -- *.p12
  else
    echo "One or more of the keystores are missing. There should be three keystores of type rsa, ecdsa256, and ecdsa384"
    exit 2
fi
}

function genExpiredKeys() {   # an undocumented option for dev/test to create an already expired set of keys
    # Create expired private keys
    local keytool=/usr/lib/jvm/openjre-11-manual-installation/bin/keytool
    local keystore_file=/home/sdouser/ocs/config/db/v1/creds/owner-keystore.p12
    for i in "rsa" "ecdsa256" "ecdsa384"; do
        echo "creating expired key ${LOWER_ORG_UNIT}_${KEY_NAME}_$i ..."
        (
            echo "$HZN_EXCHANGE_USER"
            echo "$ORG_UNIT"
            echo "$COMPANY_NAME"
            echo "$LOCALE_NAME"
            echo "$STATE_NAME"
            echo "$COUNTRY_NAME"
            echo "yes"
        ) | $keytool -alias "${LOWER_ORG_UNIT}_${KEY_NAME}_$i" -genkey -keystore $keystore_file -storepass "${SDO_KEY_PWD}" -keyalg RSA -validity 1 -startdate -2d 2> /dev/null   # it echoes all of the prompts to stderr
        # Note: in the cmd above we intentionally use -keyalg RSA for all 3 keys because it doesn't matter (they are expired/useless)
        chk $? "creating expired key ${LOWER_ORG_UNIT}_${KEY_NAME}_$i"
    done

    # Create dummy public key
    echo "creating dummy public key $ORG_UNIT/$HZN_EXCHANGE_USER/${LOWER_ORG_UNIT}_${KEY_NAME}_public-key.pem ..."
    mkdir -p /home/sdouser/ocs/config/db/v1/creds/publicKeys/${ORG_UNIT}/${HZN_EXCHANGE_USER}
    echo 'this is a dummy public key for an expired private key/cert' > /home/sdouser/ocs/config/db/v1/creds/publicKeys/$ORG_UNIT/$HZN_EXCHANGE_USER/${LOWER_ORG_UNIT}_${KEY_NAME}_public-key.pem
    chk $? "creating dummy public key $ORG_UNIT/$HZN_EXCHANGE_USER/${LOWER_ORG_UNIT}_${KEY_NAME}_public-key.pem"
}


#============================MAIN CODE=================================

ensureWeAreUser
getKeyPair

if [[ $CREATE_EXPIRED_KEY == 'true' ]]; then
    genExpiredKeys   # an undocumented option for dev/test to create an already expired set of keys
else
    # Create real keys
    allKeys
    combineKeys

    genKeyStore
    insertKeys
fi
echo "Owner key pairs have been created and imported."



