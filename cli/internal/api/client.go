package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const maxResponseBytes = 8 << 20

type Client struct {
	baseURL *url.URL
	token   string
	http    *http.Client
}

type Error struct {
	Tag             string
	Status          int
	Fields          map[string][]string
	CurrentRevision int
	Cause           error
}

var commandErrorTags = []string{
	"unauthenticated",
	"not_found",
	"forbidden",
	"invalid_input",
	"revision_conflict",
	"destroyed",
	"creation_conflict",
	"name_conflict",
	"hostname_conflict",
	"node_disabled",
	"node_abandoned",
	"capacity_exceeded",
	"temporarily_unavailable",
}

// This is the field-error vocabulary emitted by the current HTTP API. Keep the
// list explicit so adding a server-side reason requires a client mapping too.
var serverFieldErrorReasons = []string{
	"missing",
	"invalid_format",
	"out_of_range",
	"too_long",
	"too_short",
	"invalid_value",
	"no_default_node",
	"already_registered",
	"not_future",
	"too_far",
	"unknown_principal",
	"not_requested",
	"publication_not_active",
	"not_ready",
	"nul_byte",
	"secret_value_too_large",
	"too_many_layers",
	"repository_url_too_long",
	"source_ref_too_long",
	"embedded_credentials",
}

var errorMessages = map[string]string{
	"unauthenticated":         "Your session is no longer valid. Run biot login.",
	"not_found":               "That resource was not found.",
	"forbidden":               "You do not have permission to do that.",
	"invalid_input":           "The request contains invalid input.",
	"revision_conflict":       "This Biot changed; reload and try again.",
	"destroyed":               "This Biot has been destroyed.",
	"creation_conflict":       "A Biot with that ID is already being created.",
	"name_conflict":           "That Biot name is already in use.",
	"hostname_conflict":       "That hostname is already in use.",
	"node_disabled":           "The selected node is disabled.",
	"node_abandoned":          "The selected node is abandoned.",
	"capacity_exceeded":       "The selected node has no available capacity.",
	"temporarily_unavailable": "The server could not provide that resource right now.",
}

var fieldReasonMessages = map[string]string{
	"missing":                 "is required.",
	"invalid_format":          "has an invalid format.",
	"out_of_range":            "is outside the allowed range.",
	"too_long":                "is too long.",
	"too_short":               "is too short.",
	"invalid_value":           "has an invalid value.",
	"no_default_node":         "has no default node; pass --node with a node ID.",
	"already_registered":      "is already registered.",
	"not_future":              "must be in the future.",
	"too_far":                 "is beyond the allowed lifetime.",
	"unknown_principal":       "does not identify a known principal.",
	"not_requested":           "is not currently requested.",
	"publication_not_active":  "is no longer active.",
	"not_ready":               "is not ready yet.",
	"nul_byte":                "must not contain a NUL byte.",
	"secret_value_too_large":  "is larger than the maximum secret size.",
	"too_many_layers":         "has too many layers.",
	"repository_url_too_long": "exceeds the maximum repository URL length.",
	"source_ref_too_long":     "exceeds the maximum source reference length.",
	"embedded_credentials":    "must not embed credentials.",
}

func init() {
	for _, tag := range commandErrorTags {
		if strings.TrimSpace(errorMessages[tag]) == "" {
			panic("CLI error vocabulary is incomplete for " + tag)
		}
	}
	for _, reason := range serverFieldErrorReasons {
		if strings.TrimSpace(fieldReasonMessages[reason]) == "" {
			panic("CLI field-error vocabulary is incomplete for " + reason)
		}
	}
}

func (e *Error) Error() string {
	if e.Cause != nil {
		return e.Cause.Error()
	}
	if message, ok := errorMessages[e.Tag]; ok {
		if e.Tag == "revision_conflict" {
			return fmt.Sprintf("This Biot changed; its current revision is %d. Reload and try again.", e.CurrentRevision)
		}
		if e.Tag == "invalid_input" {
			return invalidInputMessage(e.Fields)
		}
		return message
	}
	switch e.Tag {
	case "revision_conflict":
		return fmt.Sprintf("This Biot changed; its current revision is %d. Reload and try again.", e.CurrentRevision)
	case "invalid_input":
		return invalidInputMessage(e.Fields)
	case "internal":
		return "The server could not complete that request."
	default:
		if e.Tag != "" {
			return fmt.Sprintf("The server returned an error this client does not understand (code %q). Update biot and try again.", e.Tag)
		}
		return "The server returned an unexpected response."
	}
}

func New(baseURL string, token string, transport http.RoundTripper) (*Client, error) {
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errors.New("server URL must be an absolute HTTP URL without credentials or a query")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, errors.New("server URL must use http or https")
	}
	parsed.Path = strings.TrimRight(parsed.Path, "/")
	if transport == nil {
		transport = http.DefaultTransport
	}
	return &Client{baseURL: parsed, token: token, http: &http.Client{Transport: transport, Timeout: 30 * time.Second}}, nil
}

func (c *Client) ServerURL() string { return c.baseURL.String() }

func (c *Client) Request(ctx context.Context, method string, path string, body any, result any) error {
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("encode request: %w", err)
		}
		reader = bytes.NewReader(encoded)
	}
	requestPath, err := url.Parse(path)
	if err != nil || requestPath.IsAbs() || requestPath.Host != "" {
		return errors.New("invalid API path")
	}
	endpoint := *c.baseURL
	endpoint.Path = strings.TrimRight(c.baseURL.Path, "/") + "/api/" + strings.TrimLeft(requestPath.Path, "/")
	endpoint.RawQuery = requestPath.RawQuery
	endpoint.Fragment = ""
	request, err := http.NewRequestWithContext(ctx, method, endpoint.String(), reader)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		request.Header.Set("Authorization", "Bearer "+c.token)
	}
	response, err := c.http.Do(request)
	if err != nil {
		return fmt.Errorf("contact the Biot server: %w", err)
	}
	defer response.Body.Close()
	contents, err := readBounded(response.Body)
	if err != nil {
		return fmt.Errorf("read the Biot server response: %w", err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return parseError(response.StatusCode, contents)
	}
	if result == nil || len(contents) == 0 {
		return nil
	}
	if err := json.Unmarshal(contents, result); err != nil {
		return fmt.Errorf("decode the Biot server response: %w", err)
	}
	return nil
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
		return "", errors.New("secret values must be valid UTF-8; this API carries them as JSON strings")
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
		Host string `json:"host"`
		Port int    `json:"port"`
	} `json:"ssh"`
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
		return "The request contains invalid input."
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
			parts = append(parts, key+" "+reasonText(reason))
		}
	}
	return strings.Join(parts, "; ")
}

func reasonText(reason string) string {
	if message, ok := fieldReasonMessages[reason]; ok {
		return message
	}
	return fmt.Sprintf("has an unknown validation reason %q; update biot and try again.", reason)
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
