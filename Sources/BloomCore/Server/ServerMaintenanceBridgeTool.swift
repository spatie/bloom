import Foundation

/// Wrap the call boundary, including standard tools that write directly to Store. Tool schemas
/// and role checks remain those of the original handler; admission belongs to the runtime.
struct ServerMaintenanceBridgeTool: BridgeToolHandling {
    let wrapped: any BridgeToolHandling
    let perform: @Sendable (MCPRequest, BridgeIdentity, Store) async -> BridgeToolResult
    var tool: BridgeTool { wrapped.tool }
    var roles: Set<BridgeRole> { wrapped.roles }

    func call(_ request: MCPRequest, as identity: BridgeIdentity, store: Store) async -> BridgeToolResult {
        await perform(request, identity, store)
    }
}
