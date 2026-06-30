//go:build darwin

package imagetype

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

func transcodePlatform(data []byte) ([]byte, error) {
	dir, err := os.MkdirTemp("", "pastememo-img-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)

	src := filepath.Join(dir, "src.img")
	dst := filepath.Join(dir, "dst.jpg")
	if err := os.WriteFile(src, data, 0o600); err != nil {
		return nil, err
	}
	cmd := exec.Command("sips", "-s", "format", "jpeg", src, "--out", dst)
	if out, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("sips: %w (%s)", err, string(out))
	}
	return os.ReadFile(dst)
}
