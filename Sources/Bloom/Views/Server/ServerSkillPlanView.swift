import SwiftUI
import BloomClient

struct ServerSkillPlanView: View {
    let plan: ServerSkillsPlan
    let session: ServerSkillsSession
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var focused: String?
    @State private var agents = Set(ServerSkillAgent.allCases)

    init(plan: ServerSkillsPlan, session: ServerSkillsSession) {
        self.plan = plan; self.session = session
        _selected = State(initialValue: Set(plan.skills.map(\.name)))
        _focused = State(initialValue: plan.skills.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.gutter) {
            Text("Review skills before installing").font(Typo.heading)
            if let repository = plan.repositoryURL { Text(repository).font(Typo.caption).textSelection(.enabled) }
            if let commit = plan.commit { Text("Pinned commit: " + commit).font(Typo.codeSmall).textSelection(.enabled) }
            Text("Skills can include instructions and scripts. Review their source and choose which agents may use them.").settingsFootnote()
            HSplitView {
                List(selection: $focused) {
                    ForEach(plan.skills) { skill in
                        Toggle(skill.name, isOn: Binding(get: { selected.contains(skill.name) }, set: {
                            if $0 { selected.insert(skill.name) } else { selected.remove(skill.name) }
                        })).toggleStyle(.checkbox).tag(skill.id)
                    }
                }.frame(minWidth: 150, idealWidth: 190, maxWidth: 230)
                if let skill = plan.skills.first(where: { $0.id == focused }) {
                    VStack(alignment: .leading, spacing: Metrics.spacing) {
                        Text(skill.description).settingsFootnote()
                        ServerSkillContentView(skill: skill, session: session, plan: plan)
                    }.padding(.leading, Metrics.spacing).frame(minWidth: 300)
                }
            }
            HStack {
                Text("Available to").font(Typo.caption)
                ForEach(ServerSkillAgent.allCases, id: \.self) { agent in
                    Toggle(agent.rawValue.capitalized, isOn: Binding(get: { agents.contains(agent) }, set: {
                        if $0 { agents.insert(agent) } else { agents.remove(agent) }
                    })).toggleStyle(.checkbox)
                }
            }
            if agents.isEmpty { Text("The skills will be installed disabled.").settingsFootnote() }
            ForEach(plan.warnings, id: \.self) { Text($0).foregroundStyle(Palette.warning).font(Typo.caption).textSelection(.enabled) }
            if let error = session.error { Text(error).foregroundStyle(Palette.warning).textSelection(.enabled) }
            HStack {
                Button("Cancel") { session.discardPlan(); dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(session.activity == .applying)
                Text("Review expires " + plan.expiresAt.formatted(date: .omitted, time: .shortened)).settingsFootnote()
                Spacer()
                if session.activity == .applying { ProgressView().controlSize(.small) }
                Button("Install \(selected.count) \(selected.count == 1 ? "Skill" : "Skills")") {
                    Task {
                        if await session.apply(planID: plan.id, selectedSkillNames: selected.sorted(),
                                               agents: ServerSkillAgent.allCases.filter { agents.contains($0) }) { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).tint(Palette.controlAccent)
                    .disabled(!session.canMutate || selected.isEmpty || plan.expiresAt <= Date())
            }
        }.padding(24).frame(width: 760, height: 650)
            .interactiveDismissDisabled(session.activity == .applying)
    }
}
