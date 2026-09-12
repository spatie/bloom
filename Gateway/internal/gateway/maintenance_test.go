package gateway

import (
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"testing"
)

// RuntimeSocket names the supervisor on managed installations. Gateway control access and
// the separately checked maintenance credential are both required; preview tokens cannot pass.
func TestMaintenancePreservesIntentBehindControlAuthentication(t *testing.T) {
	f := newFixture(t)
	count := runtimeFixture(t, f, func(connection net.Conn, request rpcRequest) {
		var payload struct {
			Value struct {
				Action     string `json:"action"`
				Credential string `json:"credential"`
				PlanID     string `json:"planID"`
				Mode       string `json:"mode"`
			} `json:"_0"`
		}
		if err := json.Unmarshal(request.Operation["maintenance"], &payload); err != nil {
			t.Error("maintenance payload was not preserved")
			return
		}
		if payload.Value.Action != "start" || payload.Value.Credential != "fixture-maintenance-key" ||
			payload.Value.PlanID != "reviewed-plan" || payload.Value.Mode != "whenIdle" {
			t.Error("maintenance intent changed in transit")
		}
		json.NewEncoder(connection).Encode(map[string]any{
			"version": request.Version, "id": request.ID,
			"result": map[string]any{"maintenance": map[string]any{"_0": map[string]any{
				"authorized": true, "components": []any{}, "jobs": []any{},
			}}},
		})
	})
	body := `{"version":14,"id":"00000000-0000-4000-8000-000000000001","operation":{"maintenance":{"_0":{"action":"start","credential":"fixture-maintenance-key","planID":"reviewed-plan","mode":"whenIdle"}}}}`
	for _, token := range []string{"", f.token(t, "workspace-a", nil), f.token(t, "control", map[string]any{"scope": "bloom:read"})} {
		response := f.request("POST", f.config.APIHost, "/v1/rpc", token, "", body)
		if response.Code != http.StatusUnauthorized || count.Load() != 0 {
			t.Fatal("a maintenance credential bypassed gateway control authentication")
		}
	}
	for range 2 {
		response := f.request("POST", f.config.APIHost, "/v1/rpc", f.token(t, "control", nil), "", body)
		if response.Code != http.StatusOK || response.Header().Get("Cache-Control") != "no-store" ||
			!strings.Contains(response.Body.String(), "00000000-0000-4000-8000-000000000001") {
			t.Fatal("maintenance retry lost its identity or cache protection")
		}
	}
	if count.Load() != 2 {
		t.Fatal("the supervisor must receive repeated identities to reconcile durable acceptance")
	}
}
