package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	Token       string
	ListenAddr  string
	DBPath      string
	TrustProxy  bool
}

func Load() (Config, error) {
	token := strings.TrimSpace(os.Getenv("SYNC_TOKEN"))
	if token == "" {
		return Config{}, fmt.Errorf("SYNC_TOKEN is required")
	}

	listen := strings.TrimSpace(os.Getenv("SYNC_LISTEN_ADDR"))
	if listen == "" {
		listen = ":8787"
	}

	dbPath := strings.TrimSpace(os.Getenv("SYNC_DB_PATH"))
	if dbPath == "" {
		dbPath = "./sync.db"
	}

	trustProxy := false
	if raw := strings.TrimSpace(os.Getenv("SYNC_TRUST_PROXY")); raw != "" {
		parsed, err := strconv.ParseBool(raw)
		if err != nil {
			return Config{}, fmt.Errorf("invalid SYNC_TRUST_PROXY: %w", err)
		}
		trustProxy = parsed
	}

	return Config{
		Token:      token,
		ListenAddr: listen,
		DBPath:     dbPath,
		TrustProxy: trustProxy,
	}, nil
}
