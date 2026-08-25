package main

import (
	"context"
	"crypto/subtle"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web/index.html
var page []byte

const (
	defaultConfigDir = "/root/.rabbit_container"
	stateFileName    = "env-manager.env"
	maxBodySize      = 512 << 10
)

type settingDefinition struct {
	Name        string
	Group       string
	Description string
	Default     string
	Secret      bool
	Reload      string
	// Service names the s6 longrun to restart when Reload == "plugin".
	Service string
}

type settingView struct {
	Name        string `json:"name"`
	Group       string `json:"group"`
	Description string `json:"description"`
	Default     string `json:"default"`
	Secret      bool   `json:"secret"`
	Reload      string `json:"reload"`
	Value       string `json:"value,omitempty"`
	MaskedValue string `json:"masked_value,omitempty"`
	ValueSet    bool   `json:"value_set"`
	Source      string `json:"source"`
}

type configResponse struct {
	Settings  []settingView `json:"settings"`
	StateFile string        `json:"state_file"`
	UpdatedAt string        `json:"updated_at,omitempty"`
}

type updateRequest struct {
	Values map[string]string `json:"values"`
	Clear  []string          `json:"clear"`
}

type reloadResult struct {
	Service string `json:"service"`
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
}

type updateResponse struct {
	Config  configResponse `json:"config"`
	Reloads []reloadResult `json:"reloads"`
}

type manager struct {
	configDir string
	statePath string
	username  string

	allowUnauthenticated bool
	s6SvcBin             string
	reloadTailscaleBin   string
	configureNginxBin    string
	nginxBin             string

	mu        sync.Mutex
	overrides map[string]string
}

var definitions = []settingDefinition{
	{Name: "MANAGER_PASSWORD", Group: "管理面板", Description: "管理面板 Basic Auth 密码。", Secret: true, Reload: "manager"},
	{Name: "GITHUB_USER", Group: "SSH", Description: "用于下载 SSH 公钥的 GitHub 用户名。", Default: "rabbit-dayi", Reload: "restart"},
	{Name: "CODE_SERVER_BIND_ADDR", Group: "code-server", Description: "code-server 监听地址，例如 0.0.0.0:8080。", Default: "0.0.0.0:8080", Reload: "code-server"},
	{Name: "CODE_SERVER_AUTH", Group: "code-server", Description: "认证模式。", Default: "password", Reload: "code-server"},
	{Name: "PASSWORD", Group: "code-server", Description: "code-server 登录密码。", Secret: true, Reload: "code-server"},
	{Name: "HASHED_PASSWORD", Group: "code-server", Description: "code-server 哈希密码。", Secret: true, Reload: "code-server"},
	{Name: "CODE_SERVER_WORKDIR", Group: "code-server", Description: "code-server 默认工作目录。", Default: "/workspace", Reload: "code-server"},
	{Name: "TS_ENABLE", Group: "Tailscale", Description: "是否启用 Tailscale。", Default: "false", Reload: "tailscale"},
	{Name: "TS_AUTHKEY", Group: "Tailscale", Description: "Tailscale 一次性认证密钥。", Secret: true, Reload: "tailscale"},
	{Name: "TS_AUTH_ONCE", Group: "Tailscale", Description: "已有登录状态时是否跳过重复认证。", Default: "true", Reload: "tailscale"},
	{Name: "TS_HOSTNAME", Group: "Tailscale", Description: "Tailscale 节点名称。", Reload: "tailscale"},
	{Name: "TS_ACCEPT_DNS", Group: "Tailscale", Description: "是否接受 Tailscale DNS 配置。", Default: "false", Reload: "tailscale"},
	{Name: "TS_ADVERTISE_TAGS", Group: "Tailscale", Description: "逗号分隔的 Tailscale tags。", Reload: "tailscale"},
	{Name: "TS_CONFIG_TIMEOUT", Group: "Tailscale", Description: "Tailscale 配置等待时间，单位为秒。", Default: "30", Reload: "tailscale"},
	{Name: "TZ", Group: "运行时", Description: "容器时区。", Default: "Asia/Shanghai", Reload: "restart"},
	{Name: "LANG", Group: "运行时", Description: "容器语言环境。", Default: "C.UTF-8", Reload: "restart"},
	{Name: "PLUGIN_FRPC_ENABLE", Group: "插件", Description: "是否启用 frpc 插件；需要先把 frpc.toml 放到 /root/.rabbit_container/plugins/frpc/。", Default: "false", Reload: "plugin", Service: "plugin-frpc"},
	{Name: "PLUGIN_CLOAKBROWSER_ENABLE", Group: "插件", Description: "是否启用 CloakBrowser-Manager 插件（第三方组件，需先启用 DOCKERD_ROOTLESS_ENABLE）。", Default: "false", Reload: "plugin", Service: "plugin-cloakbrowser"},
	{Name: "CLOAKBROWSER_LICENSE_KEY", Group: "插件", Description: "CloakBrowser Pro 许可证密钥，留空则使用免费版。", Secret: true, Reload: "plugin", Service: "plugin-cloakbrowser"},
}

var definitionByName = func() map[string]settingDefinition {
	result := make(map[string]settingDefinition, len(definitions))
	for _, definition := range definitions {
		result[definition.Name] = definition
	}
	return result
}()

var (
	githubUserPattern = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$`)
	hostnamePattern   = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$`)
	tagsPattern       = regexp.MustCompile(`^tag:[A-Za-z0-9-]+(?:,tag:[A-Za-z0-9-]+)*$`)
	zonePattern       = regexp.MustCompile(`^[A-Za-z0-9._+/-]+$`)
)

func main() {
	configDir := os.Getenv("ENV_MANAGER_CONFIG_DIR")
	if configDir == "" {
		configDir = defaultConfigDir
	}
	configDir = filepath.Clean(configDir)
	if !filepath.IsAbs(configDir) || configDir == "/" {
		log.Fatal("MANAGER_CONFIG_DIR must be a safe absolute directory")
	}
	overrides, err := readOverrides(filepath.Join(configDir, stateFileName))
	if err != nil {
		log.Printf("[env-manager] Could not read overrides: %v", err)
	}

	m := &manager{
		configDir:            configDir,
		statePath:            filepath.Join(configDir, stateFileName),
		username:             envOrDefault("ENV_MANAGER_USERNAME", "admin"),
		allowUnauthenticated: os.Getenv("ENV_MANAGER_ALLOW_UNAUTHENTICATED") == "true",
		s6SvcBin:             envOrDefault("ENV_MANAGER_S6_SVC_BIN", "/command/s6-svc"),
		reloadTailscaleBin:   envOrDefault("ENV_MANAGER_RELOAD_TAILSCALE_BIN", "/usr/local/bin/reload-tailscale"),
		configureNginxBin:    envOrDefault("ENV_MANAGER_CONFIGURE_NGINX_BIN", "/etc/s6-overlay/scripts/configure-nginx"),
		nginxBin:             envOrDefault("ENV_MANAGER_NGINX_BIN", "/usr/sbin/nginx"),
		overrides:            overrides,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", m.page)
	mux.HandleFunc("/healthz", m.health)
	mux.HandleFunc("/api/config", m.config)
	server := &http.Server{
		Addr:              envOrDefault("ENV_MANAGER_BIND_ADDR", "127.0.0.1:8789"),
		Handler:           m.withSecurityHeaders(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       20 * time.Second,
		WriteTimeout:      45 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    32 << 10,
	}
	log.Printf("[env-manager] Listening on %s; state=%s", server.Addr, m.statePath)
	var serveErr error
	if os.Getenv("ENV_MANAGER_TLS_ENABLE") != "true" {
		serveErr = server.ListenAndServe()
	} else {
		certFile := envOrDefault("ENV_MANAGER_TLS_CERT_FILE", "/run/env-manager/tls.crt")
		keyFile := envOrDefault("ENV_MANAGER_TLS_KEY_FILE", "/run/env-manager/tls.key")
		log.Printf("[env-manager] TLS enabled; certificate=%s", certFile)
		serveErr = server.ListenAndServeTLS(certFile, keyFile)
	}
	if err := serveErr; !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func (m *manager) withSecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'")
		next.ServeHTTP(w, r)
	})
}

func (m *manager) page(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if !m.authorize(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(page)
}

func (m *manager) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (m *manager) config(w http.ResponseWriter, r *http.Request) {
	if !m.authorize(w, r) {
		return
	}
	switch r.Method {
	case http.MethodGet:
		m.mu.Lock()
		response := m.snapshotLocked()
		m.mu.Unlock()
		writeJSON(w, http.StatusOK, response)
	case http.MethodPut:
		m.update(w, r)
	default:
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
	}
}

func (m *manager) update(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("X-Requested-With") != "docker-image-env-manager" || !sameOrigin(r) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "management request rejected"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodySize)
	var request updateRequest
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid configuration payload"})
		return
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	updated := cloneMap(m.overrides)
	changed := make(map[string]bool)
	for name, value := range request.Values {
		definition, ok := definitionByName[name]
		if !ok {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported variable: " + name})
			return
		}
		if err := validateValue(definition, value); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": name + ": " + err.Error()})
			return
		}
		if old, exists := updated[name]; !exists || old != value {
			changed[name] = true
		}
		updated[name] = value
	}
	for _, name := range request.Clear {
		if _, ok := definitionByName[name]; !ok {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unsupported variable: " + name})
			return
		}
		if _, exists := updated[name]; exists {
			changed[name] = true
			delete(updated, name)
		}
	}

	if err := writeOverrides(m.statePath, updated); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not persist configuration"})
		return
	}
	oldOverrides := m.overrides
	m.overrides = updated
	reloads := m.reloadChanged(oldOverrides, updated, changed)
	writeJSON(w, http.StatusOK, updateResponse{Config: m.snapshotLocked(), Reloads: reloads})
}

func (m *manager) snapshotLocked() configResponse {
	views := make([]settingView, 0, len(definitions))
	for _, definition := range definitions {
		value, source := m.effectiveValue(definition)
		view := settingView{
			Name:        definition.Name,
			Group:       definition.Group,
			Description: definition.Description,
			Default:     definition.Default,
			Secret:      definition.Secret,
			Reload:      definition.Reload,
			ValueSet:    value != "",
			Source:      source,
		}
		if definition.Secret {
			if value != "" {
				view.MaskedValue = "********"
			}
		} else {
			view.Value = value
		}
		views = append(views, view)
	}
	return configResponse{Settings: views, StateFile: m.statePath, UpdatedAt: fileModTime(m.statePath)}
}

func (m *manager) effectiveValue(definition settingDefinition) (string, string) {
	if value, ok := m.overrides[definition.Name]; ok {
		return value, "managed"
	}
	if value, ok := os.LookupEnv(definition.Name); ok {
		return value, "environment"
	}
	return definition.Default, "default"
}

func (m *manager) reloadChanged(before, after map[string]string, changed map[string]bool) []reloadResult {
	codeChanged, tailscaleChanged, managerChanged, restartRequired := false, false, false, false
	pluginServices := make(map[string]bool)
	for name := range changed {
		definition := definitionByName[name]
		if m.effectiveFrom(before, definition) == m.effectiveFrom(after, definition) {
			continue
		}
		switch definition.Reload {
		case "code-server":
			codeChanged = true
		case "tailscale":
			tailscaleChanged = true
		case "manager":
			managerChanged = true
		case "plugin":
			if definition.Service != "" {
				pluginServices[definition.Service] = true
			}
		default:
			restartRequired = true
		}
	}
	results := make([]reloadResult, 0, 4)
	if codeChanged {
		if err := runCommand(m.s6SvcBin, "-r", "/run/service/code-server"); err != nil {
			results = append(results, reloadResult{Service: "code-server", Status: "error", Message: err.Error()})
		} else {
			results = append(results, reloadResult{Service: "code-server", Status: "reloaded"})
		}
	}
	if tailscaleChanged {
		if err := runCommand(m.reloadTailscaleBin); err != nil {
			results = append(results, reloadResult{Service: "tailscale", Status: "error", Message: err.Error()})
		} else {
			results = append(results, reloadResult{Service: "tailscale", Status: "reloaded"})
		}
	}
	if managerChanged {
		results = append(results, reloadResult{Service: "env-manager", Status: "reloaded"})
	}
	if len(pluginServices) > 0 {
		// A plugin's ENABLE var (or other Reload:"plugin" setting) may also
		// add/remove its nginx route, so regenerate and hot-reload nginx
		// alongside restarting the plugin's own s6 service -- the same two
		// steps cmd/manager's certificate flow already uses.
		serviceNames := make([]string, 0, len(pluginServices))
		for service := range pluginServices {
			serviceNames = append(serviceNames, service)
		}
		sort.Strings(serviceNames)
		for _, service := range serviceNames {
			if err := runCommand(m.s6SvcBin, "-r", "/run/service/"+service); err != nil {
				results = append(results, reloadResult{Service: service, Status: "error", Message: err.Error()})
			} else {
				results = append(results, reloadResult{Service: service, Status: "reloaded"})
			}
		}
		if err := m.applyNginx(); err != nil {
			results = append(results, reloadResult{Service: "nginx", Status: "error", Message: err.Error()})
		} else {
			results = append(results, reloadResult{Service: "nginx", Status: "reloaded"})
		}
	}
	if restartRequired {
		results = append(results, reloadResult{Service: "container", Status: "restart_required", Message: "部分变量只能在容器重启后生效。"})
	}
	if len(results) == 0 {
		results = append(results, reloadResult{Service: "configuration", Status: "saved"})
	}
	return results
}

// applyNginx regenerates and hot-reloads nginx. configure-nginx doesn't
// source load-managed-env the way toggleable services' run scripts do, and
// this process's own os.Environ() is frozen at container boot, so a plugin
// enable var saved through the panel wouldn't otherwise reach it -- explicit
// env overrides are threaded through instead. Caller must hold m.mu.
func (m *manager) applyNginx() error {
	if err := runCommandWithEnv(mergeEnv(os.Environ(), m.overrides), m.configureNginxBin); err != nil {
		return err
	}
	return runCommand(m.nginxBin, "-s", "reload", "-c", "/run/nginx/nginx.conf")
}

func mergeEnv(base []string, overrides map[string]string) []string {
	if len(overrides) == 0 {
		return base
	}
	skip := make(map[string]bool, len(overrides))
	for name := range overrides {
		skip[name] = true
	}
	result := make([]string, 0, len(base)+len(overrides))
	for _, entry := range base {
		name, _, ok := strings.Cut(entry, "=")
		if ok && skip[name] {
			continue
		}
		result = append(result, entry)
	}
	for name, value := range overrides {
		result = append(result, name+"="+value)
	}
	return result
}

func (m *manager) effectiveFrom(overrides map[string]string, definition settingDefinition) string {
	if value, ok := overrides[definition.Name]; ok {
		return value
	}
	if value, ok := os.LookupEnv(definition.Name); ok {
		return value
	}
	return definition.Default
}

func (m *manager) currentPassword() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	if password, ok := m.overrides["MANAGER_PASSWORD"]; ok {
		return password
	}
	if password, ok := os.LookupEnv("MANAGER_PASSWORD"); ok {
		return password
	}
	if password, ok := m.overrides["PASSWORD"]; ok {
		return password
	}
	return os.Getenv("PASSWORD")
}

func (m *manager) authorize(w http.ResponseWriter, r *http.Request) bool {
	if m.allowUnauthenticated {
		return true
	}
	password := m.currentPassword()
	if password == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "set MANAGER_PASSWORD or PASSWORD before using the management panel"})
		return false
	}
	username, supplied, ok := r.BasicAuth()
	if !ok || subtle.ConstantTimeCompare([]byte(username), []byte(m.username)) != 1 || subtle.ConstantTimeCompare([]byte(supplied), []byte(password)) != 1 {
		w.Header().Set("WWW-Authenticate", `Basic realm="Environment manager"`)
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authentication required"})
		return false
	}
	return true
}

func validateValue(definition settingDefinition, value string) error {
	if strings.ContainsAny(value, "\x00\r\n") {
		return errors.New("不能包含换行或控制字符")
	}
	if len(value) > 4096 {
		return errors.New("长度不能超过 4096 个字符")
	}
	switch definition.Name {
	case "GITHUB_USER":
		if value != "" && !githubUserPattern.MatchString(value) {
			return errors.New("GitHub 用户名格式无效")
		}
	case "CODE_SERVER_BIND_ADDR":
		host, port, err := net.SplitHostPort(value)
		if err != nil || host == "" {
			return errors.New("必须是 host:port 格式")
		}
		portNumber, err := strconv.Atoi(port)
		if err != nil || portNumber < 1 || portNumber > 65535 {
			return errors.New("端口必须在 1-65535 之间")
		}
	case "CODE_SERVER_AUTH", "TS_ENABLE", "TS_AUTH_ONCE", "TS_ACCEPT_DNS", "PLUGIN_FRPC_ENABLE", "PLUGIN_CLOAKBROWSER_ENABLE":
		if definition.Name == "CODE_SERVER_AUTH" {
			if value != "password" && value != "none" {
				return errors.New("只能是 password 或 none")
			}
		} else if value != "true" && value != "false" {
			return errors.New("只能是 true 或 false")
		}
	case "CODE_SERVER_WORKDIR":
		if !filepath.IsAbs(value) || filepath.Clean(value) == "/" {
			return errors.New("必须是非根目录的绝对路径")
		}
	case "TS_HOSTNAME":
		if value != "" && !hostnamePattern.MatchString(value) {
			return errors.New("Tailscale 节点名称格式无效")
		}
	case "TS_ADVERTISE_TAGS":
		if value != "" && !tagsPattern.MatchString(value) {
			return errors.New("必须是 tag:name,tag:name 格式")
		}
	case "TS_CONFIG_TIMEOUT":
		number, err := strconv.Atoi(value)
		if err != nil || number < 5 || number > 300 {
			return errors.New("必须是 5-300 之间的整数")
		}
	case "TZ":
		if value != "" && !zonePattern.MatchString(value) {
			return errors.New("时区格式无效")
		}
	case "LANG":
		if value == "" {
			return errors.New("不能为空")
		}
	case "MANAGER_PASSWORD":
		if value == "" {
			return errors.New("不能为空")
		}
	}
	return nil
}

func sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	protocol := r.Header.Get("X-Forwarded-Proto")
	if protocol == "" {
		protocol = "http"
	}
	return origin == protocol+"://"+r.Host
}

func readOverrides(path string) (map[string]string, error) {
	result := make(map[string]string)
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return result, nil
	}
	if err != nil {
		return result, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxBodySize+1))
	if err != nil {
		return result, err
	}
	if len(data) > maxBodySize {
		return result, errors.New("configuration file is too large")
	}
	for lineNumber, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name, encoded, ok := strings.Cut(line, "=")
		if !ok {
			return result, fmt.Errorf("invalid configuration at line %d", lineNumber+1)
		}
		if _, ok := definitionByName[name]; !ok {
			return result, fmt.Errorf("unsupported variable at line %d", lineNumber+1)
		}
		value, err := base64.RawStdEncoding.DecodeString(encoded)
		if err != nil || strings.ContainsAny(string(value), "\x00\r\n") {
			return result, fmt.Errorf("invalid configuration value at line %d", lineNumber+1)
		}
		result[name] = string(value)
	}
	return result, nil
}

func writeOverrides(path string, values map[string]string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	names := make([]string, 0, len(values))
	for name := range values {
		names = append(names, name)
	}
	sort.Strings(names)
	var content strings.Builder
	content.WriteString("# Managed by Rabbit Dev Container environment manager.\n")
	for _, name := range names {
		if _, ok := definitionByName[name]; !ok {
			return errors.New("unsupported variable in state")
		}
		content.WriteString(name)
		content.WriteByte('=')
		content.WriteString(base64.RawStdEncoding.EncodeToString([]byte(values[name])))
		content.WriteByte('\n')
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".env-manager-*")
	if err != nil {
		return err
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.WriteString(content.String()); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryName, path)
}

func cloneMap(values map[string]string) map[string]string {
	result := make(map[string]string, len(values))
	for key, value := range values {
		result[key] = value
	}
	return result
}

func fileModTime(path string) string {
	info, err := os.Stat(path)
	if err != nil {
		return ""
	}
	return info.ModTime().UTC().Format(time.RFC3339)
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func runCommand(name string, arguments ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
	defer cancel()
	return runCommandContext(exec.CommandContext(ctx, name, arguments...))
}

func runCommandWithEnv(env []string, name string, arguments ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, arguments...)
	cmd.Env = env
	return runCommandContext(cmd)
}

func runCommandContext(cmd *exec.Cmd) error {
	output, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	message := strings.TrimSpace(string(output))
	if len(message) > 1024 {
		message = message[len(message)-1024:]
	}
	if message == "" {
		message = err.Error()
	}
	return errors.New(message)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("[env-manager] Could not write response: %v", err)
	}
}
