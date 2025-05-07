package outils

import (
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	mrand "math/rand"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Utilities for ocs-api

const (
	HTTPRequestTimeoutS        = 30
	MaxHTTPIdleConnections     = 20
	HTTPIdleConnectionTimeoutS = 120
)

var IsVerbose bool
var HttpClient *http.Client

// A "subclass" of error that also contains the http code that should be sent to the client
type HttpError struct {
	Code int
	Err  error
}

func NewHttpError(code int, errStr string, args ...interface{}) *HttpError {
	return &HttpError{Code: code, Err: fmt.Errorf(errStr, args...)}
}

func (e *HttpError) Error() string {
	return e.Err.Error()
}

// Verify that the request content type is json
func IsValidPostJson(r *http.Request) *HttpError {
	val, ok := r.Header["Content-Type"]

	if !ok || len(val) == 0 || val[0] != "application/json" {
		return NewHttpError(http.StatusBadRequest, "Error: content-type must be application/json)")
	}
	return nil
}

// Verify that the request content type is json
func IsValidPostPlainTxt(r *http.Request) *HttpError {
	val, ok := r.Header["Content-Type"]

	if !ok || len(val) == 0 || val[0] != "text/plain" {
		return NewHttpError(http.StatusBadRequest, "Error: content-type must be text/plain)")
	}
	return nil
}

// Verify that the request content type is a file
func IsValidPostBinary(r *http.Request) *HttpError {
	val, ok := r.Header["Content-Type"]

	if !ok || len(val) == 0 || val[0] != "application/octet-stream" {
		return NewHttpError(http.StatusBadRequest, "Error: content-type must be application/octet-stream)")
	}
	return nil
}

// Parse the json string into the given struct
func ParseJsonString(jsonBytes []byte, bodyStruct interface{}) *HttpError {
	err := json.Unmarshal(jsonBytes, bodyStruct)
	if err != nil {
		return NewHttpError(http.StatusBadRequest, "Error parsing request body json bytes: "+err.Error())
	}
	return nil
}

// Parse the request json body into the given struct
func ReadJsonBody(r *http.Request, bodyStruct interface{}) *HttpError {
	var unmarshalErr *json.UnmarshalTypeError
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	err := decoder.Decode(bodyStruct)
	if err != nil {
		if errors.As(err, &unmarshalErr) {
			return NewHttpError(http.StatusBadRequest, "Bad Request. Wrong Type provided for field "+unmarshalErr.Field)
		} else {
			return NewHttpError(http.StatusBadRequest, "Bad Request "+err.Error())
		}
	}
	return nil
}

// Respond to the client with this code and body struct
func WriteJsonResponse(httpCode int, w http.ResponseWriter, bodyStruct interface{}) {
	dataJson, err := json.Marshal(bodyStruct)
	if err != nil {
		http.Error(w, "Internal Server Error (could not encode json response)", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	WriteResponse(httpCode, w, dataJson)
}

// Respond to the client with this code and body bytes
func WriteResponse(httpCode int, w http.ResponseWriter, bodyBytes []byte) {
	w.WriteHeader(httpCode) // seems like this has to be before writing the body
	_, err := w.Write(bodyBytes)
	if err != nil {
		Error(err.Error())
	}
}

// Generate a random node token that follows the new exchange requirements for node and agbot tokens
func GenerateNodeToken() (string, *HttpError) {
	// Taken from anax/cutil/cutil.go
	random := mrand.New(mrand.NewSource(int64(time.Now().Nanosecond())))

	randStr := ""
	randStr += string(rune(random.Intn(10) + 48)) // add a random digit to the string
	randStr += string(rune(random.Intn(26) + 65)) // add an uppercase letter to the string
	randStr += string(rune(random.Intn(26) + 97)) // add a lowercase letter to the string
	randStr += string(rune(random.Intn(10) + 48)) // add one more random digit so we reach 64 bytes at the end

	// pad out the password to make it <=15 chars
	bytes := make([]byte, 63)
	if _, err := rand.Read(bytes); err != nil {
		return "", NewHttpError(http.StatusInternalServerError, "Error reading random bytes for node token: "+err.Error())
	}
	randStr += base64.URLEncoding.EncodeToString(bytes)

	// shuffle the string
	shuffledStr := []rune(randStr)
	mrand.Shuffle(len(shuffledStr), func(i, j int) {
		shuffledStr[i], shuffledStr[j] = shuffledStr[j], shuffledStr[i]
	})

	return string(shuffledStr), nil

	/* this method generates a 44 char token of random numbers and lowercase chars
	bytes := make([]byte, 22) // 44 hex chars
	_, err := rand.Read(bytes)
	if err != nil {
		return "", NewHttpError(http.StatusInternalServerError, "Error creating random bytes for node token: "+err.Error())
	}
	return hex.EncodeToString(bytes), nil
	*/
}

// Convert a space-separated string into a null separated string (with extra null at end)
func MakeExecCmd(execString string) string {
	returnStr := ""
	for _, w := range strings.Fields(execString) {
		returnStr += w + "\x00"
	}
	return returnStr + "\x00"
}

// Initialize the verbose setting
func SetVerbose() {
	v := GetEnvVarWithDefault("VERBOSE", "false")
	if v == "1" || strings.ToLower(v) == "true" {
		IsVerbose = true
	} else {
		IsVerbose = false
	}
}

// Print error msg to stderr
func Verbose(msg string, args ...interface{}) {
	if !IsVerbose {
		return
	}
	if !strings.HasSuffix(msg, "\n") {
		msg += "\n"
	}
	fmt.Printf("Verbose: "+msg, args...)
}

// Print warning msg to stderr
func Warning(msg string, args ...interface{}) {
	if !strings.HasSuffix(msg, "\n") {
		msg += "\n"
	}
	l := log.New(os.Stderr, "", 0)
	l.Printf("Warning: "+msg, args...)
}

// Print error msg to stderr
func Error(msg string, args ...interface{}) {
	if !strings.HasSuffix(msg, "\n") {
		msg += "\n"
	}
	l := log.New(os.Stderr, "", 0)
	l.Printf("Error: "+msg, args...)
}

// Print error msg to stderr and exit with the specified code
func Fatal(exitCode int, msg string, args ...interface{}) {
	Error(msg, args...)
	os.Exit(exitCode)
}

// Get this environment variable or use this default
func GetEnvVarWithDefault(envVarName, defaultValue string) string {
	envVarValue := os.Getenv(envVarName)
	if envVarValue == "" {
		return defaultValue
	}
	return envVarValue
}

// Get this environment variable as an int or use this default. Exits with error if the value is not a valid int.
func GetEnvVarIntWithDefault(envVarName string, defaultValue int) int {
	envVarStr := os.Getenv(envVarName)
	if envVarStr == "" {
		return defaultValue
	}
	envVarInt, err := strconv.Atoi(envVarStr)
	if err != nil {
		Fatal(1, "environment variable %s value %s must be a valid integer", envVarName, envVarStr)
	}
	return envVarInt
}

// Returns true if this env var is set
func IsEnvVarSet(envVarName string) bool {
	return os.Getenv(envVarName) != ""
}

// Returns true if this file or dir exists
func PathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// Download a file from a web site (that doesn't require authentication)
func DownloadFile(url, fileName string, perm os.FileMode) error {
	// Set up the request
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	// Create the file
	newFile, err := os.Create(fileName)
	if err != nil {
		return err
	}
	defer newFile.Close()
	if err := newFile.Chmod(perm); err != nil {
		return err
	}

	// Write the request body to the file. This streams the content straight from the request to the file, so works for large files
	_, err = io.Copy(newFile, resp.Body)
	return err
}

// Copy a file
func CopyFile(fromFileName, toFileName string, perm os.FileMode) *HttpError {
	var content []byte
	var err error
	if content, err = os.ReadFile(fromFileName); err != nil {
		return NewHttpError(http.StatusInternalServerError, "could not read "+fromFileName+": "+err.Error())
	}
	if err = os.WriteFile(toFileName, content, perm); err != nil {
		return NewHttpError(http.StatusInternalServerError, "could not write "+toFileName+": "+err.Error())
	}
	return nil
}

// Returns the org, user, and password (which can be a key) of the basic auth passed in the header of the request.
// The 4th arg returns is a boolean that is false basic auth was not specified and invalid format.
func GetBasicAuth(r *http.Request) (string, string, string, bool) {
	orgAndUser, pwOrKey, ok := r.BasicAuth()
	if !ok {
		return "", "", "", false
	}

	// Split the user into org and user
	parts := strings.Split(orgAndUser, "/")
	if len(parts) != 2 {
		return "", "", pwOrKey, false
	}
	orgId := parts[0]
	user := parts[1]
	return orgId, user, pwOrKey, true
}

type UserDefinition struct {
	Password    string `json:"password"`
	Admin       bool   `json:"admin"`
	HubAdmin    bool   `json:"hubAdmin"`
	Email       string `json:"email"`
	LastUpdated string `json:"lastUpdated,omitempty"`
	UpdatedBy   string `json:"updatedBy,omitempty"`
}

type GetUsersResponse struct {
	Users     map[string]UserDefinition `json:"users"`
	LastIndex int                       `json:"lastIndex"`
}

// Verify (with retries) we can communicate with the exchange with the specified connection info. Exits with fatal error if we can't.
func VerifyExchangeConnection(currentExchangeUrl, certificatePath string, retries, interval int) {
	method := http.MethodGet
	url := fmt.Sprintf("%v/admin/version", currentExchangeUrl)
	fmt.Printf("Verifying connection to Exchange %s ...\n", currentExchangeUrl)

	// Create an HTTP request object to the exchange.
	req, err := http.NewRequest(method, url, nil)
	if err != nil {
		Fatal(3, "unable to create HTTP request for %s, error: %v", url, err)
	}
	httpClient, httpErr := GetHTTPClient(certificatePath) // if certificatePath=="" then it won't use a cert
	if httpErr != nil {
		Fatal(3, "unable to get HTTP client for %s, error: %v", url, httpErr.Error())
	}

	// Send the request to get the version
	success := false
	for i := 1; i <= retries; i++ {
		whatsNext := fmt.Sprintf("Will retry in %d seconds.", interval)
		if i == retries {
			whatsNext = "Number of retries exhausted, giving up."
		}
		resp, err := httpClient.Do(req)
		if err != nil {
			fmt.Printf("Unable to send HTTP request to %s, message: %v . %s\n", url, err, whatsNext)
		} else if resp.StatusCode != http.StatusOK {
			fmt.Printf("Unable to connect to the %s and get its version. HTTP code: %d . %s\n", url, resp.StatusCode, whatsNext)
		} else { // the connection to the exchange succeeded
			success = true
			break
		}
		time.Sleep(time.Duration(interval) * time.Second)
	}

	if success {
		fmt.Printf("Successfully connected to Exchange %s\n", currentExchangeUrl)
	} else {
		Fatal(3, "could not connect to Exchange %s in %d attempts", currentExchangeUrl, retries)
	}
}

// Verify the request credentials with the exchange. Returns true/false and the user (if true), or error
func ExchangeAuthenticate(r *http.Request, currentExchangeUrl, deviceOrgId, certificatePath string) (bool, string, *HttpError) {
	credOrgId, user, pwOrKey, ok := GetBasicAuth(r)
	if !ok {
		return false, "", nil
	}

	// Get certificate
	var certPath string
	if !PathExists(certificatePath) {
		certPath = ""
	} else {
		certPath = certificatePath
	}

	var url, method string
	var goodStatusCode int
	if credOrgId == "root" && user == "root" {
		// Special case of exchange root user: in this case it is ok for the creds org to be different from the request/device org
		// Just need to validate the root creds by calling GET /orgs/{orgid}/users
		method = http.MethodGet
		url = fmt.Sprintf("%v/orgs/%v/users", currentExchangeUrl, deviceOrgId)
		goodStatusCode = http.StatusOK
	} else {
		// Non-root creds: Invoke exchange to confirm the client has valid user creds and have the access they need to create and manage this device.
		// Note: POST /orgs/{orgid}/users/{username}/confirm only confirms that the creds can read its own user resource. This is sufficient if the creds are in
		//		the same org as the device, so we need to catch the case when the aren't.
		if credOrgId != deviceOrgId {
			return false, "", NewHttpError(http.StatusUnauthorized, "the org id of the credentials ("+credOrgId+") does not match the org id of the SDO device ("+deviceOrgId+")")
		}
		//method = http.MethodPost
		//url = fmt.Sprintf("%v/orgs/%v/users/%v/confirm", currentExchangeUrl, credOrgId, user)
		//goodStatusCode = http.StatusCreated
		method = http.MethodGet
		url = fmt.Sprintf("%v/orgs/%v/users/%v", currentExchangeUrl, credOrgId, user)
		goodStatusCode = http.StatusOK
	}
	apiMsg := fmt.Sprintf("%v %v", method, url)
	Verbose("confirming credentials via %s", apiMsg)

	// Create an outgoing HTTP request to the exchange.
	req, err := http.NewRequest(method, url, nil)
	if err != nil {
		return false, "", NewHttpError(http.StatusInternalServerError, "unable to create HTTP request for %s, error: %v", apiMsg, err)
	}

	// Add the basic auth header so that the exchange will authenticate.
	req.SetBasicAuth(credOrgId+"/"+user, pwOrKey)
	req.Header.Add("Accept", "application/json")

	// Send the request to verify the user.
	httpClient, httpErr := GetHTTPClient(certPath)
	if httpErr != nil {
		return false, "", httpErr
	}
	resp, err := httpClient.Do(req) //todo: retry, when necessary, like CSS does
	if err != nil {
		return false, "", NewHttpError(http.StatusInternalServerError, "unable to send HTTP request for %s, error: %v", apiMsg, err)
	} else if resp.StatusCode == goodStatusCode {
		// They are authenticated, not get the real user (because the cred user could be iamapikey)
		if credOrgId == "root" && user == "root" {
			return true, "root", nil
		}
		// Non-root user, parse the response body to get the real user
		users := new(GetUsersResponse)
		if bodyBytes, err := ioutil.ReadAll(resp.Body); err != nil {
			return false, "", NewHttpError(http.StatusInternalServerError, "unable to read HTTP response body for %s, error: %v", apiMsg, err)
		} else if err = json.Unmarshal(bodyBytes, users); err != nil {
			return false, "", NewHttpError(http.StatusInternalServerError, "unable to unmarshal HTTP response body for %s, error: %v", apiMsg, err)
		} else {
			for key, userInfo := range users.Users { // there is only 1 entry in this map, but we don't know the key, so loop thru the 1st one
				// key is {orgid}/{username}
				orgAndUsername := strings.Split(key, "/")
				if len(orgAndUsername) != 2 {
					return false, "", NewHttpError(http.StatusInternalServerError, "user response from exchange in unexpected format for %s, error: %v", apiMsg, err)
				}
				exUsername := orgAndUsername[1]
				if userInfo.HubAdmin {
					return false, "", nil // hub admins can't manage devices
				} else {
					return true, exUsername, nil
				}
			}
			return false, "", nil // will never get here, but have to satisfy the compiler
		}
	} else if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return false, "", nil
	} else {
		return false, "", NewHttpError(resp.StatusCode, "unexpected http status code received from %s: %d", apiMsg, resp.StatusCode)
	}
}

func GetHTTPClient(certPath string) (*http.Client, *HttpError) {
	// Try to reuse the 1 global client
	if HttpClient == nil {
		var httpErr *HttpError
		if HttpClient, httpErr = NewHTTPClient(certPath); httpErr != nil {
			return nil, httpErr
		}
	}
	return HttpClient, nil
}

// Common function for getting an HTTP client connection object.
func NewHTTPClient(certPath string) (*http.Client, *HttpError) {
	httpClient := &http.Client{
		// remember that this timeout is for the whole request, including
		// body reading. This means that you must set the timeout according
		// to the total payload size you expect
		Timeout: time.Second * time.Duration(HTTPRequestTimeoutS),
		Transport: &http.Transport{
			Dial: (&net.Dialer{
				Timeout:   20 * time.Second,
				KeepAlive: 60 * time.Second,
			}).Dial,
			TLSHandshakeTimeout:   20 * time.Second,
			ResponseHeaderTimeout: 20 * time.Second,
			ExpectContinueTimeout: 8 * time.Second,
			MaxIdleConns:          MaxHTTPIdleConnections,
			IdleConnTimeout:       HTTPIdleConnectionTimeoutS * time.Second,
			//TLSClientConfig: &tls.Config{ InsecureSkipVerify: skipSSL }, // <- this is set by TrustIcpCert()
		},
	}
	if httpErr := TrustIcpCert(httpClient.Transport.(*http.Transport), certPath); httpErr != nil {
		return nil, httpErr
	}

	return httpClient, nil
}

/* TrustIcpCert adds the icp cert file to be trusted (if exists) in calls made by the given http client. 3 cases:
1. no cert is needed because a CA-trusted cert is being used, or the svr uses http
2. a self-signed cert is being used, but they told us to connect insecurely
3. a non-blank certPath is specified that we will use
*/
func TrustIcpCert(transport *http.Transport, certPath string) *HttpError {
	// Case 2:
	if os.Getenv("HZN_SSL_SKIP_VERIFY") != "" {
		transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
		return nil
	}
	transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: false}

	// Case 1:
	if certPath == "" {
		return nil
	}

	// Case 3:
	icpCert, err := os.ReadFile(filepath.Clean(certPath))
	if err != nil {
		return NewHttpError(http.StatusInternalServerError, "Encountered error reading ICP cert file %v: %v", certPath, err)
	}
	caCertPool := x509.NewCertPool()
	caCertPool.AppendCertsFromPEM(icpCert)

	transport.TLSClientConfig.RootCAs = caCertPool
	return nil
}

type RunCmdOpts struct {
	Environ []string // environment variables that should be set in the command's environment. Each string should contain: MY_VAR=some_value
}

// Run a command with args, and return stdout, stderr
func RunCmd(options RunCmdOpts, commandString string, args ...string) ([]byte, []byte, error) {
	/* For debug, build the full cmd string
	fullCmdStr := commandString
	for _, a := range args {
		fullCmdStr += " " + a
	}
	Verbose("Running: %v\n", fullCmdStr)
	*/

	// Create the command object with its args
	cmd := exec.Command(commandString, args...)
	if cmd == nil {
		return nil, nil, errors.New("did not return a command object for " + commandString + ", returned nil")
	}

	// Add any specified env vars to the cmd environment
	if options.Environ != nil && len(options.Environ) > 0 {
		cmd.Env = os.Environ()
		for _, keyAndValue := range options.Environ {
			parts := strings.SplitN(keyAndValue, "=", 2)
			if len(parts) != 2 {
				return nil, nil, errors.New("Invalid key=value format for RunCmdOpts.Environ element: " + keyAndValue)
			}
			cmd.Env = append(cmd.Env, keyAndValue)
		}
	}

	// Create the stdout pipe to hold the output from the command
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, nil, errors.New("Error retrieving output from command " + commandString + ", error: " + err.Error())
	}

	// Create the stderr pipe to hold the errors from the command
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, nil, errors.New("Error retrieving stderr from command " + commandString + ", error: " + err.Error())
	}

	// Get the command started
	err = cmd.Start()
	if err != nil {
		return nil, nil, errors.New("Unable to start command " + commandString + ", error: " + err.Error())
	}
	err = error(nil)

	// Read the output from stdout and stderr into byte arrays
	// stdoutBytes, err := readPipe(stdout)
	stdoutBytes, err := ioutil.ReadAll(stdout)
	if err != nil {
		return nil, nil, errors.New("Error reading stdout from command " + commandString + ", error: " + err.Error())
	}
	// stderrBytes, err := readPipe(stderr)
	stderrBytes, err := ioutil.ReadAll(stderr)
	if err != nil {
		return nil, nil, errors.New("Error reading stderr from command " + commandString + ", error: " + err.Error())
	}

	// Now wait for the command to complete (which should be immediate, because we already received EOF on stdout and stderr above)
	err = cmd.Wait()
	if err != nil {
		if exitError, ok := err.(*exec.ExitError); ok {
			codeOfExit := exitError.ExitCode()
			if codeOfExit == 3 {
				return stdoutBytes, stderrBytes, errors.New("Duplicate Key Error, " + string(stderrBytes))
			} else {
				return stdoutBytes, stderrBytes, errors.New("command " + commandString + " returned exit code: " + err.Error() + ". Stderr: " + string(stderrBytes))
			}
		}
	}
	return stdoutBytes, stderrBytes, error(nil)
}

func GetOwnerServiceApiKey() (string, string) {
	apiKey := os.Getenv("FDO_API_PWD")
	if apiKey == "" {
		log.Fatalln("FDO_API_PWD NOT SET")
	}

	return SplitIdToken(apiKey)
}

func GetTo2OwnerHost() (string, string) {
	To2Host := os.Getenv("FDO_OPS_SVC_HOST")
	if To2Host == "" {
		log.Fatalln("FDO_OPS_SVC_HOST NOT SET")
	}

	return SplitIdToken(To2Host)
}

func SplitIdToken(idToken string) (id, token string) {
	parts := strings.SplitN(idToken, ":", 2)
	id = parts[0] // SplitN will always at least return 1 element
	token = ""
	if len(parts) >= 2 {
		token = parts[1]
	}
	return
}

