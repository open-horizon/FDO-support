#!/bin/bash

# Start the open-horizon SDO OCS API, not incd  a container, for debugging

runEnv=${1:-dev}
port=${FDO_OCS_API_PORT:-9008}

if [[ "$runEnv" == "prod" ]]; then
	:   # don't know if we need this yet
elif [[ "$runEnv" == "dev" ]]; then
	# We assume they run this in the SDO-support github dir
	ocsDbDir=${FDO_OCS_API_DB_DIR:-ocs-api/ocs-db}    # this should be at the level ocs/config/db
	mkdir -p $ocsDbDir
	export VERBOSE='true'
	ocs-api/ocs-api $port $ocsDbDir &  # stdout and stderr will go to the terminal session
	if [[ $? -eq 0 ]]; then
		echo "ocs-api/ocs-api started, browse http://localhost:$port/api"
	fi

else
	echo "Usage: $0 [dev|prod]"
	exit 1
fi