package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPluginsEndpointMergesRegistryAndStatus(t *testing.T) {
	dir := t.TempDir()
	registryPath := filepath.Join(dir, "registry.json")
	statusPath := filepath.Join(dir, "status.json")
	registry := `[
		{"id":"frpc","name":"frpc","description":"d","enable_env":"PLUGIN_FRPC_ENABLE","service":"plugin-frpc","requires":[],"config_path":"/x","process_name":"frpc","web_path":null,"web_port":null,"docs_url":"https://example.test"},
		{"id":"cloakbrowser","name":"CloakBrowser-Manager","description":"d","enable_env":"PLUGIN_CLOAKBROWSER_ENABLE","service":"plugin-cloakbrowser","requires":["dockerd-rootless"],"config_path":null,"process_name":null,"web_path":"/plugins/cloakbrowser","web_port":18180,"docs_url":"https://example.test"}
	]`
	status := `{"components":{"plugin_frpc":"up"},"services":[{"name":"CloakBrowser-Manager","path":"/plugins/cloakbrowser","endpoint":"127.0.0.1:18180","state":"down"}]}`
	if err := os.WriteFile(registryPath, []byte(registry), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statusPath, []byte(status), 0o644); err != nil {
		t.Fatal(err)
	}

	m := &manager{pluginRegistryPath: registryPath, statusFilePath: statusPath}
	request := httptest.NewRequest(http.MethodGet, "http://localhost/api/plugins", nil)
	recorder := httptest.NewRecorder()
	m.plugins(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}

	var response struct {
		Plugins []pluginView `json:"plugins"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Plugins) != 2 {
		t.Fatalf("expected 2 plugins, got %d", len(response.Plugins))
	}
	byID := make(map[string]pluginView, len(response.Plugins))
	for _, plugin := range response.Plugins {
		byID[plugin.ID] = plugin
	}
	if !byID["frpc"].Enabled || byID["frpc"].State != "up" {
		t.Fatalf("frpc view = %#v", byID["frpc"])
	}
	if !byID["cloakbrowser"].Enabled || byID["cloakbrowser"].State != "down" {
		t.Fatalf("cloakbrowser view = %#v", byID["cloakbrowser"])
	}
}

func TestPluginsEndpointToleratesMissingFiles(t *testing.T) {
	dir := t.TempDir()
	m := &manager{
		pluginRegistryPath: filepath.Join(dir, "missing-registry.json"),
		statusFilePath:     filepath.Join(dir, "missing-status.json"),
	}
	request := httptest.NewRequest(http.MethodGet, "http://localhost/api/plugins", nil)
	recorder := httptest.NewRecorder()
	m.plugins(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	if recorder.Body.String() != `{"plugins":[]}`+"\n" {
		t.Fatalf("unexpected body: %s", recorder.Body.String())
	}
}

func TestValidateCertificatePair(t *testing.T) {
	now := time.Now().UTC()
	certificatePEM, keyPEM := testCertificate(t, now.Add(-time.Hour), now.Add(24*time.Hour))
	certificate, err := validateCertificatePair(certificatePEM, keyPEM, now)
	if err != nil {
		t.Fatalf("valid pair rejected: %v", err)
	}
	if certificate.Subject.CommonName != "manager.test" {
		t.Fatalf("unexpected common name: %s", certificate.Subject.CommonName)
	}
}

func TestValidateCertificatePairRejectsMismatch(t *testing.T) {
	now := time.Now().UTC()
	certificatePEM, _ := testCertificate(t, now.Add(-time.Hour), now.Add(24*time.Hour))
	_, anotherKey := testCertificate(t, now.Add(-time.Hour), now.Add(24*time.Hour))
	if _, err := validateCertificatePair(certificatePEM, anotherKey, now); err == nil {
		t.Fatal("mismatched key was accepted")
	}
}

func TestValidateCertificatePairRejectsExpired(t *testing.T) {
	now := time.Now().UTC()
	certificatePEM, keyPEM := testCertificate(t, now.Add(-48*time.Hour), now.Add(-time.Hour))
	if _, err := validateCertificatePair(certificatePEM, keyPEM, now); err == nil {
		t.Fatal("expired certificate was accepted")
	}
}

func testCertificate(t *testing.T, notBefore, notAfter time.Time) ([]byte, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "manager.test"},
		DNSNames:     []string{"manager.test"},
		NotBefore:    notBefore,
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
}
