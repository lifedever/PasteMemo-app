//go:build !darwin

package imagetype

import "fmt"

func transcodePlatform([]byte) ([]byte, error) {
	return nil, fmt.Errorf("no platform transcoder")
}
