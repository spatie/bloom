import BloomCore
import Foundation

// The stdio MCP server Bloom registers with an agent CLI, and a line relay to the app over a unix
// domain socket. Everything it does is `BridgeShim`, in BloomCore, because `Tools/test-core.sh`
// mirrors only BloomCore into the package it tests: an executable target is invisible to the
// suite, so a file with any decision in it would be a file nothing could reach. This one has none.

exit(await BridgeShim.run())
