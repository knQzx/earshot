import AppKit
import EarshotCore
import SwiftUI

@MainActor
final class PolicySettings: ObservableObject {
    let url: URL?
    @Published private(set) var policy = PolicyStore.defaults
    @Published private(set) var broken = false
    @Published private(set) var problem: String?

    init(url: URL?) {
        self.url = url
        reload()
    }

    func reload() {
        guard let url else { return }
        let load = PolicyStore.effective(at: url)
        policy = load.policy
        broken = load.unreadable
        problem = load.problem
    }

    func choice(_ id: String) -> Binding<PolicyChoice> {
        Binding(
            get: { self.policy.choice(id) },
            set: { c in self.change { $0.catalog[id] = c } })
    }

    func action(_ ruleID: String) -> Binding<PolicyAction> {
        Binding(
            get: { self.policy.rules.first { $0.id == ruleID }?.action ?? .ask },
            set: { a in self.change { p in
                if let i = p.rules.firstIndex(where: { $0.id == ruleID }) { p.rules[i].action = a }
            } })
    }

    var customRules: [PolicyRule] { policy.rules }

    func add(name: String, pattern: String, tools: [String], action: PolicyAction) {
        let rule = PolicyRule(name: name, action: action, pattern: pattern, tools: tools == ["Bash"] ? nil : tools)
        change { $0.rules.append(rule) }
    }

    func update(_ rule: PolicyRule) {
        change { p in
            if let i = p.rules.firstIndex(where: { $0.id == rule.id }) { p.rules[i] = rule }
        }
    }

    func ruleChoice(_ ruleID: String) -> Binding<PolicyChoice> {
        Binding(
            get: {
                guard let r = self.policy.rules.first(where: { $0.id == ruleID }), r.enabled else { return .off }
                switch r.action {
                case .ask: return .ask
                case .deny: return .block
                }
            },
            set: { c in self.change { p in
                guard let i = p.rules.firstIndex(where: { $0.id == ruleID }) else { return }
                p.rules[i].enabled = c != .off
                if let a = c.action { p.rules[i].action = a }
            } })
    }

    static func patterns(in text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("regex:") { return [t] }
        return t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func problem(in text: String) -> String? {
        let list = patterns(in: text)
        if list.isEmpty { return "Type a command, for example docker compose down*" }
        for p in list where PolicyRule.regex(fromPattern: p) == nil {
            return "This regex does not compile: \(p.dropFirst(6))"
        }
        return nil
    }

    func addCommands(_ text: String, action: PolicyAction) {
        let list = Self.patterns(in: text)
        change { p in
            for pattern in list where !p.rules.contains(where: { $0.pattern == pattern && $0.tools == nil }) {
                p.rules.append(PolicyRule(name: pattern, action: action, pattern: pattern))
            }
        }
    }

    func delete(_ ruleID: String) {
        change { $0.rules.removeAll { $0.id == ruleID } }
    }

    func resetToDefaults() {
        guard let url else {
            policy = PolicyStore.defaults
            return
        }
        try? PolicyStore.save(PolicyStore.defaults, to: url)
        reload()
    }

    private func change(_ body: (inout Policy) -> Void) {
        guard let url else {
            body(&policy)
            return
        }
        guard let p = try? PolicyStore.update(at: url, body) else {
            reload()
            return
        }
        policy = p
        broken = false
        problem = nil
    }

    func openFile() {
        guard let url else { return }
        _ = try? PolicyStore.ensureDefaults(at: url)
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

struct PolicyView: View {
    @ObservedObject var policy: PolicySettings
    @State private var adding = false
    @State private var editing: PolicyRule?
    @State private var confirmReset = false

    var body: some View {
        Form {
            if let problem = policy.problem {
                Section {
                    Label(policy.broken ? problem + ". Fix it or reset to defaults." : problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                NewRuleRow(policy: policy, more: { adding = true })
                ForEach(policy.customRules) { rule in
                    CustomRuleRow(rule: rule, choice: policy.ruleChoice(rule.id), detail: Self.describe(rule),
                                  edit: { editing = rule }, delete: { policy.delete(rule.id) })
                }
            } header: {
                Text("Your rules")
            } footer: {
                Text("* matches anything. Each part of a chained command is checked, so git push* also catches cd app && git push. Separate several commands with commas.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(policy.broken)
            ForEach(PolicyGroup.allCases, id: \.self) { group in
                Section {
                    ForEach(PolicyCatalog.rules(in: group)) { rule in
                        LabeledContent {
                            Picker(rule.name, selection: policy.choice(rule.id)) {
                                ForEach(rule.choices, id: \.self) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        } label: {
                            RuleLabel(name: rule.name, detail: rule.detail)
                        }
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if group == .git {
                        Text("Earshot works on top of Claude Code's own permissions, also in auto mode. Ask waits for you in the notch, Block refuses at once.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .disabled(policy.broken)
            }
            Section {
                HStack {
                    Button("Reset to Defaults…") { confirmReset = true }
                    Spacer()
                    Button("Edit policy.json…") { policy.openFile() }
                        .disabled(policy.url == nil)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) {
            AddRuleSheet { name, pattern, tools, action in
                policy.add(name: name, pattern: pattern, tools: tools, action: action)
            }
        }
        .sheet(item: $editing) { rule in
            AddRuleSheet(rule: rule) { name, pattern, tools, action in
                var r = rule
                r.name = name
                r.pattern = pattern
                r.tools = tools == ["Bash"] ? nil : tools
                r.action = action
                policy.update(r)
            }
        }
        .confirmationDialog("Reset the policy to the defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { policy.resetToDefaults() }
        } message: {
            Text("Every switch goes back to its default and custom rules are removed.")
        }
    }

    static func describe(_ r: PolicyRule) -> String {
        let scope = (r.tools ?? ["Bash"]).joined(separator: ", ")
        if let p = r.pattern, r.name != p { return scope == "Bash" ? p : "\(scope): \(p)" }
        if r.pattern != nil { return scope == "Bash" ? "Shell command" : scope }
        return "\(scope) · edited in policy.json"
    }
}

private struct RuleLabel: View {
    var name: String
    var detail: String
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(detail)
                .font(mono ? .system(.caption, design: .monospaced) : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

private struct AddRuleSheet: View {
    var rule: PolicyRule?
    var add: (String, String, [String], PolicyAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pattern = ""
    @State private var scope = Scope.bash
    @State private var action = PolicyAction.ask

    init(rule: PolicyRule? = nil, add: @escaping (String, String, [String], PolicyAction) -> Void) {
        self.rule = rule
        self.add = add
        _name = State(initialValue: rule?.name ?? "")
        _pattern = State(initialValue: rule?.pattern ?? "")
        _scope = State(initialValue: Scope.allCases.first { $0.tools == (rule?.tools ?? ["Bash"]) } ?? .bash)
        _action = State(initialValue: rule?.action ?? .ask)
    }

    enum Scope: String, CaseIterable, Identifiable {
        case bash, edits, reads, web, mcp, any
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bash: return "Shell commands"
            case .edits: return "File edits"
            case .reads: return "File reads"
            case .web: return "Web fetches"
            case .mcp: return "MCP tools"
            case .any: return "Any tool"
            }
        }
        var tools: [String] {
            switch self {
            case .bash: return ["Bash"]
            case .edits: return ["Edit", "Write", "MultiEdit", "NotebookEdit"]
            case .reads: return ["Read", "Grep", "Glob"]
            case .web: return ["WebFetch"]
            case .mcp: return ["mcp__*"]
            case .any: return ["*"]
            }
        }
        var hint: String {
            switch self {
            case .bash: return "git push*, docker compose down*"
            case .edits, .reads: return "*/migrations/*, *.lock"
            case .web: return "https://*.example.com/*"
            case .mcp: return "*\"database\"*"
            case .any: return "*"
            }
        }
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && PolicyRule.regex(fromPattern: pattern) != nil
            && !pattern.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $name, prompt: Text("Docker teardown"))
                Picker("Applies to", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.title).tag($0) }
                }
                TextField("Pattern", text: $pattern, prompt: Text(scope.hint))
                    .font(.system(.body, design: .monospaced))
                Picker("Action", selection: $action) {
                    Text("Ask").tag(PolicyAction.ask)
                    Text("Block").tag(PolicyAction.deny)
                }
                .pickerStyle(.segmented)
                Text("* matches anything. Shell patterns are checked against every part of a chained command. Start with regex: to write a regular expression.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(rule == nil ? "Add Rule" : "Save") {
                    add(name.trimmingCharacters(in: .whitespaces), pattern.trimmingCharacters(in: .whitespaces), scope.tools, action)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
    }
}

private struct NewRuleRow: View {
    @ObservedObject var policy: PolicySettings
    var more: () -> Void
    @State private var text = ""
    @State private var action = PolicyAction.ask
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("New rule", text: $text, prompt: Text("Add a command, e.g. docker compose down*"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(submit)
                    .onChange(of: text) { _, _ in error = nil }
                Picker("Action", selection: $action) {
                    Text("Ask").tag(PolicyAction.ask)
                    Text("Block").tag(PolicyAction.deny)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Menu {
                    Button("More options…", action: more)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func submit() {
        if let problem = PolicySettings.problem(in: text) {
            error = problem
            return
        }
        policy.addCommands(text, action: action)
        text = ""
        error = nil
    }
}

private struct CustomRuleRow: View {
    var rule: PolicyRule
    var choice: Binding<PolicyChoice>
    var detail: String
    var edit: () -> Void
    var delete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(rule.name == rule.pattern ? .system(.body, design: .monospaced) : .body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(rule.name == rule.pattern ? .caption : .system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .opacity(rule.enabled ? 1 : 0.5)
            Spacer(minLength: 8)
            Button(action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete rule")
            .opacity(hover ? 1 : 0)
            Picker(rule.name, selection: choice) {
                Text("Off").tag(PolicyChoice.off)
                Text("Ask").tag(PolicyChoice.ask)
                Text("Block").tag(PolicyChoice.block)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Delete", role: .destructive, action: delete)
        }
    }
}
