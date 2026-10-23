import XCTest
@testable import EarshotCore

final class ShellCommandTests: XCTestCase {
    func parts(_ s: String) -> [String] { ShellCommand.split(s).map(\.normalized) }

    func testChainsSplit() {
        XCTAssertEqual(parts("a && b || c; d | e & f"), ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(parts("a\nb |& c"), ["a", "b", "c"])
        XCTAssertEqual(parts("make 2>&1 | tee log"), ["make", "tee log"])
        XCTAssertEqual(ShellCommand.split("make 2>&1 | tee log").first?.raw, "make")
        XCTAssertEqual(ShellCommand.split("cmd &> out.txt").first?.redirects, ["out.txt"])
        XCTAssertEqual(parts("   "), [])
    }

    func testQuotesAndEscapes() {
        XCTAssertEqual(parts("echo 'a && b' && ls"), ["echo a && b", "ls"])
        XCTAssertEqual(parts(#"echo "x; y | z""#), ["echo x; y | z"])
        XCTAssertEqual(parts(#"echo a\;b"#), ["echo a;b"])
        XCTAssertEqual(parts("g\\it pu''sh \"x y\""), ["git push x y"])
        XCTAssertEqual(ShellCommand.split("rm -rf \"my dir\"").first?.words, ["rm", "-rf", "my dir"])
        XCTAssertEqual(parts("echo $'a\\tb\\x41\\'c'"), ["echo a\tbA'c"])
        XCTAssertEqual(parts("git \\\npush"), ["git push"])
        XCTAssertEqual(parts("git${IFS}push"), ["git push"])
        XCTAssertEqual(parts("ls # a 'quote\ngit status"), ["ls", "git status"])
    }

    func testSubstitutionsAndInnerScripts() {
        XCTAssertEqual(parts("echo $(git push) done"), ["echo $(…) done", "git push"])
        XCTAssertEqual(parts("echo `git push`"), ["echo `…`", "git push"])
        XCTAssertEqual(parts("echo \"$(a; b)\""), ["echo $(…)", "a", "b"])
        XCTAssertEqual(parts("bash -c 'a && b'"), ["bash -c a && b", "a", "b"])
        XCTAssertEqual(parts("/bin/sh -ec \"git push\""), ["/bin/sh -ec git push", "git push"])
        XCTAssertEqual(parts("eval git push"), ["eval git push", "git push"])
        XCTAssertEqual(parts("(cd a; make)"), ["cd a", "make"])
        XCTAssertEqual(parts("{ a; b; }"), ["a", "b"])
        XCTAssertEqual(parts("diff <(git show) x"), ["diff <(…) x", "git show"])
        XCTAssertEqual(parts("echo $((1 + 2))"), ["echo $((…))"])
        XCTAssertEqual(parts("cat <<EOF | sh\ngit push\nEOF\nls"), ["cat", "sh", "ls"])
        XCTAssertEqual(parts("sh <<'EOF'\ngit push\nEOF"), ["sh", "git push"])
    }

    func testPrefixesArePeeled() {
        let c = ShellCommand.split("FOO=1 BAR='x y' sudo -u root command time nohup nice -n 5 git push").first!
        XCTAssertEqual(c.normalized, "git push")
        XCTAssertEqual(c.forms.first, "FOO=1 BAR=x y sudo -u root command time nohup nice -n 5 git push")
        XCTAssertTrue(c.forms.contains("sudo -u root command time nohup nice -n 5 git push"))
        XCTAssertEqual(ShellCommand.split("env -i PATH=/bin git push").first?.normalized, "git push")
        XCTAssertEqual(ShellCommand.split("xargs -n 1 rm").first?.normalized, "rm")
        XCTAssertEqual(ShellCommand.split("! git push").first?.normalized, "git push")
        XCTAssertEqual(ShellCommand.split("FOO=bar").first?.normalized, "FOO=bar")
        XCTAssertEqual(ShellCommand.split("command -v git").first?.normalized, "command -v git")
        XCTAssertEqual(ShellCommand.split("git -C repo -c a=b --no-pager push -f").first?.normalized, "git push -f")
        XCTAssertEqual(ShellCommand.split("git -c alias.up=push up origin").first?.normalized, "git push origin")
    }

    func testOpaqueAndLimits() {
        XCTAssertTrue(ShellScript.parse("$(which git) push").opaque)
        XCTAssertTrue(ShellScript.parse("echo x | sh").opaque)
        XCTAssertTrue(ShellScript.parse("bash deploy.sh").opaque)
        XCTAssertTrue(ShellScript.parse("echo x | xargs rm").opaque)
        XCTAssertTrue(ShellScript.parse(". ./env.sh").opaque)
        XCTAssertFalse(ShellScript.parse("bash -c 'ls'").opaque)
        XCTAssertFalse(ShellScript.parse("echo $HOME && ls \"$PWD\"").opaque)
        XCTAssertTrue(ShellScript.parse(String(repeating: "x", count: ShellScript.maxBytes + 1)).tooBig)
        XCTAssertTrue(ShellScript.parse(String(repeating: "a;", count: 3000)).tooBig)
        XCTAssertTrue(ShellScript.parse(String(repeating: "bash -c '", count: 10)).opaque)
    }

    func testWords() {
        XCTAssertEqual(ShellCommand.words(#"rm -rf "my dir" 'x y' a\ b"#), ["rm", "-rf", "my dir", "x y", "a b"])
        XCTAssertEqual(ShellCommand.words(#"echo """#), ["echo", ""])
    }
}

final class CustomPatternTests: XCTestCase {
    func bash(_ cmd: String) -> PolicyInput {
        PolicyInput(tool: "Bash", input: .object(["command": .string(cmd)]), cwd: "/tmp/p", home: "/Users/x")
    }

    func policy(_ rules: PolicyRule...) -> Policy {
        var p = Policy()
        for r in PolicyCatalog.rules { p.catalog[r.id] = .off }
        p.rules = rules
        return p
    }

    func testWildcardPatternsAreAnchoredAndEscaped() {
        XCTAssertEqual(PolicyRule.regex(fromPattern: "git push*"), #"^(?:\S*/)?git\s+push.*$"#)
        let p = policy(PolicyRule(name: "a", action: .ask, pattern: "docker compose down*"))
        for c in ["docker compose down", "docker  compose down -v", "cd x && docker compose down", "/usr/local/bin/docker compose down"] {
            XCTAssertNotNil(p.evaluate(bash(c)), c)
        }
        for c in ["docker compose up", "echo docker compose down", "docker-compose down"] {
            XCTAssertNil(p.evaluate(bash(c)), c)
        }
        let dots = policy(PolicyRule(name: "b", action: .ask, pattern: "make a.b"))
        XCTAssertNotNil(dots.evaluate(bash("make a.b")))
        XCTAssertNil(dots.evaluate(bash("make axb")))
        XCTAssertNil(dots.evaluate(bash("make a.b c")))
        let meta = policy(PolicyRule(name: "c", action: .ask, pattern: "/p/a+b(1)[x]?{2}|^$.txt", tools: ["Edit"]))
        func edit(_ path: String) -> PolicyInput { PolicyInput(tool: "Edit", input: .object(["file_path": .string(path)]), cwd: "/p") }
        XCTAssertNotNil(meta.evaluate(edit("/p/a+b(1)[x]?{2}|^$.txt")))
        XCTAssertNil(meta.evaluate(edit("/p/aab1x.txt")))
        XCTAssertNil(meta.evaluate(edit("/p/a+b(1)[x]?{2}|^$.txt.bak")))
        let mid = policy(PolicyRule(name: "d", action: .ask, pattern: "*push*"))
        XCTAssertNotNil(mid.evaluate(bash("git push")))
        let start = policy(PolicyRule(name: "e", action: .ask, pattern: "push*"))
        XCTAssertNil(start.evaluate(bash("git push")))
    }

    func testRegexPrefix() {
        XCTAssertEqual(PolicyRule.regex(fromPattern: "regex:^ls\\b"), "^ls\\b")
        XCTAssertNil(PolicyRule.regex(fromPattern: "regex:("))
        let p = policy(PolicyRule(name: "r", action: .deny, pattern: "regex:^ls\\b"))
        XCTAssertEqual(p.evaluate(bash("cd a; ls -la"))?.action, .deny)
        XCTAssertNil(p.evaluate(bash("lsof")))
        XCTAssertTrue(PolicyRule(name: "bad", action: .ask, pattern: "regex:(").matchers.isEmpty)
        XCTAssertTrue(PolicyRule(name: "blank", action: .ask, pattern: "  ").matchers.isEmpty)
    }

    func testToolScopes() {
        let lock = PolicyRule(name: "locks", action: .ask, pattern: "*.lock", tools: ["Edit", "Write"])
        let p = policy(lock)
        XCTAssertNotNil(p.evaluate(PolicyInput(tool: "Edit", input: .object(["file_path": .string("/p/package.lock")]), cwd: "/p")))
        XCTAssertNil(p.evaluate(PolicyInput(tool: "Read", input: .object(["file_path": .string("/p/package.lock")]), cwd: "/p")))
        XCTAssertNil(p.evaluate(bash("cat package.lock")))
        let mcp = policy(PolicyRule(name: "db", action: .deny, pattern: "*\"database\"*", tools: ["mcp__*"]))
        let call = PolicyInput(tool: "mcp__pg__query", input: .object(["target": .string("database")]), cwd: "/p")
        XCTAssertEqual(mcp.evaluate(call)?.action, .deny)
        XCTAssertNil(mcp.evaluate(PolicyInput(tool: "WebFetch", input: .object(["target": .string("database")]), cwd: "/p")))
        let any = policy(PolicyRule(name: "all", action: .ask, tools: ["*"], when: [PolicyMatcher(tools: ["*"])]))
        XCTAssertNotNil(any.evaluate(PolicyInput(tool: "Whatever", input: .null, cwd: nil)))
        let web = policy(PolicyRule(name: "w", action: .ask, when: [PolicyMatcher(tools: ["WebFetch"], host: "example.com")]))
        XCTAssertNotNil(web.evaluate(PolicyInput(tool: "WebFetch", input: .object(["url": .string("https://api.Example.com/x")]), cwd: nil)))
        XCTAssertNil(web.evaluate(PolicyInput(tool: "WebFetch", input: .object(["url": .string("https://notexample.com/x")]), cwd: nil)))
    }

    func testEnabledFlagAndOffChoice() {
        var r = PolicyRule(name: "x", action: .deny, pattern: "ls*")
        r.enabled = false
        XCTAssertNil(policy(r).evaluate(bash("ls")))
        var p = PolicyCatalog.defaults
        p.catalog["git-push"] = .off
        XCTAssertNil(p.evaluate(bash("git push")))
        p.catalog["git-push"] = .block
        XCTAssertEqual(p.evaluate(bash("git push"))?.action, .deny)
    }
}

final class PolicyStoreTests: XCTestCase {
    var dir: URL!
    var url: URL { dir.appendingPathComponent("policy.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-store-\(UUID().uuidString)/Earshot")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    let v1 = """
    {"version": 1, "rules": [
      {"id": "git-push", "name": "git push", "enabled": false, "action": "ask", "when": []},
      {"id": "publish", "name": "Publish and deploy", "enabled": true, "action": "ask", "when": []},
      {"id": "destructive", "name": "Destructive commands", "enabled": true, "action": "ask", "when": []},
      {"id": "outside-edits", "name": "Edits outside the project", "enabled": false, "action": "ask", "when": []},
      {"id": "read-only", "name": "Read-only tools", "enabled": false, "action": "allow", "when": []},
      {"id": "tests", "name": "Running tests", "enabled": true, "action": "allow", "when": []},
      {"id": "mine", "name": "No ls", "enabled": true, "action": "deny", "when": [{"tools": ["Bash"], "command": "^ls\\\\b"}]}
    ]}
    """

    func write(_ s: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(s.utf8).write(to: url)
    }

    func testMigratesV1() throws {
        try write(v1)
        let p = try XCTUnwrap(PolicyStore.load(from: url))
        XCTAssertEqual(p.version, 2)
        XCTAssertEqual(p.choice("git-push"), .off)
        for id in ["publish-packages", "push-images", "kubectl", "terraform", "helm", "gh-release", "deploy",
                   "rm-outside", "sudo", "sql-destructive", "git-reset-hard", "git-clean"] {
            XCTAssertEqual(p.choice(id), .ask, id)
        }
        XCTAssertEqual(p.choice("outside-edits"), .off)
        XCTAssertEqual(p.choice("read-only"), .off)
        XCTAssertNil(p.catalog["tests"])
        XCTAssertEqual(p.choice("git-force-push"), .ask)
        XCTAssertEqual(p.choice("secrets"), .off)
        XCTAssertEqual(p.rules.map(\.id), ["mine"])
        XCTAssertEqual(p.rules.first?.action, .deny)
        let ls = PolicyInput(tool: "Bash", input: .object(["command": .string("ls -la")]), cwd: "/p")
        XCTAssertEqual(p.evaluate(ls)?.name, "No ls")
    }

    func testEnsureDefaultsUpgradesFileOnDisk() throws {
        try write(v1)
        try PolicyStore.ensureDefaults(at: url)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(obj["version"] as? Int, 2)
        let catalog = obj["catalog"] as! [String: String]
        XCTAssertEqual(catalog["git-push"], "off")
        XCTAssertEqual(catalog["git-force-push"], "ask")
        XCTAssertEqual(Set(catalog.keys), Set(PolicyCatalog.rules.map(\.id)))
        let rules = obj["rules"] as! [[String: Any]]
        XCTAssertEqual(rules.first?["action"] as? String, "block")
    }

    func testEnsureDefaultsCreatesFile() throws {
        let p = try PolicyStore.ensureDefaults(at: url)
        XCTAssertEqual(p, PolicyCatalog.defaults)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(PolicyStore.load(from: url), PolicyCatalog.defaults)
    }

    func testBrokenFileIsLeftAlone() throws {
        try write("{ not json")
        let before = try Data(contentsOf: url)
        XCTAssertNil(PolicyStore.load(from: url))
        XCTAssertEqual(try PolicyStore.ensureDefaults(at: url), PolicyCatalog.defaults)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertThrowsError(try PolicyStore.update(at: url) { $0.catalog["sudo"] = .off })
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testRoundTripAndAtomicSave() throws {
        var p = PolicyCatalog.defaults
        p.catalog["sudo"] = .block
        p.rules = [PolicyRule(id: "r1", name: "compose down", action: .deny, pattern: "docker compose down*"),
                   PolicyRule(id: "r2", name: "locks", enabled: false, action: .ask, pattern: "*.lock", tools: ["Edit"])]
        try PolicyStore.save(p, to: url)
        XCTAssertEqual(PolicyStore.load(from: url), p)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, [".policy.last-good.json", "policy.json"])
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: PolicyStore.lastGoodURL(for: url)))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(#""pattern" : "docker compose down*""#))
        XCTAssertFalse(text.contains("\\/"))

        let updated = try PolicyStore.update(at: url) { $0.rules.removeAll { $0.id == "r2" } }
        XCTAssertEqual(updated.rules.map(\.id), ["r1"])
        XCTAssertEqual(PolicyStore.load(from: url)?.rules.map(\.id), ["r1"])
    }

    func testUpdateWithoutFileStartsFromDefaults() throws {
        let p = try PolicyStore.update(at: url) { $0.catalog["git-commit"] = .off }
        XCTAssertEqual(p.choice("git-commit"), .off)
        XCTAssertEqual(p.choice("git-push"), .ask)
    }

    func testActionCoding() throws {
        let dec = try JSONDecoder().decode([PolicyAction].self, from: Data(#"["deny","BLOCK","ask","allow","maybe"]"#.utf8))
        XCTAssertEqual(dec, [.deny, .deny, .ask, .ask, .ask])
        XCTAssertEqual(try JSONDecoder().decode([PolicyChoice].self, from: Data(#"["Off","ASK","deny","allow"]"#.utf8)), [.off, .ask, .block, .off])
        XCTAssertThrowsError(try JSONDecoder().decode([PolicyChoice].self, from: Data(#"["maybe"]"#.utf8)))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode([PolicyAction.deny]), as: UTF8.self), #"["block"]"#)
        XCTAssertEqual(PolicyAction.deny.hookDecision, "deny")
        XCTAssertEqual(PolicyChoice.block.action, .deny)
        XCTAssertNil(PolicyChoice.off.action)
    }

    func testMissingCatalogIDsFallBackToDefaults() throws {
        try write(#"{"version": 2, "catalog": {"git-push": "off"}, "rules": []}"#)
        let p = try XCTUnwrap(PolicyStore.load(from: url))
        XCTAssertEqual(p.choice("git-push"), .off)
        XCTAssertEqual(p.choice("git-force-push"), .ask)
        XCTAssertEqual(p.choice("no-such-rule"), .off)
    }

    func testFailSafeLoading() throws {
        XCTAssertEqual(PolicyStore.effective(at: url), PolicyLoad(policy: PolicyCatalog.defaults, problem: nil, unreadable: false))

        var good = PolicyCatalog.defaults
        good.catalog["sudo"] = .block
        try PolicyStore.save(good, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: PolicyStore.lastGoodURL(for: url).path))
        try Data("{ broken".utf8).write(to: url)
        let fallback = PolicyStore.effective(at: url)
        XCTAssertEqual(fallback.policy.choice("sudo"), .block)
        XCTAssertTrue(fallback.unreadable)
        XCTAssertEqual(fallback.problem, "policy.json has an error, the last good copy is in use")

        try FileManager.default.removeItem(at: PolicyStore.lastGoodURL(for: url))
        let defaults = PolicyStore.effective(at: url)
        XCTAssertEqual(defaults.policy, PolicyCatalog.defaults)
        XCTAssertEqual(defaults.problem, "policy.json has an error, the defaults are in use")
    }

    func testBadRulesAreSkippedOneByOne() throws {
        try write("""
        {"version": 2, "catalog": {"git-push": "BLOCK", "sudo": 7, "git-commit": "maybe"}, "rules": [
          {"name": "ok", "pattern": "make deploy*", "action": "Block"},
          {"name": "broken", "when": [{"tools": "Bash"}]},
          {"name": "second", "pattern": "kubectl drain*"}
        ]}
        """)
        let load = PolicyStore.effective(at: url)
        XCTAssertEqual(load.policy.rules.map(\.name), ["ok", "second"])
        XCTAssertEqual(load.policy.rules.first?.action, .deny)
        XCTAssertEqual(load.policy.rules.last?.action, .ask)
        XCTAssertEqual(load.policy.choice("git-push"), .block)
        XCTAssertEqual(load.policy.choice("sudo"), .off)
        XCTAssertEqual(load.policy.choice("git-commit"), .off)
        XCTAssertEqual(load.problem, "1 rule in policy.json could not be read and is ignored")
        XCTAssertFalse(load.unreadable)
    }

    func testEnvOverride() {
        setenv("EARSHOT_POLICY", "/tmp/earshot-test-policy.json", 1)
        defer { unsetenv("EARSHOT_POLICY") }
        XCTAssertEqual(PolicyStore.defaultURL.path, "/tmp/earshot-test-policy.json")
    }
}
