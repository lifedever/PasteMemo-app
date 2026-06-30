package store

import (
	"database/sql"
	"encoding/base64"
	"fmt"
	"strings"

	"github.com/lifedever/pastememo/sync-server/internal/model"
)

const defaultItemPageSize = 30
const maxItemPageSize = 100

type ListItemsParams struct {
	ClientID    string
	ContentType string
	Cursor      *model.ItemCursor
	Limit       int
	Trash       bool
}

func (s *Store) ListItems(p ListItemsParams) (model.ItemListResponse, error) {
	if strings.TrimSpace(p.ClientID) == "" {
		return model.ItemListResponse{}, fmt.Errorf("client_id is required")
	}
	limit := p.Limit
	if limit <= 0 {
		limit = defaultItemPageSize
	}
	if limit > maxItemPageSize {
		limit = maxItemPageSize
	}

	where := []string{"client_id = ?"}
	args := []any{p.ClientID}

	if p.Trash {
		where = append(where, "deleted_at IS NOT NULL")
	} else {
		where = append(where, "deleted_at IS NULL")
	}

	if filter := contentTypeFilterSQL(p.ContentType); filter != "" {
		where = append(where, filter)
	}

	orderBy := "created_at DESC, item_id DESC"
	selectDeleted := ""
	if p.Trash {
		orderBy = "deleted_at DESC, item_id DESC"
		selectDeleted = ", deleted_at"
		if p.Cursor != nil && p.Cursor.DeletedAt != "" && p.Cursor.ItemID != "" {
			where = append(where, "(deleted_at < ? OR (deleted_at = ? AND item_id < ?))")
			args = append(args, p.Cursor.DeletedAt, p.Cursor.DeletedAt, p.Cursor.ItemID)
		}
	} else if p.Cursor != nil && p.Cursor.CreatedAt != "" && p.Cursor.ItemID != "" {
		where = append(where, "(created_at < ? OR (created_at = ? AND item_id < ?))")
		args = append(args, p.Cursor.CreatedAt, p.Cursor.CreatedAt, p.Cursor.ItemID)
	}

	query := fmt.Sprintf(`
SELECT client_id, item_id, content_type, created_at, display_title, source_app,
       content_preview, ocr_preview, truncated, is_encrypted, has_image%s
FROM items
WHERE %s
ORDER BY %s
LIMIT ?`, selectDeleted, strings.Join(where, " AND "), orderBy)
	args = append(args, limit+1)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return model.ItemListResponse{}, err
	}
	defer rows.Close()

	items := make([]model.ItemSummary, 0, limit)
	for rows.Next() {
		var item model.ItemSummary
		var displayTitle, sourceApp, contentPreview, ocrPreview sql.NullString
		var deletedAt sql.NullString
		var truncated, hasImage, isEncrypted int
		scanArgs := []any{
			&item.ClientID, &item.ItemID, &item.ContentType, &item.CreatedAt,
			&displayTitle, &sourceApp, &contentPreview, &ocrPreview, &truncated, &isEncrypted, &hasImage,
		}
		if p.Trash {
			scanArgs = append(scanArgs, &deletedAt)
		}
		if err := rows.Scan(scanArgs...); err != nil {
			return model.ItemListResponse{}, err
		}
		if displayTitle.Valid {
			v := displayTitle.String
			item.DisplayTitle = &v
		}
		if sourceApp.Valid {
			v := sourceApp.String
			item.SourceApp = &v
		}
		item.Encrypted = isEncrypted == 1
		if item.Encrypted {
			item.ContentPreview = "🔒 Encrypted"
		} else if contentPreview.Valid {
			item.ContentPreview = contentPreview.String
		}
		if !item.Encrypted && ocrPreview.Valid && ocrPreview.String != "" {
			v := ocrPreview.String
			item.OCRPreview = &v
		}
		item.HasImage = hasImage == 1
		item.Truncated = truncated == 1
		if deletedAt.Valid {
			v := deletedAt.String
			item.DeletedAt = &v
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return model.ItemListResponse{}, err
	}

	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}

	resp := model.ItemListResponse{
		Items:   items,
		HasMore: hasMore,
	}
	if hasMore && len(items) > 0 {
		last := items[len(items)-1]
		cursor := model.ItemCursor{
			CreatedAt: last.CreatedAt,
			ItemID:    last.ItemID,
		}
		if p.Trash && last.DeletedAt != nil {
			cursor.DeletedAt = *last.DeletedAt
		}
		resp.NextCursor = &cursor
	}
	return resp, nil
}

func (s *Store) GetItemDetail(clientID, itemID string) (model.ItemDetail, error) {
	row := s.db.QueryRow(`
SELECT client_id, item_id, content_type, created_at, last_used_at, received_at,
       content, display_title, source_app, source_app_bundle_id,
       is_favorite, is_pinned, is_sensitive, link_title, code_language, group_name,
       file_paths, agent_source, ocr_text, ocr_status, truncated, deleted_at,
       is_encrypted, has_image, has_favicon, has_rich_text, has_pasteboard
FROM items WHERE client_id = ? AND item_id = ?`, clientID, itemID)

	var detail model.ItemDetail
	var displayTitle, sourceApp, sourceBundle, linkTitle, codeLang, groupName sql.NullString
	var filePaths, agentSource, ocrText, ocrStatus, deletedAt sql.NullString
	var favorite, pinned, sensitive, truncated, isEncrypted int
	var hasImage, hasFavicon, hasRichText, hasPasteboard int

	err := row.Scan(
		&detail.ClientID, &detail.ItemID, &detail.ContentType, &detail.CreatedAt,
		&detail.LastUsedAt, &detail.ReceivedAt, &detail.Content,
		&displayTitle, &sourceApp, &sourceBundle,
		&favorite, &pinned, &sensitive, &linkTitle, &codeLang, &groupName,
		&filePaths, &agentSource, &ocrText, &ocrStatus, &truncated, &deletedAt,
		&isEncrypted, &hasImage, &hasFavicon, &hasRichText, &hasPasteboard,
	)
	if err == sql.ErrNoRows {
		return model.ItemDetail{}, fmt.Errorf("item not found")
	}
	if err != nil {
		return model.ItemDetail{}, err
	}

	detail.Encrypted = isEncrypted == 1
	if detail.Encrypted {
		detail.Content = ""
		payload, err := s.itemPayloadJSON(clientID, itemID)
		if err != nil {
			return model.ItemDetail{}, err
		}
		detail.PayloadEncrypted = payload
		return detail, nil
	}

	detail.IsFavorite = favorite == 1
	detail.IsPinned = pinned == 1
	detail.IsSensitive = sensitive == 1
	detail.Truncated = truncated == 1
	detail.HasImage = hasImage == 1
	detail.HasFavicon = hasFavicon == 1
	detail.HasRichText = hasRichText == 1
	detail.HasPasteboard = hasPasteboard == 1
	nullableString(displayTitle, &detail.DisplayTitle)
	nullableString(sourceApp, &detail.SourceApp)
	nullableString(sourceBundle, &detail.SourceAppBundleID)
	nullableString(linkTitle, &detail.LinkTitle)
	nullableString(codeLang, &detail.CodeLanguage)
	nullableString(groupName, &detail.GroupName)
	nullableString(filePaths, &detail.FilePaths)
	nullableString(agentSource, &detail.AgentSource)
	nullableString(ocrText, &detail.OCRText)
	nullableString(ocrStatus, &detail.OCRStatus)
	nullableString(deletedAt, &detail.DeletedAt)
	return detail, nil
}

func (s *Store) GetItemImage(clientID, itemID string) ([]byte, error) {
	return s.itemImageData(clientID, itemID)
}

func contentTypeFilterSQL(contentType string) string {
	switch strings.TrimSpace(contentType) {
	case "":
		return ""
	case "image":
		return `(content_type = 'image'
			OR (content_type = 'mixed' AND has_image = 1)
			OR (is_encrypted = 1 AND content_type IN ('image', 'mixed')))`
	default:
		return `content_type = '` + strings.ReplaceAll(contentType, "'", "''") + `'`
	}
}

func previewText(s string, max int) string {
	runes := []rune(s)
	if len(runes) <= max {
		return s
	}
	return string(runes[:max]) + "…"
}

func nullableString(src sql.NullString, dst **string) {
	if src.Valid {
		v := src.String
		*dst = &v
	}
}

func encodeOptionalBase64(data []byte) *string {
	if len(data) == 0 {
		return nil
	}
	s := base64.StdEncoding.EncodeToString(data)
	return &s
}

type ListPullParams struct {
	ClientID string
	Since    string
	Cursor   *model.ItemCursor
	Limit    int
}

func (s *Store) ListPullItems(p ListPullParams) (model.PullListResponse, error) {
	if strings.TrimSpace(p.ClientID) == "" {
		return model.PullListResponse{}, fmt.Errorf("client_id is required")
	}
	limit := p.Limit
	if limit <= 0 {
		limit = defaultItemPageSize
	}
	if limit > maxItemPageSize {
		limit = maxItemPageSize
	}

	where := []string{"i.client_id = ?", "i.deleted_at IS NULL"}
	args := []any{p.ClientID}

	if since := strings.TrimSpace(p.Since); since != "" {
		where = append(where, "i.created_at > ?")
		args = append(args, since)
	}

	if p.Cursor != nil && p.Cursor.CreatedAt != "" && p.Cursor.ItemID != "" {
		where = append(where, "(i.created_at < ? OR (i.created_at = ? AND i.item_id < ?))")
		args = append(args, p.Cursor.CreatedAt, p.Cursor.CreatedAt, p.Cursor.ItemID)
	}

	query := fmt.Sprintf(`
SELECT i.item_id, i.created_at, i.last_used_at, i.content, i.content_type,
       i.source_app, i.source_app_bundle_id, i.is_favorite, i.is_pinned, i.is_sensitive,
       i.link_title, i.display_title, i.code_language, i.rich_text_type, i.group_name,
       i.file_paths, i.original_image_file_path, i.agent_source,
       i.ocr_text, i.ocr_status, i.ocr_updated_at, i.ocr_error_message, i.ocr_version,
       a.image_data, a.favicon_data, a.rich_text_data, a.pasteboard_snapshot, i.truncated,
       i.is_encrypted, a.payload_json, i.origin_client_id, i.origin_hostname, i.origin_ip
FROM items i
LEFT JOIN item_attachments a ON a.client_id = i.client_id AND a.item_id = i.item_id
WHERE %s
ORDER BY i.created_at DESC, i.item_id DESC
LIMIT ?`, strings.Join(where, " AND "))
	args = append(args, limit+1)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return model.PullListResponse{}, err
	}
	defer rows.Close()

	items := make([]model.SyncItem, 0, limit)
	for rows.Next() {
		var item model.SyncItem
		var sourceApp, sourceBundle, linkTitle, displayTitle, codeLang sql.NullString
		var richTextType, groupName, filePaths, originalPath, agentSource sql.NullString
		var ocrText, ocrStatus, ocrUpdatedAt, ocrError sql.NullString
		var ocrVersion sql.NullInt64
		var favorite, pinned, sensitive, truncated, isEncrypted int
		var imageData, faviconData, richTextData, pasteboardData []byte
		var payloadJSON sql.NullString
		var originClientID, originHostname, originIP sql.NullString

		if err := rows.Scan(
			&item.ItemID, &item.CreatedAt, &item.LastUsedAt, &item.Content, &item.ContentType,
			&sourceApp, &sourceBundle, &favorite, &pinned, &sensitive,
			&linkTitle, &displayTitle, &codeLang, &richTextType, &groupName,
			&filePaths, &originalPath, &agentSource,
			&ocrText, &ocrStatus, &ocrUpdatedAt, &ocrError, &ocrVersion,
			&imageData, &faviconData, &richTextData, &pasteboardData, &truncated,
			&isEncrypted, &payloadJSON,
			&originClientID, &originHostname, &originIP,
		); err != nil {
			return model.PullListResponse{}, err
		}

		item.Encrypted = isEncrypted == 1
		if item.Encrypted {
			if payloadJSON.Valid {
				item.PayloadEncrypted = payloadJSON.String
			}
			item.ContentType = "encrypted"
			items = append(items, item)
			continue
		}

		item.IsFavorite = favorite == 1
		item.IsPinned = pinned == 1
		item.IsSensitive = sensitive == 1
		item.Truncated = truncated == 1
		nullableString(sourceApp, &item.SourceApp)
		nullableString(sourceBundle, &item.SourceAppBundleID)
		nullableString(linkTitle, &item.LinkTitle)
		nullableString(displayTitle, &item.DisplayTitle)
		nullableString(codeLang, &item.CodeLanguage)
		nullableString(richTextType, &item.RichTextType)
		nullableString(groupName, &item.GroupName)
		nullableString(filePaths, &item.FilePaths)
		nullableString(originalPath, &item.OriginalImagePath)
		nullableString(agentSource, &item.AgentSource)
		nullableString(ocrText, &item.OCRText)
		nullableString(ocrStatus, &item.OCRStatus)
		nullableString(ocrUpdatedAt, &item.OCRUpdatedAt)
		nullableString(ocrError, &item.OCRErrorMessage)
		nullableString(originClientID, &item.OriginClientID)
		nullableString(originHostname, &item.OriginHostname)
		nullableString(originIP, &item.OriginIP)
		if ocrVersion.Valid {
			v := int(ocrVersion.Int64)
			item.OCRVersion = &v
		}
		item.ImageDataBase64 = encodeOptionalBase64(imageData)
		item.FaviconDataBase64 = encodeOptionalBase64(faviconData)
		item.RichTextDataBase64 = encodeOptionalBase64(richTextData)
		item.PasteboardBase64 = encodeOptionalBase64(pasteboardData)
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return model.PullListResponse{}, err
	}

	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}

	resp := model.PullListResponse{Items: items, HasMore: hasMore}
	if hasMore && len(items) > 0 {
		last := items[len(items)-1]
		resp.NextCursor = &model.ItemCursor{CreatedAt: last.CreatedAt, ItemID: last.ItemID}
	}
	return resp, nil
}
