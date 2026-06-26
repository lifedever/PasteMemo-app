package store

import (
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/lifedever/pastememo/sync-server/internal/model"
)

const TrashRetentionDays = 10

func (s *Store) SoftDeleteItem(clientID, itemID string, now time.Time) error {
	nowStr := now.UTC().Format(time.RFC3339Nano)
	res, err := s.db.Exec(`
UPDATE items SET deleted_at = ?
WHERE client_id = ? AND item_id = ? AND deleted_at IS NULL`,
		nowStr, clientID, itemID,
	)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return fmt.Errorf("item not found")
	}
	return nil
}

func (s *Store) RestoreItem(clientID, itemID string) error {
	res, err := s.db.Exec(`
UPDATE items SET deleted_at = NULL
WHERE client_id = ? AND item_id = ? AND deleted_at IS NOT NULL`,
		clientID, itemID,
	)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return fmt.Errorf("item not found in trash")
	}
	return nil
}

func (s *Store) PurgeExpiredTrash(now time.Time) (int64, error) {
	cutoff := now.UTC().Add(-TrashRetentionDays * 24 * time.Hour).Format(time.RFC3339Nano)
	res, err := s.db.Exec(`DELETE FROM items WHERE deleted_at IS NOT NULL AND deleted_at < ?`, cutoff)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func (s *Store) TrashCount(clientID string) (int, error) {
	var count int
	err := s.db.QueryRow(`
SELECT COUNT(*) FROM items WHERE client_id = ? AND deleted_at IS NOT NULL`, clientID).Scan(&count)
	return count, err
}

func (s *Store) PurgeClientTrash(clientID string) (int64, error) {
	if strings.TrimSpace(clientID) == "" {
		return 0, fmt.Errorf("client_id is required")
	}
	res, err := s.db.Exec(`
DELETE FROM items WHERE client_id = ? AND deleted_at IS NOT NULL`, clientID)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

type ListTrashParams struct {
	ClientID string
	Since    string
	Cursor   *model.ItemCursor
	Limit    int
}

func (s *Store) ListTrashDeletions(p ListTrashParams) (model.TrashListResponse, error) {
	if strings.TrimSpace(p.ClientID) == "" {
		return model.TrashListResponse{}, fmt.Errorf("client_id is required")
	}
	limit := p.Limit
	if limit <= 0 {
		limit = defaultItemPageSize
	}
	if limit > maxItemPageSize {
		limit = maxItemPageSize
	}

	where := []string{"client_id = ?", "deleted_at IS NOT NULL"}
	args := []any{p.ClientID}

	if since := strings.TrimSpace(p.Since); since != "" {
		where = append(where, "deleted_at > ?")
		args = append(args, since)
	}

	if p.Cursor != nil && p.Cursor.DeletedAt != "" && p.Cursor.ItemID != "" {
		where = append(where, "(deleted_at < ? OR (deleted_at = ? AND item_id < ?))")
		args = append(args, p.Cursor.DeletedAt, p.Cursor.DeletedAt, p.Cursor.ItemID)
	}

	query := fmt.Sprintf(`
SELECT item_id, deleted_at
FROM items
WHERE %s
ORDER BY deleted_at DESC, item_id DESC
LIMIT ?`, strings.Join(where, " AND "))
	args = append(args, limit+1)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return model.TrashListResponse{}, err
	}
	defer rows.Close()

	items := make([]model.TrashItem, 0, limit)
	for rows.Next() {
		var item model.TrashItem
		if err := rows.Scan(&item.ItemID, &item.DeletedAt); err != nil {
			return model.TrashListResponse{}, err
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		return model.TrashListResponse{}, err
	}

	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}

	resp := model.TrashListResponse{Items: items, HasMore: hasMore}
	if hasMore && len(items) > 0 {
		last := items[len(items)-1]
		resp.NextCursor = &model.ItemCursor{
			DeletedAt: last.DeletedAt,
			ItemID:    last.ItemID,
		}
	}
	return resp, nil
}

func (s *Store) ensureColumn(table, column, decl string) error {
	rows, err := s.db.Query(fmt.Sprintf(`PRAGMA table_info(%s)`, table))
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, ctype string
		var notnull, pk int
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			return err
		}
		if name == column {
			return nil
		}
	}
	_, err = s.db.Exec(fmt.Sprintf(`ALTER TABLE %s ADD COLUMN %s %s`, table, column, decl))
	return err
}
