import XCTest
@testable import EarshotCore

final class UsageTests: XCTestCase {
    func testSnapshotIsSane() {
        let s = UsageSampler()
        let me = getpid()
        _ = s.sample(claudePIDs: [me])
        var x = 0.0
        for i in 0..<3_000_000 { x += Double(i % 7) }
        XCTAssertGreaterThan(x, 0)
        let snap = s.sample(claudePIDs: [me], now: Date().addingTimeInterval(0.5))
        XCTAssertGreaterThan(snap.ramTotal, 1 << 30)
        XCTAssertGreaterThan(snap.ramUsed, 0)
        XCTAssertLessThanOrEqual(snap.ramFraction, 1)
        XCTAssertGreaterThan(snap.claude.rss, 1 << 20)
        XCTAssertGreaterThanOrEqual(snap.claude.processes, 1)
        XCTAssertNotNil(snap.perSession[me])
        XCTAssertGreaterThanOrEqual(snap.cpu, 0)
        XCTAssertLessThanOrEqual(snap.cpu, 100)
    }

    func testDescendantsIncludeChildren() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        try? p.run()
        defer { p.terminate() }
        let tree = UsageSampler.descendants(of: [getpid()])
        XCTAssertTrue(tree[getpid()]?.contains(p.processIdentifier) ?? false)
    }

    func testBytesFormat() {
        XCTAssertEqual(UsageSampler.bytes(512 * 1_048_576), "512 MB")
        XCTAssertEqual(UsageSampler.bytes(UInt64(1.5 * 1_073_741_824)), "1.5 GB")
        XCTAssertEqual(UsageSampler.bytes(16 * 1_073_741_824), "16 GB")
    }
}
