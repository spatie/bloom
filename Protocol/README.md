# Bloom protocol files

Start with [the server protocol guide](../docs/SERVER-PROTOCOL.md).

- `bloom-v14.schema.json`: JSON Schema draft 2020-12 for envelopes, all method/action names and portable payloads.
- `generate-schema.py`: regenerates the schema and checks version, method inventories and argument names against the Swift source.
- `vectors-v14.json`: checked-in output from production Swift encoding, with synthetic identifiers/data.
- `verify.py`: validates vectors encoded by the production Swift Codable types.
- `examples/bloom_client.py`: read-only SSH/HTTPS Python client with strict host/TLS verification.
- `examples/test_bloom_client.py`: framing, negotiation and credential-boundary regressions.

`BloomWire.version` is the authoritative version. The standalone example mirrors that version and
is checked by the generator. `DomainRecord` marks application records whose full field-level
schemas have not been extracted yet. Do not mistake that permissive definition for complete DTO
code generation support; the guide links their exact source definitions.

The scripts run locally and do not deploy a server. Schema verification requires the Python
`jsonschema` package; the example client and its unit tests require only the standard library.
The SSH example uses POSIX nonblocking pipes and a locally installed OpenSSH client.

Version 13 schema and vectors remain checked in for existing clients. Version 14 adds the leased UI bridge.
