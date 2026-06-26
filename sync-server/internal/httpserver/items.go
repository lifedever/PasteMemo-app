package httpserver

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/lifedever/pastememo/sync-server/internal/imagetype"
	"github.com/lifedever/pastememo/sync-server/internal/model"
	"github.com/lifedever/pastememo/sync-server/internal/store"
)

func (s *Server) handleListClientsJSON(w http.ResponseWriter, r *http.Request) {
	clients, err := s.store.ListClients()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	type row struct {
		ClientID           string `json:"client_id"`
		LastIP             string `json:"last_ip"`
		LastHostname       string `json:"last_hostname"`
		LastSyncAt         string `json:"last_sync_at"`
		LastSyncCount      int    `json:"last_sync_count"`
		TotalSyncCount     int    `json:"total_sync_count"`
		ItemCount          int    `json:"item_count"`
		EncryptionEnabled  bool   `json:"encryption_enabled"`
		EncryptionKeyFP    string `json:"encryption_key_fingerprint"`
		EncryptionSalt     string `json:"encryption_salt"`
	}
	out := make([]row, 0, len(clients))
	for _, c := range clients {
		itemCount, _ := s.store.ItemCount(c.ClientID)
		out = append(out, row{
			ClientID:          c.ClientID,
			LastIP:            c.LastIP,
			LastHostname:      c.LastHostname,
			LastSyncAt:        formatDisplayTime(c.LastSyncAt),
			LastSyncCount:     c.LastSyncCount,
			TotalSyncCount:    c.TotalSyncCount,
			ItemCount:         itemCount,
			EncryptionEnabled: c.EncryptionEnabled,
			EncryptionKeyFP:   c.EncryptionKeyFP,
			EncryptionSalt:    c.EncryptionSalt,
		})
	}
	writeJSON(w, out)
}

func (s *Server) handlePullItems(w http.ResponseWriter, r *http.Request) {
	clientID := strings.TrimSpace(r.URL.Query().Get("client_id"))
	if clientID == "" {
		http.Error(w, "client_id required", http.StatusBadRequest)
		return
	}

	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	var cursor *model.ItemCursor
	if createdAt := r.URL.Query().Get("cursor_created_at"); createdAt != "" {
		itemID := r.URL.Query().Get("cursor_item_id")
		if itemID != "" {
			cursor = &model.ItemCursor{CreatedAt: createdAt, ItemID: itemID}
		}
	}

	resp, err := s.store.ListPullItems(store.ListPullParams{
		ClientID: clientID,
		Since:    strings.TrimSpace(r.URL.Query().Get("since")),
		Cursor:   cursor,
		Limit:    limit,
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, resp)
}

func (s *Server) handleListTrash(w http.ResponseWriter, r *http.Request) {
	clientID := strings.TrimSpace(r.URL.Query().Get("client_id"))
	if clientID == "" {
		http.Error(w, "client_id required", http.StatusBadRequest)
		return
	}

	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	var cursor *model.ItemCursor
	if deletedAt := r.URL.Query().Get("cursor_deleted_at"); deletedAt != "" {
		itemID := r.URL.Query().Get("cursor_item_id")
		if itemID != "" {
			cursor = &model.ItemCursor{DeletedAt: deletedAt, ItemID: itemID}
		}
	}

	resp, err := s.store.ListTrashDeletions(store.ListTrashParams{
		ClientID: clientID,
		Since:    strings.TrimSpace(r.URL.Query().Get("since")),
		Cursor:   cursor,
		Limit:    limit,
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, resp)
}

func (s *Server) handleListTypes(w http.ResponseWriter, r *http.Request) {
	clientID := strings.TrimSpace(r.URL.Query().Get("client_id"))
	if clientID == "" {
		http.Error(w, "client_id required", http.StatusBadRequest)
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=86400")
	writeJSON(w, map[string]any{"types": model.AllContentTypes})
}

func (s *Server) handleListItems(w http.ResponseWriter, r *http.Request) {
	clientID := strings.TrimSpace(r.URL.Query().Get("client_id"))
	if clientID == "" {
		http.Error(w, "client_id required", http.StatusBadRequest)
		return
	}

	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	var cursor *model.ItemCursor
	if createdAt := r.URL.Query().Get("cursor_created_at"); createdAt != "" {
		itemID := r.URL.Query().Get("cursor_item_id")
		if itemID != "" {
			cursor = &model.ItemCursor{CreatedAt: createdAt, ItemID: itemID}
			cursor.DeletedAt = r.URL.Query().Get("cursor_deleted_at")
		}
	}

	resp, err := s.store.ListItems(store.ListItemsParams{
		ClientID:    clientID,
		ContentType: strings.TrimSpace(r.URL.Query().Get("type")),
		Cursor:      cursor,
		Limit:       limit,
		Trash:       r.URL.Query().Get("trash") == "1",
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, resp)
}

func (s *Server) handleGetItem(w http.ResponseWriter, r *http.Request) {
	clientID := r.PathValue("clientID")
	itemID := r.PathValue("itemID")
	detail, err := s.store.GetItemDetail(clientID, itemID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	writeJSON(w, detail)
}

func (s *Server) handleGetItemImage(w http.ResponseWriter, r *http.Request) {
	clientID := r.PathValue("clientID")
	itemID := r.PathValue("itemID")
	data, err := s.store.GetItemImage(clientID, itemID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=86400, immutable")
	switch imagetype.DetectMIME(data) {
	case "image/jpeg":
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write(data)
		return
	case "image/png":
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(data)
		return
	case "image/gif":
		w.Header().Set("Content-Type", "image/gif")
		_, _ = w.Write(data)
		return
	}
	if jpegData, err := imagetype.AsJPEG(data, 85); err == nil {
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write(jpegData)
		return
	}
	// Browsers (especially Chrome) cannot render TIFF/HEIC in <img>; avoid serving them raw.
	http.Error(w, "image format not supported for preview", http.StatusUnsupportedMediaType)
}

func (s *Server) handleDeleteItem(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	clientID := r.PathValue("clientID")
	itemID := r.PathValue("itemID")
	if err := s.store.SoftDeleteItem(clientID, itemID, time.Now().UTC()); err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	writeJSON(w, map[string]string{"status": "deleted"})
}

func (s *Server) handleRestoreItem(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	clientID := r.PathValue("clientID")
	itemID := r.PathValue("itemID")
	if err := s.store.RestoreItem(clientID, itemID); err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	writeJSON(w, map[string]string{"status": "restored"})
}

func (s *Server) handlePurgeClientTrash(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	clientID := strings.TrimSpace(r.PathValue("clientID"))
	if clientID == "" {
		http.Error(w, "client_id required", http.StatusBadRequest)
		return
	}
	count, err := s.store.PurgeClientTrash(clientID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"deleted_count": count})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) handleDeleteClientItems(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	clientID := strings.TrimSpace(r.PathValue("clientID"))
	if clientID == "" {
		http.Error(w, "client_id required", http.StatusBadRequest)
		return
	}
	count, err := s.store.DeleteAllClientItems(clientID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"deleted_count": count})
}

func (s *Server) handlePurgeClient(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	clientID := strings.TrimSpace(r.PathValue("clientID"))
	if clientID == "" {
		http.Error(w, "client_id required", http.StatusBadRequest)
		return
	}
	exists, err := s.store.ClientExists(clientID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if !exists {
		http.Error(w, "client not found", http.StatusNotFound)
		return
	}
	itemsDeleted, err := s.store.PurgeClient(clientID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{
		"client_id":     clientID,
		"deleted_count": itemsDeleted,
	})
}
