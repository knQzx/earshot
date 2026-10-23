import Foundation

public enum PolicyGroup: String, CaseIterable, Sendable {
    case git, release, destructive, packages, network, secrets, files

    public var title: String {
        switch self {
        case .git: return "Git"
        case .release: return "Release & deploy"
        case .destructive: return "Destructive"
        case .packages: return "Packages"
        case .network: return "Network"
        case .secrets: return "Secrets"
        case .files: return "Files"
        }
    }
}

public struct CatalogRule: Sendable, Identifiable {
    public let id: String
    public let group: PolicyGroup
    public let name: String
    public let detail: String
    public let defaultChoice: PolicyChoice
    public let when: [PolicyMatcher]

    public var choices: [PolicyChoice] { [.off, .ask, .block] }
}

public enum PolicyCatalog {
    static let cmd = #"^(?:\S*/)?"#
    static let git = cmd + #"git(?:\s+(?:-C\s+\S+|-c\s+\S+|--[\w-]+(?:=\S+)?|-[A-Za-z]+))*\s+"#
    static let fileTools = ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit", "Grep", "Glob", "LS"]
    static let editTools = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    static let secretPath = #"(?:/\.env(?!\.(?:example|sample|template)$)(?:\.[^/]*)?|/[^/]*\.pem|/[^/]*\.key|/id_(?:rsa|ed25519|ecdsa|dsa)[^/]*|/\.npmrc|/\.netrc|/\.pgpass|/\.ssh(?:/.*)?|/\.aws(?:/.*)?)$"#
    static let secretGlob = #"(?:^|/)(?:\.env(?!\.(?:example|sample|template)$)[^/]*|[^/]*\.pem|[^/]*\.key|id_(?:rsa|ed25519|ecdsa|dsa)[^/]*|\.npmrc|\.netrc|\.pgpass|\.ssh(?:/.*)?|\.aws(?:/.*)?)$"#
    static let secretWord = #"(?:\.env(?!\.(?:example|sample|template)\b)(?:\.[\w.-]+)?|[\w.-]*\.pem|[\w.-]*\.key|id_(?:rsa|ed25519|ecdsa|dsa)[\w.-]*|\.npmrc|\.netrc|\.pgpass|\.ssh(?:/[\w.-]*)?|\.aws(?:/credentials)?)"#
    static let settingsPath = #"(?:/Library/Application Support/Earshot(?:/|$)|/\.claude/settings[^/]*\.json$)"#
    static let settingsWord = #"(?:Application Support/Earshot|\.claude/settings[^/\s]*\.json)"#

    static func bash(_ command: String, words: [String], script: String? = nil, outside: Bool? = nil, reason: String? = nil) -> PolicyMatcher {
        PolicyMatcher(tools: ["Bash"], command: command, script: script, outsideProject: outside, reason: reason, words: words)
    }

    public static let rules: [CatalogRule] = [
        CatalogRule(id: "git-push", group: .git, name: "git push", detail: "Any push to a remote",
                    defaultChoice: .ask, when: [bash(git + #"push\b"#, words: ["git"])]),
        CatalogRule(id: "git-commit", group: .git, name: "git commit", detail: "Creating commits",
                    defaultChoice: .off, when: [bash(git + #"commit\b"#, words: ["git"])]),
        CatalogRule(id: "git-force-push", group: .git, name: "Force push", detail: "--force, --force-with-lease and +branch pushes",
                    defaultChoice: .ask, when: [bash(git + #"push\b.*\s(?:--force(?:-with-lease|-if-includes)?(?:=\S+)?|-[A-Za-z]*f[A-Za-z]*|\+\S+)(?:\s|$)"#, words: ["git"])]),
        CatalogRule(id: "git-reset-hard", group: .git, name: "git reset --hard", detail: "Throws away uncommitted work",
                    defaultChoice: .off, when: [bash(git + #"reset\b.*\s--hard\b"#, words: ["git"])]),
        CatalogRule(id: "git-delete-branch", group: .git, name: "Delete branches", detail: "git branch -D and git push --delete",
                    defaultChoice: .off, when: [
                        bash(git + #"branch\b.*\s-[A-Za-z]*D[A-Za-z]*(?:\s|$)"#, words: ["git"]),
                        bash(git + #"branch\b.*\s--delete\b.*\s--force\b|"# + git + #"branch\b.*\s--force\b.*\s--delete\b"#, words: ["git"]),
                        bash(git + #"push\b.*\s(?:--delete|-d)(?:\s|$)"#, words: ["git"]),
                        bash(git + #"push\b.*\s:\S+"#, words: ["git"]),
                    ]),
        CatalogRule(id: "git-rebase", group: .git, name: "git rebase", detail: "Rewriting history",
                    defaultChoice: .off, when: [bash(git + #"rebase\b"#, words: ["git"])]),
        CatalogRule(id: "git-clean", group: .git, name: "git clean -f", detail: "Deletes untracked files",
                    defaultChoice: .off, when: [bash(git + #"clean\b.*\s-[A-Za-z]*f"#, words: ["git"])]),

        CatalogRule(id: "publish-packages", group: .release, name: "Publish packages", detail: "npm, pnpm, yarn and bun publish",
                    defaultChoice: .off, when: [bash(cmd + #"(?:npm|pnpm|yarn|bun)(?:\s+-\S+)*\s+(?:npm\s+)?publish\b"#, words: ["npm", "pnpm", "yarn", "bun"])]),
        CatalogRule(id: "push-images", group: .release, name: "Push images", detail: "docker push, podman push, buildx --push",
                    defaultChoice: .off, when: [
                        bash(cmd + #"(?:docker|podman)(?:\s+image)?\s+push\b"#, words: ["docker", "podman"]),
                        bash(cmd + #"(?:docker|podman)\s+buildx\s+build\b.*\s--push\b"#, words: ["docker", "podman"]),
                    ]),
        CatalogRule(id: "kubectl", group: .release, name: "kubectl apply and delete", detail: "Changes to a Kubernetes cluster",
                    defaultChoice: .off, when: [bash(cmd + #"kubectl(?:\s+-\S+(?:\s+[^-\s]\S*)?)*\s+(?:apply|delete)\b"#, words: ["kubectl"])]),
        CatalogRule(id: "terraform", group: .release, name: "terraform apply and destroy", detail: "Also OpenTofu",
                    defaultChoice: .off, when: [bash(cmd + #"(?:terraform|tofu)(?:\s+-\S+)*\s+(?:apply|destroy)\b"#, words: ["terraform", "tofu"])]),
        CatalogRule(id: "helm", group: .release, name: "helm install and upgrade", detail: "Releases to a cluster",
                    defaultChoice: .off, when: [bash(cmd + #"helm(?:\s+-\S+(?:\s+[^-\s]\S*)?)*\s+(?:install|upgrade)\b"#, words: ["helm"])]),
        CatalogRule(id: "gh-release", group: .release, name: "Merge PRs and create releases", detail: "gh pr merge, gh release create",
                    defaultChoice: .off, when: [bash(cmd + #"gh\s+(?:pr\s+merge|release\s+create)\b"#, words: ["gh"])]),
        CatalogRule(id: "deploy", group: .release, name: "Deploy", detail: "fly deploy, vercel --prod",
                    defaultChoice: .off, when: [
                        bash(cmd + #"(?:fly|flyctl)\s+deploy\b"#, words: ["fly", "flyctl"]),
                        bash(cmd + #"vercel\b.*\s--prod\b"#, words: ["vercel"]),
                    ]),

        CatalogRule(id: "rm-outside", group: .destructive, name: "Recursive delete outside the project", detail: "rm -r on other folders, /, ~ or $HOME",
                    defaultChoice: .off, when: [bash(cmd + #"rm\b.*\s(?:-[A-Za-z]*[rR][A-Za-z]*|--recursive)(?:\s|$)"#, words: ["rm"], outside: true)]),
        CatalogRule(id: "sudo", group: .destructive, name: "sudo", detail: "Anything run as root",
                    defaultChoice: .off, when: [bash(#"^(?:\S*/)?(?:sudo|doas)\b"#, words: ["sudo", "doas"])]),
        CatalogRule(id: "sql-destructive", group: .destructive, name: "Destructive SQL", detail: "DROP, TRUNCATE, DELETE without WHERE in psql, mysql, sqlite3",
                    defaultChoice: .off, when: [bash(
                        cmd + #"(?:psql|mysql|mariadb|sqlite3|duckdb|clickhouse-client)\b"#,
                        words: ["psql", "mysql", "mariadb", "sqlite3", "duckdb"],
                        script: #"\bdrop\s+(?:table|database|schema)\b|\btruncate\b|\bdelete\s+from\b(?![^;]*\bwhere\b)"#)]),
        CatalogRule(id: "chmod-outside", group: .destructive, name: "Recursive chmod or chown outside the project", detail: "chmod -R, chown -R, chgrp -R",
                    defaultChoice: .off, when: [bash(cmd + #"(?:chmod|chown|chgrp)\b.*\s-[A-Za-z]*R"#, words: ["chmod", "chown", "chgrp"], outside: true)]),

        CatalogRule(id: "install-node", group: .packages, name: "npm, pnpm, yarn, bun", detail: "Adding a package",
                    defaultChoice: .off, when: [bash(cmd + #"(?:npm|pnpm|yarn|bun)(?:\s+-\S+)*\s+(?:add|install|i|in)\s+(?:-\S+\s+)*[^-\s]"#, words: ["npm", "pnpm", "yarn", "bun"])]),
        CatalogRule(id: "install-python", group: .packages, name: "pip, uv, poetry", detail: "pip install, uv add, poetry add",
                    defaultChoice: .off, when: [bash(cmd + #"(?:pip3?|python3?\s+-m\s+pip|uv(?:\s+pip)?|poetry|pipx)\s+(?:add|install)\b"#, words: ["pip", "pip3", "uv", "poetry", "pipx"])]),
        CatalogRule(id: "install-brew", group: .packages, name: "Homebrew", detail: "brew install",
                    defaultChoice: .off, when: [bash(cmd + #"brew\s+(?:install|reinstall|tap)\b"#, words: ["brew"])]),
        CatalogRule(id: "install-cargo", group: .packages, name: "Cargo", detail: "cargo add, cargo install",
                    defaultChoice: .off, when: [bash(cmd + #"cargo\s+(?:add|install)\b"#, words: ["cargo"])]),
        CatalogRule(id: "install-go", group: .packages, name: "Go", detail: "go install, go get",
                    defaultChoice: .off, when: [bash(cmd + #"go\s+(?:install|get)\b"#, words: ["go"])]),

        CatalogRule(id: "http-remote", group: .network, name: "HTTP requests", detail: "curl, wget, httpie to anything but localhost",
                    defaultChoice: .off, when: [bash(cmd + #"(?:curl|wget|http|https|xh)\b(?!.*(?:localhost|127\.0\.0\.1|\[::1\]|0\.0\.0\.0))"#, words: ["curl", "wget", "xh"])]),
        CatalogRule(id: "copy-remote", group: .network, name: "Copy to other machines", detail: "scp, sftp, rsync to a remote",
                    defaultChoice: .off, when: [
                        bash(cmd + #"(?:scp|sftp)\b"#, words: ["scp", "sftp"]),
                        bash(cmd + #"rsync\b.*\s[^\s/-][^\s/]*:"#, words: ["rsync"]),
                    ]),
        CatalogRule(id: "ssh", group: .network, name: "ssh", detail: "Remote shells",
                    defaultChoice: .off, when: [bash(cmd + #"(?:ssh|mosh)\b(?!-)"#, words: ["ssh", "mosh"])]),

        CatalogRule(id: "secrets", group: .secrets, name: "Secret files", detail: ".env, keys, ~/.ssh, cloud and registry credentials",
                    defaultChoice: .off, when: [
                        PolicyMatcher(tools: fileTools, path: secretPath),
                        PolicyMatcher(tools: ["Glob", "Grep"], input: secretGlob),
                        bash(cmd + #"(?:cat|less|more|head|tail|grep|egrep|fgrep|rg|ag|bat|strings|xxd|hexdump|od|base64|source|\.|cp|mv|scp|rsync|tar|zip|ditto|openssl)\b.*(?:^|[\s/=])"# + secretWord + #"(?:$|[\s/])"#,
                             words: [".env", ".ssh", "id_rsa", "id_ed25519", ".aws", ".npmrc", ".netrc", ".pgpass"]),
                    ]),

        CatalogRule(id: "outside-edits", group: .files, name: "Edits outside the project", detail: "Writing files beyond the session folder",
                    defaultChoice: .off, when: [PolicyMatcher(tools: editTools, outsideProject: true)]),
        CatalogRule(id: "agent-settings", group: .files, name: "Earshot and Claude settings", detail: "Changes to the Earshot policy and Claude Code settings files",
                    defaultChoice: .ask, when: [
                        PolicyMatcher(tools: editTools, path: settingsPath),
                        bash(cmd + #"(?:rm|mv|cp|tee|ln|install|truncate|dd|sed|perl|chmod|chown|touch|unlink|shred|rsync|ditto|python3?|node|ruby|jq|sponge|plutil|vim?|nano|ed)\b.*"# + settingsWord,
                             words: ["Earshot", ".claude"]),
                        PolicyMatcher(tools: ["Bash"], redirect: settingsWord, words: ["Earshot", ".claude"]),
                    ]),
    ]

    public static func rule(_ id: String) -> CatalogRule? {
        rules.first { $0.id == id }
    }

    public static func rules(in group: PolicyGroup) -> [CatalogRule] {
        rules.filter { $0.group == group }
    }

    public static var defaults: Policy {
        Policy(catalog: Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0.defaultChoice) }))
    }

    static let legacy: [String: [String]] = [
        "git-push": ["git-push"],
        "publish": ["publish-packages", "push-images", "kubectl", "terraform", "helm", "gh-release", "deploy"],
        "destructive": ["rm-outside", "sudo", "sql-destructive", "git-reset-hard", "git-clean"],
        "outside-edits": ["outside-edits"],
        "read-only": [],
        "tests": [],
    ]

    static func migrate(v1 rules: [PolicyRule]) -> Policy {
        var p = defaults
        for r in rules {
            guard let ids = legacy[r.id] else {
                p.rules.append(r)
                continue
            }
            for id in ids {
                guard let c = rule(id) else { continue }
                p.catalog[id] = r.enabled ? (c.defaultChoice == .off ? .ask : c.defaultChoice) : .off
            }
        }
        return p
    }
}
