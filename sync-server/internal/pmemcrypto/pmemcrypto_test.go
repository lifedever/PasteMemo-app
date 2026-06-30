package pmemcrypto

import (
	"encoding/base64"
	"testing"
)

func TestKeyFingerprintDeterministic(t *testing.T) {
	salt := base64.StdEncoding.EncodeToString(make([]byte, 32))
	fp1, err := KeyFingerprint("hello", salt)
	if err != nil {
		t.Fatal(err)
	}
	fp2, err := KeyFingerprint("hello", salt)
	if err != nil {
		t.Fatal(err)
	}
	if fp1 != fp2 {
		t.Fatalf("fingerprint not stable: %s vs %s", fp1, fp2)
	}
	if len(fp1) != 64 {
		t.Fatalf("expected 64 hex chars, got %d", len(fp1))
	}
}

func TestDecryptWrongPassword(t *testing.T) {
	raw := make([]byte, headerSize+saltSize+12+16)
	copy(raw[:4], []byte(magic))
	raw[4] = 0x01
	raw[5] = flagEncrypted
	_, err := DecryptPayload(raw, "wrong")
	if err != ErrWrongPassword {
		t.Fatalf("expected ErrWrongPassword, got %v", err)
	}
}
