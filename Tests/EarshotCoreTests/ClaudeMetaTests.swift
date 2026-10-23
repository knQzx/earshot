import XCTest
@testable import EarshotCore

final class ClaudeMetaTests: XCTestCase {
    var root: URL!
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    let sid = "d3ce9d97-1b2c-4d5e-8f90-a1b2c3d4e5f6"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("earshot-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func reader() -> ClaudeMetaReader {
        ClaudeMetaReader(configDir: root, refreshEvery: 30, clock: { [unowned self] in self.clock })
    }

    func writeSession(_ pid: Int32, _ json: String) throws {
        try Data(json.utf8).write(to: root.appendingPathComponent("sessions/\(pid).json"))
    }

    func transcriptURL(_ cwd: String = "/Users/dev/src/earshot", folder: String? = nil) throws -> URL {
        let dir = root.appendingPathComponent("projects/" + (folder ?? cwd.replacingOccurrences(of: "/", with: "-")))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(sid + ".jsonl")
    }

    func line(_ i: Int) -> String {
        #"{"type":"assistant","uuid":"u\#(i)","message":{"content":[{"type":"text","text":"\#(String(repeating: "x", count: 200))"}]}}"#
    }

    func title(_ t: String) -> String { #"{"type":"ai-title","aiTitle":"\#(t)","sessionId":"d3ce9d97"}"# }

    func testParsesSessionFile() throws {
        try writeSession(14989, """
        {"pid":14989,"sessionId":"\(sid)","cwd":"/Users/dev/src/earshot","startedAt":1792694141949,"kind":"interactive",
         "entrypoint":"cli","name":"earshot-14","nameSource":"derived","status":"busy","statusUpdatedAt":1792702512657,
         "procStart":"Wed Oct 14 09:31:05 2026","pidDomain":"darwin"}
        """)
        let m = try XCTUnwrap(reader().meta(pid: 14989))
        XCTAssertEqual(m.sessionID, sid)
        XCTAssertEqual(m.cwd, "/Users/dev/src/earshot")
        XCTAssertEqual(m.name, "earshot-14")
        XCTAssertEqual(m.nameSource, "derived")
        XCTAssertEqual(m.status, "busy")
        XCTAssertEqual(m.statusUpdatedAt, Date(timeIntervalSince1970: 1792702512.657))
        XCTAssertNil(m.aiTitle)
    }

    func testMissingFieldsAndBadFiles() throws {
        try writeSession(7, #"{"pid":7}"#)
        XCTAssertEqual(reader().meta(pid: 7), ClaudeMeta())
        try writeSession(8, #"{"pid":9,"sessionId":"x"}"#)
        XCTAssertNil(reader().meta(pid: 8))
        try writeSession(10, "not json")
        XCTAssertNil(reader().meta(pid: 10))
        XCTAssertNil(reader().meta(pid: 11))
        XCTAssertNil(reader().meta(pid: 0))
    }

    func testStaleFileFromReusedPidIgnored() throws {
        try writeSession(12, #"{"pid":12,"sessionId":"\#(sid)","procStart":"Wed Oct 14 09:31:05 2026"}"#)
        let start = ClaudeMetaReader.procStart("Wed Oct 14 09:31:05 2026")!
        XCTAssertNotNil(reader().meta(pid: 12, processStart: start.addingTimeInterval(0.4)))
        XCTAssertNil(reader().meta(pid: 12, processStart: start.addingTimeInterval(3600)))
        XCTAssertEqual(ClaudeMetaReader.procStart("Sun Oct  4 07:00:00 2026"), ClaudeMetaReader.procStart("Sun Oct 4 07:00:00 2026"))
    }

    func testTitleNearEndOfBigTranscript() throws {
        let url = try transcriptURL()
        var text = title("Old title") + "\n"
        for i in 0..<20_000 { text += line(i) + "\n" }
        text += title("Control Tower and Sentinel meeting") + "\n"
        for i in 0..<50 { text += line(i) + "\n" }
        try Data(text.utf8).write(to: url)
        XCTAssertGreaterThan(text.utf8.count, 4_000_000)

        try writeSession(20, #"{"pid":20,"sessionId":"\#(sid)","cwd":"/Users/dev/src/earshot"}"#)
        let r = reader()
        XCTAssertEqual(r.meta(pid: 20)?.aiTitle, "Control Tower and Sentinel meeting")
        XCTAssertEqual(r.transcriptReads, 1)
    }

    func testWidensOnceWhenTitleIsFurtherBack() throws {
        let url = try transcriptURL()
        var text = title("Way back") + "\n"
        for i in 0..<20_000 { text += line(i) + "\n" }
        text += title("Mid title") + "\n"
        for i in 0..<2_000 { text += line(i) + "\n" }
        try Data(text.utf8).write(to: url)
        let r = reader()
        XCTAssertEqual(r.aiTitle(sessionID: sid, cwd: "/Users/dev/src/earshot"), "Mid title")
        XCTAssertEqual(r.transcriptReads, 2)
    }

    func testNoTitleAnywhere() throws {
        let url = try transcriptURL()
        try Data((line(1) + "\n" + line(2)).utf8).write(to: url)
        XCTAssertNil(reader().aiTitle(sessionID: sid, cwd: "/Users/dev/src/earshot"))
    }

    func testFindsTranscriptWithOtherFolderEncoding() throws {
        let url = try transcriptURL(folder: "-Users-dev-my-project-v2")
        try Data((title("Dotted") + "\n").utf8).write(to: url)
        let r = reader()
        XCTAssertEqual(r.aiTitle(sessionID: sid, cwd: "/Users/dev/my_project.v2"), "Dotted")
        let other = try transcriptURL(folder: "-somewhere-else")
        try FileManager.default.removeItem(at: url)
        try Data((title("Globbed") + "\n").utf8).write(to: other)
        clock += 31
        XCTAssertEqual(r.aiTitle(sessionID: sid, cwd: "/nope"), "Globbed")
    }

    func testCacheSkipsUnchangedAndThrottles() throws {
        let url = try transcriptURL()
        try Data((title("First") + "\n").utf8).write(to: url)
        let r = reader()
        let cwd = "/Users/dev/src/earshot"
        XCTAssertEqual(r.aiTitle(sessionID: sid, cwd: cwd), "First")
        XCTAssertEqual(r.transcriptReads, 1)

        clock += 31
        XCTAssertEqual(r.aiTitle(sessionID: sid, cwd: cwd), "First")
        XCTAssertEqual(r.transcriptReads, 1)

        try Data((title("First") + "\n" + title("Second") + "\n").utf8).write(to: url)
        clock += 5
        XCTAssertEqual(r.aiTitle(sessionID: sid, cwd: cwd), "First")
        XCTAssertEqual(r.transcriptReads, 1)

        clock += 30
        XCTAssertEqual(r.aiTitle(sessionID: sid, cwd: cwd), "Second")
        XCTAssertEqual(r.transcriptReads, 2)

        try Data((title("First") + "\n" + title("Second") + "\n" + line(1) + "\n").utf8).write(to: url)
        clock += 31
        XCTAssertEqual(r.aiTitle(sessionID: sid, cwd: cwd), "Second")
    }

    func testRejectsOddSessionIDs() {
        XCTAssertNil(reader().aiTitle(sessionID: "../../etc/passwd", cwd: nil))
    }

    func testLastTitleSkipsBrokenLines() {
        let data = Data((title("Good") + "\n" + #"{"type":"ai-title","aiTitle":"tru"# + "\n" + line(1)).utf8)
        XCTAssertEqual(ClaudeMetaReader.lastTitle(in: data), "Good")
        XCTAssertNil(ClaudeMetaReader.lastTitle(in: Data(#"{"type":"user","text":"ai-title"}"#.utf8)))
    }
}
