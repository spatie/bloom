package gateway

import (
	"os"
	"regexp"
	"strconv"
	"testing"
)

func TestProtocolMatchesSwiftRuntime(t *testing.T) {
	source, err := os.ReadFile("../../../Packages/BloomClient/Sources/BloomClient/RemoteCommand.swift")
	if err != nil {
		t.Fatal(err)
	}
	match := regexp.MustCompile(`version = ([0-9]+)`).FindSubmatch(source)
	if len(match) != 2 {
		t.Fatal("Swift protocol version not found")
	}
	version, err := strconv.Atoi(string(match[1]))
	if err != nil || version != protocolVersion {
		t.Fatalf("gateway protocol %d differs from Swift %s", protocolVersion, match[1])
	}
}
