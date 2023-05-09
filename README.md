# Open Horizon FDO 1.0

## Overview of the Open Horizon FDO Support

Edge devices built with [Intel FDO](https://software.intel.com/en-us/secure-device-onboard) (FIDO Device Onboard) can be added to an Open Horizon instance by simply importing their associated ownership vouchers and then powering on the devices.

The software in this git repository provides integration between FDO and Open Horizon, making it easy to use FDO-enabled edge devices with Horizon. The Horizon FDO support consists of these components:

1. A docker image of of the FDO "Owner" service (those that run on the Horizon management hub).
1. An `hzn fdo voucher` sub-command to import one or more ownership vouchers into Owner service. (An ownership voucher is a file that the device manufacturer gives to the purchaser (owner) along with the physical device.)
1. A sample script called `start-mfg.sh` to start the development Manufacturing service so that the Ownership Voucher can be extended to the user to enable them to run through the FDO-enabling steps on a VM "device" that a device manufacturer would run on a physical device. This allows you to try out the FDO process with your Horizon instance before purchasing FDO-enabled devices.
1. A REST API that authneticates users through the Exchange and enables importing and querying ownership vouchers.

## <a name="use-fdo"></a>Using the FDO Support

### <a name="start-services-developer"></a>Starting Your Own Instance of the FDO Owner Services

The FDO owner services respond to booting devices and enable administrators to import ownership vouchers, keys and files.

The FDO owner services are packaged as a single docker container that can be run on any server that has network access, and that the FDO devices can reach over the network.

1. Start up an instance of postgresDB, and create an fdo user and fdo database with connection access:

    ``` bash
    docker pull postgres
    docker run --name some-postgres -e POSTGRES_PASSWORD=fdo -e POSTGRES_USER=fdo -e POSTGRES_DB=fdo -d postgres
    sudo -i -u postgres psql
   
    CREATE ROLE fdouser 
    SUPERUSER
    LOGIN
    PASSWORD 'fdouser';
   
    CREATE DATABASE fdo;
   
    GRANT CONNECT ON DATABASE fdo TO fdouser;
    ```
   
2. Get `run-fdo-owner-services.sh`, which is used to start the container:

   ```bash
   mkdir $HOME/fdo; cd $HOME/fdo
   curl -sSLO https://raw.githubusercontent.com/open-horizon/FDO-support/main/docker/run-fdo-owner-service.sh
   chmod +x run-fdo-owner-service.sh
   ```

3. Run `./run-fdo-owner-service.sh -h` to see the usage, and set all of the necessary environment variables. For example:

   ```bash
   export HZN_EXCHANGE_URL=https://<cluster-url>/edge-exchange/v1
   export HZN_FSS_CSSURL=https://<cluster-url>/edge-css
   export HZN_EXCHANGE_USER_AUTH=iamapikey:<api-key>
   export FDO_DB_URL=jdbc:postgresql://<fdo-db-host>:5432/fdo
   export FDO_DB_USER=fdouser
   export FDO_DB_PASSWORD=fdouser
   export FDO_OPS_SVC_HOST=<fdo-owner-svc-host>:8042
   ```

4. Choose a password for the owner service API inside the owner services container and assign it to FDO_API_PWD. It must be prefixed by "apiUser". For example:
   
   ```bash
   export FDO_API_PWD=apiUser:12345
   ```
   
6. As part of installing the Horizon management hub, you should have run [edgeNodeFiles.sh](https://github.com/open-horizon/anax/blob/master/agent-install/edgeNodeFiles.sh), which created a tar file containing `agent-install.crt`. Use that to export this environment variable:

   ```bash
   export HZN_MGMT_HUB_CERT=$(cat agent-install.crt | base64)
   ```

7. Start the FDO owner services docker container and view the log:

   ```bash
   ./run-fdo-owner-service.sh 1.0.0
   docker logs -f fdo-owner-services
   ```

#### <a name="verify-services"></a>Verify the FDO Owner Services API Endpoints

Before continuing with the rest of the FDO process, it is good to verify that you have the correct information necessary to reach the FDO owner service endpoints. **On a Horizon "admin" host** run these simple FDO APIs to verify that the services are accessible and responding properly. (A Horizon admin host is one that has the `horizon-cli` package installed, which provides the `hzn` command, and has the environment variables `HZN_EXCHANGE_URL`, `HZN_FDO_SVC_URL`, and `HZN_EXCHANGE_USER_AUTH` set correctly for your Horizon management hub.)

1. Export these environment variables for the subsequent steps. Contact the management hub installer for the exact values:

   ```bash
   export HZN_EXCHANGE_USER_AUTH=iamapikey:<password>
   export HZN_FDO_SVC_URL=<protocol>://<fdo-owner-svc-host>:9008
   export FDO_RV_URL=http://sdo.lfedge.iol.unh.edu:80
   ```

2. Query the Owner services and Ocs API  health and version:

```bash
curl -k -sS -w "%{http_code}" -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" $HZN_FDO_SVC_URL/fdo/version | jq
curl -k -sS $HZN_FDO_SVC_URL/version && echo
```

3. Query the ownership vouchers that have already been imported (initially it will be an empty list):

```bash
# either use curl directly
curl -k -sS -w "%{http_code}" -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" $HZN_FDO_SVC_URL/orgs/$HZN_ORG_ID/fdo/vouchers | jq
# or use the hzn command, if you have the horizon-cli package installed
hzn fdo voucher list
```

4. "Ping" the rendezvous server:

```bash
curl -D - --digest -u $HZN_EXCHANGE_USER_AUTH --location --request GET $FDO_RV_URL/health

```


### <a name="init-device"></a>Simulate Manufacturing Steps to Generate Ownership Voucher

For production use of FDO, you need to import an Ownership Voucher into the owner services container. This ownership voucher enables you to securely take over ownership of FDO ownership vouchers from FDO-enabled device manufacturers, and to securely configure your booting FDO devices. Follow the instructions to build the manufacturing service and use the provided script to simulate the process of retrieving an Ownership Voucher from the manufacturer.

####################

The sample script called `start-mfg.sh` downloads and extracts all necessary components for the Manufacturing services. After building the manufacturing services, it then simulates the steps of an FDO-enabled device manufacturer: Initialize your "device" with FDO, retrieve a public key (from the Owner service) based of the device metadata, and retrieve an ownership voucher (from the manufacturer). Perform these steps on the VM device to be initialized (these steps are written for Ubuntu 22.04):

 ```bash
curl -sSLO https://raw.githubusercontent.com/open-horizon/FDO-support/main/sample-mfg/start-mfg.sh
chmod +x start-mfg.sh
export HZN_EXCHANGE_USER_AUTH=iamapikey:<password>
export FDO_RV_URL=http://sdo.lfedge.iol.unh.edu:80
export HZN_FDO_SVC_URL=http://<fdo-owner-svc-host>:9008
sudo -E ./start-mfg.sh
```

All of the following steps interacting with localhost:8039 are automated by the `./start-mfh.sh` script.

1. **On your VM to be initialized**, run the first API to post instructions for manufacturer to redirect device to correct RV server, and run the second API to verify you posted the correct instructions:

```bash
curl -D - --digest -u $HZN_EXCHANGE_USER_AUTH --location --request POST 'http://localhost:8039/api/v1/rvinfo' --header 'Content-Type: text/plain' --data-raw '[[[5,"<FDO_RV_URL DNS>"],[3,<FDO_RV_URL PORT>],[12,1],[2,"<FDO_RV_URL DNS>"],[4,<FDO_RV_URL PORT>]]]'

## Configures for TLS -> '[[[5,"localhost"],[3,8040],[12,1],[2,"127.0.0.1"],[4,8041]]]'
#For Example
curl -D - --digest -u $HZN_EXCHANGE_USER_AUTH --location --request POST 'http://localhost:8039/api/v1/rvinfo' --header 'Content-Type: text/plain' --data-raw '[[[5,"9.30.217.77"],[3,8040],[12,1],[2,"9.30.217.77"],[4,8040]]]' #'[[[5,"9.30.217.77"],[3,8040],[12,2],[2,"9.30.217.77"],[4,8041]]]' For TLS

curl -D - --digest -u $HZN_EXCHANGE_USER_AUTH --location --request GET 'http://localhost:8039/api/v1/rvinfo' --header 'Content-Type: text/plain'

```

2. On your VM to be initialized, go to the device directory and run the following command to initialize your VM "Device":

```bash
cd fdo/pri-fidoiot-v1.1.1/device
java -jar device.jar
```
The response should end with  
[INFO ] DI complete, GUID is <Device GUID here>
[INFO ] Starting Fdo Completed

3. Now that your device is initialized, run the following API call to verify your device is initialized and also to get the device "alias", "uuid" and "serial" information for the following steps

```bash
curl -D - --digest -u $HZN_EXCHANGE_USER_AUTH --location --request GET 'http://localhost:8039/api/v1/deviceinfo/10000' --header 'Content-Type: text/plain'
```


4. Given your device alias is the default "SECP256R1", run the following command to retrieve your public key:

```bash
curl -k -sS -w "%{http_code}" -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" $HZN_FDO_SVC_URL/orgs/$HZN_ORG_ID/fdo/certificate/SECP256R1 -o public_key.pem && echo 
```

5. Now that you have the public key and serial number, you can use the following API call to retrieve your ownership voucher.

```bash
curl -D - --digest -u $HZN_EXCHANGE_USER_AUTH --location --request POST "http://localhost:8039/api/v1/mfg/vouchers/<device-serial-here>" --header 'Content-Type: text/plain' --data-binary '@public_key.pem' -o owner_voucher.txt
#For example
curl -D - --digest -u $HZN_EXCHANGE_USER_AUTH --location --request POST "http://localhost:8039/api/v1/mfg/vouchers/BC9A649C" --header 'Content-Type: text/plain' --data-binary '@public_key.pem' -o owner_voucher.txt
```
This creates an ownership voucher in the file `owner_voucher.txt`.

### <a name="import-voucher"></a>Import the Ownership Voucher

The ownership voucher created for the device in the previous step needs to be imported to the FDO Owner service. **On the Horizon admin host**:

1. When you purchase a physical FDO-enabled device, you receive an ownership voucher from the manufacturer. In the case of the VM device you have configured to simulate an FDO-enabled device, the analogous step is to copy the file `owner_voucher.txt` from your VM device to here.

2. Import the ownership voucher.

   ```bash
   curl -k -sS -w "%{http_code}" -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" -X POST -H Content-Type:text/plain --data-binary @owner_voucher.txt $HZN_FDO_SVC_URL/orgs/$HZN_ORG_ID/fdo/vouchers && echo

   hzn fdo voucher import owner_voucher.txt
   ```

**Note:** If importing the voucher is successful, the response body will be the ownership voucher guid which you will need in order to initiate To0 or to check the status of a specific device.

### <a name="service-info"></a>Configuring Service Info Package

All of the following steps have been automated by the ocs-api to install the horizon agent on the target device. In this step you can also control what edge services should be run on the device, once it is booted and configured. To do this, you must:


1. To0 will be automatically triggered, but if it has not been you can run the following call to initiate To0 of specific device guid from Owner Services.

```bash
curl -k -sS -w "%{http_code}" -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" $HZN_FDO_SVC_URL/orgs/$HZN_ORG_ID/fdo/to0/<deviceUUid> && echo

#For example
curl -k -sS -w "%{http_code}" -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" $HZN_FDO_SVC_URL/orgs/$HZN_ORG_ID/fdo/to0/937e4731-0a6e-455e-bd99-b08bcdbb51da && echo

```

2. Post the script that you want in the service info package. This is the script that will configure your device on boot up.

```bash
curl -k -sS -w "%{http_code}" -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" -X POST -H Content-Type:text/plain --data-binary @<script-name-here> $HZN_FDO_SVC_URL/orgs/$HZN_ORG_ID/fdo/resource/<script-name-here> && echo
#For Example
curl -k -sS -w "%{http_code}" -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" -X POST -H Content-Type:text/plain --data-binary @test.sh $HZN_FDO_SVC_URL/orgs/$HZN_ORG_ID/fdo/resource/test.sh && echo
#To verify
curl -k -sS -w "%{http_code}" -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" -H Content-Type:text/plain $HZN_FDO_SVC_URL/orgs/$HZN_ORG_ID/fdo/resource/agent-install-script-<deviceGuid>.sh && echo

```


3. Now you can configure the service info package with the script that has been posted to the Owner Services DB.
```bash
curl -k -sS -w "%{http_code}" -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" -X POST -H Content-Type:text/plain --data-raw '[{"filedesc" : "<script-name-here>","resource" : "<script-name-here>"}, {"exec" : ["bash","<script-name-here>"] }]' $HZN_FDO_SVC_URL/orgs/$HZN_ORG_ID/fdo/svi && echo

#For Example
curl -k -sS -w "%{http_code}" -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" -X POST -H Content-Type:text/plain --data-raw '[{"filedesc" : "test.sh","resource" : "test.sh"}, {"exec" : ["bash","test.sh"] }]' $HZN_FDO_SVC_URL/orgs/$HZN_ORG_ID/fdo/svi && echo
```

### <a name="boot-device"></a>Boot the Device to Have it Configured

When an FDO-enabled device (like your VM) boots, it starts the FDO process. The first thing the FDO process does is have the Owner service contact the rendezvous server (To0), which instructs the RV server where to redirect, which is the FDO Owner Services in your Horizon instance (To1), which downloads, installs, and registers the Horizon agent onto the device (To2). All of this happens in the background. If you **prefer to watch the process**, perform these steps on your VM device:

1. **Back on your VM device** go to the device directory and run the following API command to "boot" your device:

```bash
cd fdo/pri-fidoiot-v1.1.1/device
java -jar device.jar
```

Now that FDO has configured your edge device, it is automatically disabled on this device so that when the device is rebooted FDO will not run. (The sole purpose of FDO is configuration of a brand new device.)

If you run into any database errors or you just want to run through this process again with a fresh database

```bash
sudo -i -u postgres psql
DROP DATABASE fdo;
```


#### <a name="troubleshooting"></a>Troubleshooting

- If the edge device does not give a `[INFO ] TO2 completed successfully. [INFO ] Starting Fdo Completed`, check /fdo/pri-fidoiot-v1.1.5/owner/app-data/service.log or use command `docker logs -f fdo-owner-services` for error messages.
- If your Owner, RV or Manufacturer service does not respond, you can check the logs in the same location as above. If the logs never printed that it started the service, for example: "Started Owner Service", then make sure you have all dependencies installed and environment variables correctly exported.
- If your Service Info Package fails during the process of getting onboarded to the edge device, make sure you posted the file correctly to the owner service DB. Also make sure that you posted the correct To2 address.


These steps only need to be performed by developers of this project

### <a name="create-new-release"></a>Creating a Release in the FDO-support Repo

- Create a [release](https://github.com/open-horizon/FDO-support/releases) with the major and minor version (but not a patch number), e.g. `v1.11`
- Upload these assets to the release:
    - sample-mfg/start-mfg.sh
    - docker/run-fdo-owner-service.sh
- Copy the previous version of the `README-*.md` to a new version and make the appropriate changes

### <a name="new-fdo-version"></a>Checklist For Moving Up to a New FDO Version

What to modify in our FDO support code when Intel releases a new version of FDO:

- Update `.gitignore` and `.dockerignore`
- `mv fdo fdo-<prev-version>`
- `mkdir fdo`
- Update `getFDO.sh` to download/unpack new version
- If new major or minor version, make copy of README. If a fix pack, just update the version numbers within the README.
- Search for previous version number in rest of repo. Should find hits to change in:
    - `docker/start-fdo-owner-service.sh`
    - `docker/Dockerfile`
    - `docs/README.md`
    - `start-mfg.sh`

- If new major or minor version:
    - update `.gitignore`
    - create a new release in https://github.com/open-horizon/FDO-support/releases/ , and upload all device-related files/scripts.
- If a fix pack:
    - Update the device binary tar file and `start-mfg.sh` in the current release in https://github.com/open-horizon/FDO-support/releases/
    - Update the title and description to indicate the new fix pack version
- When testing, copy new versions of scripts to the test machines