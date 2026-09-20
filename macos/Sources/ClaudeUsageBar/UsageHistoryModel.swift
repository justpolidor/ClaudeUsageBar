import Foundation

struct UsageDataPoint: Codable, Identifiable {
    var id: UUID
    let timestamp: Date
    let pct5h: Double
    let pct7d: Double
    /// Codex's two windows, nil when Codex tracking is off or has never
    /// reported. Optional so a `history.json` written before Codex support
    /// still decodes, and so the chart can skip the gap rather than draw a
    /// false zero.
    let pct5hCodex: Double?
    let pct7dCodex: Double?

    init(
        timestamp: Date = Date(),
        pct5h: Double,
        pct7d: Double,
        pct5hCodex: Double? = nil,
        pct7dCodex: Double? = nil
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.pct5h = pct5h
        self.pct7d = pct7d
        self.pct5hCodex = pct5hCodex
        self.pct7dCodex = pct7dCodex
    }
}

struct UsageHistory: Codable {
    var dataPoints: [UsageDataPoint] = []
}

enum TimeRange: String, CaseIterable, Identifiable {
    case hour1 = "1h"
    case hour6 = "6h"
    case day1 = "1d"
    case day7 = "7d"
    case day30 = "30d"

    var id: String { rawValue }

    var interval: TimeInterval {
        switch self {
        case .hour1: return 3600
        case .hour6: return 6 * 3600
        case .day1: return 86400
        case .day7: return 7 * 86400
        case .day30: return 30 * 86400
        }
    }

    var targetPointCount: Int {
        switch self {
        case .hour1: return 120
        case .hour6: return 180
        case .day1: return 200
        case .day7: return 200
        case .day30: return 200
        }
    }
}
