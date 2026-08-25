import Foundation

/// The four tools over the owner's quick prompts: `quick_prompt_list`, `quick_prompt_create`,
/// `quick_prompt_update` and `quick_prompt_delete`.
///
/// All four in one file for the reason `ProjectHideTool` holds its pair: they are one feature seen
/// from four sides, they share the reading of a mark, the resolving of an id and the JSON a prompt
/// is rendered as, and the way a set like this goes wrong is one of them learning something the
/// others do not. Read side by side, that cannot happen quietly.
///
/// ## Four, because three would be unusable
///
/// `quick_prompt_update` and `quick_prompt_delete` both take an id, and an id is not a thing a
/// model can guess or a person would ever type. Without a list there is nothing to update or
/// delete by, so the read is not a convenience, it is what makes the other three reachable.
///
/// ## No seam into the app, and why that is not an oversight
///
/// The pane tools and `workspace_merge` are injected closures because a pane is a thing the window
/// owns and a merge has to take the same path the Merge button takes. A quick prompt is a row in
/// `quick_prompt`, and `Store` is an actor a bridge handler on a background task calls directly.
/// So these four live in `BridgeToolbox.standard`, are testable without a window, and the window
/// finds out the way it finds out about every other write: `Store`'s update hook publishes the
/// `quickPrompts` domain and `QuickPromptCatalog` re-reads. An injected main-actor closure here
/// would have been a second way to write the same row.
///
/// ## Why every one of them reads through `seedQuickPrompts`
///
/// The panel seeds Bloom's built-ins the first time it is opened, not at launch, so on a copy of
/// Bloom whose composer panel has never been opened the table is genuinely empty. A tool reading
/// `quickPrompts()` there would report an empty library, an agent asked to add "Explain changes"
/// would write a second copy of a prompt Bloom is about to insert, and the owner would open the
/// panel to two of them. Seeding here costs one settings lookup on a database that has already
/// been seeded, and it means the tools and the panel always describe the same list.
enum QuickPromptCall {
    /// The library as the panel would show it, seeding the built-ins if this database has never
    /// been asked before. See the note at the head of this file.
    static func library(_ store: Store) async throws -> [QuickPrompt] {
        try await store.seedQuickPrompts()
    }

    /// A create's three arguments, once they have been found to make sense.
    struct Draft: Sendable, Equatable {
        var name: String
        var symbol: String
        var text: String
    }

    /// An update's three optional arguments. A field that is nil was not named and keeps the value
    /// the row already holds; that is the whole of the partial semantics and it is why these are
    /// optionals rather than a `QuickPrompt` with the gaps filled in from somewhere.
    struct Edit: Sendable, Equatable {
        var name: String?
        var symbol: String?
        var text: String?

        /// The fields this call names, for the answer. A model that cannot tell a change that
        /// landed from one that was ignored will make the same call again.
        var changed: [String] {
            var fields: [String] = []
            if name != nil { fields.append("name") }
            if symbol != nil { fields.append("symbol") }
            if text != nil { fields.append("text") }
            return fields
        }
    }

    /// Reads the arguments `quick_prompt_create` takes.
    ///
    /// Pure and static so the suite can hold every refusal without a database: what a model is
    /// told when it passes a blank prompt is a sentence somebody has to be able to read back.
    ///
    /// **It accepts exactly what the panel's own form accepts**, which is the rule the three
    /// fields' different treatments of "empty" all come from. The form disables Save on a blank
    /// text and trims the name and saves it even when it is empty, because a nameless prompt shows
    /// the start of its text instead. So a blank text is refused here, a blank name is a name
    /// cleared, and a blank symbol is Bloom's default rather than a hole down the left of the row.
    static func draft(name: String?, symbol: String?, text: String?) -> Result<Draft, QuickPromptTrouble> {
        let body = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .failure(.noText) }

        let chosenMark: String
        switch mark(symbol) {
        case .failure(let trouble): return .failure(trouble)
        case .success(let resolved): chosenMark = resolved ?? QuickPrompt.defaultSymbol
        }

        return .success(
            Draft(
                name: (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                symbol: chosenMark,
                text: body
            )
        )
    }

    /// Reads the arguments `quick_prompt_update` takes.
    ///
    /// A call that names no field at all is refused rather than answered with "nothing changed",
    /// because the two calls a model makes after those two answers are different: one is a fixed
    /// call, the other is the same call again.
    static func edit(name: String?, symbol: String?, text: String?) -> Result<Edit, QuickPromptTrouble> {
        var edit = Edit()

        if let name {
            // Not guarded on emptiness: `""` clears the name, and the row falls back to showing
            // the start of its text, which is a state the panel's own form can produce.
            edit.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let text {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return .failure(.blankText(field: "text")) }
            edit.text = body
        }

        switch mark(symbol) {
        case .failure(let trouble): return .failure(trouble)
        case .success(let resolved): edit.symbol = resolved
        }

        guard !edit.changed.isEmpty else { return .failure(.nothingToChange) }
        return .success(edit)
    }

    /// What goes in the `symbol` column, or nil when the caller named none.
    ///
    /// Refused rather than stored, and that is the decision worth recording. `QuickPromptMark`
    /// deliberately falls back to a default for anything it cannot draw, because a row written
    /// years ago must still draw something. Letting a tool through that same fallback would store
    /// the model's guess and draw something else, with nothing said to the caller, so the row the
    /// owner sees would not be the row the model believes it wrote.
    static func mark(_ symbol: String?) -> Result<String?, QuickPromptTrouble> {
        guard let symbol else { return .success(nil) }
        let trimmed = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        // Blank is "I have no mark to give" rather than a mark, and is treated as though the
        // argument had been left out. There is nothing a blank column could mean: every row draws
        // something.
        guard !trimmed.isEmpty else { return .success(nil) }
        guard QuickPromptMark(stored: trimmed).stored == trimmed else {
            return .failure(.unknownSymbol(trimmed))
        }
        return .success(trimmed)
    }

    /// The prompt an id names, or why none does.
    ///
    /// By id and never by name, unlike the project tools, which resolve a name, a path or an id.
    /// Two quick prompts may be called the same thing, nothing about a prompt is unique except its
    /// id, and the two tools that take one overwrite and delete. A near miss on a name there is
    /// the wrong prompt destroyed rather than a wrong list printed.
    static func find(
        id raw: String?, in prompts: [QuickPrompt], tool: String
    ) -> Result<QuickPrompt, QuickPromptTrouble> {
        let id = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return .failure(.noID(tool: tool)) }
        guard !prompts.isEmpty else { return .failure(.emptyLibrary(tool: tool)) }
        guard let found = prompts.first(where: { $0.id.rawValue == id }) else {
            return .failure(.unknownID(id: id, known: prompts))
        }
        return .success(found)
    }

    /// One prompt, whole. The text is not truncated: a model asked to change a prompt has to be
    /// able to read the one it is changing, and the preview the panel draws is not the prompt.
    static func json(_ prompt: QuickPrompt) -> JSONValue {
        .object([
            "id": .string(prompt.id.rawValue),
            "name": .string(prompt.name),
            "shown_as": .string(prompt.resolvedName),
            "symbol": .string(prompt.symbol),
            "text": .string(prompt.text),
            "sort_order": .integer(prompt.sortOrder),
            "created_at": .string(prompt.createdAt.formatted(.iso8601)),
        ])
    }

    /// The one sentence every tool that changes the library ends on. Written once, because four
    /// descriptions of where these rows live is four chances to describe it differently.
    static let panelSentence =
        "Quick prompts are global: one library, in the panel beside the composer in every "
            + "workspace, rather than anything belonging to a project or a workspace."
}

/// `quick_prompt_list`: the owner's library, and the ids the other three take.
///
/// **Self-approved, and the only one of the four that is.** `BridgeToolApproval`'s test is whether
/// a tool has to work while nobody is watching, and this one is offered to `.parent`, which is an
/// agent that runs for ten minutes on its own. A permission question on a call that reads is the
/// worst kind of ask: there is nothing for a person to weigh, and an unanswered one hangs the turn.
///
/// The one thing it can write is Bloom's own built-in, on a database whose panel has never been
/// opened, which is exactly what opening the panel would have done. See the head of
/// `QuickPromptCall`.
public struct QuickPromptListTool: BridgeToolHandling {
    public init() {}

    /// A parent and the owner's own client.
    ///
    /// The pane tools were taken away from `.owner` because they are scoped to a worktree the
    /// owner's client is not standing in. The opposite holds here: a quick prompt belongs to no
    /// workspace and no project, so there is nothing for this caller to be missing, and it is the
    /// owner's own library that is being read.
    ///
    /// `.parent` because an agent asked to save a prompt has to be able to see the ones that are
    /// already there, and because a parent that could create without reading would write a second
    /// copy of a prompt the owner already has.
    ///
    /// Not `.child`. A child sees `whoami` and nothing else, because it is an agent another agent
    /// asked for and nobody weighed.
    public let roles: Set<BridgeRole> = [.parent, .owner]

    public let tool = BridgeTool(
        name: "quick_prompt_list",
        description: """
            The owner's quick prompts: the few lines they keep typing again, kept by Bloom and put \
            back into the composer from the panel beside it. Each one carries its id, its name, \
            the mark drawn down the left of its row, and the whole of its text.

            Call this before quick_prompt_update or quick_prompt_delete, because the id it prints \
            is the only thing either of those takes. It is also what stops you writing a second \
            copy of a prompt the owner already has.

            \(QuickPromptCall.panelSentence)

            It reads. The only thing it can ever write is Bloom's own built-in prompt, on a copy \
            of Bloom whose quick prompt panel has never been opened, which is what opening the \
            panel would have done anyway.
            """,
        inputSchema: BridgeTool.noArguments
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        do {
            let prompts = try await QuickPromptCall.library(store)
            return .json(.object([
                "count": .integer(prompts.count),
                "prompts": .array(prompts.map(QuickPromptCall.json)),
                "note": .string(
                    prompts.isEmpty
                        ? "Bloom has no quick prompts. quick_prompt_create writes one."
                        : QuickPromptCall.panelSentence
                ),
            ]))
        } catch {
            return .failure(
                QuickPromptTrouble.unexplained(
                    tool: tool.name, message: error.readableMessage
                ).sentence
            )
        }
    }
}

/// `quick_prompt_create`: write a prompt into the owner's library.
///
/// **Not self-approved, although it destroys nothing.** A pane an agent opens appears in front of
/// the reader and is closed with the shortcut every other tab uses, which is what earned those
/// four their place on `BridgeToolApproval.selfApproved`. A quick prompt is written into a list
/// that is only ever seen when the panel is opened, so a row nobody asked for is invisible until
/// the owner goes looking, and the library is a thing they curate. That is worth one ask.
///
/// The cost of the ask is the documented one: a call made while nobody is watching hangs the turn.
/// It is accepted here because this tool is only ever called on the owner's own instruction, in
/// the chat they just typed it in, which the description says out loud. `workspace_start` is the
/// opposite case and is on the list for exactly that reason.
public struct QuickPromptCreateTool: BridgeToolHandling {
    public init() {}

    /// A parent and the owner's own client, matching `quick_prompt_list`.
    ///
    /// `.parent` is the case worth defending. The owner mostly talks to Bloom from inside Bloom,
    /// so "save that as a quick prompt" is a sentence typed into a workspace chat, and a tool the
    /// owner cannot reach from where they are is a tool that does not exist. Creating adds a row
    /// and changes nothing that is there, and the panel it lands in is one click away in the same
    /// composer.
    public let roles: Set<BridgeRole> = [.parent, .owner]

    public let tool = BridgeTool(
        name: "quick_prompt_create",
        description: """
            Write a new quick prompt into the owner's library, so it is in the panel beside the \
            composer from then on.

            Call it when the owner asks you to save something as a quick prompt, and not on your \
            own initiative. This is their own list in their own words, and a row they did not ask \
            for is one they have to find and delete.

            'text' is the prompt itself and is required: it is what goes into the composer when \
            the row is picked. 'name' is what the row is called and is optional; leave it out and \
            the row shows the start of the text instead. 'symbol' is the mark down the left of \
            the row: one emoji, or an SF Symbol name Bloom's own picker offers. Leave it out for \
            Bloom's default.

            \(QuickPromptCall.panelSentence)

            It adds a row and changes nothing that is already there. The owner takes it away again \
            from the panel, or you can with quick_prompt_delete.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "text": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The words the prompt puts in the composer. It cannot be blank."
                    ),
                ]),
                "name": .object([
                    "type": .string("string"),
                    "description": .string(
                        "What the row is called. Leave it out to show the start of the text."
                    ),
                ]),
                "symbol": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The mark down the left of the row: one emoji, or an SF Symbol name from "
                            + "Bloom's picker. Leave it out for Bloom's default."
                    ),
                ]),
            ]),
            "required": .array([.string("text")]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        let draft: QuickPromptCall.Draft
        switch QuickPromptCall.draft(
            name: request.stringParam("name"),
            symbol: request.stringParam("symbol"),
            text: request.stringParam("text")
        ) {
        case .failure(let trouble): return .failure(trouble.sentence)
        case .success(let read): draft = read
        }

        do {
            // Seeded first, so a prompt written into a database whose panel has never been opened
            // does not sit above Bloom's own built-in when the panel finally inserts it.
            _ = try await QuickPromptCall.library(store)
            let written = try await store.insert(
                QuickPrompt(name: draft.name, symbol: draft.symbol, text: draft.text)
            )
            var answer = QuickPromptCall.json(written)
            if case .object(var fields) = answer {
                fields["note"] = .string(
                    "It is in the quick prompt panel in every workspace's composer now. Nothing "
                        + "else changed. quick_prompt_delete removes it again, and there is no "
                        + "undo on that."
                )
                answer = .object(fields)
            }
            return .json(answer)
        } catch {
            return .failure(
                QuickPromptTrouble.unexplained(
                    tool: tool.name, message: error.readableMessage
                ).sentence
            )
        }
    }
}

/// `quick_prompt_update`: change a prompt the owner already has, field by field.
///
/// **Owner only, and not self-approved.** This overwrites text somebody wrote by hand, in a
/// library that belongs to no workspace, and Bloom keeps no copy of what was there before. Two
/// things follow from that.
///
/// It is not offered to `.parent`, although listing and creating are, and the difference is who is
/// in the room. A parent is a workspace agent that runs for ten minutes at a time with nobody
/// looking, and a global overwrite decided in the middle of one of those is a change the owner
/// finds weeks later in a project this workspace has nothing to do with. The owner's own client is
/// a conversation the owner is typing into, which is also why the ask below is answerable.
///
/// It is not on `BridgeToolApproval.selfApproved`, for the reason `workspace_merge` is not: the
/// list is for calls where there is nothing left for a person to weigh, and here there is. The
/// owner is sitting at the client that can call this, exactly as they are for the project tools.
public struct QuickPromptUpdateTool: BridgeToolHandling {
    public init() {}

    public let roles: Set<BridgeRole> = [.owner]

    public let tool = BridgeTool(
        name: "quick_prompt_update",
        description: """
            Change a quick prompt the owner already has, named by the id quick_prompt_list prints.

            Partial, so pass only what you are changing. 'name', 'symbol' and 'text' are each \
            optional and whatever you leave out keeps the value it already has: changing the name \
            is a call with 'id' and 'name' and nothing else, and it does not touch the text. \
            Passing 'name' as an empty string clears the name, and the row goes back to showing \
            the start of its text. 'text' cannot be blank, because a prompt with no words in it \
            inserts nothing. A call that names no field at all is refused rather than treated as \
            a change of nothing.

            There is no undo. What you overwrite was written by hand and Bloom keeps no copy of \
            it, so read the prompt with quick_prompt_list first and change what the owner asked \
            you to change and nothing else.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("Which prompt, by the id quick_prompt_list prints."),
                ]),
                "name": .object([
                    "type": .string("string"),
                    "description": .string(
                        "A new name for the row. Leave it out to keep the one it has; pass an "
                            + "empty string to clear it."
                    ),
                ]),
                "symbol": .object([
                    "type": .string("string"),
                    "description": .string(
                        "A new mark: one emoji, or an SF Symbol name from Bloom's picker. Leave "
                            + "it out to keep the one it has."
                    ),
                ]),
                "text": .object([
                    "type": .string("string"),
                    "description": .string(
                        "New words for the composer. Leave it out to keep the ones it has. It "
                            + "cannot be blank."
                    ),
                ]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        let edit: QuickPromptCall.Edit
        switch QuickPromptCall.edit(
            name: request.stringParam("name"),
            symbol: request.stringParam("symbol"),
            text: request.stringParam("text")
        ) {
        case .failure(let trouble): return .failure(trouble.sentence)
        case .success(let read): edit = read
        }

        do {
            let prompts = try await QuickPromptCall.library(store)
            let target: QuickPrompt
            switch QuickPromptCall.find(
                id: request.stringParam("id"), in: prompts, tool: tool.name
            ) {
            case .failure(let trouble): return .failure(trouble.sentence)
            case .success(let found): target = found
            }

            // Through `update` rather than by writing the row back, which is `Store`'s own rule
            // and is what makes the partial semantics real: the row is re-read inside the actor
            // and only the fields this call named are assigned, so a field left out keeps
            // whatever the panel's own form wrote a second ago.
            let changed = try await store.update(quickPromptID: target.id) { prompt in
                if let name = edit.name { prompt.name = name }
                if let symbol = edit.symbol { prompt.symbol = symbol }
                if let text = edit.text { prompt.text = text }
            }
            guard let changed else {
                return .failure(
                    QuickPromptTrouble.unknownID(id: target.id.rawValue, known: prompts).sentence
                )
            }

            var answer = QuickPromptCall.json(changed)
            if case .object(var fields) = answer {
                fields["changed"] = .array(edit.changed.map { .string($0) })
                fields["note"] = .string(
                    "The prompt above is the whole row as it stands now. Anything not in "
                        + "'changed' is untouched, and there is no undo on what was."
                )
                answer = .object(fields)
            }
            return .json(answer)
        } catch {
            return .failure(
                QuickPromptTrouble.unexplained(
                    tool: tool.name, message: error.readableMessage
                ).sentence
            )
        }
    }
}

/// `quick_prompt_delete`: take a prompt out of the library for good.
///
/// **Owner only, and not self-approved**, for the reasons `quick_prompt_update` gives at more
/// length and one of its own. `BridgeRole.owner` may not do "anything that destroys work, because
/// the whole reason Bloom asks before archiving is that the answer is sometimes no and there is
/// nobody on this connection to ask", and this is the closest thing on the bridge to that clause.
/// It is allowed, and here is the whole of why:
///
/// 1. **There is somebody to ask.** The role is the owner at a client they started themselves, and
///    the tool is off `selfApproved`, so the call stops and asks a person who is sitting there.
///    That is the same argument the project tools are held to.
/// 2. **The answer carries the prompt back.** A worktree cannot be handed to a model in a tool
///    result; a quick prompt is a name, a mark and a few lines, and all three are in the answer.
///    `quick_prompt_create` writes it back verbatim, which is an undo that costs one call.
///
/// **Deleting a built-in behaves exactly as deleting one in the window does**, because it is the
/// same call: `Store.deleteQuickPrompt`. Nothing here writes `QuickPromptSeed.versionKey`, and
/// seeding compares that recorded version rather than the rows, so a built-in deleted through this
/// tool is not seen as missing and no later launch and no later build puts it back. See
/// `QuickPromptSeed` and `Store.seedQuickPrompts`.
public struct QuickPromptDeleteTool: BridgeToolHandling {
    public init() {}

    public let roles: Set<BridgeRole> = [.owner]

    public let tool = BridgeTool(
        name: "quick_prompt_delete",
        description: """
            Remove a quick prompt from the owner's library, named by the id quick_prompt_list \
            prints.

            There is no undo and Bloom keeps no copy. The answer repeats the whole prompt, its \
            name, its mark and its text, so quick_prompt_create can write it back if this turns \
            out to have been the wrong one. That is the only way back.

            Deleting one of Bloom's own built-in prompts is a deletion like any other: it stays \
            deleted, and no later launch and no later version of Bloom puts it back.

            Only call this when the owner has said to delete that prompt. Never as tidying up, and \
            never on a prompt you did not just read.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Which prompt to delete, by the id quick_prompt_list prints."
                    ),
                ]),
            ]),
            "required": .array([.string("id")]),
        ])
    )

    public func call(
        _ request: MCPRequest,
        as identity: BridgeIdentity,
        store: Store
    ) async -> BridgeToolResult {
        do {
            let prompts = try await QuickPromptCall.library(store)
            let target: QuickPrompt
            switch QuickPromptCall.find(
                id: request.stringParam("id"), in: prompts, tool: tool.name
            ) {
            case .failure(let trouble): return .failure(trouble.sentence)
            case .success(let found): target = found
            }

            try await store.deleteQuickPrompt(id: target.id)

            var answer = QuickPromptCall.json(target)
            if case .object(var fields) = answer {
                fields["deleted"] = .bool(true)
                fields["remaining"] = .integer(prompts.count - 1)
                fields["note"] = .string(
                    "That prompt is gone from the panel and there is no undo. The whole of it is "
                        + "above: quick_prompt_create writes it back if this was the wrong one. "
                        + "If it was one Bloom shipped with, it stays deleted and no later "
                        + "version puts it back."
                )
                answer = .object(fields)
            }
            return .json(answer)
        } catch {
            return .failure(
                QuickPromptTrouble.unexplained(
                    tool: tool.name, message: error.readableMessage
                ).sentence
            )
        }
    }
}
