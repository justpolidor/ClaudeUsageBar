import Foundation
import Combine

/// The two providers the app can show. Kept in one place because three
/// separate UI decisions turn on it: which tab the popover is showing, which
/// series the chart draws, and which bars the menu bar icon renders.
enum UsageProvider: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Four bars in 18 points is mush, so the icon shows one provider.
    static let menuBarDefaultsKey = "menuBarProvider"
    /// Remembered across launches: whichever tab was open last reopens.
    static let popoverTabDefaultsKey = "popoverProvider"
}

/// Codex usage read from the Codex CLI's own session logs.
///
/// Codex does not expose a usage API the way Claude does — but every request it
/// makes writes a `token_count` event into the current session's rollout file,
/// and that event carries the account's rate-limit windows verbatim:
///
/// ```json
/// {"timestamp":"…","payload":{"type":"token_count","rate_limits":{
///   "limit_id":"codex",
///   "primary":{"used_percent":83.0,"window_minutes":300,"resets_at":1789852658},
///   "secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1790441339},
///   "credits":{"has_credits":false,"unlimited":false,"balance":"0"},
///   "plan_type":"plus"}}}
/// ```
///
/// So there is nothing to authenticate against and nothing to fetch: the
/// numbers are already on disk. The tradeoff is staleness — they only advance
/// when Codex actually runs, so `observedAt` is when Codex last talked to the
/// server, not when this app last looked.
struct CodexUsage {
    let primary: UsageBucket?
    let secondary: UsageBucket?
    /// Derived from `window_minutes`, because the window lengths are the
    /// server's to choose — today 300 and 10080, but nothing promises that.
    let primaryLabel: String
    let secondaryLabel: String
    let creditBalance: String?
    let planType: String?
    /// When Codex recorded these numbers, not when they were read.
    let observedAt: Date
}

@MainActor
final class CodexUsageService: ObservableObject {
    @Published private(set) var usage: CodexUsage?
    @Published private(set) var isEnabled: Bool

    /// Whether a Codex CLI session directory exists at all. Checked once: an
    /// install that appears mid-session is picked up on the next app launch.
    let isInstalled: Bool

    private let sessionsDirectory: URL

    static let enabledDefaultsKey = "codexTrackingEnabled"

    var pct5h: Double { (usage?.primary?.utilization ?? 0) / 100.0 }
    var pct7d: Double { (usage?.secondary?.utilization ?? 0) / 100.0 }

    /// True when there is something worth showing.
    var isActive: Bool { isEnabled && isInstalled }

    init(
        sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        defaults: UserDefaults = .standard
    ) {
        self.sessionsDirectory = sessionsDirectory

        var isDirectory: ObjCBool = false
        isInstalled = FileManager.default.fileExists(
            atPath: sessionsDirectory.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue

        // Defaults on when Codex is installed — the user asked for the app to
        // track it by installing it. `object(forKey:)` separates "never set"
        // from "set to false", which `bool(forKey:)` cannot.
        self.isEnabled = (defaults.object(forKey: Self.enabledDefaultsKey) as? Bool) ?? true
    }

    func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        if !enabled { usage = nil }
    }

    /// Re-reads the newest rate limits from disk. Cheap — it only tails a
    /// handful of files — but off the main actor all the same, because a
    /// rollout file can be hundreds of megabytes.
    func refresh() async {
        guard isActive else { return }
        let directory = sessionsDirectory
        usage = await Task.detached(priority: .utility) {
            CodexRolloutReader.latestUsage(in: directory)
        }.value
    }
}

// MARK: - Reading the rollout files

enum CodexRolloutReader {
    /// How many recent rollout files to look through before giving up. The
    /// newest file is not guaranteed to contain a usable entry: a session that
    /// only ever got a `limit_id` without windows (seen in practice with
    /// `"limit_id":"premium"`, both windows null) has to fall through to the
    /// session before it.
    static let candidateFileLimit = 10

    /// Bytes read from the end of each file. A rollout grows to hundreds of MB
    /// and the entry we want is near its end, so nothing reads a whole file.
    static let tailByteLimit = 256 * 1024

    static func latestUsage(in directory: URL, now: Date = Date()) -> CodexUsage? {
        for url in recentRolloutFiles(in: directory) {
            if let usage = latestUsage(inFileAt: url, now: now) {
                return usage
            }
        }
        return nil
    }

    /// Newest-first by modification time.
    ///
    /// ponytail: stats every rollout file in the tree (236 here, one syscall
    /// each). If that ever shows up in a profile, walk the year/month/day
    /// directories newest-first instead — the names sort chronologically.
    static func recentRolloutFiles(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            candidates.append((url, modified))
        }

        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(candidateFileLimit)
            .map(\.url)
    }

    /// The last entry in this file that actually reports a window, or nil.
    static func latestUsage(inFileAt url: URL, now: Date = Date()) -> CodexUsage? {
        guard let tail = tail(of: url) else { return nil }

        for line in tail.split(separator: "\n").reversed() {
            // Cheap reject before paying for JSON decoding: most lines in a
            // rollout are message content, not token counts.
            guard line.contains("\"rate_limits\"") else { continue }
            guard let usage = usage(fromLine: line, now: now) else { continue }
            return usage
        }
        return nil
    }

    static func usage(fromLine line: some StringProtocol, now: Date = Date()) -> CodexUsage? {
        guard let data = line.data(using: .utf8),
              let entry = try? JSONDecoder().decode(RolloutEntry.self, from: data),
              let limits = entry.payload?.rateLimits else { return nil }

        // An entry whose windows are both null says nothing about usage — it
        // reports a limit the account is not metered against. Skipping it lets
        // the caller keep looking further back.
        guard limits.primary?.usedPercent != nil || limits.secondary?.usedPercent != nil else {
            return nil
        }

        let observedAt = entry.timestampDate ?? now
        return CodexUsage(
            primary: limits.primary?.bucket(observedAt: observedAt),
            secondary: limits.secondary?.bucket(observedAt: observedAt),
            primaryLabel: CodexRateWindow.label(forWindowMinutes: limits.primary?.windowMinutes),
            secondaryLabel: CodexRateWindow.label(forWindowMinutes: limits.secondary?.windowMinutes),
            creditBalance: (limits.credits?.hasCredits == true) ? limits.credits?.balance : nil,
            planType: limits.planType,
            observedAt: observedAt
        )
    }

    /// The last `tailByteLimit` bytes of a file, with any partial first line
    /// dropped so every line handed back is parseable.
    static func tail(of url: URL, maxBytes: Int = tailByteLimit) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // Lossy: a tail can start mid-codepoint, and one mangled character in a
        // line we are going to skip anyway is not worth failing the read over.
        let text = String(decoding: data, as: UTF8.self)
        guard offset > 0, let firstNewline = text.firstIndex(of: "\n") else { return text }
        return String(text[text.index(after: firstNewline)...])
    }
}

// MARK: - Rollout JSON

private struct RolloutEntry: Decodable {
    let timestamp: String?
    let payload: Payload?

    struct Payload: Decodable {
        let type: String?
        let rateLimits: CodexRateLimits?

        enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
        }
    }

    /// Codex writes fractional seconds, which `JSONDecoder.iso8601` rejects,
    /// so the field is decoded as a string and parsed here.
    var timestampDate: Date? {
        guard let timestamp else { return nil }
        for options in [
            ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
            ISO8601DateFormatter.Options([.withInternetDateTime])
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: timestamp) { return date }
        }
        return nil
    }
}

struct CodexRateLimits: Decodable {
    let limitId: String?
    let primary: CodexRateWindow?
    let secondary: CodexRateWindow?
    let credits: CodexCredits?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case limitId = "limit_id"
        case primary
        case secondary
        case credits
        case planType = "plan_type"
    }
}

struct CodexRateWindow: Decodable {
    let usedPercent: Double?
    let windowMinutes: Int?
    /// Epoch seconds. Older Codex builds send `resets_in_seconds` instead.
    let resetsAt: Double?
    let resetsInSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
        case resetsInSeconds = "resets_in_seconds"
    }

    /// Reuses the Claude-side bucket so the popover rows and the icon need no
    /// Codex-specific rendering.
    func bucket(observedAt: Date) -> UsageBucket {
        UsageBucket(utilization: usedPercent, resetsAt: resetDateString(observedAt: observedAt))
    }

    private func resetDateString(observedAt: Date) -> String? {
        let date: Date
        if let resetsAt {
            date = Date(timeIntervalSince1970: resetsAt)
        } else if let resetsInSeconds {
            // Relative to when Codex wrote the entry, not to now.
            date = observedAt.addingTimeInterval(resetsInSeconds)
        } else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func label(forWindowMinutes minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Usage" }
        if minutes % 1440 == 0 {
            let days = minutes / 1440
            return days == 1 ? "Daily Window" : "\(days)-Day Window"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)-Hour Window"
        }
        return "\(minutes)-Minute Window"
    }
}

struct CodexCredits: Decodable {
    let hasCredits: Bool?
    let unlimited: Bool?
    /// A string in the rollout, e.g. `"0"` — passed through rather than parsed,
    /// because nothing here needs it as a number.
    let balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}
