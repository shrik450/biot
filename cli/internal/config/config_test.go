package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func withConfigHome(t *testing.T) string {
	t.Helper()
	directory := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", directory)
	return directory
}

func TestSaveLoadRemoveRoundTrip(t *testing.T) {
	withConfigHome(t)
	want := Config{ServerURL: "https://biot.example.test", Token: "biot_secret_token"}
	if err := Save(want); err != nil {
		t.Fatalf("Save returned error: %v", err)
	}
	got, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if got != want {
		t.Fatalf("Load = %#v, want %#v", got, want)
	}
	if err := Remove(); err != nil {
		t.Fatalf("Remove returned error: %v", err)
	}
	if _, err := Load(); err == nil {
		t.Fatal("Load after Remove should fail")
	}
	if err := Remove(); err != nil {
		t.Fatalf("removing an absent configuration should succeed: %v", err)
	}
}

func TestSavedFileAndDirectoryArePrivate(t *testing.T) {
	home := withConfigHome(t)
	if err := Save(Config{ServerURL: "https://biot.example.test", Token: "token"}); err != nil {
		t.Fatalf("Save returned error: %v", err)
	}
	path, err := Path()
	if err != nil {
		t.Fatalf("Path returned error: %v", err)
	}
	if !strings.HasPrefix(path, home) {
		t.Fatalf("configuration path %q is not under XDG_CONFIG_HOME %q", path, home)
	}
	fileInfo, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat configuration: %v", err)
	}
	if mode := fileInfo.Mode().Perm(); mode != 0o600 {
		t.Errorf("configuration mode = %o, want 600", mode)
	}
	directoryInfo, err := os.Stat(filepath.Dir(path))
	if err != nil {
		t.Fatalf("stat configuration directory: %v", err)
	}
	if mode := directoryInfo.Mode().Perm(); mode != 0o700 {
		t.Errorf("configuration directory mode = %o, want 700", mode)
	}
}

func TestSaveReplacesAnExistingConfiguration(t *testing.T) {
	withConfigHome(t)
	if err := Save(Config{ServerURL: "https://one.example.test", Token: "first"}); err != nil {
		t.Fatalf("first Save returned error: %v", err)
	}
	if err := Save(Config{ServerURL: "https://two.example.test", Token: "second"}); err != nil {
		t.Fatalf("second Save returned error: %v", err)
	}
	got, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if got.ServerURL != "https://two.example.test" || got.Token != "second" {
		t.Fatalf("Load = %#v, want the second configuration", got)
	}
}

func TestSaveRequiresBothValues(t *testing.T) {
	withConfigHome(t)
	for _, value := range []Config{
		{ServerURL: "https://biot.example.test"},
		{Token: "token"},
		{},
	} {
		if err := Save(value); err == nil {
			t.Errorf("Save(%#v) should be rejected", value)
		}
	}
}

func TestLoadMissingConfigurationTellsThePersonToLogIn(t *testing.T) {
	withConfigHome(t)
	_, err := Load()
	if err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(err.Error(), "biot login") {
		t.Fatalf("missing-config error should name biot login: %v", err)
	}
}

func TestLoadInvalidConfigurationTellsThePersonToLogIn(t *testing.T) {
	home := withConfigHome(t)
	directory := filepath.Join(home, "biot")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatalf("create directory: %v", err)
	}
	for name, contents := range map[string]string{
		"not-json":      "{",
		"missing-url":   `{"token":"t"}`,
		"missing-token": `{"server_url":"https://biot.example.test"}`,
	} {
		if err := os.WriteFile(filepath.Join(directory, "config.json"), []byte(contents), 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
		_, err := Load()
		if err == nil {
			t.Fatalf("%s should be rejected", name)
		}
		if !strings.Contains(err.Error(), "biot login") {
			t.Fatalf("%s error should name biot login: %v", name, err)
		}
	}
}
