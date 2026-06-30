package imagetype

import (
	"bytes"
	"image"
	"image/png"
	"testing"

	"golang.org/x/image/tiff"
)

func TestDetectMIME(t *testing.T) {
	tests := []struct {
		name string
		data []byte
		want string
	}{
		{"png", []byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}, "image/png"},
		{"jpeg", []byte{0xFF, 0xD8, 0xFF, 0xE0}, "image/jpeg"},
		{"tiff-le", []byte{0x49, 0x49, 0x2A, 0x00}, "image/tiff"},
		{"tiff-be", []byte{0x4D, 0x4D, 0x00, 0x2A}, "image/tiff"},
		{"heic", []byte{0, 0, 0, 28, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63}, "image/heic"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := DetectMIME(tt.data); got != tt.want {
				t.Fatalf("DetectMIME() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestAsJPEGFromPNG(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	var src bytes.Buffer
	if err := png.Encode(&src, img); err != nil {
		t.Fatal(err)
	}
	out, err := AsJPEG(src.Bytes(), 85)
	if err != nil {
		t.Fatal(err)
	}
	if DetectMIME(out) != "image/jpeg" {
		t.Fatalf("expected jpeg output, got %s", DetectMIME(out))
	}
}

func TestAsJPEGFromTIFF(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	var src bytes.Buffer
	if err := tiff.Encode(&src, img, &tiff.Options{Compression: tiff.Uncompressed}); err != nil {
		t.Fatal(err)
	}
	out, err := AsJPEG(src.Bytes(), 85)
	if err != nil {
		t.Fatalf("AsJPEG from TIFF failed: %v", err)
	}
	if DetectMIME(out) != "image/jpeg" {
		t.Fatalf("expected jpeg output, got %s", DetectMIME(out))
	}
}
