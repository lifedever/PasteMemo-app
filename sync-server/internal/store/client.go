package store

import (
	"database/sql"
	"fmt"
	"strings"
)

// PurgeClient removes every item (live and trashed) for the client as well as
// the client row itself. Attachments are removed automatically via the
// items_delete_attachments trigger. Returns the number of items deleted.
func (s *Store) PurgeClient(clientID string) (int64, error) {
	clientID = strings.TrimSpace(clientID)
	if clientID == "" {
		return 0, fmt.Errorf("client_id is required")
	}
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`DELETE FROM items WHERE client_id = ?`, clientID)
	if err != nil {
		return 0, err
	}
	itemsDeleted, err := res.RowsAffected()
	if err != nil {
		return 0, err
	}

	if _, err := tx.Exec(`DELETE FROM clients WHERE client_id = ?`, clientID); err != nil {
		return 0, err
	}

	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return itemsDeleted, nil
}

// ClientExists reports whether a client row with the given ID is registered.
func (s *Store) ClientExists(clientID string) (bool, error) {
	clientID = strings.TrimSpace(clientID)
	if clientID == "" {
		return false, fmt.Errorf("client_id is required")
	}
	var found int
	err := s.db.QueryRow(`SELECT 1 FROM clients WHERE client_id = ? LIMIT 1`, clientID).Scan(&found)
	if err == sql.ErrNoRows {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}
