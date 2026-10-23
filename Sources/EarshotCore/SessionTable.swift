import Foundation

public enum SessionTable {
    public static func render(_ rows: [SessionSnapshot]) -> String {
        if rows.isEmpty { return "no Claude sessions" }
        let header = ["STATUS", "PROJECT", "FOR", "TTY", "NOW"]
        let body = rows.map { r -> [String] in
            let now = r.activity ?? r.lastMessage ?? r.title ?? ""
            return [clean(r.status), clean(r.project), duration(r.seconds), clean(r.tty ?? "-"), ToolSummary.clip(clean(now), 70)]
        }
        let widths = header.indices.map { i in ([header] + body).map { $0[i].count }.max() ?? 0 }
        return ([header] + body).map { row in
            row.enumerated().map { i, cell in
                i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    public static func clean(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            switch c.value {
            case 0x1B:
                guard let next = it.next() else { break }
                if next == "[" {
                    while let x = it.next(), !(0x40...0x7E).contains(x.value) {}
                } else if next == "]" || next == "P" || next == "_" || next == "^" {
                    var prev: Unicode.Scalar?
                    while let x = it.next() {
                        if x.value == 0x07 || (prev?.value == 0x1B && x == "\\") { break }
                        prev = x
                    }
                }
            case 0x9B:
                while let x = it.next(), !(0x40...0x7E).contains(x.value) {}
            case 0x09, 0x0A, 0x0D:
                out.append(" ")
            case 0x00...0x1F, 0x7F...0x9F:
                break
            default:
                out.append(c)
            }
        }
        return String(out)
    }

    public static func duration(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h\(s % 3600 / 60 > 0 ? "\(s % 3600 / 60)m" : "")"
    }
}
