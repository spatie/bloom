// A loopback-only application for checking that the complete OAuth proxy chain carries
// browser WebSockets while withholding the proxy's own credentials from the application.
package main

import (
	"github.com/gorilla/websocket"
	"log"
	"net/http"
	"strings"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" || r.Header.Get("X-Forwarded-Access-Token") != "" || strings.Contains(r.Header.Get("Cookie"), "__Host-bloom-preview") {
			http.Error(w, "Authentication credential leaked to preview", 500)
			return
		}
		if r.URL.Path == "/socket" {
			connection, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
			if err != nil {
				return
			}
			defer connection.Close()
			for {
				kind, data, err := connection.ReadMessage()
				if err != nil {
					return
				}
				if err = connection.WriteMessage(kind, data); err != nil {
					return
				}
			}
		}
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte(`<!doctype html><html><title>Bloom private preview</title><h1>Private preview works</h1><p>Signed in through Keycloak and OAuth2 Proxy. Agent credentials were stripped.</p><button id="connect">Test live connection</button><p id="result">Not connected</p><script>
 document.getElementById('connect').onclick=()=>{
 const socket=new WebSocket('wss://'+location.host+'/socket');window.previewSocket=socket;
 socket.onopen=()=>socket.send('Bloom live preview verified');
 socket.onmessage=event=>document.getElementById('result').textContent=event.data;
 socket.onclose=()=>document.getElementById('result').textContent='Connection closed';
 };
 </script></html>`))
	})
	log.Fatal(http.ListenAndServe("127.0.0.1:18123", nil))
}
