#!/bin/bash 

#This script will go into the fdo directory and grab the credentials for API calls

grabCreds() {
    components=("manufacturer" "rv" "owner")
    for i in ${components[@]}; do
        if [[ "${components[@]}" =~ "$i" ]]; then

            keypwd="$(grep -E '^ *api_password=' fdo/pri-fidoiot-v1.1.6/$i/service.env)"
            API_PWD=${keypwd#api_password=}
           
	    echo export "$i"=$API_PWD
        fi
    done
  

}

grabCreds