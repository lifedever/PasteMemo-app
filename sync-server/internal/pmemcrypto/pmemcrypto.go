package pmemcrypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"

	"golang.org/x/crypto/pbkdf2"
)

const (
	magic         = "PMEM"
	headerSize    = 6
	saltSize      = 32
	pbkdf2Iter    = 600_000
	flagEncrypted = 0x01
)

var (
	ErrInvalidFormat = errors.New("invalid PMEM format")
	ErrWrongPassword = errors.New("wrong password")
)

// KeyFingerprint matches SyncCrypto.keyFingerprint / DataPorterCrypto PBKDF2 parameters.
func KeyFingerprint(password string, saltB64 string) (string, error) {
	salt, err := base64.StdEncoding.DecodeString(saltB64)
	if err != nil {
		return "", fmt.Errorf("decode salt: %w", err)
	}
	key := pbkdf2.Key([]byte(password), salt, pbkdf2Iter, 32, sha256.New)
	sum := sha256.Sum256(key)
	return hex.EncodeToString(sum[:]), nil
}

// DecryptPayloadBase64 decrypts a PMEM-wrapped AES-GCM blob produced by DataPorterCrypto.encrypt.
func DecryptPayloadBase64(b64 string, password string) ([]byte, error) {
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, fmt.Errorf("decode payload: %w", err)
	}
	return DecryptPayload(data, password)
}

func DecryptPayload(data []byte, password string) ([]byte, error) {
	if len(data) < headerSize+saltSize+aes.BlockSize {
		return nil, ErrInvalidFormat
	}
	if string(data[:4]) != magic {
		return nil, ErrInvalidFormat
	}
	if data[5] != flagEncrypted {
		return nil, ErrInvalidFormat
	}

	salt := data[headerSize : headerSize+saltSize]
	combined := data[headerSize+saltSize:]
	if len(combined) < 12+16 {
		return nil, ErrInvalidFormat
	}

	key := pbkdf2.Key([]byte(password), salt, pbkdf2Iter, 32, sha256.New)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	nonce := combined[:12]
	ciphertext := combined[12:]
	plain, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, ErrWrongPassword
	}
	return plain, nil
}
