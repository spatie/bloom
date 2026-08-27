import SwiftUI
import BloomCore

/// The Servers pane: the machines Bloom can reach over SSH, and what each of them has on it.
///
/// **Deliberately plain, and deliberately read-mostly.** There are two things a person does here,
/// adding a server and looking at one, and everything else on the screen is a fact that came back
/// from a probe. Every decision behind those facts is in the core with tests over it: what the
/// Add field will accept is `SSHDestination.parse`, what a probe means is `ServerProbe.parse` and
/// `ServerVerdict`, whether the daemon needs copying is `Bloomd.decide`. This file chooses fonts.
///
/// **Nothing here says anything about the user's key**, because Bloom does not have one. It shells
/// out to the `ssh` they already use, which reads their config, their agent, their jump hosts and
/// their hardware key. A pane with a "paste your private key" field would be a worse product and a
/// much worse idea, and the absence of one is the feature.
///
/// The tool list is a `SetupReport`, the same value the welcome window draws for this Mac, so the
/// two screens cannot drift apart about what "ready" means.
struct ServerSettingsView: View {
    @Environment(AppModel.self) private var app

    @State private var model: ServersModel?
    @State private var draft = ""
    @State private var isAdding = false
    /// The server a second press would remove. Two presses rather than a sheet, which is what the
    /// Approvals pane settled on for the same shape of action: cheap to redo, and a modal over a
    /// list of four rows is worse than the mistake it prevents.
    @State private var confirmingRemoval: ServerID?

    var body: some View {
        Form {
            if let model {
                listSection(model)
                addSection(model)

                if let server = model.selected {
                    detailSection(model, server)
                    toolsSection(model, server)
                    machineSection(model, server)
                    daemonSection(model, server)
                }
            } else {
                Section {
                    LoadingView("Opening")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, Metrics.gutter)
                }
            }
        }
        .settingsForm()
        .task {
            guard model == nil, let store = app.store else { return }
            let fresh = ServersModel(store: store)
            await fresh.load()
            model = fresh
        }
    }

    // MARK: - The list

    @ViewBuilder
    private func listSection(_ model: ServersModel) -> some View {
        Section {
            if model.servers.isEmpty {
                Text("None yet.")
                    .foregroundStyle(Palette.textSecondary)
            }
            ForEach(model.servers) { server in
                row(model, server)
            }
        } header: {
            Text("Servers")
        } footer: {
            if model.servers.isEmpty {
                Text(
                    "Bloom talks to a server through the ssh you already use, so whatever is in "
                    + "your ~/.ssh/config already applies. It never asks for a key and never "
                    + "stores one."
                )
                .settingsFootnote()
            }
        }
    }

    private func row(_ model: ServersModel, _ server: Server) -> some View {
        let isSelected = model.selection == server.id
        return HStack(spacing: Metrics.gutter) {
            ServerDot(state: server.state)

            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                Text(server.label)
                    .font(Typo.bodyEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                Text(server.destination.display)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Metrics.gutter)

            if model.busy.contains(server.id) {
                ProgressView().controlSize(.small)
            } else {
                Text(server.state.title)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .contentShape(.rect)
        .onTapGesture { model.selection = server.id }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Palette.selected : Color.clear)
    }

    // MARK: - Adding

    @ViewBuilder
    private func addSection(_ model: ServersModel) -> some View {
        Section {
            SettingsRow("Add") {
                HStack(spacing: Metrics.gutter) {
                    TextField("user@host", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submit(model) }
                        .disabled(isAdding)

                    Button("Add") { submit(model) }
                        .disabled(isAdding || draft.trimmingCharacters(in: .whitespaces).isEmpty)

                    if isAdding { ProgressView().controlSize(.small) }
                }
            }

            if let problem = model.addProblem {
                ErrorBanner(title: "Could not add that", message: problem) {
                    model.dismissAddProblem()
                }
            }
        } footer: {
            // A port, an alias out of the config, and a bare host are all valid, so the hint says
            // so rather than implying one shape.
            Text("A destination as ssh takes it: host, user@host, or user@host:port. An alias from your ~/.ssh/config works too.")
                .settingsFootnote()
        }
    }

    private func submit(_ model: ServersModel) {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !isAdding else { return }
        isAdding = true
        Task {
            await model.add(text)
            if model.addProblem == nil { draft = "" }
            isAdding = false
        }
    }

    // MARK: - One server

    @ViewBuilder
    private func detailSection(_ model: ServersModel, _ server: Server) -> some View {
        Section(server.label) {
            SettingsRow("State") {
                VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                    HStack(spacing: Metrics.spacing) {
                        ServerDot(state: server.state)
                        Text(server.state.title)
                            .font(Typo.bodyEmphasis)
                    }
                    if !server.detail.isEmpty {
                        Text(server.detail)
                            .font(Typo.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .settingsRowBaseline()
            }

            SettingsRow("Last checked") {
                Text(lastChecked(server))
                    .foregroundStyle(Palette.textSecondary)
            }

            SettingsRow("Name") {
                ServerNameField(label: server.label) { name in
                    Task { await model.rename(server.id, to: name) }
                }
            }

            HStack(spacing: Metrics.gutter) {
                Button(model.busy.contains(server.id) ? "Checking" : "Check now") {
                    Task { await model.check(server.id) }
                }
                .disabled(model.busy.contains(server.id))

                Spacer()

                if confirmingRemoval == server.id {
                    Button("Remove", role: .destructive) {
                        confirmingRemoval = nil
                        Task { await model.remove(server.id) }
                    }
                    .controlSize(.small)
                    Button("Cancel") { confirmingRemoval = nil }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                } else {
                    Button("Remove") { confirmingRemoval = server.id }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
    }

    /// The tool list, drawn off the same `SetupReport` the welcome window uses for this Mac, with
    /// the two tools that matter only on a server beside it.
    @ViewBuilder
    private func toolsSection(_ model: ServersModel, _ server: Server) -> some View {
        if let facts = model.facts[server.id] {
            Section {
                ForEach(ServerTool.displayOrder) { tool in
                    toolRow(tool, facts: facts)
                }
            } header: {
                Text("What it has")
            } footer: {
                if facts.findings.contains(where: \.needsPathHelp) {
                    // The day-one problem, said out loud rather than papered over. A tool only the
                    // widened PATH could find is a tool that anything else shelling out to that
                    // name on that server will not find either.
                    Text(
                        "Some of these are not on the PATH a plain ssh command gets, so Bloom "
                        + "looks in the places node version managers use. Anything else you run "
                        + "over ssh on that server will need the same help."
                    )
                    .settingsFootnote()
                }
            }
        }
    }

    private func toolRow(_ tool: ServerTool, facts: ServerFacts) -> some View {
        let finding = facts.finding(for: tool)
        let state = finding?.state ?? .missing
        return SettingsRow(tool.title) {
            VStack(alignment: .leading, spacing: Metrics.spacingTight) {
                HStack(spacing: Metrics.spacing) {
                    Image(systemName: glyph(state))
                        .foregroundStyle(tint(state))
                        .font(Typo.caption)
                    Text(summary(state))
                        .font(Typo.label)
                        .foregroundStyle(Palette.textPrimary)
                    if finding?.needsPathHelp == true {
                        Chip(text: "off PATH")
                    }
                }
                if let path = state.path {
                    Text(path)
                        .font(Typo.codeTiny)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }
            .settingsRowBaseline()
        }
    }

    @ViewBuilder
    private func machineSection(_ model: ServersModel, _ server: Server) -> some View {
        if let facts = model.facts[server.id] {
            Section("Machine") {
                SettingsRow("System", value: facts.osName.isEmpty ? facts.system : facts.osName)
                SettingsRow("Architecture", value: facts.architecture)
                SettingsRow("Disk") {
                    Text("\(facts.diskSummary) on \(facts.diskMount)")
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func daemonSection(_ model: ServersModel, _ server: Server) -> some View {
        Section {
            SettingsRow("On the server", value: server.bloomdVersion ?? "Not installed")
            SettingsRow("This build ships", value: ServersModel.shippingBloomdVersion ?? "Nothing")
            if let action = model.actions[server.id] {
                SettingsRow("Last check") {
                    Text(actionSentence(action))
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("bloomd")
        } footer: {
            Text(
                "bloomd is one readable Python file. Bloom copies it to ~/.bloom/bin on the "
                + "server when the version there is not the version it ships, and answers the "
                + "several git questions a diff pass asks in one round trip instead of six."
            )
            .settingsFootnote()
        }
    }

    // MARK: - Words

    private func lastChecked(_ server: Server) -> String {
        guard let moment = server.probedAt else { return "Never" }
        return moment.formatted(date: .abbreviated, time: .shortened)
    }

    private func actionSentence(_ action: BloomdAction) -> String {
        switch action {
        case .upToDate(let version): "Already on version \(version), so nothing was copied."
        case .install(let reason, let version): "Copied version \(version), because \(reason.sentence)."
        case .impossible: "Nothing to run it with."
        }
    }

    private func summary(_ state: ServerToolState) -> String {
        switch state {
        case .missing: "Not installed"
        case .present(_, let version): version ?? "Installed"
        case .broken(_, let detail): detail
        }
    }

    private func glyph(_ state: ServerToolState) -> String {
        switch state {
        case .missing: "circle.dashed"
        case .present: "checkmark.circle.fill"
        case .broken: "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ state: ServerToolState) -> Color {
        switch state {
        case .missing: Palette.textTertiary
        case .present: Palette.positive
        case .broken: Palette.warning
        }
    }
}

/// The state mark, the same disc the sidebar and the Agents pane use.
private struct ServerDot: View {
    let state: ServerState

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: Metrics.dot, height: Metrics.dot)
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch state {
        case .ready: Palette.positive
        case .incomplete: Palette.warning
        case .unreachable: Palette.negative
        case .unknown, .probing: Palette.textTertiary
        }
    }
}

/// A field that edits a server's name and commits on blur or return.
///
/// Its own small type because the draft has to live somewhere that survives the parent redrawing
/// on every store change, and because committing on every keystroke would write a row per letter
/// into a table a probe is also writing to.
private struct ServerNameField: View {
    let label: String
    let commit: (String) -> Void

    @State private var draft = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .focused($isEditing)
            .onAppear { draft = label }
            .onChange(of: label) { _, new in
                // The row changed underneath, from a rename made elsewhere. Do not stamp on
                // something somebody is in the middle of typing.
                if !isEditing { draft = new }
            }
            .onSubmit { commit(draft) }
            .onChange(of: isEditing) { _, editing in
                if !editing, draft != label { commit(draft) }
            }
    }
}
