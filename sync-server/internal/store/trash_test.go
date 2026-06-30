package store

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/lifedever/pastememo/sync-server/internal/model"
)

func TestSoftDeleteRestoreAndPurge(t *testing.T) {
	dir := t.TempDir()
	st, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Date(2026, 6, 25, 12, 0, 0, 0, time.UTC)
	_, err = st.IngestSync(model.SyncRequest{
		ClientID: "client-a",
		Hostname: "test",
		Items: []model.SyncItem{{
			ItemID:      "item-1",
			CreatedAt:   "2026-06-25T10:00:00.000Z",
			LastUsedAt:  "2026-06-25T10:00:00.000Z",
			Content:     "hello",
			ContentType: "text",
		}},
	}, "127.0.0.1", now)
	if err != nil {
		t.Fatal(err)
	}

	if err := st.SoftDeleteItem("client-a", "item-1", now); err != nil {
		t.Fatal(err)
	}

	active, err := st.ItemCount("client-a")
	if err != nil {
		t.Fatal(err)
	}
	if active != 0 {
		t.Fatalf("active count = %d, want 0", active)
	}

	trash, err := st.TrashCount("client-a")
	if err != nil {
		t.Fatal(err)
	}
	if trash != 1 {
		t.Fatalf("trash count = %d, want 1", trash)
	}

	list, err := st.ListItems(ListItemsParams{ClientID: "client-a", Trash: true, Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(list.Items) != 1 || list.Items[0].DeletedAt == nil {
		t.Fatalf("expected one trashed item, got %+v", list.Items)
	}

	if err := st.RestoreItem("client-a", "item-1"); err != nil {
		t.Fatal(err)
	}
	active, err = st.ItemCount("client-a")
	if err != nil {
		t.Fatal(err)
	}
	if active != 1 {
		t.Fatalf("active count after restore = %d, want 1", active)
	}

	if err := st.SoftDeleteItem("client-a", "item-1", now.Add(-11*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	n, err := st.PurgeExpiredTrash(now)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("purged %d, want 1", n)
	}
}

func TestPurgeClientTrash(t *testing.T) {
	dir := t.TempDir()
	st, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Date(2026, 6, 25, 12, 0, 0, 0, time.UTC)
	_, err = st.IngestSync(model.SyncRequest{
		ClientID: "client-a",
		Hostname: "test",
		Items: []model.SyncItem{
			{
				ItemID:      "item-1",
				CreatedAt:   "2026-06-25T10:00:00.000Z",
				LastUsedAt:  "2026-06-25T10:00:00.000Z",
				Content:     "one",
				ContentType: "text",
			},
			{
				ItemID:      "item-2",
				CreatedAt:   "2026-06-25T11:00:00.000Z",
				LastUsedAt:  "2026-06-25T11:00:00.000Z",
				Content:     "two",
				ContentType: "text",
			},
		},
	}, "127.0.0.1", now)
	if err != nil {
		t.Fatal(err)
	}

	if err := st.SoftDeleteItem("client-a", "item-1", now); err != nil {
		t.Fatal(err)
	}
	if err := st.SoftDeleteItem("client-a", "item-2", now); err != nil {
		t.Fatal(err)
	}

	n, err := st.PurgeClientTrash("client-a")
	if err != nil {
		t.Fatal(err)
	}
	if n != 2 {
		t.Fatalf("purged %d, want 2", n)
	}

	trash, err := st.TrashCount("client-a")
	if err != nil {
		t.Fatal(err)
	}
	if trash != 0 {
		t.Fatalf("trash count = %d, want 0", trash)
	}

	active, err := st.ItemCount("client-a")
	if err != nil {
		t.Fatal(err)
	}
	if active != 0 {
		t.Fatalf("active count = %d, want 0", active)
	}
}
