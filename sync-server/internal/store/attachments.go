package store

import (
	"database/sql"
	"fmt"
)

func (s *Store) ensureAttachmentsSchema() error {
	if _, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS item_attachments (
    client_id TEXT NOT NULL,
    item_id TEXT NOT NULL,
    image_data BLOB,
    favicon_data BLOB,
    rich_text_data BLOB,
    pasteboard_snapshot BLOB,
    payload_json TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (client_id, item_id)
)`); err != nil {
		return err
	}
	_, err := s.db.Exec(`
CREATE TRIGGER IF NOT EXISTS items_delete_attachments
AFTER DELETE ON items
BEGIN
    DELETE FROM item_attachments WHERE client_id = OLD.client_id AND item_id = OLD.item_id;
END`)
	return err
}

func (s *Store) migrateAttachmentsOutOfItems() error {
	var pending int
	err := s.db.QueryRow(`
SELECT 1 FROM items
WHERE image_data IS NOT NULL OR favicon_data IS NOT NULL OR rich_text_data IS NOT NULL
   OR pasteboard_snapshot IS NOT NULL OR payload_json != ''
LIMIT 1`).Scan(&pending)
	if err == sql.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}

	if _, err := s.db.Exec(`
INSERT INTO item_attachments (client_id, item_id, image_data, favicon_data, rich_text_data, pasteboard_snapshot, payload_json)
SELECT client_id, item_id, image_data, favicon_data, rich_text_data, pasteboard_snapshot, payload_json
FROM items
WHERE (image_data IS NOT NULL OR favicon_data IS NOT NULL OR rich_text_data IS NOT NULL
       OR pasteboard_snapshot IS NOT NULL OR payload_json != '')
  AND NOT EXISTS (
    SELECT 1 FROM item_attachments a
    WHERE a.client_id = items.client_id AND a.item_id = items.item_id
  )`); err != nil {
		return err
	}

	if _, err := s.db.Exec(`
UPDATE items SET
    image_data = NULL,
    favicon_data = NULL,
    rich_text_data = NULL,
    pasteboard_snapshot = NULL,
    payload_json = '',
    has_image = CASE WHEN EXISTS (
        SELECT 1 FROM item_attachments a
        WHERE a.client_id = items.client_id AND a.item_id = items.item_id AND a.image_data IS NOT NULL
    ) THEN 1 ELSE has_image END,
    has_favicon = CASE WHEN EXISTS (
        SELECT 1 FROM item_attachments a
        WHERE a.client_id = items.client_id AND a.item_id = items.item_id AND a.favicon_data IS NOT NULL
    ) THEN 1 ELSE has_favicon END,
    has_rich_text = CASE WHEN EXISTS (
        SELECT 1 FROM item_attachments a
        WHERE a.client_id = items.client_id AND a.item_id = items.item_id AND a.rich_text_data IS NOT NULL
    ) THEN 1 ELSE has_rich_text END,
    has_pasteboard = CASE WHEN EXISTS (
        SELECT 1 FROM item_attachments a
        WHERE a.client_id = items.client_id AND a.item_id = items.item_id AND a.pasteboard_snapshot IS NOT NULL
    ) THEN 1 ELSE has_pasteboard END
WHERE image_data IS NOT NULL OR favicon_data IS NOT NULL OR rich_text_data IS NOT NULL
   OR pasteboard_snapshot IS NOT NULL OR payload_json != ''`); err != nil {
		return err
	}
	return nil
}

type itemAttachmentFlags struct {
	hasImage      int
	hasFavicon    int
	hasRichText   int
	hasPasteboard int
}

func attachmentFlags(imageData, faviconData, richTextData, pasteboardData []byte) itemAttachmentFlags {
	return itemAttachmentFlags{
		hasImage:      boolInt(len(imageData) > 0),
		hasFavicon:    boolInt(len(faviconData) > 0),
		hasRichText:   boolInt(len(richTextData) > 0),
		hasPasteboard: boolInt(len(pasteboardData) > 0),
	}
}

func (s *Store) upsertAttachments(tx *sql.Tx, clientID, itemID string, imageData, faviconData, richTextData, pasteboardData []byte, payloadJSON string) error {
	flags := attachmentFlags(imageData, faviconData, richTextData, pasteboardData)
	if _, err := tx.Exec(`
UPDATE items SET has_image = ?, has_favicon = ?, has_rich_text = ?, has_pasteboard = ?
WHERE client_id = ? AND item_id = ?`,
		flags.hasImage, flags.hasFavicon, flags.hasRichText, flags.hasPasteboard, clientID, itemID,
	); err != nil {
		return err
	}

	if len(imageData) == 0 && len(faviconData) == 0 && len(richTextData) == 0 && len(pasteboardData) == 0 && payloadJSON == "" {
		return nil
	}

	_, err := tx.Exec(`
INSERT INTO item_attachments (
    client_id, item_id, image_data, favicon_data, rich_text_data, pasteboard_snapshot, payload_json
) VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(client_id, item_id) DO UPDATE SET
    image_data = excluded.image_data,
    favicon_data = excluded.favicon_data,
    rich_text_data = excluded.rich_text_data,
    pasteboard_snapshot = excluded.pasteboard_snapshot,
    payload_json = excluded.payload_json`,
		clientID, itemID, nullBytes(imageData), nullBytes(faviconData), nullBytes(richTextData), nullBytes(pasteboardData), payloadJSON,
	)
	return err
}

func nullBytes(data []byte) any {
	if len(data) == 0 {
		return nil
	}
	return data
}

func (s *Store) itemPayloadJSON(clientID, itemID string) (string, error) {
	var payload sql.NullString
	err := s.db.QueryRow(`
SELECT payload_json FROM item_attachments
WHERE client_id = ? AND item_id = ?`, clientID, itemID).Scan(&payload)
	if err == sql.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if payload.Valid {
		return payload.String, nil
	}
	return "", nil
}

func (s *Store) itemImageData(clientID, itemID string) ([]byte, error) {
	var data []byte
	err := s.db.QueryRow(`
SELECT image_data FROM item_attachments
WHERE client_id = ? AND item_id = ? AND image_data IS NOT NULL`, clientID, itemID).Scan(&data)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("image not found")
	}
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("image not found")
	}
	return data, nil
}

func (s *Store) itemAttachmentBlobs(clientID, itemID string) (imageData, faviconData, richTextData, pasteboardData []byte, err error) {
	err = s.db.QueryRow(`
SELECT image_data, favicon_data, rich_text_data, pasteboard_snapshot
FROM item_attachments WHERE client_id = ? AND item_id = ?`, clientID, itemID).Scan(
		&imageData, &faviconData, &richTextData, &pasteboardData,
	)
	if err == sql.ErrNoRows {
		return nil, nil, nil, nil, nil
	}
	return imageData, faviconData, richTextData, pasteboardData, err
}
