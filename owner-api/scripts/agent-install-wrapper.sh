#!/bin/sh

# The primary purpose of this wrapper is to be able to invoke agent-install.sh in the SDO context to install and register
# the horizon agent and log all of its stdout/stderr. SDO is slow at downloading this wrapper script to the device, so keep it as short as possible.
# This wrapper script is run on the edge device in the SDO directory /var/sdo/sdo_device_binaries_<version>_linux_x64/device. All of the needed files
# like agent-install.cfg and agent-install.crt are downloaded by SDO to the same directory.

echo "$0 starting...."
echo "Will be running: ./agent-install.sh $*"

# Verify the number of args is what we are handling below
maxArgs=8   # the exec statement below is only passing up to this many args to agent-install.sh
if [ $# -gt $maxArgs -o "$1" != '-i' -o "$3" != '-a' -o "$5" != '-O' -o "$7" != '-k' ]; then
    # it is easy to miss this error msg in the midst of the verbose sdo output, so make it more obvious
    echo "~~~~~~~~~~~~~~~~\nError: too many arguments passed to agent-install-wrapper.sh or the arguments are in the wrong order\n~~~~~~~~~~~~~~~~"
    exit 2
fi

# This script has a 2nd purpose in the native client case: when run inside the docker sdo container, copy the downloaded files to outside the container
if [ -f /target/boot/inside-sdo-container ]; then
    # Copy all of the downloaded files (including ourselves) to /target/boot, which is mounted from host /var/horizon/sdo-native
    echo "Copying downloaded files to /target/boot: $(ls | tr "\n" " ")"
    # need to exclude a few files and dirs, so copy with find
    find . -maxdepth 1 -type f ! -name inside-sdo-container ! -name linux-client ! -name run_csdk_sdo.sh -exec cp -p -t /target/boot/ {} +
    if [ $? -ne 0 ]; then echo "Error: can not copy downloaded files to /target/boot"; fi
    # The <device-uuid>_exec file is not actually saved to disk, so recreate it (with a fixed name)
    echo "/bin/sh agent-install-wrapper.sh \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" \"$7\" \"$8\" " > /target/boot/device_exec
    chmod +x /target/boot/device_exec
    echo "Created /target/boot/device_exec: $(cat /target/boot/device_exec)"
    exit
    # now the sdo container will exit, then our owner-boot-device script will find the files and run us again
fi

# Download agent-install.sh
pkgsFrom="$2"   #future: add a very lightweight arg parser so we are not dependent on these being in a specific order
nodeAuth="$4"
deviceOrgId="$6"
cfgFrom="$8"

#future: When Intel's host native client stops setting these, remove this line
unset http_proxy https_proxy

# Install curl if not present
if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -yqf curl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -yq curl
    else
        echo "~~~~~~~~~~~~~~~~\nError: the curl command is not installed and neither apt-get or dnf is present\n~~~~~~~~~~~~~~~~"
        exit 2
    fi
fi

eval export `cat agent-install.cfg`   # we need the value of HZN_FSS_CSSURL regardless of the value of $pkgsFrom

if [ "${pkgsFrom%%:*}" = 'css' ]; then
    # Get agent-install.sh from the mgmt hub CSS
    agentInstallRemotePath="${HZN_FSS_CSSURL%/}/api/v1/objects/IBM/agent_files/agent-install.sh/data"
    echo "Downloading $agentInstallRemotePath ..."
    httpCode=`curl -sSL -w "%{http_code}" -u "$deviceOrgId/$nodeAuth" --cacert agent-install.crt -o agent-install.sh "$agentInstallRemotePath"`
    if [ $? -ne 0 -o "$httpCode" != '200' ]; then
        echo "~~~~~~~~~~~~~~~~\nError downloading $agentInstallRemotePath: httpCode=$httpCode\n~~~~~~~~~~~~~~~~"
        exit 2
    fi
else   # $pkgsFrom==https://github.com/open-horizon/anax/releases/* but $cfgFrom is likely css:
    # It is a URL like https://github.com/open-horizon/anax/releases/latest/download, just add agent-install.sh to the end
    agentInstallRemotePath="$pkgsFrom/agent-install.sh"
    echo "Downloading $agentInstallRemotePath ..."
    httpCode=`curl -sSLO -w "%{http_code}" "$agentInstallRemotePath"`
    if [ $? -ne 0 -o "$httpCode" != '200' ]; then
        echo "~~~~~~~~~~~~~~~~\nError downloading $agentInstallRemotePath: httpCode=$httpCode\n~~~~~~~~~~~~~~~~"
        exit 2
    fi
fi
chmod 755 agent-install.sh

mkdir -p /var/sdo
logFile=/var/sdo/agent-install.log
echo "Logging all output to $logFile"

# If tee is installed, use it so the output can go to both stdout/stderr and the log file
if command -v tee >/dev/null 2>&1; then
    # Note: the individual arg variables need to be listed like this and quoted to handle spaces in an arg
    exec ./agent-install.sh "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" 2>&1 | tee $logFile
else
    exec ./agent-install.sh "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" 2>&1 > $logFile
fi
#exit 2   # it only gets here if exec failed
