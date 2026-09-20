import SwiftUI
import Charts

struct UsageChartView: View {
    @ObservedObject var historyService: UsageHistoryService
    /// Which provider's two series to draw. The popover shows one provider at
    /// a time, so the chart does too — four lines in a 120pt plot is noise.
    var provider: UsageProvider = .claude
    @State private var selectedRange: TimeRange = .day1
    @State private var hoverDate: Date?

    private func window5h(_ point: UsageDataPoint) -> Double? {
        provider == .codex ? point.pct5hCodex : point.pct5h
    }

    private func window7d(_ point: UsageDataPoint) -> Double? {
        provider == .codex ? point.pct7dCodex : point.pct7d
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $selectedRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let points = historyService.downsampledPoints(for: selectedRange)

            // A point recorded before Codex tracking was on carries nothing for
            // this provider, so "has points" is not the same as "has a line".
            if !points.contains(where: { window5h($0) != nil || window7d($0) != nil }) {
                Text("No history data yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                chartView(points: points)
            }
        }
    }

    @ViewBuilder
    private func chartView(points: [UsageDataPoint]) -> some View {
        let interpolated = hoverDate.flatMap {
            UsageChartInterpolation.interpolateValues(at: $0, in: points)
        }

        Chart {
            // Filtering the nils leaves a gap in the line rather than a run of
            // false zeros, for the stretch before Codex tracking was on.
            ForEach(points.filter { window5h($0) != nil }) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage", (window5h(point) ?? 0) * 100)
                )
                .foregroundStyle(by: .value("Window", "5h"))
                .interpolationMethod(.catmullRom)
            }

            ForEach(points.filter { window7d($0) != nil }) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Usage", (window7d(point) ?? 0) * 100)
                )
                .foregroundStyle(by: .value("Window", "7d"))
                .interpolationMethod(.catmullRom)
            }

            if let iv = interpolated {
                RuleMark(x: .value("Selected", iv.date))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                if let pct5h = iv.value5h(for: provider) {
                    PointMark(
                        x: .value("Time", iv.date),
                        y: .value("Usage", pct5h * 100)
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(24)
                }

                if let pct7d = iv.value7d(for: provider) {
                    PointMark(
                        x: .value("Time", iv.date),
                        y: .value("Usage", pct7d * 100)
                    )
                    .foregroundStyle(.orange)
                    .symbolSize(24)
                }
            }
        }
        .chartXScale(domain: Date.now.addingTimeInterval(-selectedRange.interval)...Date.now)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)%")
                            .font(.caption2)
                    }
                }
                AxisGridLine()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel(format: xAxisFormat)
                    .font(.caption2)
                AxisGridLine()
            }
        }
        .chartForegroundStyleScale([
            "5h": Color.blue,
            "7d": Color.orange
        ])
        .chartLegend(.visible)
        .chartPlotStyle { plot in
            plot.clipped()
        }
        // Swift Charts maps the pointer onto the x scale itself and clears the
        // binding on exit — no plot-area coordinate math, and no `plotFrame`
        // to force-unwrap before the first layout pass.
        .chartXSelection(value: $hoverDate)
        .overlay(alignment: .top) {
            if let iv = interpolated {
                tooltipView(values: iv)
            }
        }
        .frame(height: 120)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func tooltipView(values: UsageChartInterpolatedValues) -> some View {
        VStack(spacing: 2) {
            Text(values.date, format: tooltipDateFormat)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let pct5h = values.value5h(for: provider) {
                    tooltipValue(pct5h, color: .blue)
                }
                if let pct7d = values.value7d(for: provider) {
                    tooltipValue(pct7d, color: .orange)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    private func tooltipValue(_ fraction: Double, color: Color) -> some View {
        Label("\(Int(round(fraction * 100)))%", systemImage: "circle.fill")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color)
    }

    // MARK: - Formatting

    private var xAxisFormat: Date.FormatStyle {
        switch selectedRange {
        case .hour1:
            return .dateTime.hour().minute()
        case .hour6, .day1:
            return .dateTime.hour()
        case .day7:
            return .dateTime.weekday(.abbreviated)
        case .day30:
            return .dateTime.day().month(.abbreviated)
        }
    }

    private var tooltipDateFormat: Date.FormatStyle {
        switch selectedRange {
        case .hour1, .hour6, .day1:
            return .dateTime.hour().minute()
        case .day7:
            return .dateTime.weekday(.abbreviated).hour().minute()
        case .day30:
            return .dateTime.month(.abbreviated).day().hour()
        }
    }
}

struct UsageChartInterpolatedValues {
    let date: Date
    let pct5h: Double
    let pct7d: Double
    let pct5hCodex: Double?
    let pct7dCodex: Double?

    init(
        date: Date,
        pct5h: Double,
        pct7d: Double,
        pct5hCodex: Double? = nil,
        pct7dCodex: Double? = nil
    ) {
        self.date = date
        self.pct5h = pct5h
        self.pct7d = pct7d
        self.pct5hCodex = pct5hCodex
        self.pct7dCodex = pct7dCodex
    }

    func value5h(for provider: UsageProvider) -> Double? {
        provider == .codex ? pct5hCodex : pct5h
    }

    func value7d(for provider: UsageProvider) -> Double? {
        provider == .codex ? pct7dCodex : pct7d
    }
}

enum UsageChartInterpolation {
    static func catmullRom(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    static func interpolateValues(at date: Date, in points: [UsageDataPoint]) -> UsageChartInterpolatedValues? {
        guard points.count >= 2 else { return nil }

        let sorted = points.sorted { $0.timestamp < $1.timestamp }

        if date < sorted.first!.timestamp || date > sorted.last!.timestamp {
            return UsageChartInterpolatedValues(date: date, pct5h: 0, pct7d: 0)
        }

        for i in 0..<(sorted.count - 1) {
            if date >= sorted[i].timestamp && date <= sorted[i + 1].timestamp {
                let span = sorted[i + 1].timestamp.timeIntervalSince(sorted[i].timestamp)
                let t = span > 0 ? date.timeIntervalSince(sorted[i].timestamp) / span : 0

                let i0 = max(0, i - 1)
                let i3 = min(sorted.count - 1, i + 2)

                let pct5h = catmullRom(
                    sorted[i0].pct5h, sorted[i].pct5h,
                    sorted[i + 1].pct5h, sorted[i3].pct5h, t: t
                )
                let pct7d = catmullRom(
                    sorted[i0].pct7d, sorted[i].pct7d,
                    sorted[i + 1].pct7d, sorted[i3].pct7d, t: t
                )

                return UsageChartInterpolatedValues(
                    date: date,
                    pct5h: clampToUnitInterval(pct5h),
                    pct7d: clampToUnitInterval(pct7d),
                    pct5hCodex: interpolateOptional(
                        sorted, i0: i0, i: i, i3: i3, t: t, key: \.pct5hCodex
                    ),
                    pct7dCodex: interpolateOptional(
                        sorted, i0: i0, i: i, i3: i3, t: t, key: \.pct7dCodex
                    )
                )
            }
        }

        return nil
    }

    private static func clampToUnitInterval(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    /// Interpolates a series that may be missing values.
    ///
    /// Both bracketing points must have one — a value cannot be invented for a
    /// span where Codex reported nothing. The outer control points fall back to
    /// their neighbours, which is what the existing series does at the ends of
    /// the array anyway.
    private static func interpolateOptional(
        _ sorted: [UsageDataPoint],
        i0: Int,
        i: Int,
        i3: Int,
        t: Double,
        key: KeyPath<UsageDataPoint, Double?>
    ) -> Double? {
        guard let p1 = sorted[i][keyPath: key],
              let p2 = sorted[i + 1][keyPath: key] else { return nil }
        let p0 = sorted[i0][keyPath: key] ?? p1
        let p3 = sorted[i3][keyPath: key] ?? p2
        return clampToUnitInterval(catmullRom(p0, p1, p2, p3, t: t))
    }
}
