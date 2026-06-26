package store

import (
	"database/sql"
	"encoding/base64"
	"fmt"
	"strings"
	"time"

	"github.com/lifedever/pastememo/sync-server/internal/model"
	_ "modernc.org/sqlite"
)

type Store struct {
	db *sql.DB
}

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=cache_size(-64000)&_pragma=temp_store(MEMORY)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) migrate() error {
	schema := `
CREATE TABLE IF NOT EXISTS clients (
    client_id TEXT PRIMARY KEY,
    last_ip TEXT NOT NULL DEFAULT '',
    last_hostname TEXT NOT NULL DEFAULT '',
    last_sync_at TEXT NOT NULL,
    last_sync_count INTEGER NOT NULL DEFAULT 0,
    total_sync_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS items (
    client_id TEXT NOT NULL,
    item_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    received_at TEXT NOT NULL,
    last_used_at TEXT NOT NULL DEFAULT '',
    content_type TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL DEFAULT '',
    display_title TEXT,
    source_app TEXT,
    source_app_bundle_id TEXT,
    is_favorite INTEGER NOT NULL DEFAULT 0,
    is_pinned INTEGER NOT NULL DEFAULT 0,
    is_sensitive INTEGER NOT NULL DEFAULT 0,
    link_title TEXT,
    code_language TEXT,
    rich_text_type TEXT,
    group_name TEXT,
    file_paths TEXT,
    original_image_file_path TEXT,
    agent_source TEXT,
    ocr_text TEXT,
    ocr_status TEXT,
    ocr_updated_at TEXT,
    ocr_error_message TEXT,
    ocr_version INTEGER,
    image_data BLOB,
    favicon_data BLOB,
    rich_text_data BLOB,
    pasteboard_snapshot BLOB,
    truncated INTEGER NOT NULL DEFAULT 0,
    payload_json TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (client_id, item_id)
);

CREATE INDEX IF NOT EXISTS idx_items_client_created ON items(client_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_items_client_type ON items(client_id, content_type);
`
	if _, err := s.db.Exec(schema); err != nil {
		return err
	}
	if err := s.ensureColumn("items", "deleted_at", "TEXT"); err != nil {
		return err
	}
	if err := s.ensureColumn("clients", "encryption_enabled", "INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	if err := s.ensureColumn("clients", "encryption_key_fp", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("clients", "encryption_salt", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("items", "is_encrypted", "INTEGER NOT NULL DEFAULT 0"); err != nil {
		return err
	}
	for _, col := range []struct{ name, decl string }{
		{"origin_client_id", "TEXT NOT NULL DEFAULT ''"},
		{"origin_hostname", "TEXT NOT NULL DEFAULT ''"},
		{"origin_ip", "TEXT NOT NULL DEFAULT ''"},
		{"has_image", "INTEGER NOT NULL DEFAULT 0"},
		{"has_favicon", "INTEGER NOT NULL DEFAULT 0"},
		{"has_rich_text", "INTEGER NOT NULL DEFAULT 0"},
		{"has_pasteboard", "INTEGER NOT NULL DEFAULT 0"},
	} {
		if err := s.ensureColumn("items", col.name, col.decl); err != nil {
			return err
		}
	}
	if err := s.ensureAttachmentsSchema(); err != nil {
		return err
	}
	if err := s.migrateAttachmentsOutOfItems(); err != nil {
		return err
	}
	if _, err := s.db.Exec(`CREATE INDEX IF NOT EXISTS idx_items_client_type_created ON items(client_id, content_type, created_at DESC) WHERE deleted_at IS NULL`); err != nil {
		return err
	}
	if _, err := s.db.Exec(`CREATE INDEX IF NOT EXISTS idx_items_client_active_created ON items(client_id, created_at DESC, item_id DESC) WHERE deleted_at IS NULL`); err != nil {
		return err
	}
	if err := s.ensureColumn("items", "content_preview", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.ensureColumn("items", "ocr_preview", "TEXT NOT NULL DEFAULT ''"); err != nil {
		return err
	}
	if err := s.backfillContentPreviews(); err != nil {
		return err
	}
	_, err := s.db.Exec(`CREATE INDEX IF NOT EXISTS idx_items_trash ON items(client_id, deleted_at DESC) WHERE deleted_at IS NOT NULL`)
	return err
}

func (s *Store) backfillContentPreviews() error {
	var pending int
	err := s.db.QueryRow(`
SELECT 1 FROM items
WHERE (content != '' AND content_preview = '')
   OR (ocr_text IS NOT NULL AND ocr_text != '' AND ocr_preview = '')
LIMIT 1`).Scan(&pending)
	if err == sql.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}
	if _, err := s.db.Exec(`UPDATE items SET content_preview = SUBSTR(content, 1, 240) WHERE content_preview = '' AND content != ''`); err != nil {
		return err
	}
	_, err = s.db.Exec(`UPDATE items SET ocr_preview = SUBSTR(ocr_text, 1, 120) WHERE ocr_preview = '' AND ocr_text IS NOT NULL AND ocr_text != ''`)
	return err
}

type IngestResult struct {
	Accepted int
	Deduped  int
}

func (s *Store) IngestSync(req model.SyncRequest, clientIP string, now time.Time) (IngestResult, error) {
	if strings.TrimSpace(req.ClientID) == "" {
		return IngestResult{}, fmt.Errorf("client_id is required")
	}

	tx, err := s.db.Begin()
	if err != nil {
		return IngestResult{}, err
	}
	defer func() { _ = tx.Rollback() }()

	var accepted, deduped int
	for _, item := range req.Items {
		if strings.TrimSpace(item.ItemID) == "" {
			continue
		}
		var exists int
		err := tx.QueryRow(
			`SELECT 1 FROM items WHERE client_id = ? AND item_id = ? LIMIT 1`,
			req.ClientID, item.ItemID,
		).Scan(&exists)
		if err == nil {
			deduped++
			continue
		}
		if err != sql.ErrNoRows {
			return IngestResult{}, err
		}

		if item.Encrypted {
			if strings.TrimSpace(item.PayloadEncrypted) == "" {
				return IngestResult{}, fmt.Errorf("item %s missing payload_encrypted", item.ItemID)
			}
			_, err = tx.Exec(`
INSERT INTO items (
    client_id, item_id, created_at, received_at, last_used_at,
    content_type, content, truncated, payload_json, is_encrypted
) VALUES (?, ?, ?, ?, ?, ?, '', 0, '', 1)`,
				req.ClientID,
				item.ItemID,
				item.CreatedAt,
				now.UTC().Format(time.RFC3339Nano),
				item.LastUsedAt,
				encryptedContentType(item),
			)
			if err != nil {
				return IngestResult{}, err
			}
			if err := s.upsertAttachments(tx, req.ClientID, item.ItemID, nil, nil, nil, nil, item.PayloadEncrypted); err != nil {
				return IngestResult{}, err
			}
			accepted++
			continue
		}

		imageData, err := decodeOptionalBase64(item.ImageDataBase64)
		if err != nil {
			return IngestResult{}, fmt.Errorf("item %s image_data: %w", item.ItemID, err)
		}
		faviconData, err := decodeOptionalBase64(item.FaviconDataBase64)
		if err != nil {
			return IngestResult{}, fmt.Errorf("item %s favicon_data: %w", item.ItemID, err)
		}
		richTextData, err := decodeOptionalBase64(item.RichTextDataBase64)
		if err != nil {
			return IngestResult{}, fmt.Errorf("item %s rich_text_data: %w", item.ItemID, err)
		}
		pasteboardData, err := decodeOptionalBase64(item.PasteboardBase64)
		if err != nil {
			return IngestResult{}, fmt.Errorf("item %s pasteboard_snapshot: %w", item.ItemID, err)
		}

		truncated := 0
		if item.Truncated {
			truncated = 1
		}

		ocrPreview := ""
		if item.OCRText != nil {
			ocrPreview = previewText(*item.OCRText, 120)
		}

		_, err = tx.Exec(`
INSERT INTO items (
    client_id, item_id, created_at, received_at, last_used_at,
    content_type, content, content_preview, display_title, source_app, source_app_bundle_id,
    is_favorite, is_pinned, is_sensitive, link_title, code_language,
    rich_text_type, group_name, file_paths, original_image_file_path,
    agent_source, ocr_text, ocr_preview, ocr_status, ocr_updated_at, ocr_error_message,
    ocr_version, truncated, payload_json, is_encrypted,
    origin_client_id, origin_hostname, origin_ip
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', 0, ?, ?, ?)`,
			req.ClientID,
			item.ItemID,
			item.CreatedAt,
			now.UTC().Format(time.RFC3339Nano),
			item.LastUsedAt,
			item.ContentType,
			item.Content,
			previewText(item.Content, 240),
			nullString(item.DisplayTitle),
			nullString(item.SourceApp),
			nullString(item.SourceAppBundleID),
			boolInt(item.IsFavorite),
			boolInt(item.IsPinned),
			boolInt(item.IsSensitive),
			nullString(item.LinkTitle),
			nullString(item.CodeLanguage),
			nullString(item.RichTextType),
			nullString(item.GroupName),
			nullString(item.FilePaths),
			nullString(item.OriginalImagePath),
			nullString(item.AgentSource),
			nullString(item.OCRText),
			ocrPreview,
			nullString(item.OCRStatus),
			nullString(item.OCRUpdatedAt),
			nullString(item.OCRErrorMessage),
			nullInt(item.OCRVersion),
			truncated,
			stringOrDefault(item.OriginClientID, req.ClientID),
			stringOrDefault(item.OriginHostname, req.Hostname),
			stringOrDefault(item.OriginIP, clientIP),
		)
		if err != nil {
			return IngestResult{}, err
		}
		if err := s.upsertAttachments(tx, req.ClientID, item.ItemID, imageData, faviconData, richTextData, pasteboardData, ""); err != nil {
			return IngestResult{}, err
		}
		accepted++
	}

	nowStr := now.UTC().Format(time.RFC3339Nano)
	batchCount := accepted

	encEnabled := 0
	encKeyFP := ""
	encSalt := ""
	if req.Encryption != nil {
		if req.Encryption.Enabled {
			encEnabled = 1
		}
		encKeyFP = strings.TrimSpace(req.Encryption.KeyFingerprint)
		encSalt = strings.TrimSpace(req.Encryption.Salt)
	}

	var total int
	err = tx.QueryRow(`SELECT total_sync_count FROM clients WHERE client_id = ?`, req.ClientID).Scan(&total)
	switch {
	case err == sql.ErrNoRows:
		_, err = tx.Exec(`
INSERT INTO clients (
    client_id, last_ip, last_hostname, last_sync_at, last_sync_count, total_sync_count,
    created_at, updated_at, encryption_enabled, encryption_key_fp, encryption_salt
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			req.ClientID, clientIP, req.Hostname, nowStr, batchCount, batchCount, nowStr, nowStr,
			encEnabled, encKeyFP, encSalt,
		)
	case err == nil:
		if req.Encryption != nil {
			if encSalt != "" {
				_, err = tx.Exec(`
UPDATE clients SET last_ip = ?, last_hostname = ?, last_sync_at = ?, last_sync_count = ?,
    total_sync_count = total_sync_count + ?, updated_at = ?,
    encryption_enabled = ?, encryption_key_fp = ?, encryption_salt = ?
WHERE client_id = ?`,
					clientIP, req.Hostname, nowStr, batchCount, batchCount, nowStr,
					encEnabled, encKeyFP, encSalt, req.ClientID,
				)
			} else {
				_, err = tx.Exec(`
UPDATE clients SET last_ip = ?, last_hostname = ?, last_sync_at = ?, last_sync_count = ?,
    total_sync_count = total_sync_count + ?, updated_at = ?,
    encryption_enabled = ?, encryption_key_fp = ?
WHERE client_id = ?`,
					clientIP, req.Hostname, nowStr, batchCount, batchCount, nowStr,
					encEnabled, encKeyFP, req.ClientID,
				)
			}
		} else {
			_, err = tx.Exec(`
UPDATE clients SET last_ip = ?, last_hostname = ?, last_sync_at = ?, last_sync_count = ?,
    total_sync_count = total_sync_count + ?, updated_at = ?
WHERE client_id = ?`,
				clientIP, req.Hostname, nowStr, batchCount, batchCount, nowStr, req.ClientID,
			)
		}
	default:
		return IngestResult{}, err
	}
	if err != nil {
		return IngestResult{}, err
	}

	if err := tx.Commit(); err != nil {
		return IngestResult{}, err
	}
	return IngestResult{Accepted: accepted, Deduped: deduped}, nil
}

func (s *Store) ListClients() ([]model.ClientRow, error) {
	rows, err := s.db.Query(`
SELECT client_id, last_ip, last_hostname, last_sync_at, last_sync_count, total_sync_count,
       created_at, updated_at, encryption_enabled, encryption_key_fp, encryption_salt
FROM clients ORDER BY last_sync_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []model.ClientRow
	for rows.Next() {
		var row model.ClientRow
		var lastSyncAt, createdAt, updatedAt string
		var encEnabled int
		if err := rows.Scan(
			&row.ClientID, &row.LastIP, &row.LastHostname,
			&lastSyncAt, &row.LastSyncCount, &row.TotalSyncCount,
			&createdAt, &updatedAt,
			&encEnabled, &row.EncryptionKeyFP, &row.EncryptionSalt,
		); err != nil {
			return nil, err
		}
		row.EncryptionEnabled = encEnabled == 1
		row.LastSyncAt = parseTime(lastSyncAt)
		row.CreatedAt = parseTime(createdAt)
		row.UpdatedAt = parseTime(updatedAt)
		out = append(out, row)
	}
	return out, rows.Err()
}

func (s *Store) ItemCount(clientID string) (int, error) {
	var count int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM items WHERE client_id = ? AND deleted_at IS NULL`, clientID).Scan(&count)
	return count, err
}

func decodeOptionalBase64(raw *string) ([]byte, error) {
	if raw == nil || strings.TrimSpace(*raw) == "" {
		return nil, nil
	}
	return base64.StdEncoding.DecodeString(strings.TrimSpace(*raw))
}

func nullString(s *string) interface{} {
	if s == nil {
		return nil
	}
	return *s
}

func nullInt(v *int) interface{} {
	if v == nil {
		return nil
	}
	return *v
}

func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}

func stringOrDefault(value *string, fallback string) string {
	if value == nil {
		return fallback
	}
	trimmed := strings.TrimSpace(*value)
	if trimmed == "" {
		return fallback
	}
	return trimmed
}

func encryptedContentType(item model.SyncItem) string {
	ct := strings.TrimSpace(item.ContentType)
	if ct == "" || ct == "encrypted" {
		return "text"
	}
	return ct
}

func parseTime(raw string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, raw)
	if err == nil {
		return t
	}
	t, err = time.Parse(time.RFC3339, raw)
	if err == nil {
		return t
	}
	return time.Time{}
}
