import Foundation

public struct ShellCommand: Equatable, Sendable {
    public var raw: String
    public var words: [String]
    public var forms: [String]
    public var redirects: [String]
    public var opaque: Bool

    public var normalized: String { forms.last ?? "" }

    public static func split(_ script: String) -> [ShellCommand] {
        ShellScript.parse(script).commands
    }

    public static func words(_ s: String) -> [String] {
        var lexer = ShellLexer(s, depth: 0)
        return lexer.run().compactMap { if case .word(let w) = $0 { return w.text } else { return nil } }
    }

    func touchesOutside(_ x: PolicyInput, dir: String?) -> Bool {
        var args: [String] = []
        var options = true
        for w in words.dropFirst() {
            if options && w == "--" {
                options = false
                continue
            }
            if options && w.hasPrefix("-") && w.count > 1 { continue }
            args.append(w)
        }
        return args.contains { PathCheck.dangerous($0, x, dir: dir) }
    }
}

public struct ShellScript: Equatable, Sendable {
    public static let maxBytes = 64 * 1024
    public static let maxTokens = 2000
    public static let maxDepth = 6

    public var commands: [ShellCommand]
    public var opaque: Bool
    public var tooBig: Bool

    public static func parse(_ s: String) -> ShellScript {
        if s.utf8.count > maxBytes { return ShellScript(commands: [], opaque: true, tooBig: true) }
        var budget = maxTokens
        let commands = parse(s, depth: 0, budget: &budget)
        let tooBig = budget < 0
        return ShellScript(commands: commands, opaque: tooBig || commands.contains(where: \.opaque), tooBig: tooBig)
    }

    static func parse(_ s: String, depth: Int, budget: inout Int) -> [ShellCommand] {
        guard depth <= maxDepth else {
            return [ShellCommand(raw: s, words: [], forms: [], redirects: [], opaque: true)]
        }
        var lexer = ShellLexer(s, depth: depth)
        let tokens = lexer.run()
        budget -= tokens.count
        if budget < 0 { return [] }
        var out: [ShellCommand] = []
        var words: [ShellWord] = []
        var redirects: [ShellRedirect] = []
        func flush() {
            out += analyze(words, redirects, source: s, depth: depth, budget: &budget)
            words = []
            redirects = []
        }
        for t in tokens {
            switch t {
            case .word(let w): words.append(w)
            case .redirect(let r): redirects.append(r)
            case .op: flush()
            }
        }
        flush()
        return out
    }

    static let reserved: Set<String> = ["if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "fi", "done", "esac"]
    static let headers: Set<String> = ["for", "case", "select", "function", "in"]
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]

    static func analyze(_ all: [ShellWord], _ redirects: [ShellRedirect], source: String, depth: Int, budget: inout Int) -> [ShellCommand] {
        var nested: [ShellCommand] = []
        for w in all {
            for sub in w.subs { nested += parse(sub, depth: depth + 1, budget: &budget) }
        }
        for r in redirects {
            for sub in r.target?.subs ?? [] { nested += parse(sub, depth: depth + 1, budget: &budget) }
        }
        var words = all
        while let f = words.first, !f.quoted, reserved.contains(f.text) { words.removeFirst() }
        while let l = words.last, !l.quoted, l.text == "}" { words.removeLast() }
        let targets = redirects.compactMap { $0.target?.text }
        guard let first = words.first else {
            if redirects.isEmpty { return nested }
            return [ShellCommand(raw: rawText(all, source), words: [], forms: [], redirects: targets, opaque: false)] + nested
        }
        if !first.quoted, headers.contains(first.text) { return nested }

        var texts = words.map(\.text)
        var dynamic = words.map(\.dynamic)
        var forms = [texts.joined(separator: " ")]
        var opaque = false
        var p = 0

        func push() { forms.append(texts[p...].joined(separator: " ")) }
        func skipOptions(_ withValue: Set<String>, attached: Bool = true) {
            while p < texts.count, texts[p].hasPrefix("-") || texts[p].hasPrefix("+"), texts[p].count > 1 {
                if texts[p] == "--" {
                    p += 1
                    return
                }
                let opt = texts[p]
                p += 1
                if withValue.contains(opt), p < texts.count { p += 1 }
                if attached, let eq = opt.firstIndex(of: "="), withValue.contains(String(opt[..<eq])) { continue }
            }
        }

        var peeled = true
        while peeled, p < texts.count {
            peeled = false
            let name = (texts[p] as NSString).lastPathComponent
            if texts[p].range(of: #"^[A-Za-z_][A-Za-z0-9_]*\+?="#, options: .regularExpression) != nil {
                p += 1
                peeled = true
            } else if !dynamic[p] {
                switch name {
                case "env":
                    p += 1
                    while p < texts.count, texts[p].hasPrefix("-"), texts[p].count > 1 {
                        let opt = texts[p]
                        p += 1
                        if ["-S", "--split-string"].contains(opt), p < texts.count {
                            let extra = ShellCommand.words(texts[p])
                            texts.replaceSubrange(p...p, with: extra)
                            dynamic.replaceSubrange(p...p, with: Array(repeating: false, count: extra.count))
                            break
                        } else if opt.hasPrefix("-S") || opt.hasPrefix("--split-string=") {
                            let value = opt.hasPrefix("-S") ? String(opt.dropFirst(2)) : String(opt.drop { $0 != "=" }.dropFirst())
                            let extra = ShellCommand.words(value)
                            texts.insert(contentsOf: extra, at: p)
                            dynamic.insert(contentsOf: Array(repeating: false, count: extra.count), at: p)
                            break
                        } else if ["-u", "--unset", "-C", "--chdir", "-P"].contains(opt), p < texts.count {
                            p += 1
                        } else if opt == "--" {
                            break
                        }
                    }
                    peeled = true
                case "sudo":
                    p += 1
                    skipOptions(["-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T", "--user", "--group", "--host",
                                 "--prompt", "--close-from", "--chdir", "--role", "--type", "--other-user", "--command-timeout"])
                    peeled = true
                case "doas":
                    p += 1
                    skipOptions(["-u", "-C"])
                    peeled = true
                case "command":
                    if p + 1 < texts.count, ["-v", "-V"].contains(texts[p + 1]) { break }
                    p += 1
                    skipOptions([])
                    peeled = true
                case "builtin", "nohup":
                    p += 1
                    peeled = true
                case "exec":
                    p += 1
                    skipOptions(["-a"])
                    peeled = true
                case "time":
                    p += 1
                    skipOptions([])
                    peeled = true
                case "nice":
                    p += 1
                    skipOptions(["-n", "--adjustment"])
                    peeled = true
                case "ionice":
                    p += 1
                    skipOptions(["-c", "-n", "--class", "--classdata"])
                    peeled = true
                case "timeout", "gtimeout":
                    p += 1
                    skipOptions(["-s", "-k", "--signal", "--kill-after"])
                    if p < texts.count { p += 1 }
                    peeled = true
                case "caffeinate":
                    p += 1
                    skipOptions(["-t", "-w"])
                    peeled = true
                case "arch":
                    p += 1
                    skipOptions(["-arch", "-e", "-d"])
                    peeled = true
                case "stdbuf", "gstdbuf":
                    p += 1
                    skipOptions(["-i", "-o", "-e", "--input", "--output", "--error"])
                    peeled = true
                case "script":
                    p += 1
                    skipOptions(["-F", "-t", "-T"])
                    if p < texts.count { p += 1 }
                    if p >= texts.count { opaque = true }
                    peeled = true
                case "xargs", "gxargs":
                    p += 1
                    skipOptions(["-I", "-i", "-n", "-P", "-s", "-E", "-e", "-L", "-l", "-J", "-R", "-S", "-d", "-a",
                                 "--max-args", "--max-procs", "--delimiter", "--arg-file", "--replace", "--max-lines"])
                    opaque = true
                    peeled = true
                default:
                    break
                }
            }
            if peeled, p < texts.count { push() }
        }

        guard p < texts.count else {
            return [ShellCommand(raw: rawText(all, source), words: [], forms: forms, redirects: targets, opaque: opaque)] + nested
        }
        if dynamic[p] { opaque = true }
        let name = (texts[p] as NSString).lastPathComponent
        var inner: [ShellCommand] = []

        if shells.contains(name) {
            var q = p + 1
            var hasC = false
            while q < texts.count {
                let w = texts[q]
                if w == "--" || w == "-" {
                    q += 1
                    break
                }
                if ["-o", "+o", "-O", "+O", "--rcfile", "--init-file"].contains(w) {
                    q += 2
                    continue
                }
                if w.hasPrefix("--") {
                    q += 1
                    continue
                }
                if (w.hasPrefix("-") || w.hasPrefix("+")) && w.count > 1 {
                    if w.dropFirst().contains("c") { hasC = true }
                    q += 1
                    continue
                }
                break
            }
            if hasC {
                if q < texts.count {
                    inner = parse(texts[q], depth: depth + 1, budget: &budget)
                    if dynamic[q] { opaque = true }
                } else {
                    opaque = true
                }
            } else if q < texts.count {
                opaque = true
            } else if let stdin = redirects.compactMap(\.stdin).last {
                inner = parse(stdin, depth: depth + 1, budget: &budget)
            } else {
                opaque = true
            }
        } else if name == "eval" {
            inner = parse(texts[(p + 1)...].joined(separator: " "), depth: depth + 1, budget: &budget)
            if dynamic[(p + 1)...].contains(true) { opaque = true }
        } else if name == "source" || name == "." {
            opaque = true
        } else if name == "git" {
            let g = gitCanonical(Array(texts[p...]), dynamic: Array(dynamic[p...]))
            if let c = g.form, c != forms.last { forms.append(c) }
            if g.opaque { opaque = true }
            if let script = g.shellAlias { inner = parse(script, depth: depth + 1, budget: &budget) }
        }
        if inner.contains(where: \.opaque) { opaque = true }
        let cmd = ShellCommand(raw: rawText(all, source), words: Array(texts[p...]), forms: forms, redirects: targets, opaque: opaque)
        return [cmd] + inner + nested
    }

    static let gitValueOptions: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix",
                                               "--config-env", "--exec-path", "--list-cmds", "--attr-source"]

    static func gitCanonical(_ words: [String], dynamic: [Bool]) -> (form: String?, opaque: Bool, shellAlias: String?) {
        var i = 1
        var aliases: [String: String] = [:]
        var opaque = false
        while i < words.count, words[i].hasPrefix("-") {
            let w = words[i]
            var opt = w, value: String?
            if let eq = w.firstIndex(of: "="), w.hasPrefix("--") {
                opt = String(w[..<eq])
                value = String(w[w.index(after: eq)...])
            }
            if gitValueOptions.contains(opt), value == nil, !["--exec-path"].contains(opt) {
                value = i + 1 < words.count ? words[i + 1] : nil
                i += 1
            }
            if opt == "-c", let v = value, v.lowercased().hasPrefix("alias."), let eq = v.firstIndex(of: "=") {
                aliases[String(v[v.index(v.startIndex, offsetBy: 6)..<eq]).lowercased()] = String(v[v.index(after: eq)...])
            }
            if opt == "--config-env", let v = value, v.lowercased().hasPrefix("alias.") { opaque = true }
            i += 1
        }
        guard i < words.count else { return (nil, opaque, nil) }
        if dynamic[i] { opaque = true }
        var rest = Array(words[i...])
        var shellAlias: String?
        if let a = aliases[rest[0].lowercased()] {
            if a.hasPrefix("!") {
                shellAlias = String(a.dropFirst())
                opaque = true
            } else {
                rest.replaceSubrange(0...0, with: ShellCommand.words(a))
            }
        }
        return ((["git"] + rest).joined(separator: " "), opaque, shellAlias)
    }

    static func rawText(_ words: [ShellWord], _ source: String) -> String {
        guard let s = words.first?.start, let e = words.last?.end else { return "" }
        let chars = Array(source)
        guard s >= 0, e <= chars.count, s < e else { return words.map(\.text).joined(separator: " ") }
        return String(chars[s..<e]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ShellWord: Equatable, Sendable {
    var text = ""
    var dynamic = false
    var quoted = false
    var subs: [String] = []
    var start = 0
    var end = 0
}

struct ShellRedirect: Equatable, Sendable {
    var op: String
    var target: ShellWord?
    var stdin: String?
}

enum ShellToken: Equatable, Sendable {
    case word(ShellWord)
    case op(String)
    case redirect(ShellRedirect)
}

struct ShellLexer {
    let chars: [Character]
    let depth: Int
    var i = 0
    var tokens: [ShellToken] = []
    var cur: ShellWord?
    var awaitingTarget: Int?
    var heredocs: [(index: Int, delimiter: String, strip: Bool)] = []

    init(_ s: String, depth: Int) {
        chars = Array(s)
        self.depth = depth
    }

    mutating func run() -> [ShellToken] {
        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t", "\r":
                flush()
                i += 1
            case "\n":
                flush()
                tokens.append(.op("\n"))
                i += 1
                readHeredocBodies()
            case "#" where cur == nil:
                while i < chars.count, chars[i] != "\n" { i += 1 }
            case "\\":
                if i + 1 < chars.count {
                    if chars[i + 1] != "\n" { append(chars[i + 1]) }
                    i += 2
                } else {
                    append("\\")
                    i += 1
                }
            case "'":
                begin()
                cur?.quoted = true
                i += 1
                while i < chars.count, chars[i] != "'" {
                    append(chars[i])
                    i += 1
                }
                i += 1
            case "\"":
                begin()
                cur?.quoted = true
                i += 1
                doubleQuoted()
            case "$":
                dollar(inQuotes: false)
            case "`":
                backtick()
            case ";", "&", "|", "(", ")":
                if c == "&", i + 1 < chars.count, chars[i + 1] == ">" {
                    flush()
                    redirect()
                    continue
                }
                flush()
                operatorToken()
            case "<", ">":
                if i + 1 < chars.count, chars[i + 1] == "(", let end = closing(from: i + 1) {
                    begin()
                    cur?.dynamic = true
                    cur?.subs.append(String(chars[(i + 2)..<end]))
                    cur?.text += "\(c)(…)"
                    i = end + 1
                    continue
                }
                if let w = cur, !w.quoted, !w.text.isEmpty, w.text.allSatisfy(\.isNumber) {
                    cur = nil
                } else {
                    flush()
                }
                redirect()
            default:
                append(c)
                i += 1
            }
        }
        flush()
        return tokens
    }

    mutating func begin() {
        if cur == nil { cur = ShellWord(start: i) }
    }

    mutating func append(_ c: Character) {
        begin()
        cur?.text.append(c)
    }

    mutating func flush() {
        guard var w = cur else { return }
        w.end = i
        cur = nil
        if let t = awaitingTarget, case .redirect(var r) = tokens[t] {
            r.target = w
            if r.op == "<<<" { r.stdin = w.text }
            tokens[t] = .redirect(r)
            awaitingTarget = nil
            if r.op == "<<" || r.op == "<<-" { heredocs.append((t, w.text, r.op == "<<-")) }
            return
        }
        tokens.append(.word(w))
    }

    mutating func operatorToken() {
        let c = chars[i]
        let n: Character? = i + 1 < chars.count ? chars[i + 1] : nil
        var op = String(c)
        if (c == "&" && n == "&") || (c == "|" && (n == "|" || n == "&")) || (c == ";" && (n == ";" || n == "&")) {
            op.append(n!)
            i += 1
        }
        i += 1
        tokens.append(.op(op))
    }

    mutating func redirect() {
        var op = ""
        for candidate in ["<<<", "<<-", "&>>", "<<", "<>", "<&", ">>", ">|", ">&", "&>", "<", ">"] {
            let cs = Array(candidate)
            if i + cs.count <= chars.count, Array(chars[i..<(i + cs.count)]) == cs {
                op = candidate
                break
            }
        }
        i += op.count
        tokens.append(.redirect(ShellRedirect(op: op)))
        if op == ">&" || op == "<&" {
            var j = i
            while j < chars.count, chars[j] == " " { j += 1 }
            if j < chars.count, chars[j].isNumber || chars[j] == "-" {
                i = j
                while i < chars.count, chars[i].isNumber || chars[i] == "-" { i += 1 }
                return
            }
        }
        awaitingTarget = tokens.count - 1
    }

    mutating func readHeredocBodies() {
        while !heredocs.isEmpty {
            let h = heredocs.removeFirst()
            var body: [String] = []
            while i < chars.count {
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                var line = String(chars[i..<j])
                i = min(j + 1, chars.count)
                if h.strip { line = String(line.drop { $0 == "\t" }) }
                if line == h.delimiter { break }
                body.append(line)
            }
            if case .redirect(var r) = tokens[h.index] {
                r.stdin = body.joined(separator: "\n")
                tokens[h.index] = .redirect(r)
            }
        }
    }

    mutating func doubleQuoted() {
        while i < chars.count, chars[i] != "\"" {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "\n" {
                } else if "$`\"\\".contains(n) {
                    append(n)
                } else {
                    append("\\")
                    append(n)
                }
                i += 2
            } else if c == "$" {
                dollar(inQuotes: true)
            } else if c == "`" {
                backtick()
            } else {
                append(c)
                i += 1
            }
        }
        i += 1
    }

    mutating func dollar(inQuotes: Bool) {
        let n: Character? = i + 1 < chars.count ? chars[i + 1] : nil
        begin()
        switch n {
        case "'" where !inQuotes:
            i += 2
            cur?.quoted = true
            ansiC()
        case "\"" where !inQuotes:
            i += 2
            cur?.quoted = true
            doubleQuoted()
        case "(":
            if i + 2 < chars.count, chars[i + 2] == "(", let end = closing(from: i + 1) {
                cur?.dynamic = true
                cur?.text += "$((…))"
                i = end + 1
            } else if let end = closing(from: i + 1) {
                cur?.dynamic = true
                cur?.subs.append(String(chars[(i + 2)..<end]))
                cur?.text += "$(…)"
                i = end + 1
            } else {
                cur?.dynamic = true
                i = chars.count
            }
        case "{":
            var j = i + 2
            while j < chars.count, chars[j] != "}" { j += 1 }
            let name = String(chars[min(i + 2, chars.count)..<min(j, chars.count)])
            i = min(j + 1, chars.count)
            variable(name, inQuotes: inQuotes)
        case let c? where c.isLetter || c == "_":
            var j = i + 1
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
            let name = String(chars[(i + 1)..<j])
            i = j
            variable(name, inQuotes: inQuotes)
        case let c? where c.isNumber || "@*#?$!-".contains(c):
            cur?.dynamic = true
            cur?.text += "$\(c)"
            i += 2
        default:
            append("$")
            i += 1
        }
    }

    mutating func variable(_ name: String, inQuotes: Bool) {
        if name == "IFS" && !inQuotes {
            if let w = cur, w.text.isEmpty, !w.quoted, !w.dynamic { cur = nil } else { flush() }
            return
        }
        cur?.dynamic = true
        cur?.text += "${\(name)}"
    }

    mutating func backtick() {
        begin()
        var j = i + 1
        var inner = ""
        while j < chars.count, chars[j] != "`" {
            if chars[j] == "\\", j + 1 < chars.count {
                inner.append(chars[j + 1])
                j += 2
            } else {
                inner.append(chars[j])
                j += 1
            }
        }
        cur?.dynamic = true
        cur?.subs.append(inner)
        cur?.text += "`…`"
        i = min(j + 1, chars.count)
    }

    mutating func ansiC() {
        while i < chars.count, chars[i] != "'" {
            let c = chars[i]
            guard c == "\\", i + 1 < chars.count else {
                append(c)
                i += 1
                continue
            }
            let n = chars[i + 1]
            i += 2
            switch n {
            case "n": append("\n")
            case "t": append("\t")
            case "r": append("\r")
            case "a", "b", "e", "E", "f", "v": append(" ")
            case "x":
                var hex = ""
                while hex.count < 2, i < chars.count, chars[i].isHexDigit {
                    hex.append(chars[i])
                    i += 1
                }
                if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { append(Character(u)) }
            case "u", "U":
                var hex = ""
                while hex.count < (n == "u" ? 4 : 8), i < chars.count, chars[i].isHexDigit {
                    hex.append(chars[i])
                    i += 1
                }
                if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { append(Character(u)) }
            case "0", "1", "2", "3", "4", "5", "6", "7":
                var oct = String(n)
                while oct.count < 3, i < chars.count, ("0"..."7").contains(chars[i]) {
                    oct.append(chars[i])
                    i += 1
                }
                if let v = UInt32(oct, radix: 8), let u = Unicode.Scalar(v) { append(Character(u)) }
            default: append(n)
            }
        }
        i += 1
    }

    func closing(from open: Int) -> Int? {
        var depth = 0
        var j = open
        var quote: Character?
        while j < chars.count {
            let c = chars[j]
            if let q = quote {
                if c == "\\" && q == "\"" {
                    j += 2
                    continue
                }
                if c == q { quote = nil }
            } else if c == "\\" {
                j += 2
                continue
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == "(" {
                depth += 1
            } else if c == ")" {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return nil
    }
}
