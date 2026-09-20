import XCTest
@testable import ClaudeUsageBar

final class CodexUsageServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Shaped exactly like a real rollout line.
    private func rateLimitLine(
        timestamp: String = "2026-09-19T16:52:18.198Z",
        limitId: String = "codex",
        primary: String = #"{"used_percent":83.0,"window_minutes":300,"resets_at":1789852658}"#,
        secondary: String = #"{"used_percent":1.0,"window_minutes":10080,"resets_at":1790441339}"#
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"total_tokens":25667}},\
        "rate_limits":{"limit_id":"\(limitId)","primary":\(primary),"secondary":\(secondary),\
        "credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"plus"}}}
        """
    }

    private func writeRollout(
        _ lines: [String],
        name: String,
        modified: Date? = nil
    ) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    private let noise = #"{"timestamp":"2026-09-19T16:00:00.000Z","type":"response_item","payload":{"type":"message","content":"hello"}}"#

    // MARK: - Parsing

    func testParsesWindowsFromRealShapedLine() throws {
        let url = try writeRollout([noise, rateLimitLine()], name: "rollout-a.jsonl")
        let usage = try XCTUnwrap(CodexRolloutReader.latestUsage(inFileAt: url))

        XCTAssertEqual(usage.primary?.utilization, 83.0)
        XCTAssertEqual(usage.secondary?.utilization, 1.0)
        XCTAssertEqual(usage.primaryLabel, "5-Hour Window")
        XCTAssertEqual(usage.secondaryLabel, "7-Day Window")
        XCTAssertEqual(usage.planType, "plus")
        XCTAssertEqual(
            usage.primary?.resetsAtDate,
            Date(timeIntervalSince1970: 1789852658)
        )
        // has_credits is false, so there is no balance worth showing.
        XCTAssertNil(usage.creditBalance)
    }

    func testTakesTheLastUsableEntryInAFile() throws {
        let older = rateLimitLine(
            primary: #"{"used_percent":10.0,"window_minutes":300,"resets_at":1789852658}"#
        )
        let newer = rateLimitLine(
            primary: #"{"used_percent":42.0,"window_minutes":300,"resets_at":1789852658}"#
        )
        let url = try writeRollout([older, noise, newer], name: "rollout-b.jsonl")

        XCTAssertEqual(
            CodexRolloutReader.latestUsage(inFileAt: url)?.primary?.utilization,
            42.0
        )
    }

    /// The regression that motivated scanning backwards: the newest entry in a
    /// live session can report a limit the account is not metered against, with
    /// both windows null.
    func testSkipsEntriesWithNoWindows() throws {
        let usable = rateLimitLine()
        let unmetered = """
        {"timestamp":"2026-09-19T17:00:00.000Z","type":"event_msg","payload":{"type":"token_count",\
        "rate_limits":{"limit_id":"premium","primary":null,"secondary":null,\
        "credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"plus"}}}
        """
        let url = try writeRollout([usable, unmetered], name: "rollout-c.jsonl")

        XCTAssertEqual(
            CodexRolloutReader.latestUsage(inFileAt: url)?.primary?.utilization,
            83.0
        )
    }

    func testFallsThroughToAnOlderFileWhenTheNewestHasNothinged() throws {
        let unmetered = """
        {"timestamp":"2026-09-19T17:00:00.000Z","type":"event_msg","payload":{"type":"token_count",\
        "rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}
        """
        _ = try writeRollout(
            [rateLimitLine()],
            name: "rollout-old.jsonl",
            modified: Date(timeIntervalSince1970: 1_000_000)
        )
        _ = try writeRollout(
            [unmetered],
            name: "rollout-new.jsonl",
            modified: Date(timeIntervalSince1970: 2_000_000)
        )

        XCTAssertEqual(
            CodexRolloutReader.latestUsage(in: tempDir)?.primary?.utilization,
            83.0
        )
    }

    func testIgnoresFilesThatAreNotRollouts() throws {
        _ = try writeRollout([rateLimitLine()], name: "history.jsonl")
        XCTAssertNil(CodexRolloutReader.latestUsage(in: tempDir))
    }

    func testMissingDirectoryYieldsNoUsage() {
        let missing = tempDir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertNil(CodexRolloutReader.latestUsage(in: missing))
    }

    // MARK: - Tail reading

    /// Rollout files reach hundreds of megabytes, so only the tail is read —
    /// the entry still has to be found, and the truncated first line dropped.
    func testReadsOnlyTheTailAndDropsThePartialLine() throws {
        let filler = String(repeating: "x", count: 4096)
        let padding = (0..<100).map { _ in
            #"{"timestamp":"2026-09-19T16:00:00.000Z","payload":{"type":"message","content":"\#(filler)"}}"#
        }
        let url = try writeRollout(padding + [rateLimitLine()], name: "rollout-big.jsonl")

        let tail = try XCTUnwrap(CodexRolloutReader.tail(of: url, maxBytes: 8192))
        XCTAssertLessThan(tail.utf8.count, 9000, "Should not read the whole file")
        XCTAssertFalse(tail.hasPrefix("x"), "Partial first line should be dropped")
        for line in tail.split(separator: "\n") {
            XCTAssertTrue(line.hasPrefix("{"), "Every returned line should be parseable JSON")
        }

        XCTAssertEqual(
            CodexRolloutReader.latestUsage(inFileAt: url)?.primary?.utilization,
            83.0
        )
    }

    // MARK: - Window labels

    func testWindowLabelsFollowTheReportedMinutes() {
        XCTAssertEqual(CodexRateWindow.label(forWindowMinutes: 300), "5-Hour Window")
        XCTAssertEqual(CodexRateWindow.label(forWindowMinutes: 10080), "7-Day Window")
        XCTAssertEqual(CodexRateWindow.label(forWindowMinutes: 1440), "Daily Window")
        XCTAssertEqual(CodexRateWindow.label(forWindowMinutes: 90), "90-Minute Window")
        XCTAssertEqual(CodexRateWindow.label(forWindowMinutes: nil), "Usage")
    }

    /// Older Codex builds report a relative reset, which is relative to when
    /// the entry was written rather than to now.
    func testRelativeResetIsAnchoredToTheEntryTimestamp() throws {
        let line = rateLimitLine(
            timestamp: "2026-09-19T16:00:00.000Z",
            primary: #"{"used_percent":50.0,"window_minutes":300,"resets_in_seconds":3600}"#
        )
        let url = try writeRollout([line], name: "rollout-rel.jsonl")
        let usage = try XCTUnwrap(CodexRolloutReader.latestUsage(inFileAt: url))

        let expected = ISO8601DateFormatter().date(from: "2026-09-19T17:00:00Z")
        XCTAssertEqual(usage.primary?.resetsAtDate, expected)
    }

    // MARK: - Service gating

    @MainActor
    func testServiceIsInactiveWithoutACodexInstall() {
        let service = CodexUsageService(
            sessionsDirectory: tempDir.appendingPathComponent("absent", isDirectory: true),
            defaults: makeDefaults()
        )
        XCTAssertFalse(service.isInstalled)
        XCTAssertFalse(service.isActive)
    }

    @MainActor
    func testServiceReadsUsageWhenInstalled() async throws {
        _ = try writeRollout([rateLimitLine()], name: "rollout-d.jsonl")
        let service = CodexUsageService(sessionsDirectory: tempDir, defaults: makeDefaults())

        XCTAssertTrue(service.isActive, "Tracking defaults on when Codex is installed")
        await service.refresh()

        XCTAssertEqual(service.pct5h, 0.83, accuracy: 0.0001)
        XCTAssertEqual(service.pct7d, 0.01, accuracy: 0.0001)
    }

    @MainActor
    func testDisablingClearsUsageAndStopsReading() async throws {
        _ = try writeRollout([rateLimitLine()], name: "rollout-e.jsonl")
        let defaults = makeDefaults()
        let service = CodexUsageService(sessionsDirectory: tempDir, defaults: defaults)
        await service.refresh()
        XCTAssertNotNil(service.usage)

        service.setEnabled(false, defaults: defaults)
        XCTAssertNil(service.usage)

        await service.refresh()
        XCTAssertNil(service.usage, "A disabled service should not read from disk")
    }

    /// A suite of its own, so the test does not inherit or leave behind the
    /// real app's preference.
    private func makeDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "CodexUsageServiceTests-\(UUID().uuidString)")!
        addTeardownBlock { suite.removePersistentDomain(forName: suite.description) }
        return suite
    }
}
