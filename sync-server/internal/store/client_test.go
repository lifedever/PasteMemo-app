package store

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/lifedever/pastememo/sync-server/internal/model"
)

func TestPurgeClientRemovesItemsAndClientRow(t *testing.T) {
	dir := t.TempDir()
	st, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Date(2026, 6, 26, 12, 0, 0, 0, time.UTC)
	_, err = st.IngestSync(model.SyncRequest{
		ClientID: "client-a",
		Hostname: "host-a",
		Items: []model.SyncItem{{
			ItemID:      "text-1",
			CreatedAt:   "2026-06-26T10:00:00.000Z",
			LastUsedAt:  "2026-06-26T10:00:00.000Z",
			Content:     "hello",
			ContentType: "text",
		}},
	}, "127.0.0.1", now)
	if err != nil {
		t.Fatal(err)
	}

	if err := st.SoftDeleteItem("client-a", "text-1", now); err != nil {
		t.Fatal(err)
	}

	// Sanity check: client and item both present.
	clients, err := st.ListClients()
	if err != nil {
		t.Fatal(err)
	}
	if len(clients) != 1 || clients[0].ClientID != "client-a" {
		t.Fatalf("unexpected clients before purge: %+v", clients)
	}
	if count, _ := st.ItemCount("client-a"); count != 0 {
		// Soft-deleted items are not counted by ItemCount.
		t.Fatalf("expected ItemCount=0 after soft delete, got %d", count)
	}
	trashCount, err := st.TrashCount("client-a")
	if err != nil {
		t.Fatal(err)
	}
	if trashCount != 1 {
		t.Fatalf("expected trash count=1, got %d", trashCount)
	}

	deleted, err := st.PurgeClient("client-a")
	if err != nil {
		t.Fatal(err)
	}
	if deleted != 1 {
		t.Fatalf("expected deleted_count=1, got %d", deleted)
	}

	// Client row should be gone.
	exists, err := st.ClientExists("client-a")
	if err != nil {
		t.Fatal(err)
	}
	if exists {
		t.Fatal("client row should be removed after PurgeClient")
	}

	// ItemCount should error or return 0 — both indicate removal.
	if count, _ := st.ItemCount("client-a"); count != 0 {
		t.Fatalf("expected ItemCount=0 after purge, got %d", count)
	}
	if trashCount, _ := st.TrashCount("client-a"); trashCount != 0 {
		t.Fatalf("expected TrashCount=0 after purge, got %d", trashCount)
	}
}

func TestPurgeClientLeavesOtherClientsAlone(t *testing.T) {
	dir := t.TempDir()
	st, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	now := time.Date(2026, 6, 26, 12, 0, 0, 0, time.UTC)
	for _, id := range []string{"client-a", "client-b"} {
		_, err = st.IngestSync(model.SyncRequest{
			ClientID: id,
			Hostname: "host-" + id,
			Items: []model.SyncItem{{
				ItemID:      "i-" + id,
				CreatedAt:   "2026-06-26T10:00:00.000Z",
				LastUsedAt:  "2026-06-26T10:00:00.000Z",
				Content:     "hi " + id,
				ContentType: "text",
			}},
		}, "127.0.0.1", now)
		if err != nil {
			t.Fatal(err)
		}
	}

	if _, err := st.PurgeClient("client-a"); err != nil {
		t.Fatal(err)
	}

	exists, err := st.ClientExists("client-a")
	if err != nil {
		t.Fatal(err)
	}
	if exists {
		t.Fatal("client-a should be removed")
	}
	exists, err = st.ClientExists("client-b")
	if err != nil {
		t.Fatal(err)
	}
	if !exists {
		t.Fatal("client-b should still exist")
	}
	if count, _ := st.ItemCount("client-b"); count != 1 {
		t.Fatalf("client-b should still have its item, got count=%d", count)
	}
}

func TestPurgeClientRejectsEmptyID(t *testing.T) {
	dir := t.TempDir()
	st, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	if _, err := st.PurgeClient(""); err == nil {
		t.Fatal("expected error for empty client id")
	}
	if _, err := st.PurgeClient("   "); err == nil {
		t.Fatal("expected error for whitespace client id")
	}
}
