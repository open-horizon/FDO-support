#!/bin/bash

# Stop the ocs-api rest api.
# Not using killall, so we do not require it to be installed.

# Find the pid of the ui to kill
pid=$(ps aux|grep ocs-api|grep -v grep|grep -v 'stop-ocs-api'|grep -v 'run-ocs-api'|awk '{print $2}')

if [[ $? -ne 0 ]]; then
	echo "error finding ocs-api process id"  # stderr should have already displayed
	exit 3
elif [[ -z "$pid" ]]; then
	echo "ocs-api process not found"
	exit 1
elif [[ "$pid" =~ " " ]]; then
	# got multiple words instead of 1 pid
	echo "found more than 1 process id for ocs-api: $pid"
	exit 2
fi

#echo kill $pid
kill $pid

if [[ $? -eq 0 ]]; then
	echo "ocs-api stopped"
fi