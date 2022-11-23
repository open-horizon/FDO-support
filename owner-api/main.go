package main

import (
	"encoding/base64"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"github.com/google/uuid"
	"github.com/open-horizon/SDO-support/ocs-api/data"
	"github.com/open-horizon/SDO-support/ocs-api/outils"
)

/*
REST API server to authenticate user in order to use the FDO Owner Service (Owner Companion Service) DB files for import a voucher and setting up horizon files for device boot.
*/

// These global vars are necessary because the handler functions are not given any context
var OcsDbDir string
var GetOrgVoucherRegex = regexp.MustCompile(`^/api/orgs/([^/]+)/vouchers/([^/]+)$`)
var GetVoucherRegex = regexp.MustCompile(`^/api/vouchers/([^/]+)$`)       // backward compat
var OrgVouchersRegex = regexp.MustCompile(`^/api/orgs/([^/]+)/vouchers$`) // used for both GET and POST
var OrgKeyRegex = regexp.MustCompile(`^/api/orgs/([^/]+)/keys/([^/]+)$`)  // used for both GET and DELETE
var OrgKeysRegex = regexp.MustCompile(`^/api/orgs/([^/]+)/keys$`)         // used for both GET and POST
var ExchangeUrl string                                                    // the external url, that the device needs
var ExchangeInternalUrl string                                            // will default to ExchangeUrl
var ExchangeInternalCertPath string                                       // will default to /home/sdouser/ocs-api-dir/keys/sdoapi.crt if not set by EXCHANGE_INTERNAL_CERT
var ExchangeInternalRetries int                                           // the number of times to retry connecting to the exchange during startup
var ExchangeInternalInterval int                                          // the number of seconds to wait before retrying again to connect to the exchange during startup
var CssUrl string                                                         // the external url, that the device needs
var PkgsFrom string                                                       // the argument to the agent-install.sh -i flag
var CfgFileFrom string                                                    // the argument to the agent-install.sh -k flag
var KeyImportLock sync.RWMutex
var OCS_API_VERSION = "development"

func main() {
	if len(os.Args) < 3 {
		fmt.Println("Usage: ./ocs-api <port> <ocs-db-path>")
		os.Exit(1)
	}

	// Process cmd line args and env vars
	port := os.Args[1]
	OcsDbDir = os.Args[2]
	outils.SetVerbose()
	ExchangeInternalRetries = outils.GetEnvVarIntWithDefault("EXCHANGE_INTERNAL_RETRIES", 12) // by default a total of 1 minute of trying
	ExchangeInternalInterval = outils.GetEnvVarIntWithDefault("EXCHANGE_INTERNAL_INTERVAL", 5)

	// Ensure we can get to the db, and create the necessary subdirs, if necessary
	if err := os.MkdirAll(OcsDbDir+"/v1/devices", 0750); err != nil {
		outils.Fatal(3, "could not create directory %s: %v", OcsDbDir+"/v1/devices", err)
	}
	if err := os.MkdirAll(OcsDbDir+"/v1/values", 0750); err != nil {
		outils.Fatal(3, "could not create directory %s: %v", OcsDbDir+"/v1/values", err)
	}
	if err := os.MkdirAll(OcsDbDir+"/v1/creds/publicKeys", 0750); err != nil {
		outils.Fatal(3, "could not create directory %s: %v", OcsDbDir+"/v1/creds/publicKeys", err)
	}

	// Create all of the common config files, if we have the necessary env vars to do so
	if httpErr := createConfigFiles(); httpErr != nil {
		outils.Fatal(3, "creating common config files: %s", httpErr.Error())

	}

	//http.HandleFunc("/", rootHandler)
	http.HandleFunc("/api/", apiHandler)

	// Get the cert to use when talking to the exchange for authentication, if set
	if outils.IsEnvVarSet("EXCHANGE_INTERNAL_CERT") {
		crtBytes, err := base64.StdEncoding.DecodeString(os.Getenv("EXCHANGE_INTERNAL_CERT"))
		if err != nil {
			outils.Verbose("Base64 decoding EXCHANGE_INTERNAL_CERT was unsuccessful (%s), using it as not encoded ...", err.Error())
			// Note: supposedly we could instead use this regex to check for base64 encoding: ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)?$
			crtBytes = []byte(os.Getenv("EXCHANGE_INTERNAL_CERT"))
		}
		ExchangeInternalCertPath = "/Users/lorenzoking/Documents/src/github.com/open-horizon/FDO-support/owner-api/agent-install.crt"
		outils.Verbose("Creating %s ...", ExchangeInternalCertPath)
		if err := ioutil.WriteFile(ExchangeInternalCertPath, crtBytes, 0644); err != nil {
			outils.Fatal(3, "could not create "+ExchangeInternalCertPath+": "+err.Error())
		}
	}

	// Listen on the specified port and protocol
	keysDir := outils.GetEnvVarWithDefault("SDO_API_CERT_PATH", "/ocs-api-dir/keys")
	certBaseName := outils.GetEnvVarWithDefault("SDO_API_CERT_BASE_NAME", "sdoapi")
	if outils.PathExists(keysDir+"/"+certBaseName+".crt") && outils.PathExists(keysDir+"/"+certBaseName+".key") {
		if ExchangeInternalCertPath == "" {
			ExchangeInternalCertPath = keysDir + "/" + certBaseName + ".crt" // if it wasn't set, default it to the same cert we are using for listening on our port
			fmt.Printf("Environment variable EXCHANGE_INTERNAL_CERT is not set, defaulting to the certificate in %s\n", ExchangeInternalCertPath)
		}
		outils.VerifyExchangeConnection(ExchangeInternalUrl, ExchangeInternalCertPath, ExchangeInternalRetries, ExchangeInternalInterval)
		fmt.Printf("Listening on HTTPS port %s and using ocs db %s\n", port, OcsDbDir)
		log.Fatal(http.ListenAndServeTLS(":"+port, keysDir+"/"+certBaseName+".crt", keysDir+"/"+certBaseName+".key", nil))
	} else {
		outils.VerifyExchangeConnection(ExchangeInternalUrl, ExchangeInternalCertPath, ExchangeInternalRetries, ExchangeInternalInterval)
		fmt.Printf("Listening on HTTP port %s and using ocs db %s\n", port, OcsDbDir)
		log.Fatal(http.ListenAndServe(":"+port, nil))
	}
} // end of main

// API route dispatcher
func apiHandler(w http.ResponseWriter, r *http.Request) {
	outils.Verbose("Handling %s ...", r.URL.Path)
	if r.Method == "GET" && r.URL.Path == "/api/version" {
		getVersionHandler(w, r)
	} else if matches := GetOrgVoucherRegex.FindStringSubmatch(r.URL.Path); r.Method == "GET" && len(matches) >= 3 { // GET /api/orgs/{ord-id}/vouchers/{device-id}
		getVoucherHandler(matches[1], matches[2], w, r)
	} else if matches := GetVoucherRegex.FindStringSubmatch(r.URL.Path); r.Method == "GET" && len(matches) >= 2 { // backward compat: GET /api/vouchers/{device-id}
		getVoucherHandler("", matches[1], w, r)
	} else if matches := OrgVouchersRegex.FindStringSubmatch(r.URL.Path); r.Method == "GET" && len(matches) >= 2 { // GET /api/orgs/{ord-id}/vouchers
		getVouchersHandler(matches[1], w, r)
	} else if r.Method == "GET" && r.URL.Path == "/api/vouchers" { // backward compat
		getVouchersHandler("", w, r)
	} else if matches := OrgVouchersRegex.FindStringSubmatch(r.URL.Path); r.Method == "POST" && len(matches) >= 2 { // POST /api/orgs/{ord-id}/vouchers
		postVoucherHandler(matches[1], w, r)
	} else if r.Method == "POST" && (r.URL.Path == "/api/vouchers" || r.URL.Path == "/api/voucher") { // backward compat: /api/voucher is for until we update hzn voucher import
		postVoucherHandler("", w, r)
	} else if matches := OrgKeyRegex.FindStringSubmatch(r.URL.Path); r.Method == "GET" && len(matches) >= 3 { // GET /api/orgs/{org-id}/keys/{key-name}
		getKeyHandler(matches[1], matches[2], w, r)
	} else if matches := OrgKeyRegex.FindStringSubmatch(r.URL.Path); r.Method == "DELETE" && len(matches) >= 3 { // DELETE /api/orgs/{org-id}/keys/{key-name}
		deleteKeyHandler(matches[1], matches[2], w, r)
	} else if matches := OrgKeysRegex.FindStringSubmatch(r.URL.Path); r.Method == "GET" && len(matches) >= 2 { // GET /api/orgs/{ord-id}/keys
		getKeysHandler(matches[1], w, r)
	} else if matches := OrgKeysRegex.FindStringSubmatch(r.URL.Path); r.Method == "POST" && len(matches) >= 2 { // POST /api/orgs/{ord-id}/keys
		postImportKeysHandler(matches[1], w, r)
	} else {
		http.Error(w, "Route "+r.URL.Path+" not found", http.StatusNotFound)
	}
	// Note: we used to also support a route that would allow an admin to change the config (i.e. run createConfigFiles()) w/o restarting
	//		the container, but penetration testing deemed it a security exposure, because you can cause this service to do arbitrary DNS lookups.
}

// Route Handlers --------------------------------------------------------------------------------------------------

//============= GET /api/version =============
// Returns the ocs-api version (in plain text, not json)
func getVersionHandler(w http.ResponseWriter, r *http.Request) {
	outils.Verbose("GET /api/version ...")

	// Send voucher to client
	w.WriteHeader(http.StatusOK) // seems like this has to be before writing the body
	w.Header().Set("Content-Type", "text/plain")
	_, err := w.Write([]byte(OCS_API_VERSION))
	if err != nil {
		outils.Error(err.Error())
	}
}

//============= GET /api/orgs/{ord-id}/vouchers/{device-id} and GET /api/vouchers/{device-id} =============
// Reads/returns an already imported voucher
func getVoucherHandler(orgId, deviceUuid string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("GET /api/orgs/%s/vouchers/%s ...", orgId, deviceUuid)

	// Determine the org id to use for the device, based on various inputs
	deviceOrgId, httpErr := getDeviceOrgId(orgId, r)
	if httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	if authenticated, _, httpErr := outils.ExchangeAuthenticate(r, ExchangeInternalUrl, deviceOrgId, ExchangeInternalCertPath); httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	} else if !authenticated {
		http.Error(w, "invalid exchange credentials provided", http.StatusUnauthorized)
		return
	}

	// Read voucher.json from the db
	voucherFileName := OcsDbDir + "/v1/devices/" + deviceUuid + "/voucher.json"
	voucherBytes, err := ioutil.ReadFile(filepath.Clean(voucherFileName))
	if err != nil {
		http.Error(w, "Error reading "+voucherFileName+": "+err.Error(), http.StatusNotFound)
		return
	}

	// Confirm this voucher/device is in the client's org. Doing this check after getting the voucher, because if the
	// voucher doesn't exist, we want them get that error, rather than that it is not in their org
	orgidTxtStr, httpErr := getOrgidTxtStr(deviceUuid)
	if httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}
	if orgidTxtStr != deviceOrgId { // this device is in our org
		http.Error(w, "Device "+deviceUuid+" is not in org "+deviceOrgId, http.StatusForbidden)
		return
	}

	// Send voucher to client
	w.Header().Set("Content-Type", "application/json")
	outils.WriteResponse(http.StatusOK, w, voucherBytes)
}

//============= GET /api/orgs/{ord-id}/vouchers and GET /api/vouchers =============
// Reads/returns all of the already imported vouchers
func getVouchersHandler(orgId string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("GET /api/orgs/%s/vouchers ...", orgId)

	// Determine the org id to use for the device, based on various inputs
	deviceOrgId, httpErr := getDeviceOrgId(orgId, r)
	if httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	if authenticated, _, httpErr := outils.ExchangeAuthenticate(r, ExchangeInternalUrl, deviceOrgId, ExchangeInternalCertPath); httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	} else if !authenticated {
		http.Error(w, "invalid exchange credentials provided", http.StatusUnauthorized)
		return
	}

	// Read the v1/devices/ directory in the db
	vouchersDirName := OcsDbDir + "/v1/devices"
	deviceDirs, err := ioutil.ReadDir(filepath.Clean(vouchersDirName))
	if err != nil {
		http.Error(w, "Error reading "+vouchersDirName+" directory: "+err.Error(), http.StatusInternalServerError)
		return
	}

	vouchers := []string{}
	for _, dir := range deviceDirs {
		if dir.IsDir() {
			// Look inside the device dir for orgid.txt to see if is part of the org we are listing
			orgidTxtStr, httpErr := getOrgidTxtStr(dir.Name())
			if httpErr != nil {
				http.Error(w, httpErr.Error(), httpErr.Code)
				return
			}
			if orgidTxtStr == deviceOrgId { // this device is in our org
				vouchers = append(vouchers, dir.Name())
			}
		}
	}

	// Send vouchers to client
	outils.WriteJsonResponse(http.StatusOK, w, vouchers)
}

//============= POST /api/orgs/{ord-id}/vouchers and POST /api/vouchers =============
// Imports a voucher (can be called again for an existing voucher and will update/overwrite)
func postVoucherHandler(orgId string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("POST /api/orgs/%s/vouchers ...", orgId)
	valuesDir := OcsDbDir + "/v1/values"

	// Determine the org id to use for the device, based on various inputs
	deviceOrgId, httpErr := getDeviceOrgId(orgId, r)
	if httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	// Authenticate this user with the exchange
	if authenticated, _, httpErr := outils.ExchangeAuthenticate(r, ExchangeInternalUrl, deviceOrgId, ExchangeInternalCertPath); httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	} else if !authenticated {
		http.Error(w, "invalid exchange credentials provided", http.StatusUnauthorized)
		return
	}

	if httpErr := outils.IsValidPostJson(r); httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	// Parse the request body
	type OhStruct struct {
		Guid []byte `json:"g"` // making it type []byte will automatically base64 decode the json value
	}
	type Voucher struct {
		Oh OhStruct `json:"oh"`
	}

	voucher := Voucher{}
	bodyBytes, err := ioutil.ReadAll(r.Body) // we need the request body in 2 forms (bytes and the Voucher struct), but can only read it once, so get it as bytes
	if err != nil {
		http.Error(w, "Error reading the request body: "+err.Error(), http.StatusBadRequest)
		return
	}
	if httpErr := outils.ParseJsonString(bodyBytes, &voucher); httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	// Get, decode, and convert the device uuid
	uuid, err := uuid.FromBytes(voucher.Oh.Guid)
	if err != nil {
		http.Error(w, "Error converting GUID to UUID: "+err.Error(), http.StatusBadRequest)
		return
	}
	outils.Verbose("POST /api/orgs/%/vouchers: device UUID: %s", deviceOrgId, uuid.String())

	// Create the device directory in the OCS DB
	deviceDir := OcsDbDir + "/v1/devices/" + uuid.String()
	if err := os.MkdirAll(deviceDir, 0750); err != nil {
		http.Error(w, "could not create directory "+deviceDir+": "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Remove the state.json file, in case this voucher was previously imported. This allows to0 to be run again (register it with RV)
	fileName := deviceDir + "/state.json"
	outils.Verbose("POST /api/orgs/%s/vouchers: removing %s (if exists) ...", deviceOrgId, fileName)
	if err := os.RemoveAll(filepath.Clean(fileName)); err != nil { // RemoveAll does NOT return an error if fileName doesn't exist
		http.Error(w, "could not remove "+fileName+": "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Put the voucher in the OCS DB
	fileName = deviceDir + "/voucher.json"
	outils.Verbose("POST /api/orgs/%s/vouchers: creating %s ...", deviceOrgId, fileName)
	if err := ioutil.WriteFile(filepath.Clean(fileName), bodyBytes, 0644); err != nil {
		http.Error(w, "could not create "+fileName+": "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Create the device download file (svi.json) and psi.json
	fileName = deviceDir + "/svi.json"
	outils.Verbose("POST /api/orgs/%s/vouchers: creating %s ...", deviceOrgId, fileName)
	sviJson1 := ""
	if outils.PathExists(valuesDir + "/agent-install.crt") {
		sviJson1 = data.SviJson1
	}
	sviJson := "[" + sviJson1 + data.SviJson2 + uuid.String() + data.SviJson3 + "]"
	if err := ioutil.WriteFile(filepath.Clean(fileName), []byte(sviJson), 0644); err != nil {
		http.Error(w, "could not create "+fileName+": "+err.Error(), http.StatusInternalServerError)
		return
	}
	fileName = deviceDir + "/psi.json"
	outils.Verbose("POST /api/orgs/%s/vouchers: creating %s ...", deviceOrgId, fileName)
	if err := ioutil.WriteFile(filepath.Clean(fileName), []byte(data.PsiJson), 0644); err != nil {
		http.Error(w, "could not create "+fileName+": "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Create orgid.txt file to identify what org this device/voucher is part of
	fileName = deviceDir + "/orgid.txt"
	outils.Verbose("POST /api/orgs/%s/vouchers: creating %s with value: %s ...", deviceOrgId, fileName, deviceOrgId)
	if err := ioutil.WriteFile(filepath.Clean(fileName), []byte(deviceOrgId), 0644); err != nil {
		http.Error(w, "could not create "+fileName+": "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Generate a node token
	nodeToken, httpErr := outils.GenerateNodeToken()
	if httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	// Create exec file
	// Note: currently agent-install-wrapper.sh requires that the flags be in this order!!!!
	execCmd := outils.MakeExecCmd(fmt.Sprintf("/bin/sh agent-install-wrapper.sh -i %s -a %s:%s -O %s -k %s", PkgsFrom, uuid.String(), nodeToken, deviceOrgId, CfgFileFrom))
	fileName = OcsDbDir + "/v1/values/" + uuid.String() + "_exec"
	outils.Verbose("POST /api/orgs/%s/vouchers: creating %s ...", deviceOrgId, fileName)
	if err := ioutil.WriteFile(filepath.Clean(fileName), []byte(execCmd), 0644); err != nil {
		http.Error(w, "could not create "+fileName+": "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Send response to client
	respBody := map[string]interface{}{
		"deviceUuid": uuid.String(),
		"nodeToken":  nodeToken,
	}
	outils.WriteJsonResponse(http.StatusCreated, w, respBody)
}

//============= GET /api/orgs/{org-id}/keys =============
// Reads/returns metadata of the already created owner key
func getKeysHandler(orgId string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("GET /api/orgs/%s/keys ...", orgId)

	// Determine the org id to use for the device, based on various inputs
	deviceOrgId, httpErr := getDeviceOrgId(orgId, r)
	if httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	authenticated, user, httpErr := outils.ExchangeAuthenticate(r, ExchangeInternalUrl, deviceOrgId, ExchangeInternalCertPath)
	if httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	} else if !authenticated {
		http.Error(w, "invalid exchange credentials provided", http.StatusUnauthorized)
		return
	}

	// Get the expired disposition of each key certificate and build a map of them
	outils.Verbose("Running command: ./get-owner-key-expirations.sh %s %s", deviceOrgId, user)
	// using read mutex so only no other client can write to the keystore while we are reading the keystore
	KeyImportLock.RLock()
	stdOut, stdErr, err := outils.RunCmd(outils.RunCmdOpts{}, "./get-owner-key-expirations.sh", deviceOrgId, user)
	KeyImportLock.RUnlock()
	if err != nil {
		http.Error(w, "error running get-owner-key-expirations.sh: "+err.Error(), http.StatusInternalServerError) // this includes stdErr
		return
	} else {
		if len(stdErr) > 0 { // with shell scripts there can be error msgs in stderr even though the exit code was 0
			outils.Verbose("stderr from delete-owner-key.sh: %s", string(stdErr))
		}
		outils.Verbose("get-owner-key-expirations.sh stdout: " + string(stdOut))
	}
	expiredMap := make(map[string]bool)
	trimmedStdOut := strings.TrimRight(string(stdOut), "\n") // using TrimRight() instead of TrimSuffix() because the former will trim multiple newlines
	if len(trimmedStdOut) > 0 {
		for _, line := range strings.Split(trimmedStdOut, "\n") {
			// echo line is: <org>_<key-name>: <true or false>
			parts := strings.Split(line, ": ")
			if len(parts) != 2 {
				http.Error(w, "unexpected line of output from get-owner-key-expirations.sh: "+line, http.StatusInternalServerError)
				return
			}
			orgAndKey := parts[0]
			var isExpired bool
			if parts[1] == "true" {
				isExpired = true
			} else if parts[1] == "false" {
				isExpired = false
			} else {
				http.Error(w, "unexpected expiration value from get-owner-key-expirations.sh: "+parts[1], http.StatusInternalServerError)
				return
			}
			expiredMap[orgAndKey] = isExpired
		}
	} // else just leave expiredMap empty

	// Read the publicKeys/<org> directory in the db, and then read each <user> sub-dir to get all of the pubic key file names
	pubKeyDirName := OcsDbDir + "/v1/creds/publicKeys/" + deviceOrgId
	if err := os.MkdirAll(pubKeyDirName, 0750); err != nil { // in case the sub-dir doesn't even exist yet
		http.Error(w, "could not create directory "+pubKeyDirName+": "+err.Error(), http.StatusInternalServerError)
		return
	}
	userDirs, err := ioutil.ReadDir(filepath.Clean(pubKeyDirName))
	if err != nil {
		http.Error(w, "Error reading "+pubKeyDirName+" directory: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Struct for 1 element of the response body array
	type KeyMeta struct {
		Name      string `json:"name"`
		Orgid     string `json:"orgid"`
		Owner     string `json:"owner"`
		FileName  string `json:"fileName"`
		IsExpired bool   `json:"isExpired"`
	}

	pubKeyList := make([]KeyMeta, 0)
	for _, u := range userDirs {
		if u.IsDir() {
			user := u.Name()
			uDir := pubKeyDirName + "/" + user
			keyFiles, err := ioutil.ReadDir(filepath.Clean(uDir))
			if err != nil {
				http.Error(w, "Error reading "+uDir+" directory: "+err.Error(), http.StatusInternalServerError)
				return
			}
			for _, f := range keyFiles {
				if !f.IsDir() {
					// determine key-name by stripping org and public-key.pem
					orgAndKey := strings.TrimSuffix(f.Name(), "_public-key.pem")
					keyName := strings.TrimPrefix(orgAndKey, strings.ToLower(deviceOrgId)+"_")
					// get whether of not this key is expired from the map we created earlier
					isExpired, ok := expiredMap[orgAndKey]
					if !ok {
						http.Error(w, "map key "+orgAndKey+" does not exist in expiration map", http.StatusInternalServerError) // mismatch between private keys in keystore and public keys in directory
						return
					}
					keyMeta := KeyMeta{Name: keyName, FileName: f.Name(), Orgid: deviceOrgId, Owner: user, IsExpired: isExpired}
					pubKeyList = append(pubKeyList, keyMeta)
				}
			}
		}
	}

	// Send file names to client
	httpCode := http.StatusOK
	if len(pubKeyList) == 0 {
		httpCode = http.StatusNotFound
	}
	outils.WriteJsonResponse(httpCode, w, pubKeyList)
}

//============= GET /api/orgs/{org-id}/keys/{key-name} =============
// Reads/returns an already existing public key
func getKeyHandler(orgId, keyName string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("GET /api/orgs/%s/keys/%s ...", orgId, keyName)

	// Determine the org id to use for the device, based on various inputs
	deviceOrgId, httpErr := getDeviceOrgId(orgId, r)
	if httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	authenticated, user, httpErr := outils.ExchangeAuthenticate(r, ExchangeInternalUrl, deviceOrgId, ExchangeInternalCertPath)
	if httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	} else if !authenticated {
		http.Error(w, "invalid exchange credentials provided", http.StatusUnauthorized)
		return
	}

	// Verify key file is in the db
	pubKeyDirName := OcsDbDir + "/v1/creds/publicKeys/" + deviceOrgId
	if err := os.MkdirAll(pubKeyDirName, 0750); err != nil { // in case the sub-dir doesn't even exist yet
		http.Error(w, "could not create directory "+pubKeyDirName+": "+err.Error(), http.StatusInternalServerError)
		return
	}
	pubKeyFileName := pubKeyDirName + "/" + user + "/" + strings.ToLower(deviceOrgId+"_"+keyName) + "_public-key.pem"
	if !outils.PathExists(pubKeyFileName) {
		//http.Error(w, "Public key "+keyName+" for user "+user+" not found", http.StatusNotFound)
		w.WriteHeader(http.StatusNotFound)
		return
	}

	// Send public key file to client
	//w.WriteHeader(http.StatusCreated) // http.ServeFile() does this too
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment; filename="+keyName)
	http.ServeFile(w, r, pubKeyFileName)
}

//============= DELETE /api/orgs/{org-id}/keys/{key-name} =============
// Deletes an already imported key pair (public and private keys)
func deleteKeyHandler(orgId, keyName string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("DELETE /api/orgs/%s/keys/%s ...", orgId, keyName)

	// Determine the org id to use for the device, based on various inputs
	deviceOrgId, httpErr := getDeviceOrgId(orgId, r)
	if httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	authenticated, user, httpErr := outils.ExchangeAuthenticate(r, ExchangeInternalUrl, deviceOrgId, ExchangeInternalCertPath)
	if httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	} else if !authenticated {
		http.Error(w, "invalid exchange credentials provided", http.StatusUnauthorized)
		return
	}

	// Verify key file is in the db
	pubKeyDirName := OcsDbDir + "/v1/creds/publicKeys/" + deviceOrgId
	if err := os.MkdirAll(pubKeyDirName, 0750); err != nil { // in case the sub-dir doesn't even exist yet
		http.Error(w, "could not create directory "+pubKeyDirName+": "+err.Error(), http.StatusInternalServerError)
		return
	}
	pubKeyFileName := pubKeyDirName + "/" + user + "/" + strings.ToLower(deviceOrgId+"_"+keyName) + "_public-key.pem"
	if !outils.PathExists(pubKeyFileName) {
		//http.Error(w, "Public key "+keyName+" for user "+user+" not found", http.StatusNotFound)
		w.WriteHeader(http.StatusNotFound)
		return
	}

	// Run script to delete the private and public keys
	outils.Verbose("Running command: ./delete-owner-key.sh %s %s %s", deviceOrgId, user, keyName)
	// Using mutex so only 1 instance of the script writes to the keystore at a time
	KeyImportLock.Lock()
	stdOut, stdErr, err := outils.RunCmd(outils.RunCmdOpts{}, "./delete-owner-key.sh", deviceOrgId, user, keyName)
	KeyImportLock.Unlock()
	if err != nil {
		http.Error(w, "error running delete-owner-key.sh: "+err.Error(), http.StatusBadRequest) // this includes stdErr
		return
	} else {
		if len(stdErr) > 0 { // with shell scripts there can be error msgs in stderr even though the exit code was 0
			outils.Verbose("stderr from delete-owner-key.sh: %s", string(stdErr))
		}
		outils.Verbose(string(stdOut))
	}

	w.WriteHeader(http.StatusNoContent)
}

//============= POST /api/orgs/{org-id}/keys =============
// Receives in the body json the arguments required to run import-owner-key-pairs.sh script, which will create and import the private keys into the master keystore,
// and stores the combine public keys into the file DB.
// This allows sdo-owner-services to read vouchers intended for them, and to securely communicate with their devices booting up.
func postImportKeysHandler(orgId string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("POST /api/orgs/%s/keys ...", orgId)

	// Determine the org id to use for the device, based on various inputs
	deviceOrgId, httpErr := getDeviceOrgId(orgId, r)
	if httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	//valuesDir := OcsDbDir + "/v1/values"
	authenticated, user, httpErr := outils.ExchangeAuthenticate(r, ExchangeInternalUrl, deviceOrgId, ExchangeInternalCertPath)
	if httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	} else if !authenticated {
		http.Error(w, "invalid exchange credentials provided", http.StatusUnauthorized)
		return
	}

	// Verify content type
	if httpErr := outils.IsValidPostBinary(r); httpErr == nil {
		http.Error(w, "Error: Passing a key pair tar file into this API is no longer supported.", http.StatusBadRequest)
		return
	}

	if httpErr := outils.IsValidPostJson(r); httpErr != nil {
		http.Error(w, "Error: This API only supports json.", httpErr.Code)
		return
	}

	// Struct for json form containing key pair information
	type Information struct {
		Key_name     string `json:"key_name"`
		Common_name  string `json:"common_name"`
		Email_name   string `json:"email_name"`
		Company_name string `json:"company_name"`
		Country_name string `json:"country_name"`
		State_name   string `json:"state_name"`
		Locale_name  string `json:"locale_name"`
	}

	info := Information{}
	// Parse the request body
	if httpErr := outils.ReadJsonBody(r, &info); httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	// Key name must not contain any characters that cant be stored in a file name.
	// Also can't allow underscores - since orgs can also have them, it could result in 2 different combos of org and key name having the same private key alias
	var isStringAlphabetic = regexp.MustCompile(`^[a-z0-9\-]*$`).MatchString
	if !isStringAlphabetic(info.Key_name) {
		http.Error(w, "Key Name can only contain lowercase characters, numbers, and hyphens.", http.StatusBadRequest)
		return
	}

	if len(info.Country_name) > 2 {
		http.Error(w, "Country name must be a 2 Letter Country Code.", http.StatusBadRequest)
		return
	}

	// Run the script that will create and import the key pairs
	// for dev/test they can specify the url param expired=true to create an already expired key
	runCmdOpts := outils.RunCmdOpts{}
	expired, ok := r.URL.Query()["expired"]
	if ok && len(expired) > 0 && expired[0] == "true" {
		runCmdOpts.Environ = append(runCmdOpts.Environ, "CREATE_EXPIRED_KEY=true")
		//os.Setenv("CREATE_EXPIRED_KEY", "true") // can't do this, because it will set it persistently for all threads serving clients
		fmt.Printf("Creating expired test key %s ...\n", strings.ToLower(deviceOrgId+"_"+info.Key_name))
	}
	outils.Verbose("Running command: ./import-owner-private-keys2.sh %s %s %s %s %s %s %s %s %s", deviceOrgId, info.Key_name, info.Common_name, info.Email_name, info.Company_name, info.Country_name, info.State_name, info.Locale_name, user)
	// Using mutex so only 1 instance of the script writes to the keystore at a time
	KeyImportLock.Lock()
	stdOut, stdErr, err := outils.RunCmd(runCmdOpts, "./import-owner-private-keys2.sh", deviceOrgId, info.Key_name, info.Common_name, info.Email_name, info.Company_name, info.Country_name, info.State_name, info.Locale_name, user)
	KeyImportLock.Unlock()
	if err != nil {
		http.Error(w, "error running import-owner-private-keys2.sh: "+err.Error(), http.StatusBadRequest) // this includes stdErr
		return
	} else {
		if len(stdErr) > 0 { // with shell scripts there can be error msgs in stderr even though the exit code was 0
			outils.Verbose("stderr from import-owner-private-keys2.sh: %s", string(stdErr))
		}
		outils.Verbose(string(stdOut))
	}

	pubKeyDirName := OcsDbDir + "/v1/creds/publicKeys/" + deviceOrgId + "/" + user
	fileName := strings.ToLower(deviceOrgId+"_"+info.Key_name) + "_public-key.pem" // need to make the file name lowercase, because the script did

	w.WriteHeader(http.StatusCreated) // http.ServeFile() sets the code to StatusOK so you'll see a warning about superfluous response.WriteHeader
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment; filename=owner-public-key.pem")
	http.ServeFile(w, r, pubKeyDirName+"/"+fileName)
}

//============= Non-Route Functions =============

// Determine the org id to use for the device, based on various inputs from the client
func getDeviceOrgId(orgId string, r *http.Request) (string, *outils.HttpError) {
	/* Get the orgid this device should be put in. It can come from several places (in precedence order):
	- they ran a route that includes the org id (and is passed to this function as orgId)
	- they explicitly specify the org in the url param: ?orgid=<org>
	- if the creds are NOT in the root org, use the cred org
	*/
	if orgId != "" {
		return orgId, nil
	}

	orgAndUser, _, ok := r.BasicAuth()
	if !ok {
		return "", outils.NewHttpError(http.StatusUnauthorized, "invalid exchange credentials provided")
	}
	parts := strings.Split(orgAndUser, "/")
	if len(parts) != 2 {
		return "", outils.NewHttpError(http.StatusUnauthorized, "invalid exchange credentials provided")
	}
	credOrgId := parts[0]

	deviceOrgId := ""
	orgidParams, ok := r.URL.Query()["orgid"]
	if ok && len(orgidParams) > 0 && len(orgidParams[0]) > 0 {
		deviceOrgId = orgidParams[0]
	} else if credOrgId != "root" {
		deviceOrgId = credOrgId
	}

	if deviceOrgId == "" {
		return "", outils.NewHttpError(http.StatusBadRequest, "if using the exchange root user, you must explicitly specify the org id via the ?orgid=<org-id> URL query parameter")
	}
	return deviceOrgId, nil
}

// Return the org of this device based on the orgid.txt file stored with it, or return ""
func getOrgidTxtStr(deviceId string) (string, *outils.HttpError) {
	// Look inside the device dir for orgid.txt to what org it belongs to
	vouchersDirName := OcsDbDir + "/v1/devices"
	orgidTxtFileName := filepath.Clean(vouchersDirName + "/" + deviceId + "/orgid.txt")
	orgidTxtStr := "" // default if we don't find it in the orgid.txt
	if outils.PathExists(orgidTxtFileName) {
		var orgidTxtBytes []byte
		var err error
		if orgidTxtBytes, err = ioutil.ReadFile(orgidTxtFileName); err != nil {
			return "", outils.NewHttpError(http.StatusInternalServerError, "Error reading "+orgidTxtFileName+": "+err.Error())
		} else {
			orgidTxtStr = string(orgidTxtBytes)
			orgidTxtStr = strings.TrimSuffix(orgidTxtStr, "\n")
		}
	}
	return orgidTxtStr, nil
}

// Create the common (not device specific) config files. Called during startup.
func createConfigFiles() *outils.HttpError {
	// These env vars are required
	if !outils.IsEnvVarSet("HZN_EXCHANGE_URL") || !outils.IsEnvVarSet("HZN_FSS_CSSURL") {
		return outils.NewHttpError(http.StatusBadRequest, "these environment variables must be set: HZN_EXCHANGE_URL, HZN_FSS_CSSURL")
	}

	valuesDir := OcsDbDir + "/v1/values"
	var fileName, dataStr string

	// Create agent-install.crt and its name file
	var crt []byte
	if outils.IsEnvVarSet("HZN_MGMT_HUB_CERT") {
		var err error
		crt, err = base64.StdEncoding.DecodeString(os.Getenv("HZN_MGMT_HUB_CERT"))
		if err != nil {
			outils.Verbose("Base64 decoding HZN_MGMT_HUB_CERT was unsuccessful (%s), using it as not encoded ...", err.Error())
			// Note: supposedly we could instead use this regex to check for base64 encoding: ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)?$
			crt = []byte(os.Getenv("HZN_MGMT_HUB_CERT"))
			//return outils.NewHttpError(http.StatusBadRequest, "could not base64 decode HZN_MGMT_HUB_CERT: "+err.Error())
		}
	}
	if len(crt) > 0 {
		fileName = valuesDir + "/agent-install.crt"
		outils.Verbose("Creating %s ...", fileName)
		if err := ioutil.WriteFile(filepath.Clean(fileName), crt, 0644); err != nil {
			return outils.NewHttpError(http.StatusInternalServerError, "could not create "+fileName+": "+err.Error())
		}

		fileName = valuesDir + "/agent-install-crt_name"
		outils.Verbose("Creating %s ...", fileName)
		dataStr = "agent-install.crt"
		if err := ioutil.WriteFile(filepath.Clean(fileName), []byte(dataStr), 0644); err != nil {
			return outils.NewHttpError(http.StatusInternalServerError, "could not create "+fileName+": "+err.Error())
		}
	}

	// Create agent-install.cfg and its name file
	ExchangeUrl = os.Getenv("HZN_EXCHANGE_URL")
	// CurrentExchangeInternalUrl is not needed for the device config file, only for ocs-api exchange authentication
	if outils.IsEnvVarSet("EXCHANGE_INTERNAL_URL") {
		ExchangeInternalUrl = os.Getenv("EXCHANGE_INTERNAL_URL")
	} else {
		ExchangeInternalUrl = ExchangeUrl // default
	}
	CssUrl = os.Getenv("HZN_FSS_CSSURL")
	fileName = valuesDir + "/agent-install.cfg"
	outils.Verbose("Creating %s ...", fileName)
	dataStr = "HZN_EXCHANGE_URL=" + ExchangeUrl + "\nHZN_FSS_CSSURL=" + CssUrl + "\n" // we now explicitly set the org via the agent-install.sh -O flag
	if len(crt) > 0 {
		// only add this if we actually created the agent-install.crt file above
		dataStr += "HZN_MGMT_HUB_CERT_PATH=agent-install.crt\n"
	}
	if err := ioutil.WriteFile(fileName, []byte(dataStr), 0644); err != nil {
		return outils.NewHttpError(http.StatusInternalServerError, "could not create "+fileName+": "+err.Error())
	}
	fmt.Printf("Will be configuring devices to use config:\n%s\n", dataStr)

	fileName = valuesDir + "/agent-install-cfg_name"
	outils.Verbose("Creating %s ...", fileName)
	dataStr = "agent-install.cfg"
	if err := ioutil.WriteFile(filepath.Clean(fileName), []byte(dataStr), 0644); err != nil {
		return outils.NewHttpError(http.StatusInternalServerError, "could not create "+fileName+": "+err.Error())
	}

	// Create agent-install-wrapper.sh and its name file
	fileName = valuesDir + "/agent-install-wrapper.sh"
	outils.Verbose("Copying ./agent-install-wrapper.sh to %s ...", fileName)
	if err := outils.CopyFile("./scripts/agent-install-wrapper.sh", filepath.Clean(fileName), 0750); err != nil {
		return outils.NewHttpError(http.StatusInternalServerError, "could not copy ./agent-install-wrapper.sh to "+fileName+": "+err.Error())
	}

	fileName = valuesDir + "/agent-install-wrapper-sh_name"
	outils.Verbose("Creating %s ...", fileName)
	dataStr = "agent-install-wrapper.sh"
	if err := ioutil.WriteFile(filepath.Clean(fileName), []byte(dataStr), 0644); err != nil {
		return outils.NewHttpError(http.StatusInternalServerError, "could not create "+fileName+": "+err.Error())
	}

	PkgsFrom = os.Getenv("SDO_GET_PKGS_FROM")
	if PkgsFrom == "" {
		PkgsFrom = "https://github.com/open-horizon/anax/releases/latest/download" // default
	}
	fmt.Printf("Will be configuring devices to get horizon packages from %s\n", PkgsFrom)
	// try to ensure they didn't give us a bad value for SDO_GET_PKGS_FROM
	if !strings.HasPrefix(PkgsFrom, "https://github.com/open-horizon/anax/releases") && !strings.HasPrefix(PkgsFrom, "css:") {
		outils.Warning("Unrecognized value specified for SDO_GET_PKGS_FROM: %s", PkgsFrom)
		// continue, because maybe this is a value for the agent-install.sh -i flag that we don't know about yet
	}

	CfgFileFrom = os.Getenv("SDO_GET_CFG_FILE_FROM")
	if CfgFileFrom == "" {
		CfgFileFrom = "css:" // default
	}
	fmt.Printf("Will be configuring devices to get agent-install.cfg from %s\n", CfgFileFrom)
	// try to ensure they didn't give us a bad value for SDO_GET_CFG_FILE_FROM
	if !strings.HasPrefix(CfgFileFrom, "agent-install.cfg") && !strings.HasPrefix(CfgFileFrom, "css:") {
		outils.Warning("Unrecognized value specified for SDO_GET_CFG_FILE_FROM: %s", CfgFileFrom)
		// continue, because maybe this is a value for the agent-install.sh -i flag that we don't know about yet
	}

	return nil
}
