package httpserver

import (
	"compress/gzip"
	"embed"
	"encoding/json"
	"html/template"
	"io"
	"log"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/lifedever/pastememo/sync-server/internal/config"
	"github.com/lifedever/pastememo/sync-server/internal/model"
	"github.com/lifedever/pastememo/sync-server/internal/store"
)

//go:embed web/*
var webFS embed.FS

type Server struct {
	cfg   config.Config
	store *store.Store
	mux   *http.ServeMux
}

func New(cfg config.Config, st *store.Store) *Server {
	s := &Server{cfg: cfg, store: st, mux: http.NewServeMux()}
	s.routes()
	return s
}

func (s *Server) Handler() http.Handler {
	return s.mux
}

func (s *Server) routes() {
	s.mux.HandleFunc("GET /healthz", s.handleHealthz)
	s.mux.Handle("POST /api/v1/sync", s.authMiddleware(s.compressMiddleware(http.HandlerFunc(s.handleSync))))
	s.mux.Handle("GET /api/v1/pull", s.authMiddleware(s.compressMiddleware(http.HandlerFunc(s.handlePullItems))))
	s.mux.Handle("GET /api/v1/trash", s.authMiddleware(s.compressMiddleware(http.HandlerFunc(s.handleListTrash))))
	s.mux.Handle("DELETE /api/v1/clients/{clientID}/items", s.authMiddleware(http.HandlerFunc(s.handleDeleteClientItems)))
	s.mux.HandleFunc("GET /api/v1/clients", s.compressMiddleware(s.handleListClientsJSON))
	s.mux.HandleFunc("GET /api/v1/types", s.compressMiddleware(s.handleListTypes))
	s.mux.HandleFunc("GET /api/v1/items", s.compressMiddleware(s.handleListItems))
	s.mux.HandleFunc("DELETE /api/v1/items/{clientID}/{itemID}", s.handleDeleteItem)
	s.mux.HandleFunc("POST /api/v1/items/{clientID}/{itemID}/restore", s.handleRestoreItem)
	s.mux.HandleFunc("DELETE /api/v1/clients/{clientID}/trash", s.handlePurgeClientTrash)
	s.mux.HandleFunc("DELETE /api/v1/clients/{clientID}", s.handlePurgeClient)
	s.mux.HandleFunc("GET /api/v1/items/{clientID}/{itemID}/image", s.handleGetItemImage)
	s.mux.HandleFunc("GET /api/v1/items/{clientID}/{itemID}", s.compressMiddleware(s.handleGetItem))
	s.mux.HandleFunc("GET /favicon.ico", s.handleFavicon)
	s.mux.HandleFunc("GET /", s.handleDashboard)
}

func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(auth, prefix) || strings.TrimSpace(auth[len(prefix):]) != s.cfg.Token {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// compressMiddleware adds gzip compression for JSON responses when client supports it
func (s *Server) compressMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
			next(w, r)
			return
		}
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Add("Vary", "Accept-Encoding")
		gz, err := gzip.NewWriterLevel(w, gzip.BestSpeed)
		if err != nil {
			next(w, r)
			return
		}
		defer gz.Close()
		cw := &compressResponseWriter{ResponseWriter: w, Writer: gz}
		next(cw, r)
	}
}

type compressResponseWriter struct {
	http.ResponseWriter
	Writer io.Writer
}

func (cw *compressResponseWriter) Write(b []byte) (int, error) {
	return cw.Writer.Write(b)
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func (s *Server) handleFavicon(w http.ResponseWriter, _ *http.Request) {
	data, err := webFS.ReadFile("web/favicon.ico")
	if err != nil {
		http.NotFound(w, nil)
		return
	}
	w.Header().Set("Content-Type", "image/x-icon")
	w.Header().Set("Cache-Control", "public, max-age=86400")
	_, _ = w.Write(data)
}

func (s *Server) handleSync(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 512<<20))
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	if len(body) == 512<<20 {
		http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
		return
	}

	var req model.SyncRequest
	if err := json.Unmarshal(body, &req); err != nil {
		log.Printf("sync json error: %v (body bytes=%d)", err, len(body))
		http.Error(w, "invalid json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if len(req.Items) == 0 {
		http.Error(w, "items required", http.StatusBadRequest)
		return
	}

	now := time.Now().UTC()
	result, err := s.store.IngestSync(req, clientIP(r, s.cfg.TrustProxy), now)
	if err != nil {
		log.Printf("sync ingest error: %v", err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(model.SyncResponse{
		AcceptedCount: result.Accepted,
		DedupedCount:  result.Deduped,
		ServerTime:    now.Format(time.RFC3339Nano),
	})
}

type dashboardClient struct {
	ClientID          string
	LastIP            string
	LastHostname      string
	LastSyncAt        string
	LastSyncCount     int
	TotalSyncCount    int
	ItemCount         int
	EncryptionEnabled bool
	EncryptionSalt    string
	EncryptionKeyFP   string
}

func (s *Server) handleDashboard(w http.ResponseWriter, _ *http.Request) {
	clients, err := s.store.ListClients()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	rows := make([]dashboardClient, 0, len(clients))
	for _, c := range clients {
		itemCount, _ := s.store.ItemCount(c.ClientID)
		rows = append(rows, dashboardClient{
			ClientID:          c.ClientID,
			LastIP:            c.LastIP,
			LastHostname:      c.LastHostname,
			LastSyncAt:        formatDisplayTime(c.LastSyncAt),
			LastSyncCount:     c.LastSyncCount,
			TotalSyncCount:    c.TotalSyncCount,
			ItemCount:         itemCount,
			EncryptionEnabled: c.EncryptionEnabled,
			EncryptionSalt:    c.EncryptionSalt,
			EncryptionKeyFP:   c.EncryptionKeyFP,
		})
	}

	tmpl, err := template.ParseFS(webFS, "web/index.html")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
	_ = tmpl.Execute(w, map[string]any{
		"Clients": rows,
		"Now":     formatDisplayTime(time.Now().UTC()),
	})
}

func clientIP(r *http.Request, trustProxy bool) string {
	if trustProxy {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			if len(parts) > 0 {
				return strings.TrimSpace(parts[0])
			}
		}
		if xri := strings.TrimSpace(r.Header.Get("X-Real-IP")); xri != "" {
			return xri
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func formatDisplayTime(t time.Time) string {
	if t.IsZero() {
		return "—"
	}
	return t.UTC().Format("2006-01-02 15:04:05 UTC")
}
