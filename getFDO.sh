#!/bin/bash

# This script only needs to be run by developers of this project when needing to move up to a new version of FDO.
# Before running, update the versions of the tar files as necessary.

SCRIPT_LOCATION=$(dirname "$0")

# Check the exit code passed in and exit if non-zero
chk() {
    local exitCode=$1
    local task=$2
    if [[ $exitCode == 0 ]]; then return; fi
    echo "Error: exit code $exitCode from: $task"
    exit $exitCode
}

echo "Retrieving Intel FDO Release 1.1.5 dependencies..."
mkdir -p ${SCRIPT_LOCATION}/fdo && cd ${SCRIPT_LOCATION}/fdo
chk $? 'making fdo dir'

echo "Getting client-sdk-fidoiot"
curl --progress-bar -LO https://github.com/secure-device-onboard/release-fidoiot/releases/download/v1.1.5/client-sdk-fidoiot-v1.1.5.tar.gz
chk $? 'downloading client-sdk-fidoiot'
tar -zxf client-sdk-fidoiot-v1.1.5.tar.gz
chk $? 'unpacking client-sdk-fidoiot'


echo "Getting Protocol Reference Implementation"
curl --progress-bar -LO https://github.com/secure-device-onboard/release-fidoiot/releases/download/v1.1.5/pri-fidoiot-v1.1.5.tar.gz
chk $? 'downloading pri'
tar -zxf pri-fidoiot-v1.1.5.tar.gz
chk $? 'unpacking pri'

echo "Getting NOTICES"
curl --progress-bar -LO https://github.com/secure-device-onboard/release-fidoiot/releases/download/v1.1.5/NOTICES-v1.1.5.tar.gz
chk $? 'downloading NOTICES'
tar -zxf NOTICES-v1.1.5.tar.gz
chk $? 'unpacking NOTICES'

echo "Getting Third Party Components"
curl --progress-bar -LO https://github.com/secure-device-onboard/release-fidoiot/releases/download/v1.1.5/third-party-components.tar.gz
chk $? 'downloading third-party-components'
tar -zxf third-party-components.tar.gz
chk $? 'unpacking third-party-components'

cd ${SCRIPT_LOCATION}
echo "Complete."