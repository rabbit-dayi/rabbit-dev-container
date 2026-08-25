package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOverridesRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "env-manager.env")
	want := map[string]string{
		"PASSWORD":            "p@ss word",
		"TS_HOSTNAME":         "dev-box",
		"TS_ADVERTISE_TAGS":   "tag:dev,tag:container",
		"CODE_SERVER_WORKDIR": "/workspace/project",
	}
	if err := writeOverrides(path, want); err != nil {
		t.Fatalf("writeOverrides() error = %v", err)
	}
	got, err := readOverrides(path)
	if err != nil {
		t.Fatalf("readOverrides() error = %v", err)
	}
	if len(got) != len(want) {
		t.Fatalf("readOverrides() returned %d values, want %d", len(got), len(want))
	}
	for name, value := range want {
		if got[name] != value {
			t.Errorf("readOverrides()[%s] = %q, want %q", name, got[name], value)
		}
	}
	mode, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if mode.Mode().Perm() != 0o600 {
		t.Fatalf("state file mode = %o, want 600", mode.Mode().Perm())
	}
}

func TestConfigUpdateMasksSecretsAndReloadsCodeServer(t *testing.T) {
	t.Setenv("PASSWORD", "old-password")
	m := &manager{
		statePath:          filepath.Join(t.TempDir(), "env-manager.env"),
		username:           "admin",
		s6SvcBin:           "/bin/true",
		reloadTailscaleBin: "/bin/true",
		overrides:          map[string]string{},
	}
	request := httptest.NewRequest(http.MethodPut, "http://localhost/api/config", strings.NewReader(`{"values":{"PASSWORD":"new-password","CODE_SERVER_AUTH":"none"}}`))
	request.SetBasicAuth("admin", "old-password")
	request.Header.Set("X-Requested-With", "docker-image-env-manager")
	recorder := httptest.NewRecorder()
	m.config(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("config update status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	if strings.Contains(recorder.Body.String(), "new-password") {
		t.Fatal("secret value was returned in the update response")
	}
	var response updateResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Reloads) != 1 || response.Reloads[0].Service != "code-server" || response.Reloads[0].Status != "reloaded" {
		t.Fatalf("unexpected reload result: %#v", response.Reloads)
	}
	values, err := readOverrides(m.statePath)
	if err != nil {
		t.Fatal(err)
	}
	if values["PASSWORD"] != "new-password" {
		t.Fatalf("persisted password = %q", values["PASSWORD"])
	}
}

func TestConfigUpdateRestartsPluginServiceAndNginx(t *testing.T) {
	t.Setenv("PASSWORD", "old-password")
	dir := t.TempDir()
	seenEnvFile := filepath.Join(dir, "seen-plugin-frpc-enable")
	fakeConfigureNginx := filepath.Join(dir, "configure-nginx")
	script := "#!/bin/sh\nprintf '%s' \"$PLUGIN_FRPC_ENABLE\" > " + seenEnvFile + "\n"
	if err := os.WriteFile(fakeConfigureNginx, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	m := &manager{
		statePath:         filepath.Join(dir, "env-manager.env"),
		username:          "admin",
		s6SvcBin:          "/bin/true",
		configureNginxBin: fakeConfigureNginx,
		nginxBin:          "/bin/true",
		overrides:         map[string]string{},
	}
	request := httptest.NewRequest(http.MethodPut, "http://localhost/api/config", strings.NewReader(`{"values":{"PLUGIN_FRPC_ENABLE":"true"}}`))
	request.SetBasicAuth("admin", "old-password")
	request.Header.Set("X-Requested-With", "docker-image-env-manager")
	recorder := httptest.NewRecorder()
	m.config(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("config update status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	var response updateResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	services := make(map[string]string, len(response.Reloads))
	for _, reload := range response.Reloads {
		services[reload.Service] = reload.Status
	}
	if services["plugin-frpc"] != "reloaded" {
		t.Fatalf("expected plugin-frpc to be reloaded, got: %#v", response.Reloads)
	}
	if services["nginx"] != "reloaded" {
		t.Fatalf("expected nginx to be reloaded, got: %#v", response.Reloads)
	}
	seen, err := os.ReadFile(seenEnvFile)
	if err != nil {
		t.Fatal(err)
	}
	if string(seen) != "true" {
		t.Fatalf("configure-nginx did not see the freshly toggled PLUGIN_FRPC_ENABLE override; got %q", seen)
	}
}

func TestConfigRejectsUnsupportedAndInvalidValues(t *testing.T) {
	for name, value := range map[string]string{
		"UNKNOWN":               "value",
		"TS_ENABLE":             "yes",
		"TS_CONFIG_TIMEOUT":     "301",
		"CODE_SERVER_BIND_ADDR": "8080",
	} {
		definition, ok := definitionByName[name]
		if !ok {
			continue
		}
		if err := validateValue(definition, value); err == nil {
			t.Errorf("validateValue(%s, %q) accepted invalid value", name, value)
		}
	}
	if _, ok := definitionByName["UNKNOWN"]; ok {
		t.Fatal("UNKNOWN unexpectedly became an editable variable")
	}
}
