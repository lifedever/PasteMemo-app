package store

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lifedever/pastememo/sync-server/internal/model"
)

func TestListItemsOmitsLargeFields(t *testing.T) {
	dir := t.TempDir()
	st, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Date(2026, 6, 26, 12, 0, 0, 0, time.UTC)
	largePayload := strings.Repeat("x", 256*1024)
	_, err = st.IngestSync(model.SyncRequest{
		ClientID: "client-a",
		Hostname: "test",
		Items: []model.SyncItem{{
			ItemID:           "enc-1",
			CreatedAt:        "2026-06-26T10:00:00.000Z",
			LastUsedAt:       "2026-06-26T10:00:00.000Z",
			ContentType:      "text",
			Encrypted:        true,
			PayloadEncrypted: largePayload,
		}},
	}, "127.0.0.1", now)
	if err != nil {
		t.Fatal(err)
	}

	list, err := st.ListItems(ListItemsParams{ClientID: "client-a", Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(list.Items) != 1 {
		t.Fatalf("items = %d, want 1", len(list.Items))
	}
	item := list.Items[0]
	if item.PayloadEncrypted != "" {
		t.Fatal("list response must not include payload_encrypted")
	}
	if !item.Encrypted || item.ContentPreview != "🔒 Encrypted" {
		t.Fatalf("unexpected list item: %+v", item)
	}

	detail, err := st.GetItemDetail("client-a", "enc-1")
	if err != nil {
		t.Fatal(err)
	}
	if detail.PayloadEncrypted != largePayload {
		t.Fatalf("detail payload len = %d, want %d", len(detail.PayloadEncrypted), len(largePayload))
	}
}

func TestListItemsUsesContentPreviewColumn(t *testing.T) {
	dir := t.TempDir()
	st, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	longContent := strings.Repeat("x", 500)
	now := time.Date(2026, 6, 26, 12, 0, 0, 0, time.UTC)
	_, err = st.IngestSync(model.SyncRequest{
		ClientID: "client-a",
		Hostname: "test",
		Items: []model.SyncItem{{
			ItemID:      "text-1",
			CreatedAt:   "2026-06-26T10:00:00.000Z",
			LastUsedAt:  "2026-06-26T10:00:00.000Z",
			Content:     longContent,
			ContentType: "text",
		}},
	}, "127.0.0.1", now)
	if err != nil {
		t.Fatal(err)
	}

	list, err := st.ListItems(ListItemsParams{ClientID: "client-a", Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(list.Items) != 1 {
		t.Fatalf("items = %d, want 1", len(list.Items))
	}
	preview := list.Items[0].ContentPreview
	if len([]rune(preview)) > 241 {
		t.Fatalf("preview too long: %d runes", len([]rune(preview)))
	}
	if !strings.HasPrefix(preview, strings.Repeat("x", 100)) {
		t.Fatalf("unexpected preview: %q", preview)
	}
}
