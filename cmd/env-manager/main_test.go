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
