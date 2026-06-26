package model

import "time"

type SyncEncryptionMeta struct {
	Enabled        bool   `json:"enabled"`
	KeyFingerprint string `json:"key_fingerprint"`
	Salt           string `json:"salt,omitempty"`
}

type SyncRequest struct {
	ClientID   string              `json:"client_id"`
	Hostname   string              `json:"hostname"`
	SentAt     string              `json:"sent_at"`
	Encryption *SyncEncryptionMeta `json:"encryption,omitempty"`
	Items      []SyncItem          `json:"items"`
}

type SyncItem struct {
	ItemID              string  `json:"item_id"`
	CreatedAt           string  `json:"created_at"`
	LastUsedAt          string  `json:"last_used_at"`
	Content             string  `json:"content"`
	ContentType         string  `json:"content_type"`
	SourceApp           *string `json:"source_app,omitempty"`
	SourceAppBundleID   *string `json:"source_app_bundle_id,omitempty"`
	IsFavorite          bool    `json:"is_favorite"`
	IsPinned            bool    `json:"is_pinned"`
	IsSensitive         bool    `json:"is_sensitive"`
	LinkTitle           *string `json:"link_title,omitempty"`
	DisplayTitle        *string `json:"display_title,omitempty"`
	CodeLanguage        *string `json:"code_language,omitempty"`
	RichTextType        *string `json:"rich_text_type,omitempty"`
	GroupName           *string `json:"group_name,omitempty"`
	FilePaths           *string `json:"file_paths,omitempty"`
	OriginalImagePath   *string `json:"original_image_file_path,omitempty"`
	AgentSource         *string `json:"agent_source,omitempty"`
	OCRText             *string `json:"ocr_text,omitempty"`
	OCRStatus           *string `json:"ocr_status,omitempty"`
	OCRUpdatedAt        *string `json:"ocr_updated_at,omitempty"`
	OCRErrorMessage     *string `json:"ocr_error_message,omitempty"`
	OCRVersion          *int    `json:"ocr_version,omitempty"`
	ImageDataBase64     *string `json:"image_data_base64,omitempty"`
	FaviconDataBase64   *string `json:"favicon_data_base64,omitempty"`
	RichTextDataBase64  *string `json:"rich_text_data_base64,omitempty"`
	PasteboardBase64    *string `json:"pasteboard_snapshot_base64,omitempty"`
	Truncated           bool    `json:"truncated"`
	Encrypted           bool    `json:"encrypted"`
	PayloadEncrypted    string  `json:"payload_encrypted,omitempty"`
	OriginClientID      *string `json:"origin_client_id,omitempty"`
	OriginHostname      *string `json:"origin_hostname,omitempty"`
	OriginIP            *string `json:"origin_ip,omitempty"`
}

type SyncResponse struct {
	AcceptedCount int    `json:"accepted_count"`
	DedupedCount  int    `json:"deduped_count"`
	ServerTime    string `json:"server_time"`
}

type ClientRow struct {
	ClientID           string
	LastIP             string
	LastHostname       string
	LastSyncAt         time.Time
	LastSyncCount      int
	TotalSyncCount     int
	CreatedAt          time.Time
	UpdatedAt          time.Time
	EncryptionEnabled  bool
	EncryptionKeyFP    string
	EncryptionSalt     string
}

type ItemSummary struct {
	ClientID       string  `json:"client_id"`
	ItemID         string  `json:"item_id"`
	ContentType    string  `json:"content_type"`
	CreatedAt      string  `json:"created_at"`
	DisplayTitle   *string `json:"display_title,omitempty"`
	SourceApp      *string `json:"source_app,omitempty"`
	ContentPreview string  `json:"content_preview,omitempty"`
	HasImage       bool    `json:"has_image"`
	Truncated      bool    `json:"truncated"`
	OCRPreview     *string `json:"ocr_preview,omitempty"`
	DeletedAt      *string `json:"deleted_at,omitempty"`
	Encrypted      bool    `json:"encrypted"`
	PayloadEncrypted string `json:"payload_encrypted,omitempty"`
}

type ItemListResponse struct {
	Items      []ItemSummary `json:"items"`
	HasMore    bool          `json:"has_more"`
	NextCursor *ItemCursor   `json:"next_cursor,omitempty"`
}

type ItemCursor struct {
	CreatedAt string `json:"created_at"`
	ItemID    string `json:"item_id"`
	DeletedAt string `json:"deleted_at,omitempty"`
}

type PullListResponse struct {
	Items      []SyncItem  `json:"items"`
	HasMore    bool        `json:"has_more"`
	NextCursor *ItemCursor `json:"next_cursor,omitempty"`
}

type TrashItem struct {
	ItemID    string `json:"item_id"`
	DeletedAt string `json:"deleted_at"`
}

type TrashListResponse struct {
	Items      []TrashItem `json:"items"`
	HasMore    bool        `json:"has_more"`
	NextCursor *ItemCursor `json:"next_cursor,omitempty"`
}

type ItemDetail struct {
	ClientID            string  `json:"client_id"`
	ItemID              string  `json:"item_id"`
	ContentType         string  `json:"content_type"`
	CreatedAt           string  `json:"created_at"`
	LastUsedAt          string  `json:"last_used_at"`
	ReceivedAt          string  `json:"received_at"`
	Content             string  `json:"content"`
	DisplayTitle        *string `json:"display_title,omitempty"`
	SourceApp           *string `json:"source_app,omitempty"`
	SourceAppBundleID   *string `json:"source_app_bundle_id,omitempty"`
	IsFavorite          bool    `json:"is_favorite"`
	IsPinned            bool    `json:"is_pinned"`
	IsSensitive         bool    `json:"is_sensitive"`
	LinkTitle           *string `json:"link_title,omitempty"`
	CodeLanguage        *string `json:"code_language,omitempty"`
	GroupName           *string `json:"group_name,omitempty"`
	FilePaths           *string `json:"file_paths,omitempty"`
	AgentSource         *string `json:"agent_source,omitempty"`
	OCRText             *string `json:"ocr_text,omitempty"`
	OCRStatus           *string `json:"ocr_status,omitempty"`
	HasImage            bool    `json:"has_image"`
	HasFavicon          bool    `json:"has_favicon"`
	HasRichText         bool    `json:"has_rich_text"`
	HasPasteboard       bool    `json:"has_pasteboard"`
	Truncated           bool    `json:"truncated"`
	DeletedAt           *string `json:"deleted_at,omitempty"`
	Encrypted           bool    `json:"encrypted"`
	PayloadEncrypted    string  `json:"payload_encrypted,omitempty"`
}

// AllContentTypes lists every PasteMemo content_type value (see ClipContentType in the app).
// GET /api/v1/types returns this fixed list without querying the database.
var AllContentTypes = []string{
	"application",
	"archive",
	"audio",
	"code",
	"color",
	"document",
	"email",
	"file",
	"image",
	"link",
	"mixed",
	"phone",
	"text",
	"video",
}
