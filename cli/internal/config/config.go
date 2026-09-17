package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

type Config struct {
	ServerURL string `json:"server_url"`
	Token     string `json:"token"`
}

func Path() (string, error) {
	directory, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("find the user configuration directory: %w", err)
	}
	return filepath.Join(directory, "biot", "config.json"), nil
}

func Load() (Config, error) {
	path, err := Path()
	if err != nil {
		return Config{}, err
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Config{}, fmt.Errorf("you are not logged in; run biot login")
		}
		return Config{}, fmt.Errorf("read Biot configuration: %w", err)
	}
	var value Config
	if err := json.Unmarshal(contents, &value); err != nil || value.ServerURL == "" || value.Token == "" {
		return Config{}, fmt.Errorf("Biot configuration is invalid; run biot login")
	}
	return value, nil
}

func Save(value Config) error {
	if value.ServerURL == "" || value.Token == "" {
		return errors.New("server URL and token are required")
	}
	path, err := Path()
	if err != nil {
		return err
	}
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create Biot configuration directory: %w", err)
	}
	temporary, err := os.CreateTemp(directory, ".config-*")
	if err != nil {
		return fmt.Errorf("create temporary Biot configuration: %w", err)
	}
	temporaryName := temporary.Name()
	defer os.Remove(temporaryName)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return fmt.Errorf("protect Biot configuration: %w", err)
	}
	contents, err := json.Marshal(value)
	if err == nil {
		_, err = temporary.Write(append(contents, '\n'))
	}
	if closeErr := temporary.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return fmt.Errorf("write Biot configuration: %w", err)
	}
	if err := os.Rename(temporaryName, path); err != nil {
		return fmt.Errorf("replace Biot configuration: %w", err)
	}
	return nil
}

func Remove() error {
	path, err := Path()
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove Biot configuration: %w", err)
	}
	return nil
}
