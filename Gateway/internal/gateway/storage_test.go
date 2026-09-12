package gateway

import (
	"encoding/json"
	"net"
	"net/http"
	"testing"
)

func TestStorageRequiresTheExistingOwnerControlAccess(t *testing.T) {
	f := newFixture(t)
	count := runtimeFixture(t, f, func(connection net.Conn, request rpcRequest) {
		json.NewEncoder(connection).Encode(map[string]any{"version": protocolVersion, "id": request.ID, "result": map[string]any{"accepted": map[string]any{}}})
	})
	for _, operation := range []string{`{"storage":{}}`, `{"cleanupStorage":{"targets":["buildCache","unusedImages"]}}`} {
		body := `{"version":14,"id":"00000000-0000-4000-8000-000000000001","operation":` + operation + `}`
		before := count.Load()
		for _, token := range []string{
			"",
			f.token(t, "control", map[string]any{"scope": "bloom:read"}),
			f.token(t, "control", map[string]any{"email": "someone-else@example.com"}),
			f.token(t, "workspace-a", nil),
		} {
			if response := f.request("POST", f.config.APIHost, "/v1/rpc", token, "", body); response.Code != http.StatusUnauthorized {
				t.Fatalf("storage access: got %d", response.Code)
			}
		}
		if count.Load() != before {
			t.Fatal("refused storage request reached the runtime")
		}
		response := f.request("POST", f.config.APIHost, "/v1/rpc", f.token(t, "control", nil), "", body)
		if response.Code != http.StatusOK || count.Load() != before+1 {
			t.Fatalf("authorised storage request: status=%d forwarded=%d", response.Code, count.Load()-before)
		}
	}
}
