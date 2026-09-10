package gateway

// Keep in step with BloomWire.version. The contract test checks the Swift source.
const protocolVersion = 14

func supportedProtocol(version int) bool {
	return version == 12 || version == 13 || version == protocolVersion
}
