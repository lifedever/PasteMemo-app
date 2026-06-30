package imagetype

import (
	"bytes"
	"fmt"
	"image"
	"image/jpeg"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"net/http"
	"strings"

	_ "golang.org/x/image/bmp"
	_ "golang.org/x/image/tiff"
	_ "golang.org/x/image/webp"
)

// DetectMIME returns the best image/* MIME type for raw bytes. macOS clipboard
// images are often TIFF or HEIC, which net/http's sniffer reports as octet-stream.
func DetectMIME(data []byte) string {
	if len(data) == 0 {
		return "application/octet-stream"
	}
	if mime := sniffMIME(data); mime != "" {
		return mime
	}
	ct := http.DetectContentType(data)
	if strings.HasPrefix(ct, "image/") {
		return ct
	}
	return "application/octet-stream"
}

func sniffMIME(data []byte) string {
	if len(data) < 4 {
		return ""
	}
	switch {
	case data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47:
		return "image/png"
	case data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF:
		return "image/jpeg"
	case data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46:
		return "image/gif"
	case (data[0] == 0x49 && data[1] == 0x49 && data[2] == 0x2A) ||
		(data[0] == 0x4D && data[1] == 0x4D && data[2] == 0x00 && data[3] == 0x2A):
		return "image/tiff"
	case data[0] == 0x42 && data[1] == 0x4D:
		return "image/bmp"
	}
	if len(data) >= 12 &&
		data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 &&
		data[8] == 0x57 && data[9] == 0x45 && data[10] == 0x42 && data[11] == 0x50 {
		return "image/webp"
	}
	if len(data) >= 12 && data[4] == 0x66 && data[5] == 0x74 && data[6] == 0x79 && data[7] == 0x70 {
		if len(data) >= 12 {
			switch string(data[8:12]) {
			case "avif":
				return "image/avif"
			case "heic", "heix", "hevc", "hevx", "mif1", "msf1":
				return "image/heic"
			}
		}
		return "image/heic"
	}
	return ""
}

// AsJPEG decodes supported raster formats and re-encodes as JPEG for browser display.
// On macOS, falls back to `sips` for HEIC and other formats Chrome cannot render.
func AsJPEG(data []byte, quality int) ([]byte, error) {
	if jpeg, err := decodeAndEncode(data, quality); err == nil {
		return jpeg, nil
	}
	if jpeg, err := transcodePlatform(data); err == nil && len(jpeg) > 0 {
		return jpeg, nil
	}
	return nil, fmt.Errorf("unsupported image format")
}

func decodeAndEncode(data []byte, quality int) ([]byte, error) {
	img, err := decode(data)
	if err != nil {
		return nil, err
	}
	if quality <= 0 || quality > 100 {
		quality = 85
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: quality}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func decode(data []byte) (image.Image, error) {
	// Register TIFF, BMP, WebP decoders so image.Decode can handle them
	r := bytes.NewReader(data)
	if img, _, err := image.Decode(r); err == nil {
		return img, nil
	}
	return nil, fmt.Errorf("unsupported image format")
}
