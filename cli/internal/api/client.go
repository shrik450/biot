package api

import (
	"bytes"
	"context"
	"crypto/tls"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const maxResponseBytes = 8 << 20

const transportNoticeDelay = 2 * time.Second

type Client struct {
	baseURL *url.URL
	token   string
	http    *http.Client
	notice  io.Writer
}

type Error struct {
	Tag             string
	Status          int
	Fields          map[string][]string
	CurrentRevision int
	Cause           error
}

func IsUnauthenticated(err error) bool {
	var apiError *Error
	return errors.As(err, &apiError) && apiError.Tag == "unauthenticated"
}

// This is the generated vocabulary emitted by the current HTTP API. The Mix task checks the
// artifact against the server vocabularies; the client embeds that same artifact here.
//
//go:embed error_vocabulary.txt
var vocabularyFile string

type vocabularyEntry struct {
	kind     string
	limit    int
	sentence string
	remedy   bool
}

var vocabulary = parseVocabulary(vocabularyFile)

var clientRemedies = map[string]string{
	"unauthenticated":        "Run biot login.",
	"revision_conflict":      "Run the command again.",
	"publication_not_active": "choose an active publication.",
}

var placeholderPattern = regexp.MustCompile(`\{([a-z_][a-z0-9_]*)\}`)

var expectedPlaceholders = map[string][]string{
	"revision_conflict": {"revision"},
}

var serverFieldErrorReasons = vocabularyNames("field")

var commandErrorTags = vocabularyNames("command")

func init() {
	for _, tag := range commandErrorTags {
		entry, ok := vocabulary[tag]
		if !ok || entry.kind != "command" || strings.TrimSpace(entry.sentence) == "" {
			panic("CLI error vocabulary is incomplete for " + tag)
		}
	}
	for _, reason := range serverFieldErrorReasons {
		entry, ok := vocabulary[reason]
		if !ok || entry.kind != "field" || strings.TrimSpace(entry.sentence) == "" {
			panic("CLI field-error vocabulary is incomplete for " + reason)
		}
	}
	for reason, entry := range vocabulary {
		remedy, hasRemedy := clientRemedies[reason]
		if entry.remedy != hasRemedy {
			panic("CLI remedy coverage is incomplete for " + reason)
		}
		if entry.remedy && strings.TrimSpace(remedy) == "" {
			panic("CLI remedy is empty for " + reason)
		}
		if entry.remedy {
			first, _ := utf8.DecodeRuneInString(remedy)
			if (entry.kind == "field" && !unicode.IsLower(first)) ||
				(entry.kind == "command" && !unicode.IsUpper(first)) {
				panic("CLI remedy has the wrong capitalization for " + reason)
			}
		}
		validatePlaceholders(reason, entry.sentence)
	}
	for reason := range clientRemedies {
		entry, ok := vocabulary[reason]
		if !ok || !entry.remedy {
			panic("CLI remedy is not declared by the vocabulary for " + reason)
		}
	}
}

func parseVocabulary(contents string) map[string]vocabularyEntry {
	if !strings.HasSuffix(contents, "\n") {
		panic("embedded CLI vocabulary artifact must end with a newline")
	}
	lines := strings.Split(strings.TrimSuffix(contents, "\n"), "\n")
	if len(lines) == 0 || lines[0] == "" {
		panic("embedded CLI vocabulary artifact must not be empty")
	}
	entries := make(map[string]vocabularyEntry, len(lines))
	previous := ""
	for _, line := range lines {
		parts := strings.Split(line, "|")
		if len(parts) != 5 || parts[0] == "" || parts[1] == "" || parts[3] == "" {
			panic("embedded CLI vocabulary artifact has an invalid line")
		}
		if parts[0] <= previous {
			panic("embedded CLI vocabulary artifact must be sorted and unique")
		}
		if parts[1] != "field" && parts[1] != "command" {
			panic("embedded CLI vocabulary artifact has an invalid kind")
		}
		limit, err := strconv.Atoi(parts[2])
		if err != nil || limit < 0 {
			panic("embedded CLI vocabulary artifact has an invalid limit")
		}
		if parts[4] != "none" && parts[4] != "required" {
			panic("embedded CLI vocabulary artifact has an invalid remedy marker")
		}
		entries[parts[0]] = vocabularyEntry{
			kind:     parts[1],
			limit:    limit,
			sentence: parts[3],
			remedy:   parts[4] == "required",
		}
		previous = parts[0]
	}
	return entries
}

func vocabularyNames(kind string) []string {
	names := make([]string, 0)
	for name, entry := range vocabulary {
		if entry.kind == kind {
			names = append(names, name)
		}
	}
	slicesSort(names)
	return names
}

func validatePlaceholders(reason string, sentence string) {
	placeholders := make([]string, 0)
	for _, match := range placeholderPattern.FindAllStringSubmatch(sentence, -1) {
		placeholders = append(placeholders, match[1])
	}
	if strings.Count(sentence, "{") != len(placeholders) || strings.Count(sentence, "}") != len(placeholders) {
		panic("embedded CLI vocabulary artifact has an invalid placeholder for " + reason)
	}
	expected := expectedPlaceholders[reason]
	if len(placeholders) != len(expected) {
		panic("embedded CLI vocabulary artifact has unexpected placeholders for " + reason)
	}
	for index := range placeholders {
		if placeholders[index] != expected[index] {
			panic("embedded CLI vocabulary artifact has unexpected placeholders for " + reason)
		}
	}
}

func (e *Error) Error() string {
	if e.Cause != nil {
		return e.Cause.Error()
	}
	switch e.Tag {
	case "revision_conflict":
		return renderCommandSentence(e.Tag, map[string]string{"revision": strconv.Itoa(e.CurrentRevision)})
	case "invalid_input":
		return invalidInputMessage(e.Fields)
	case "internal":
		return "The server could not complete that request."
	default:
		if entry, ok := vocabulary[e.Tag]; ok && entry.kind == "command" {
			return renderCommandSentence(e.Tag, nil)
		}
		if e.Tag != "" {
			return fmt.Sprintf("The server returned an error this client does not understand (code %q). Update biot and try again.", e.Tag)
		}
		return "The server returned an unexpected response."
	}
}

func New(baseURL string, token string, transport http.RoundTripper) (*Client, error) {
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errors.New("server URL must be an absolute HTTP URL without credentials or a query.")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, errors.New("server URL must use http or https.")
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	if transport == nil {
		transport = http.DefaultTransport
	}
	return &Client{
		baseURL: parsed,
		token:   token,
		http:    &http.Client{Transport: transport, Timeout: 30 * time.Second},
		notice:  os.Stderr,
	}, nil
}

func (c *Client) ServerURL() string { return c.baseURL.String() }

func (c *Client) Request(ctx context.Context, method string, path string, body any, result any) error {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("encode request: %w.", err)
		}
		reader = bytes.NewReader(encoded)
	}
	requestPath, err := url.Parse(path)
	if err != nil || requestPath.IsAbs() || requestPath.Host != "" {
		return errors.New("invalid API path.")
	}
	endpoint := *c.baseURL
	endpoint.Path = strings.TrimRight(c.baseURL.Path, "/") + "/api/" + strings.TrimLeft(requestPath.Path, "/")
	endpoint.RawQuery = requestPath.RawQuery
	endpoint.Fragment = ""
	request, err := http.NewRequestWithContext(ctx, method, endpoint.String(), reader)
	if err != nil {
		return fmt.Errorf("build request: %w.", err)
	}
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		request.Header.Set("Authorization", "Bearer "+c.token)
	}
	response, err := c.do(request)
	if err != nil {
		return serverCommunicationError(c.ServerURL(), err)
	}
	defer response.Body.Close()
	contents, err := readBounded(response.Body)
	if err != nil {
		return serverCommunicationError(c.ServerURL(), err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return parseError(response.StatusCode, contents)
	}
	if result == nil || len(contents) == 0 {
		return nil
	}
	if err := json.Unmarshal(contents, result); err != nil {
		return fmt.Errorf("decode the Biot server response: %w.", err)
	}
	return nil
}

func (c *Client) do(request *http.Request) (*http.Response, error) {
	if c.notice == nil {
		return c.http.Do(request)
	}

	finished := make(chan struct{})
	noticeDone := make(chan struct{})
	go func() {
		defer close(noticeDone)
		timer := time.NewTimer(transportNoticeDelay)
		defer timer.Stop()

		select {
		case <-timer.C:
			fmt.Fprintf(c.notice, "Waiting for the Biot server at %s...\n", c.ServerURL())
		case <-finished:
		}
	}()

	response, err := c.http.Do(request)
	close(finished)
	<-noticeDone
	return response, err
}

func (c *Client) Me(ctx context.Context) (Principal, error) {
	var principal Principal
	err := c.Request(ctx, http.MethodGet, "me", nil, &principal)
	return principal, err
}

func (c *Client) ListBiots(ctx context.Context) ([]Biot, error) {
	const pageSize = 200
	var biots []Biot
	after := ""
	for {
		query := url.Values{"limit": []string{strconv.Itoa(pageSize)}}
		if after != "" {
			query.Set("after", after)
		}
		var page []Biot
		if err := c.Request(ctx, http.MethodGet, "biots?"+query.Encode(), nil, &page); err != nil {
			return nil, err
		}
		biots = append(biots, page...)
		if len(page) < pageSize {
			return biots, nil
		}
		next := page[len(page)-1].ID
		if next == "" || next == after {
			return nil, errors.New("the server returned an invalid Biot listing cursor")
		}
		after = next
	}
}

func (c *Client) GetBiot(ctx context.Context, id string) (Biot, error) {
	var biot Biot
	err := c.Request(ctx, http.MethodGet, "biots/"+url.PathEscape(id), nil, &biot)
	return biot, err
}

type LifecycleResult struct {
	OperationID string `json:"operation_id"`
	BiotID      string `json:"biot_id"`
	Revision    int    `json:"revision"`
}

func (c *Client) CreateBiot(ctx context.Context, id string, body map[string]any) (LifecycleResult, error) {
	var result LifecycleResult
	err := c.Request(ctx, http.MethodPut, "biots/"+url.PathEscape(id), body, &result)
	return result, err
}

func (c *Client) StartBiot(ctx context.Context, id string, revision int) (LifecycleResult, error) {
	return c.lifecycle(ctx, http.MethodPost, url.PathEscape(id)+"/start", revision)
}

func (c *Client) StopBiot(ctx context.Context, id string, revision int) (LifecycleResult, error) {
	return c.lifecycle(ctx, http.MethodPost, url.PathEscape(id)+"/stop", revision)
}

func (c *Client) RebuildBiot(ctx context.Context, id string, revision int, environment map[string]any) (LifecycleResult, error) {
	body := map[string]any{"environment": environment, "expected_revision": revision}
	var result LifecycleResult
	err := c.Request(ctx, http.MethodPost, "biots/"+url.PathEscape(id)+"/environment", body, &result)
	return result, err
}

func (c *Client) DestroyBiot(ctx context.Context, id string) (LifecycleResult, error) {
	var result LifecycleResult
	err := c.Request(ctx, http.MethodDelete, "biots/"+url.PathEscape(id), nil, &result)
	return result, err
}

func (c *Client) GetOperation(ctx context.Context, id string) (Operation, error) {
	var operation Operation
	err := c.Request(ctx, http.MethodGet, "operations/"+url.PathEscape(id), nil, &operation)
	return operation, err
}

func (c *Client) DeliverSecret(ctx context.Context, id string, name string, value []byte) error {
	encoded, err := secretJSONValue(value)
	if err != nil {
		return err
	}
	body := map[string]any{"value": encoded}
	return c.Request(ctx, http.MethodPut, "biots/"+url.PathEscape(id)+"/secrets/"+url.PathEscape(name), body, nil)
}

func (c *Client) ListSecrets(ctx context.Context, id string) ([]Secret, error) {
	var secrets []Secret
	err := c.Request(ctx, http.MethodGet, "biots/"+url.PathEscape(id)+"/secrets", nil, &secrets)
	return secrets, err
}

func (c *Client) RemoveSecret(ctx context.Context, id string, name string) error {
	return c.Request(ctx, http.MethodDelete, "biots/"+url.PathEscape(id)+"/secrets/"+url.PathEscape(name), nil, nil)
}

func (c *Client) DeliverFetchCredential(ctx context.Context, id string, source string, value []byte) error {
	encoded, err := secretJSONValue(value)
	if err != nil {
		return err
	}
	body := map[string]any{"source": source, "value": encoded}
	return c.Request(ctx, http.MethodPut, "biots/"+url.PathEscape(id)+"/fetch-credentials", body, nil)
}

func secretJSONValue(value []byte) (string, error) {
	if !utf8.Valid(value) {
		return "", errors.New("secret values must be valid UTF-8; this API carries them as JSON strings.")
	}
	return string(value), nil
}

func (c *Client) RemoveFetchCredential(ctx context.Context, id string, source string) error {
	body := map[string]any{"source": source}
	return c.Request(ctx, http.MethodDelete, "biots/"+url.PathEscape(id)+"/fetch-credentials", body, nil)
}

func (c *Client) GetDeployment(ctx context.Context) (Deployment, error) {
	var deployment Deployment
	err := c.Request(ctx, http.MethodGet, "deployment", nil, &deployment)
	return deployment, err
}

func (c *Client) ListNodes(ctx context.Context) ([]Node, error) {
	var nodes []Node
	err := c.Request(ctx, http.MethodGet, "nodes", nil, &nodes)
	return nodes, err
}

func (c *Client) GetDiagnostic(ctx context.Context, reference string) (Diagnostic, error) {
	var diagnostic Diagnostic
	err := c.Request(ctx, http.MethodGet, "diagnostics/"+url.PathEscape(reference), nil, &diagnostic)
	return diagnostic, err
}

func (c *Client) GetRuntimeLogs(ctx context.Context, id string, maxBytes int) (Logs, error) {
	var logs Logs
	query := url.Values{"max_bytes": []string{strconv.Itoa(maxBytes)}}
	path := "biots/" + url.PathEscape(id) + "/logs?" + query.Encode()
	err := c.Request(ctx, http.MethodGet, path, nil, &logs)
	return logs, err
}

func (c *Client) ListSSHKeys(ctx context.Context) ([]SSHKey, error) {
	var keys []SSHKey
	err := c.Request(ctx, http.MethodGet, "ssh-keys", nil, &keys)
	return keys, err
}

func (c *Client) AddSSHKey(ctx context.Context, publicKey string, label string) (SSHKey, error) {
	var key SSHKey
	body := map[string]any{"public_key": publicKey, "label": label}
	err := c.Request(ctx, http.MethodPost, "ssh-keys", body, &key)
	return key, err
}

func (c *Client) RemoveSSHKey(ctx context.Context, id string) error {
	return c.Request(ctx, http.MethodDelete, "ssh-keys/"+url.PathEscape(id), nil, nil)
}

func (c *Client) ListCredentials(ctx context.Context) ([]Credential, error) {
	var credentials []Credential
	err := c.Request(ctx, http.MethodGet, "credentials", nil, &credentials)
	return credentials, err
}

func (c *Client) RevokeCredential(ctx context.Context, id string) error {
	return c.Request(ctx, http.MethodDelete, "credentials/"+url.PathEscape(id), nil, nil)
}

func (c *Client) ListPublications(ctx context.Context, id string) ([]Publication, error) {
	var publications []Publication
	err := c.Request(ctx, http.MethodGet, "biots/"+url.PathEscape(id)+"/publications", nil, &publications)
	return publications, err
}

func (c *Client) Publish(ctx context.Context, id string, port int) (PolicyResult, error) {
	return c.publicationPolicy(ctx, http.MethodPut, id, port)
}

func (c *Client) Unpublish(ctx context.Context, id string, port int) (PolicyResult, error) {
	return c.publicationPolicy(ctx, http.MethodDelete, id, port)
}

func (c *Client) publicationPolicy(ctx context.Context, method string, id string, port int) (PolicyResult, error) {
	var result PolicyResult
	path := "biots/" + url.PathEscape(id) + "/publications/" + strconv.Itoa(port)
	err := c.Request(ctx, method, path, map[string]any{}, &result)
	return result, err
}

func (c *Client) ResolvePrincipal(ctx context.Context, email string) (Principal, error) {
	var principal Principal
	query := url.Values{"email": []string{email}}
	err := c.Request(ctx, http.MethodGet, "principals?"+query.Encode(), nil, &principal)
	return principal, err
}

func (c *Client) GetGrants(ctx context.Context, id string) (Grants, error) {
	var grants Grants
	err := c.Request(ctx, http.MethodGet, "biots/"+url.PathEscape(id)+"/grants", nil, &grants)
	return grants, err
}

func (c *Client) GrantShell(ctx context.Context, id string, principalID string) (PolicyResult, error) {
	return c.grantPolicy(ctx, http.MethodPut, id, "shell", principalID)
}

func (c *Client) RevokeShell(ctx context.Context, id string, principalID string) (PolicyResult, error) {
	return c.grantPolicy(ctx, http.MethodDelete, id, "shell", principalID)
}

func (c *Client) GrantView(ctx context.Context, id string, port int, principalID string) (PolicyResult, error) {
	return c.grantPolicy(ctx, http.MethodPut, id, "view/"+strconv.Itoa(port), principalID)
}

func (c *Client) RevokeView(ctx context.Context, id string, port int, principalID string) (PolicyResult, error) {
	return c.grantPolicy(ctx, http.MethodDelete, id, "view/"+strconv.Itoa(port), principalID)
}

func (c *Client) grantPolicy(ctx context.Context, method string, id string, kind string, principalID string) (PolicyResult, error) {
	var result PolicyResult
	path := "biots/" + url.PathEscape(id) + "/grants/" + kind + "/" + url.PathEscape(principalID)
	err := c.Request(ctx, method, path, map[string]any{}, &result)
	return result, err
}

func (c *Client) lifecycle(ctx context.Context, method string, path string, revision int) (LifecycleResult, error) {
	body := map[string]any{"expected_revision": revision}
	var result LifecycleResult
	err := c.Request(ctx, method, "biots/"+path, body, &result)
	return result, err
}

type Biot struct {
	ID                           string         `json:"id"`
	Name                         string         `json:"name"`
	OwnerID                      string         `json:"owner_id"`
	NodeID                       string         `json:"node_id"`
	Role                         Role           `json:"role"`
	Desired                      Desired        `json:"desired"`
	Environment                  map[string]any `json:"environment"`
	Actual                       Actual         `json:"actual"`
	Node                         string         `json:"node"`
	Operation                    *Operation     `json:"operation"`
	Access                       Access         `json:"access"`
	Publications                 []Publication  `json:"publications"`
	DirectSecretExposurePossible bool           `json:"direct_secret_exposure_possible"`
}

type Role struct {
	Kind      string `json:"kind"`
	Shell     bool   `json:"shell"`
	ViewPorts []int  `json:"view_ports"`
}

type Desired struct {
	Revision      int    `json:"revision"`
	State         string `json:"state"`
	EnvironmentID string `json:"environment_id"`
}

type Actual struct {
	Kind                 string      `json:"kind"`
	ReceivedAt           string      `json:"received_at"`
	Freshness            string      `json:"freshness"`
	InstalledEnvironment string      `json:"installed_environment"`
	Container            Container   `json:"container"`
	Data                 string      `json:"data"`
	WaitingFor           *WaitingFor `json:"waiting_for"`
	Failure              *Failure    `json:"failure"`
}

type Container struct {
	Kind          string `json:"kind"`
	IncarnationID string `json:"incarnation_id"`
	State         string `json:"state"`
	Status        *int   `json:"status"`
}

type WaitingFor struct {
	Kind   string `json:"kind"`
	Source string `json:"source"`
}

type Failure struct {
	Stage          string `json:"stage"`
	Code           string `json:"code"`
	Retry          string `json:"retry"`
	Message        string `json:"message"`
	DiagnosticRef  string `json:"diagnostic_ref"`
	TargetRevision int    `json:"target_revision"`
}

type Operation struct {
	ID             string           `json:"id"`
	Kind           string           `json:"kind"`
	TargetRevision int              `json:"target_revision"`
	Outcome        OperationOutcome `json:"outcome"`
}

type OperationOutcome struct {
	Kind    string   `json:"kind"`
	Failure *Failure `json:"-"`
}

func (o *OperationOutcome) UnmarshalJSON(contents []byte) error {
	var value struct {
		Kind string `json:"kind"`
	}
	if err := json.Unmarshal(contents, &value); err != nil {
		return err
	}
	o.Kind = value.Kind
	if value.Kind == "failed" {
		var failure Failure
		if err := json.Unmarshal(contents, &failure); err != nil {
			return err
		}
		o.Failure = &failure
	}
	return nil
}

type Access struct {
	Revision    int         `json:"revision"`
	Enforcement Enforcement `json:"enforcement"`
}

type Enforcement struct {
	Kind   string `json:"kind"`
	NodeID string `json:"node_id"`
}

type Publication struct {
	Port int    `json:"port"`
	URL  string `json:"url"`
}

type Deployment struct {
	PublicationDomain string `json:"publication_domain"`
	SSH               struct {
		Host     string    `json:"host"`
		Port     int       `json:"port"`
		HostKeys []HostKey `json:"host_keys"`
	} `json:"ssh"`
}

type HostKey struct {
	Type        string `json:"type"`
	PublicKey   string `json:"public_key"`
	Fingerprint string `json:"fingerprint"`
}

type OperationResult struct {
	OperationID string `json:"operation_id"`
	BiotID      string `json:"biot_id"`
	Revision    int    `json:"revision"`
}

type PolicyResult struct {
	Result         string      `json:"result"`
	BiotID         string      `json:"biot_id"`
	AccessRevision int         `json:"access_revision"`
	Enforcement    Enforcement `json:"enforcement"`
}

type Secret struct {
	Name string `json:"name"`
}

type Principal struct {
	ID    string `json:"id"`
	Email string `json:"email"`
	Name  string `json:"name"`
}

type Credential struct {
	ID         string `json:"id"`
	Label      string `json:"label"`
	ExpiresAt  string `json:"expires_at"`
	LastUsedAt string `json:"last_used_at"`
}

type SSHKey struct {
	ID          string `json:"id"`
	PublicKey   string `json:"public_key"`
	Fingerprint string `json:"fingerprint"`
	Label       string `json:"label"`
}

type Node struct {
	ID            string          `json:"id"`
	Status        string          `json:"status"`
	Platform      string          `json:"platform"`
	MaxBiots      int             `json:"max_biots"`
	AssignedBiots int             `json:"assigned_biots"`
	Connection    string          `json:"connection"`
	Orphans       json.RawMessage `json:"orphans"`
}

type Grants struct {
	Owner  Principal `json:"owner"`
	Grants []Grant   `json:"grants"`
}

type Grant struct {
	Kind      string    `json:"kind"`
	Port      int       `json:"port"`
	Principal Principal `json:"principal"`
}

type Logs struct {
	IncarnationID string `json:"incarnation_id"`
	Content       string `json:"content"`
	Truncated     bool   `json:"truncated"`
}

type Diagnostic struct {
	Content   string `json:"content"`
	Truncated bool   `json:"truncated"`
}

func readBounded(reader io.Reader) ([]byte, error) {
	contents, err := io.ReadAll(io.LimitReader(reader, maxResponseBytes+1))
	if err != nil {
		return nil, err
	}
	if len(contents) > maxResponseBytes {
		return nil, errors.New("response is too large")
	}
	return contents, nil
}

func serverCommunicationError(serverURL string, err error) error {
	var dnsError *net.DNSError
	var operationError *net.OpError
	var certificateError *tls.CertificateVerificationError

	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return fmt.Errorf("The Biot server at %s did not respond in time; check that it is running.", serverURL)
	case errors.As(err, &certificateError):
		return fmt.Errorf("The Biot server at %s did not present a trusted certificate; check its HTTPS certificate.", serverURL)
	case errors.As(err, &dnsError):
		return fmt.Errorf("The Biot server at %s could not be found; check the server URL.", serverURL)
	case errors.Is(err, io.ErrUnexpectedEOF):
		return fmt.Errorf("The Biot server at %s closed its response before it was complete; check that it is running.", serverURL)
	case errors.As(err, &operationError):
		return fmt.Errorf("The Biot server at %s is not accepting connections; check that it is running.", serverURL)
	default:
		cause := "unknown transport failure."
		if err != nil {
			cause = punctuate(leafError(err).Error())
		}
		return fmt.Errorf(
			"Could not contact the Biot server at %s; check that it is running. Cause: %s",
			serverURL,
			cause,
		)
	}
}

func leafError(err error) error {
	for {
		unwrapped := errors.Unwrap(err)
		if unwrapped == nil {
			return err
		}
		err = unwrapped
	}
}

func punctuate(message string) string {
	message = strings.TrimSpace(message)
	if message == "" {
		return "unknown transport failure."
	}
	if strings.HasSuffix(message, ".") {
		return message
	}
	return message + "."
}

func parseError(status int, contents []byte) *Error {
	value := struct {
		Error           string              `json:"error"`
		Fields          map[string][]string `json:"fields"`
		CurrentRevision int                 `json:"current_revision"`
	}{}
	if json.Unmarshal(contents, &value) != nil || value.Error == "" {
		if status == http.StatusUnauthorized {
			value.Error = "unauthenticated"
		} else {
			value.Error = "internal"
		}
	}
	return &Error{Tag: value.Error, Status: status, Fields: value.Fields, CurrentRevision: value.CurrentRevision}
}

func invalidInputMessage(fields map[string][]string) string {
	if len(fields) == 0 {
		return commandSentence("invalid_input")
	}
	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	slicesSort(keys)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		reasons := fields[key]
		for _, reason := range reasons {
			parts = append(parts, key+" "+fieldReasonSentence(reason))
		}
	}
	if len(parts) == 0 {
		return commandSentence("invalid_input")
	}
	return strings.Join(parts, "; ")
}

func reasonText(reason string) string {
	if message, ok := vocabulary[reason]; ok && message.kind == "field" {
		return message.sentence
	}
	return fmt.Sprintf("has an unknown validation reason %q; update biot and try again.", reason)
}

func fieldReasonSentence(reason string) string {
	return sentenceWithRemedy(reason, reasonText(reason))
}

func commandSentence(tag string) string {
	entry, ok := vocabulary[tag]
	if !ok || entry.kind != "command" || entry.sentence == "" {
		panic("CLI command-error vocabulary is incomplete for " + tag)
	}
	return entry.sentence
}

func renderCommandSentence(tag string, replacements map[string]string) string {
	sentence := commandSentence(tag)
	for name, value := range replacements {
		sentence = strings.ReplaceAll(sentence, "{"+name+"}", value)
	}
	if placeholderPattern.MatchString(sentence) {
		panic("CLI command-error vocabulary left a placeholder in " + tag)
	}
	return sentenceWithRemedy(tag, sentence)
}

func sentenceWithRemedy(reason string, sentence string) string {
	if remedy, ok := clientRemedies[reason]; ok {
		if vocabulary[reason].kind == "field" {
			return strings.TrimSuffix(sentence, ".") + "; " + remedy
		}
		return sentence + " " + remedy
	}
	return sentence
}

// FieldReasonMessage renders the sentence for a rejected field. It is also used by local input
// guards so a value rejected before an HTTP request receives the same wording as a server reject.
func FieldReasonMessage(field string, reason string) string {
	return field + " " + fieldReasonSentence(reason)
}

// FieldReasonLimit returns the bound carried by a field reason. A zero limit means that reason has
// no numeric bound in the generated vocabulary.
func FieldReasonLimit(reason string) (int, bool) {
	entry, ok := vocabulary[reason]
	return entry.limit, ok && entry.kind == "field" && entry.limit > 0
}

func slicesSort(values []string) {
	for i := 1; i < len(values); i++ {
		for j := i; j > 0 && values[j] < values[j-1]; j-- {
			values[j], values[j-1] = values[j-1], values[j]
		}
	}
}

func Int(value string) (int, error) {
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("%q is not a number", value)
	}
	return parsed, nil
}
