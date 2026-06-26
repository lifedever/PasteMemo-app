package store

import (
	"database/sql"
	"fmt"
	"strings"
)

func (s *Store) DeleteAllClientItems(clientID string) (int64, error) {
	if strings.TrimSpace(clientID) == "" {
		return 0, fmt.Errorf("client_id is required")
	}
	res, err := s.db.Exec(`DELETE FROM items WHERE client_id = ?`, clientID)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func (s *Store) UpdateClientEncryption(clientID string, enabled bool, keyFP, salt string) error {
	if strings.TrimSpace(clientID) == "" {
		return fmt.Errorf("client_id is required")
	}
	enabledInt := 0
	if enabled {
		enabledInt = 1
	}
	_, err := s.db.Exec(`
UPDATE clients SET encryption_enabled = ?, encryption_key_fp = ?, encryption_salt = ?, updated_at = datetime('now')
WHERE client_id = ?`,
		enabledInt, strings.TrimSpace(keyFP), strings.TrimSpace(salt), clientID,
	)
	return err
}

func (s *Store) GetClientEncryption(clientID string) (enabled bool, keyFP, salt string, err error) {
	var enabledInt int
	err = s.db.QueryRow(`
SELECT encryption_enabled, encryption_key_fp, encryption_salt
FROM clients WHERE client_id = ?`, clientID).Scan(&enabledInt, &keyFP, &salt)
	if err == sql.ErrNoRows {
		return false, "", "", nil
	}
	if err != nil {
		return false, "", "", err
	}
	return enabledInt == 1, keyFP, salt, nil
}
