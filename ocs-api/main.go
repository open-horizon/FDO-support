package main

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"io/ioutil"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	dab "github.com/Snawoot/go-http-digest-auth-client"
	"github.com/open-horizon/FDO-support/ocs-api/outils"
)

/*
REST API server to authenticate user in order to use the FDO Owner Service (Owner Companion Service) DB files for import a voucher and setting up horizon files for device boot.
*/

// These global vars are necessary because the handler functions are not given any context
var OcsDbDir string
var OrgFDOVersionRegex = regexp.MustCompile(`^/api/orgs/([^/]+)/fdo/version$`)          // used for GET
var OrgFDOVouchersRegex = regexp.MustCompile(`^/api/orgs/([^/]+)/fdo/vouchers$`)        // used for both GET and POST
var GetFDOVoucherRegex = regexp.MustCompile(`^/api/orgs/([^/]+)/fdo/vouchers/([^/]+)$`) // backward compat
var OrgFDOKeyRegex = regexp.MustCompile(`^/api/orgs/([^/]+)/fdo/certificate/([^/]+)$`)  // used for GET , THIS NEEDS TO BE UPDATED IN ORDER TO RECOGNIZE KEY TYPE
var OrgFDORedirectRegex = regexp.MustCompile(`^/api/orgs/([^/]+)/fdo/redirect$`)        // used for GET
var GetFDOTo0Regex = regexp.MustCompile(`^/api/orgs/([^/]+)/fdo/to0/([^/]+)$`)
var OrgFDOResourceRegex = regexp.MustCompile(`^/api/orgs/([^/]+)/fdo/resource/([^/]+)$`) //used for both GET and POST
var OrgFDOServiceInfoRegex = regexp.MustCompile(`^/api/orgs/([^/]+)/fdo/svi$`)           // used for GET
var ExchangeUrl string                                                                   // the external url, that the device needs
var ExchangeInternalUrl string                                                           // will default to ExchangeUrl
var ExchangeInternalCertPath string                                                      // will default to /home/sdouser/ocs-api-dir/keys/sdoapi.crt if not set by EXCHANGE_INTERNAL_CERT
var ExchangeInternalRetries int                                                          // the number of times to retry connecting to the exchange during startup
var ExchangeInternalInterval int                                                         // the number of seconds to wait before retrying again to connect to the exchange during startup
var CssUrl string                                                                        // the external url, that the device needs
var PkgsFrom string                                                                      // the argument to the agent-install.sh -i flag
var CfgFileFrom string                                                                   // the argument to the agent-install.sh -k flag
var KeyImportLock sync.RWMutex

func main() {
	if len(os.Args) < 3 {
		fmt.Println("Usage: ./ocs-api <port> <ocs-db-path>")
		os.Exit(1)
	}

	var fdoTo2URL string
	var to2Body string

	// Process cmd line args and env vars
	port := os.Args[1]
	OcsDbDir = os.Args[2]

	workingDir, err := os.Getwd()
	if err != nil {
		fmt.Println(err)
	}
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

	// Set To2 Address on start up in FDO Owner Services
	fdoTo2Host, fdoTo2Port := outils.GetTo2OwnerHost()
	fmt.Println("Setting To2 Address as: " + fdoTo2Host + ":" + fdoTo2Port)
	fdoOwnerURL := os.Getenv("HZN_FDO_API_URL")
	if fdoOwnerURL == "" {
		log.Fatalln("HZN_FDO_API_URL is not set")
	}
	to2Body = (`[[null,"` + fdoTo2Host + `",` + fdoTo2Port + `,3]]`)
	fdoTo2URL = fdoOwnerURL + "/api/v1/owner/redirect"
	to2Byte := []byte(to2Body)
	username, password := outils.GetOwnerServiceApiKey()
	fmt.Println("This is the GET To2 Redirect API route: " + fdoTo2URL)

	client := &http.Client{
		Transport: dab.NewDigestTransport(username, password, http.DefaultTransport),
	}
	if !isValidURL(fdoOwnerURL) {
		log.Fatalln("url not in whitelist")
	}
	resp, err := client.Post(fdoTo2URL, "text/plain", bytes.NewReader(to2Byte))
	if err != nil {
		outils.NewHttpError(http.StatusInternalServerError, "Error setting To2 address: "+fdoTo2URL+": "+err.Error())
		return
	}

	if resp.Body != nil {
		defer resp.Body.Close()
	}

	// Create agent-install.crt
	valuesDir := OcsDbDir + "/v1/values"
	fileName := valuesDir + "/agent-install.crt"
	fmt.Println("Posting agent-install.crt package: " + fileName)
	certFile, err := ioutil.ReadFile(fileName)
	if err != nil {
		outils.NewHttpError(http.StatusInternalServerError, "Error reading "+fileName+": "+err.Error())
		return
	}
	// Post agent-install.crt in FDO Owner Services
	certResource := "agent-install.crt"
	fdoCertURL := fdoOwnerURL + "/api/v1/owner/resource?filename=" + certResource
	fmt.Println("URL for agent-install.crt: " + fdoCertURL)

	newResp, err := client.Post(fdoCertURL, "text/plain", bytes.NewReader(certFile))
	if err != nil {
		outils.NewHttpError(http.StatusInternalServerError, "Error posting "+certResource+" in SVI Database: "+err.Error())
		return
	}
	if newResp.Body != nil {
		defer newResp.Body.Close()
	}

	// Create agent-install.cfg
	valuesDir = OcsDbDir + "/v1/values"
	fileName = valuesDir + "/agent-install.cfg"
	fmt.Println("Posting agent-install.cfg package: " + fileName)
	cfgFile, err := ioutil.ReadFile(fileName)
	if err != nil {
		outils.NewHttpError(http.StatusInternalServerError, "Error reading "+fileName+": "+err.Error())
		return
	}
	// Post agent-install.cfg in FDO Owner Services
	configResource := "agent-install.cfg"
	fdoCfgURL := fdoOwnerURL + "/api/v1/owner/resource?filename=" + configResource
	fmt.Println("URL for agent-install.cfg: " + fdoCfgURL)
	newResp, err = client.Post(fdoCfgURL, "text/plain", bytes.NewReader(cfgFile))
	if err != nil {
		outils.NewHttpError(http.StatusInternalServerError, "Error posting "+configResource+" in SVI Database: "+err.Error())
		return
	}
	if newResp.Body != nil {
		defer newResp.Body.Close()
	}

	// Create agent-install-wrapper
	valuesDir = OcsDbDir + "/v1/values"
	fileName = valuesDir + "/agent-install-wrapper.sh"
	fmt.Println("Setting SVI package: " + fileName)
	wrapperFile, err := ioutil.ReadFile(fileName)
	if err != nil {
		outils.NewHttpError(http.StatusInternalServerError, "Error reading "+fileName+": "+err.Error())
		return
	}
	// Post agent-install-wrapper in FDO Owner Services
	wrapperResource := "agent-install-wrapper.sh"
	fdoResourceURL := fdoOwnerURL + "/api/v1/owner/resource?filename=" + wrapperResource
	fmt.Println("URL for agent-install-wrapper package: " + fdoResourceURL)

	newResp, err = client.Post(fdoResourceURL, "text/plain", bytes.NewReader(wrapperFile))
	if err != nil {
		outils.NewHttpError(http.StatusInternalServerError, "Error posting "+wrapperResource+" in SVI Database: "+err.Error())
		return
	}
	if newResp.Body != nil {
		defer newResp.Body.Close()
	}

	// Get the cert to use when talking to the exchange for authentication, if set
	if outils.IsEnvVarSet("EXCHANGE_INTERNAL_CERT") {
		crtBytes, err := base64.StdEncoding.DecodeString(os.Getenv("EXCHANGE_INTERNAL_CERT"))
		if err != nil {
			outils.Verbose("Base64 decoding EXCHANGE_INTERNAL_CERT was unsuccessful (%s), using it as not encoded ...", err.Error())
			// Note: supposedly we could instead use this regex to check for base64 encoding: ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)?$
			crtBytes = []byte(os.Getenv("EXCHANGE_INTERNAL_CERT"))
		}
		ExchangeInternalCertPath = workingDir + "/agent-install.crt"
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

func isValidURL(requestURL string) bool {
	parsedURL, err := url.Parse(requestURL)
	if err != nil {
		return false
	}

	if parsedURL.Scheme != "http" && parsedURL.Scheme != "https" {
		return false
	}

	host := parsedURL.Hostname()
	if strings.HasPrefix(host, "localhost") || strings.HasPrefix(host, "127.") || strings.HasPrefix(host, "0.") ||
		strings.HasPrefix(host, "10.") || strings.HasPrefix(host, "172.") || strings.HasPrefix(host, "192.") {
		return false
	}

	allowedHosts := []string{"example.com", "api.example.com"}
	for _, allowedHost := range allowedHosts {
		if host == allowedHost {
			return true
		}
	}

	return false
}

// API route dispatcher
func apiHandler(w http.ResponseWriter, r *http.Request) {
	outils.Verbose("Handling %s ...", r.URL.Path)
	if r.Method == "GET" && r.URL.Path == "/api/version" {
		getVersionHandler(w, r)
	} else if r.Method == "GET" && r.URL.Path == "/api/fdo/version" {
		getFdoVersionHandler(w, r)
	} else if matches := OrgFDOKeyRegex.FindStringSubmatch(r.URL.Path); r.Method == "GET" && len(matches) >= 2 { // GET /api/orgs/{ord-id}/fdo/certificate?alias=SECP256R1
		getFdoPublicKeyHandler(matches[1], matches[2], w, r)
	} else if matches := OrgFDOVouchersRegex.FindStringSubmatch(r.URL.Path); r.Method == "GET" && len(matches) >= 2 { // GET /api/orgs/{ord-id}/fdo/vouchers
		getFdoVouchersHandler(matches[1], w, r)
	} else if matches := GetFDOVoucherRegex.FindStringSubmatch(r.URL.Path); r.Method == "GET" && len(matches) >= 3 { // GET /api/orgs/{ord-id}/fdo/vouchers/{deviceUuid}
		getFdoVoucherHandler(matches[1], matches[2], w, r)
	} else if matches := OrgFDOVouchersRegex.FindStringSubmatch(r.URL.Path); r.Method == "POST" && len(matches) >= 2 { // POST /api/orgs/{ord-id}/fdo/vouchers
		postFdoVoucherHandler(matches[1], w, r)
	} else if matches := OrgFDORedirectRegex.FindStringSubmatch(r.URL.Path); r.Method == "POST" && len(matches) >= 2 { // POST /api/orgs/{ord-id}/fdo/redirect
		postFdoRedirectHandler(matches[1], w, r)
	} else if matches := OrgFDORedirectRegex.FindStringSubmatch(r.URL.Path); r.Method == "GET" && len(matches) >= 2 { // GET /api/orgs/{ord-id}/fdo/redirect
		getFdoRedirectHandler(matches[1], w, r)
	} else if matches := GetFDOTo0Regex.FindStringSubmatch(r.URL.Path); r.Method == "GET" && len(matches) >= 3 { // GET /api/orgs/{ord-id}/fdo/to0/{deviceUuid}
		getFdoTo0Handler(matches[1], matches[2], w, r)
	} else if matches := OrgFDOResourceRegex.FindStringSubmatch(r.URL.Path); r.Method == "POST" && len(matches) >= 3 { // POST /api/orgs/{ord-id}/fdo/resource/{resourceFile}
		postFdoResourceHandler(matches[1], matches[2], w, r)
	} else if matches := OrgFDOResourceRegex.FindStringSubmatch(r.URL.Path); r.Method == "GET" && len(matches) >= 3 { // GET /api/orgs/{ord-id}/fdo/resource/{resourceFile}
		getFdoResourceHandler(matches[1], matches[2], w, r)
	} else if matches := OrgFDOServiceInfoRegex.FindStringSubmatch(r.URL.Path); r.Method == "POST" && len(matches) >= 2 { // POST /api/orgs/{ord-id}/fdo/redirect
		postFdoSVIHandler(matches[1], w, r)
	} else {
		http.Error(w, "Route "+r.URL.Path+" not found", http.StatusNotFound)
	}
	// Note: we used to also support a route that would allow an admin to change the config (i.e. run createConfigFiles()) w/o restarting
	//		the container, but penetration testing deemed it a security exposure, because you can cause this service to do arbitrary DNS lookups.
}

// Route Handlers --------------------------------------------------------------------------------------------------

// ============= GET /api/version =============
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

// ============= GET /api/fdo/version =============
// Returns the fdo Owner Service version (in plain text, not json)
func getFdoVersionHandler(w http.ResponseWriter, r *http.Request) {
	outils.Verbose("GET /api/fdo/version ...")

	fdoOwnerURL := os.Getenv("HZN_FDO_API_URL")
	if fdoOwnerURL == "" {
		log.Fatalln("HZN_FDO_API_URL is not set")
	}

	resp, err := http.Get(fdoOwnerURL + "/health")
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Error reading the response body: "+err.Error(), http.StatusBadRequest)
		return
	}
	w.WriteHeader(http.StatusOK) // seems like this has to be before writing the body
	w.Header().Set("Content-Type", "text/plain")
	outils.WriteResponse(http.StatusOK, w, body)

}

// ============= GET /api/orgs/{ord-id}/fdo/certificate/<alias> =============
// Reads/returns owner service public keys based off device alias
func getFdoPublicKeyHandler(orgId string, publicKeyType string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("GET /api/orgs/%s/fdo/certificate/%s ...", orgId)

	var respBodyBytes []byte
	//var requestBodyBytes []byte
	var fdoPublicKeyURL string
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

	//Only 5 public key alias types allowed
	if (publicKeyType) != "SECP256R1" && (publicKeyType) != "SECP384R1" && (publicKeyType) != "RSAPKCS3072" && (publicKeyType) != "RSAPKCS2048" && (publicKeyType) != "RSA2048RESTR" {
		http.Error(w, "Public key type must be one of these supported alias': SECP256R1, SECP384R1, RSAPKCS3072, RSAPKCS2048, RSA2048RESTR", http.StatusBadRequest)
		return
	}

	fdoOwnerURL := os.Getenv("HZN_FDO_API_URL")
	if fdoOwnerURL == "" {
		log.Fatalln("HZN_FDO_API_URL is not set")
	}
	fdoPublicKeyURL = fdoOwnerURL + "/api/v1/certificate?alias=" + publicKeyType
	username, password := outils.GetOwnerServiceApiKey()

	client := &http.Client{
		Transport: dab.NewDigestTransport(username, password, http.DefaultTransport),
	}
	resp, err := client.Get(fdoPublicKeyURL)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if resp.Body != nil {
		defer resp.Body.Close()
	}

	respBodyBytes, err = ioutil.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Error reading the response body: "+err.Error(), http.StatusBadRequest)
		return
	}
	sb := string(respBodyBytes)
	log.Printf(sb)

	w.WriteHeader(http.StatusOK) // seems like this has to be before writing the body
	w.Header().Set("Content-Type", "text/plain")
	outils.WriteResponse(http.StatusOK, w, respBodyBytes)
}

// IMPORT VOUCHER
// ============= POST /api/orgs/{ord-id}/fdo/vouchers and POST /api/fdo/vouchers =============
// Imports a voucher
func postFdoVoucherHandler(orgId string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("POST /api/orgs/%s/fdo/vouchers ... ...", orgId)

	var respBodyBytes []byte
	var bodyBytes []byte
	var fdoVoucherURL string

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

	// Verify content type
	if httpErr := outils.IsValidPostPlainTxt(r); httpErr != nil {
		//http.Error(w, "Error: This API only accepts plain text", http.StatusBadRequest)
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	bodyBytes, err := ioutil.ReadAll(r.Body) // we need the request body so get it as bytes
	if err != nil {
		http.Error(w, "Error reading the request body: "+err.Error(), http.StatusBadRequest)
		return
	}

	fdoOwnerURL := os.Getenv("HZN_FDO_API_URL")
	if fdoOwnerURL == "" {
		log.Fatalln("HZN_FDO_API_URL is not set")
	}
	fdoVoucherURL = fdoOwnerURL + "/api/v1/owner/vouchers"
	username, password := outils.GetOwnerServiceApiKey()

	//Digest auth request to import voucher
	client := &http.Client{
		Transport: dab.NewDigestTransport(username, password, http.DefaultTransport),
	}

	resp, err := client.Post(fdoVoucherURL, "text/plain", bytes.NewReader(bodyBytes))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if resp.Body != nil {
		defer resp.Body.Close()
	}

	respBodyBytes, err = ioutil.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Error reading the response body: "+err.Error(), http.StatusBadRequest)
		return
	}

	//string device UUID
	deviceUuid := string(respBodyBytes)
	outils.Verbose("POST /api/orgs/%s/fdo/vouchers: device UUID: %s", deviceOrgId, deviceUuid)

	// Create the device directory in the OCS DB
	deviceDir := OcsDbDir + "/v1/devices/" + deviceUuid
	if err := os.MkdirAll(deviceDir, 0750); err != nil {
		http.Error(w, "could not create directory "+deviceDir+": "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Put the voucher in the OCS DB
	fileName := deviceDir + "/ownership_voucher.txt"
	outils.Verbose("POST /api/orgs/%s/fdo/vouchers: creating %s ...", deviceOrgId, fileName)
	if err := ioutil.WriteFile(filepath.Clean(fileName), bodyBytes, 0644); err != nil {
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
	execCmd := fmt.Sprintf("/bin/sh agent-install-wrapper.sh -i %s -a %s:%s -O %s -k %s", PkgsFrom, deviceUuid, nodeToken, deviceOrgId, CfgFileFrom)
	fileName = OcsDbDir + "/v1/values/" + deviceUuid + "_exec"
	outils.Verbose("POST /api/orgs/%s/vouchers: creating %s ...", deviceOrgId, fileName)
	if err := ioutil.WriteFile(filepath.Clean(fileName), []byte(execCmd), 0644); err != nil {
		http.Error(w, "could not create "+fileName+": "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Post device specified exec file in FDO Owner Services
	valuesDir := OcsDbDir + "/v1/values"
	fileName = valuesDir + "/" + deviceUuid + "_exec"
	fmt.Println("Device Specific Wrapper: " + fileName)
	wrapperFile, err := ioutil.ReadFile(fileName)
	if err != nil {
		http.Error(w, "Error reading "+fileName+": "+err.Error(), http.StatusNotFound)
		return
	}
	// Create agent-install-wrapper
	wrapperResource := deviceUuid + "_exec"
	fdoResourceURL := fdoOwnerURL + "/api/v1/owner/resource?filename=" + wrapperResource
	fmt.Println("URL for device specific exec file: " + fdoResourceURL)

	newResp, err := client.Post(fdoResourceURL, "text/plain", bytes.NewReader(wrapperFile))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if newResp.Body != nil {
		defer resp.Body.Close()
	}

	// Set SVI and agent-install-wrapper.sh arguments in FDO Owner Services
	// post specified exec file

	sviBody := (`[{"filedesc" : "agent-install.crt","resource" : "agent-install.crt"},
            {"filedesc" : "agent-install.cfg","resource" : "agent-install.cfg"},
            {"filedesc" : "agent-install-wrapper.sh","resource" : "agent-install-wrapper.sh"},
            {"filedesc" : "setup.sh","resource" : "$(guid)_exec"},
            {"exec" : ["bash","setup.sh"] }]`)

	fmt.Println("SVI request body: " + sviBody)
	sviByte := []byte(sviBody)

	fdoSVIURL := fdoOwnerURL + "/api/v1/owner/svi"

	client = &http.Client{
		Transport: dab.NewDigestTransport(username, password, http.DefaultTransport),
	}

	postResponse, err := client.Post(fdoSVIURL, "text/plain", bytes.NewReader(sviByte))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if postResponse.Body != nil {
		defer resp.Body.Close()
	}

	respBodyBytes, err = ioutil.ReadAll(postResponse.Body)
	if err != nil {
		http.Error(w, "Error reading the response body: "+err.Error(), http.StatusInternalServerError)
		return
	}

	lk := string(respBodyBytes)
	log.Printf(lk)

	// Send response to client
	respBody := map[string]interface{}{
		"deviceUuid": deviceUuid,
		"nodeToken":  nodeToken,
	}

	w.WriteHeader(http.StatusOK) // seems like this has to be before writing the body
	w.Header().Set("Content-Type", "text/plain")
	outils.WriteJsonResponse(http.StatusOK, w, respBody)

}

// ============= GET /api/orgs/{ord-id}/fdo/vouchers =============
// Reads/returns all of the already imported vouchers
func getFdoVouchersHandler(orgId string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("GET /api/orgs/%s/fdo/vouchers ...", orgId)

	//var respBodyBytes []byte
	//var requestBodyBytes []byte
	var fdoVoucherURL string
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

	fdoOwnerURL := os.Getenv("HZN_FDO_API_URL")
	if fdoOwnerURL == "" {
		log.Fatalln("HZN_FDO_API_URL is not set")
	}
	fdoVoucherURL = fdoOwnerURL + "/api/v1/owner/vouchers"

	username, password := outils.GetOwnerServiceApiKey()

	client := &http.Client{
		Transport: dab.NewDigestTransport(username, password, http.DefaultTransport),
	}
	resp, err := client.Get(fdoVoucherURL)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if resp.Body != nil {
		defer resp.Body.Close()
	}

	//     	respBodyBytes, err = ioutil.ReadAll(resp.Body)
	//     	if err != nil {
	//     		log.Fatalln(err)
	//     	}

	// Read the v1/devices/ directory in the db for multitenancy
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

	//Verify that each value in vouchers is also in respBodyBytes - THIS IS NOT WORKING RIGHT

	//         dbQuery := bytes.NewBuffer(respBodyBytes).String()
	//         vouchersString := strings.Join(vouchers,"\n")
	//         fmt.Println("FDO Db Query: " + dbQuery)
	//         fmt.Println("Index Query: " + vouchersString)
	//         result := vouchersString == dbQuery
	//         fmt.Println(result)

	w.WriteHeader(http.StatusOK) // seems like this has to be before writing the body
	w.Header().Set("Content-Type", "text/plain")
	outils.WriteJsonResponse(http.StatusOK, w, vouchers)

}

// GET A SPECIFIED VOUCHER
// ============= GET /api/orgs/{ord-id}/fdo/vouchers/{deviceUuid} =============
// Reads/returns a specific imported voucher
func getFdoVoucherHandler(orgId string, deviceUuid string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("GET /api/orgs/%s/fdo/vouchers/%s ...", orgId)

	var respBodyBytes []byte
	//var requestBodyBytes []byte
	var fdoVoucherURL string
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

	fdoOwnerURL := os.Getenv("HZN_FDO_API_URL")
	if fdoOwnerURL == "" {
		log.Fatalln("HZN_FDO_API_URL is not set")
	}
	fdoVoucherURL = fdoOwnerURL + "/api/v1/owner/vouchers/" + deviceUuid

	//check if deviceUuid is found in the directory index first, if it is then continue with the request.
	//if not, then return error
	// Read voucher.json from the db
	voucherFileName := OcsDbDir + "/v1/devices/" + deviceUuid + "/ownership_voucher.txt"
	voucherBytes, err := ioutil.ReadFile(filepath.Clean(voucherFileName))
	if err != nil {
		http.Error(w, "Error reading "+voucherFileName+": "+err.Error(), http.StatusNotFound)
		return
	}

	//Getting voucher from FDO DB
	username, password := outils.GetOwnerServiceApiKey()

	client := &http.Client{
		Transport: dab.NewDigestTransport(username, password, http.DefaultTransport),
	}
	resp, err := client.Get(fdoVoucherURL)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if resp.Body != nil {
		defer resp.Body.Close()
	}

	respBodyBytes, err = ioutil.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Error reading the response body: "+err.Error(), http.StatusInternalServerError)
		return
	}
	lk := string(respBodyBytes)
	log.Printf(lk)

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

	//Verify that the value in voucherBytes is also in respBodyBytes - THIS IS NOT WORKING RIGHT

	//                 dbQuery := bytes.NewBuffer(respBodyBytes).String()
	//                 //fmt.Println("Db Query: " + dbQuery)
	//                 //fmt.Println("Index Query: " + string(voucherBytes))
	//                 result := string(voucherBytes) == dbQuery
	//                 fmt.Println(result)

	w.WriteHeader(http.StatusOK) // seems like this has to be before writing the body
	w.Header().Set("Content-Type", "text/plain")
	outils.WriteResponse(http.StatusOK, w, voucherBytes)
}

// ============= POST /api/orgs/{ord-id}/fdo/redirect =============
// Configure the Owner Services TO2 address
func postFdoRedirectHandler(orgId string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("POST /api/orgs/%s/fdo/redirect ... ...", orgId)

	var respBodyBytes []byte
	var bodyBytes []byte
	var fdoTo2URL string

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

	// Verify content type
	if httpErr := outils.IsValidPostPlainTxt(r); httpErr != nil {
		//http.Error(w, "Error: This API only accepts plain text", http.StatusBadRequest)
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	bodyBytes, err := ioutil.ReadAll(r.Body) // we need the request body so get it as bytes
	if err != nil {
		http.Error(w, "Error reading the request body: "+err.Error(), http.StatusBadRequest)
		return
	}

	st := string(bodyBytes)
	log.Printf(st)

	fdoOwnerURL := os.Getenv("HZN_FDO_API_URL")
	if fdoOwnerURL == "" {
		log.Fatalln("HZN_FDO_API_URL is not set")
	}
	fdoTo2URL = fdoOwnerURL + "/api/v1/owner/redirect"
	username, password := outils.GetOwnerServiceApiKey()

	client := &http.Client{
		Transport: dab.NewDigestTransport(username, password, http.DefaultTransport),
	}

	resp, err := client.Post(fdoTo2URL, "text/plain", bytes.NewReader(bodyBytes))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if resp.Body != nil {
		defer resp.Body.Close()
	}

	respBodyBytes, err = ioutil.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Error reading the response body: "+err.Error(), http.StatusInternalServerError)
		return
	}

	sb := string(respBodyBytes)
	log.Printf(sb)

	w.WriteHeader(http.StatusOK) // seems like this has to be before writing the body
	w.Header().Set("Content-Type", "text/plain")
	outils.WriteResponse(http.StatusOK, w, respBodyBytes)
}

// ============= GET /api/orgs/{ord-id}/fdo/redirect =============
// Get the Owner Services TO2 address
func getFdoRedirectHandler(orgId string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("GET /api/orgs/%s/fdo/redirect ... ...", orgId)

	var respBodyBytes []byte
	var fdoTo2URL string

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

	fdoOwnerURL := os.Getenv("HZN_FDO_API_URL")
	if fdoOwnerURL == "" {
		log.Fatalln("HZN_FDO_API_URL is not set")
	}
	fdoTo2URL = fdoOwnerURL + "/api/v1/owner/redirect"
	username, password := outils.GetOwnerServiceApiKey()

	client := &http.Client{
		Transport: dab.NewDigestTransport(username, password, http.DefaultTransport),
	}

	resp, err := client.Get(fdoTo2URL)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if resp.Body != nil {
		defer resp.Body.Close()
	}

	respBodyBytes, err = ioutil.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Error reading the response body: "+err.Error(), http.StatusInternalServerError)
		return
	}

	sb := string(respBodyBytes)
	log.Printf(sb)

	w.WriteHeader(http.StatusOK) // seems like this has to be before writing the body
	w.Header().Set("Content-Type", "text/plain")
	outils.WriteResponse(http.StatusOK, w, respBodyBytes)
}

// ============= GET /api/orgs/{ord-id}/fdo/to0/{deviceUuid} =============
// Initiates TO0 from Owner service
func getFdoTo0Handler(orgId string, deviceUuid string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("GET /api/orgs/%s/fdo/to0/%s ...", orgId)

	var respBodyBytes []byte
	//var requestBodyBytes []byte
	var fdoTo0URL string
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

	fdoOwnerURL := os.Getenv("HZN_FDO_API_URL")
	if fdoOwnerURL == "" {
		log.Fatalln("HZN_FDO_API_URL is not set")
	}
	fdoTo0URL = fdoOwnerURL + "/api/v1/to0/" + deviceUuid
	username, password := outils.GetOwnerServiceApiKey()
	client := &http.Client{
		Transport: dab.NewDigestTransport(username, password, http.DefaultTransport),
	}
	resp, err := client.Get(fdoTo0URL)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if resp.Body != nil {
		defer resp.Body.Close()
	}

	respBodyBytes, err = ioutil.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Error reading the response body: "+err.Error(), http.StatusInternalServerError)
		return
	}
	sb := string(respBodyBytes)
	log.Printf(sb)

	w.WriteHeader(http.StatusOK) // seems like this has to be before writing the body
	w.Header().Set("Content-Type", "text/plain")
	outils.WriteResponse(http.StatusOK, w, respBodyBytes)
}

// IMPORT RESOURCE FILE (agent-install-wrapper.sh) TO OWNER DB FOR SERVICE INFO PACKAGE
// ============= POST /api/orgs/{ord-id}/fdo/resource/{resourceFile} =============
// Imports a resource file to the DB in order to use for service info package
func postFdoResourceHandler(orgId string, resourceFile string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("POST /api/orgs/%s/fdo/resource/%s ... ...", orgId)

	var respBodyBytes []byte
	var bodyBytes []byte
	var fdoResourceURL string

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

	// Verify content type
	if httpErr := outils.IsValidPostPlainTxt(r); httpErr != nil {
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	bodyBytes, err := ioutil.ReadAll(r.Body) // we need the request body so get it as bytes
	if err != nil {
		http.Error(w, "Error reading the request body: "+err.Error(), http.StatusBadRequest)
		return
	}

	st := string(bodyBytes)
	log.Printf(st)

	//resourceFile in URL must = file name in request body

	fdoOwnerURL := os.Getenv("HZN_FDO_API_URL")
	if fdoOwnerURL == "" {
		log.Fatalln("HZN_FDO_API_URL is not set")
	}
	fdoResourceURL = fdoOwnerURL + "/api/v1/owner/resource?filename=" + resourceFile
	username, password := outils.GetOwnerServiceApiKey()
	client := &http.Client{
		Transport: dab.NewDigestTransport(username, password, http.DefaultTransport),
	}

	resp, err := client.Post(fdoResourceURL, "text/plain", bytes.NewReader(bodyBytes))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if resp.Body != nil {
		defer resp.Body.Close()
	}

	respBodyBytes, err = ioutil.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Error reading the response body: "+err.Error(), http.StatusInternalServerError)
		return
	}

	sb := string(respBodyBytes)
	log.Printf(sb)

	w.WriteHeader(http.StatusOK) // seems like this has to be before writing the body
	w.Header().Set("Content-Type", "text/plain")
	outils.WriteResponse(http.StatusOK, w, respBodyBytes)
}

// ============= GET /api/orgs/{ord-id}/fdo/resource/{resourceFile} =============
// Gets a resource file that was imported to the DB in order to use for service info package
func getFdoResourceHandler(orgId string, resourceFile string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("GET /api/orgs/%s/fdo/resource/%s ... ...", orgId)

	var respBodyBytes []byte
	var bodyBytes []byte
	var fdoResourceURL string

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

	// Verify content type
	if httpErr := outils.IsValidPostPlainTxt(r); httpErr != nil {
		//http.Error(w, "Error: This API only accepts plain text", http.StatusBadRequest)
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	bodyBytes, err := ioutil.ReadAll(r.Body) // we need the request body so get it as bytes
	if err != nil {
		http.Error(w, "Error reading the request body: "+err.Error(), http.StatusBadRequest)
		return
	}

	st := string(bodyBytes)
	log.Printf(st)

	//resourceFile in URL must = file name in request body

	fdoOwnerURL := os.Getenv("HZN_FDO_API_URL")
	if fdoOwnerURL == "" {
		log.Fatalln("HZN_FDO_API_URL is not set")
	}
	fdoResourceURL = fdoOwnerURL + "/api/v1/owner/resource?filename=" + resourceFile
	username, password := outils.GetOwnerServiceApiKey()
	client := &http.Client{
		Transport: dab.NewDigestTransport(username, password, http.DefaultTransport),
	}
	resp, err := client.Get(fdoResourceURL)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if resp.Body != nil {
		defer resp.Body.Close()
	}

	respBodyBytes, err = ioutil.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Error reading the response body: "+err.Error(), http.StatusInternalServerError)
		return
	}

	sb := string(respBodyBytes)
	log.Printf(sb)

	w.WriteHeader(http.StatusOK) // seems like this has to be before writing the body
	w.Header().Set("Content-Type", "text/plain")
	outils.WriteResponse(http.StatusOK, w, respBodyBytes)
}

// ============= POST /api/orgs/{ord-id}/fdo/svi =============
// Uploads SVI instructions to SYSTEM_PACKAGE table in owner db.
func postFdoSVIHandler(orgId string, w http.ResponseWriter, r *http.Request) {
	outils.Verbose("POST /api/orgs/%s/fdo/svi ... ...", orgId)

	var respBodyBytes []byte
	var bodyBytes []byte
	var fdoSVIURL string

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

	// Verify content type
	if httpErr := outils.IsValidPostPlainTxt(r); httpErr != nil {
		//http.Error(w, "Error: This API only accepts plain text", http.StatusBadRequest)
		http.Error(w, httpErr.Error(), httpErr.Code)
		return
	}

	bodyBytes, err := ioutil.ReadAll(r.Body) // we need the request body so get it as bytes
	if err != nil {
		http.Error(w, "Error reading the request body: "+err.Error(), http.StatusBadRequest)
		return
	}

	fdoOwnerURL := os.Getenv("HZN_FDO_API_URL")
	if fdoOwnerURL == "" {
		log.Fatalln("HZN_FDO_API_URL is not set")
	}
	fdoSVIURL = fdoOwnerURL + "/api/v1/owner/svi"
	username, password := outils.GetOwnerServiceApiKey()
	client := &http.Client{
		Transport: dab.NewDigestTransport(username, password, http.DefaultTransport),
	}

	resp, err := client.Post(fdoSVIURL, "text/plain", bytes.NewReader(bodyBytes))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if resp.Body != nil {
		defer resp.Body.Close()
	}

	respBodyBytes, err = ioutil.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Error reading the response body: "+err.Error(), http.StatusInternalServerError)
		return
	}

	sb := string(respBodyBytes)
	log.Printf(sb)

	w.WriteHeader(http.StatusOK) // seems like this has to be before writing the body
	w.Header().Set("Content-Type", "text/plain")
	outils.WriteResponse(http.StatusOK, w, respBodyBytes)
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

// Return the org of this device based on the orgid.txt file stored with it, or return ""
func getNodeTokenTxtStr(deviceId string) (string, *outils.HttpError) {
	// Look inside the device dir for orgid.txt to what org it belongs to
	vouchersDirName := OcsDbDir + "/v1/devices"
	nodeTokenTxtFileName := filepath.Clean(vouchersDirName + "/" + deviceId + "/nodeToken.txt")
	nodeTokenTxtStr := "" // default if we don't find it in the nodeToken.txt
	if outils.PathExists(nodeTokenTxtFileName) {
		var nodeTokenTxtBytes []byte
		var err error
		if nodeTokenTxtBytes, err = ioutil.ReadFile(nodeTokenTxtFileName); err != nil {
			return "", outils.NewHttpError(http.StatusInternalServerError, "Error reading "+nodeTokenTxtFileName+": "+err.Error())
		} else {
			nodeTokenTxtStr = string(nodeTokenTxtBytes)
			nodeTokenTxtStr = strings.TrimSuffix(nodeTokenTxtStr, "\n")
		}
	}
	return nodeTokenTxtStr, nil
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

	PkgsFrom = os.Getenv("FDO_GET_PKGS_FROM")
	if PkgsFrom == "" {
		PkgsFrom = "https://github.com/open-horizon/anax/releases/latest/download" // default
	}
	fmt.Printf("Will be configuring devices to get horizon packages from %s\n", PkgsFrom)
	// try to ensure they didn't give us a bad value for SDO_GET_PKGS_FROM
	if !strings.HasPrefix(PkgsFrom, "https://github.com/open-horizon/anax/releases") && !strings.HasPrefix(PkgsFrom, "css:") {
		outils.Warning("Unrecognized value specified for FDO_GET_PKGS_FROM: %s", PkgsFrom)
		// continue, because maybe this is a value for the agent-install.sh -i flag that we don't know about yet
	}

	CfgFileFrom = os.Getenv("FDO_GET_CFG_FILE_FROM")
	if CfgFileFrom == "" {
		CfgFileFrom = "css:" // default
	}
	fmt.Printf("Will be configuring devices to get agent-install.cfg from %s\n", CfgFileFrom)
	// try to ensure they didn't give us a bad value for FDO_GET_CFG_FILE_FROM
	if !strings.HasPrefix(CfgFileFrom, "agent-install.cfg") && !strings.HasPrefix(CfgFileFrom, "css:") {
		outils.Warning("Unrecognized value specified for FDO_GET_CFG_FILE_FROM: %s", CfgFileFrom)
		// continue, because maybe this is a value for the agent-install.sh -i flag that we don't know about yet
	}

	return nil
}
