#!/bin/bash

# Returns whether each key is expired or not. Output is a series of lines like:
# <org>_<key-name>: <true or false>
# ...

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cat << EndOfMessage
Usage: ${0##*/} <org-id> <username> <key-name>

Arguments:
  <org-id> - The Horizon Org ID the user is in.
  <username> - The exchange user running the API that is calling this script.

EndOfMessage
    exit 0
fi

# Make all positional arguments required
if [[ -z "$1" || -z "$2" ]]; then
    echo "Error: All positional arguments were not specified" >&2
    exit 1
fi

# Positional Arguments for ocs api
HZN_ORG_ID="$1"
LOWER_ORG_ID=$(echo "$HZN_ORG_ID" | tr '[:upper:]' '[:lower:]')
HZN_EXCHANGE_USER="$2"
#KEY_NAME="$3"
#KEY_NAME=$(echo "$KEY_NAME" | tr '[:upper:]' '[:lower:]')

# Globals
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

# Grab keystore password from the ocs/ocs.env inside the container
keypwd="$(grep -E '^ *FS_OWNER_KEYSTORE_PASSWORD=' ocs/ocs.env)"
SDO_KEY_PWD=${keypwd#FS_OWNER_KEYSTORE_PASSWORD=}

# Get list of keys and their expiration dates, and store them in an array
# For keytool man page, see: https://docs.oracle.com/javase/7/docs/technotes/tools/windows/keytool.html
readarray -t keystoreLines < <($KEYTOOL -list -v -keystore $KEYSTORE_FILE -storepass "$SDO_KEY_PWD"  | grep -E '^(Alias name|Valid from):')
chk $? "getting keys from ocs/config/db/v1/creds/owner-keystore.p12"

# Process each pair of lines. The cmd above produces sets of 6 lines like:
# Alias name: mycluster_bp_ecdsa256
# Valid from: Fri Jun 18 12:36:23 UTC 2021 until: Mon Jun 16 12:36:23 UTC 2031
# Alias name: mycluster_bp_ecdsa384
# Valid from: Fri Jun 18 12:36:23 UTC 2021 until: Mon Jun 16 12:36:23 UTC 2031
# Alias name: mycluster_bp_rsa
# Valid from: Fri Jun 18 12:36:23 UTC 2021 until: Mon Jun 16 12:36:23 UTC 2031

keyType='rsa'   # we only need to look at 1 of the 3 types of keys we create, because they all have the same expiry
for i in ${!keystoreLines[@]}; do
    line=${keystoreLines[$i]}
    #echo "debug: processing line: $line"
    if [[ $line != 'Alias name: '*_rsa ]]; then continue; fi   # this skips the 'Valid from' lines, the other keys types, and the sample keys

    orgAndKeyName=${line#Alias name: }   # strip beginning and suffix, so we are left with <org>_<key-name>
    orgAndKeyName=${orgAndKeyName%_rsa}
    #echo "debug: processing $orgAndKeyName"

    # Only return keys for this org
    org=${orgAndKeyName%_*}   # key names can not contain underscores (but orgs can), so look for shortest pattern at the end of the string
    if [[ $org != $LOWER_ORG_ID ]]; then continue; fi

    # Get the expiry on the next line
    nextLine=${keystoreLines[$((i+1))]}   # should start with 'Valid from:'
    if [[ $nextLine != 'Valid from: '*'ntil: '* ]]; then fatal 3 "expected 'Valid from' line, but found: $nextLine"; fi
    expiry=${nextLine##*ntil: }
    #echo "debug: expiry $expiry"

    # Convert it to epoch seconds and see if it is expired
    expiryEpochSeconds=$(date +%s --date="$expiry")
    nowEpochSeconds=$(date +%s)
    secondsRemaining=$(($expiryEpochSeconds-$nowEpochSeconds))
    if [[ $secondsRemaining -le 0 ]]; then
        isExpired='true'
    else
        isExpired='false'
    fi

    echo "${orgAndKeyName}: $isExpired"   # output the value for this key
done
