import Charts
import ClewCore
import ClewDomain
import SwiftUI

// SPEC 2026-11-18: Settings › Progress › Done so far (a line that only rises), and a
// goal's days as Bars or Heatmap in its Details.

/// "Done so far": the total, its range and the rising line.
struct DoneSoFarSection: View {
    let done: DoneSoFar
    let today: LocalDay
    @Binding var range: ProgressRange

    @State private var hovered: LocalDay?

    private var start: LocalDay { range.start(today: today, first: done.firstDay) }
    private var points: [DoneSoFar.Point] { done.series(from: start, through: today) }
    private var low: Int { done.total(through: start.adding(days: -1)) }
    private var total: Int { done.total(through: today) }
    private var rise: Int { total - low }

    private var subtitle: String {
        switch range {
        case .all: done.firstDay.map { String(localized: "since \(DoneSoFarText.date($0))") } ?? ""
        case .year: String(localized: "+\(rise.formatted()) in the last year")
        case .days30: String(localized: "+\(rise.formatted()) in the last 30 days")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Done so far").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if done.firstDay != nil {
                        Text(verbatim: String(localized: "\(total.formatted()) done"))
                            .font(.title2.weight(.semibold).monospacedDigit())
                        Text(verbatim: subtitle).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Picker(selection: $range) {
                    Text("30 days").tag(ProgressRange.days30)
                    Text("Year").tag(ProgressRange.year)
                    Text("All").tag(ProgressRange.all)
                } label: { Text("Range") }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(Text("Range"))
            }
            if done.firstDay == nil {
                VStack(spacing: 0) {
                    Text("Your first tick starts the line.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Line().stroke(style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        .foregroundStyle(.tertiary)
                        .frame(height: 1)
                        .padding(.bottom, 20)
                }
                .frame(height: 170)
            } else {
                chart.frame(height: 170)
            }
        }
        .padding(.vertical, 4)
    }

    /// Months between labels: one, or more when the range spans many months.
    private var monthStep: Int { max(1, (today.ordinal - start.ordinal) / 150) }

    private var chart: some View {
        let top = max(points.last?.total ?? 0, low + 1)
        return Chart {
            ForEach(points, id: \.day) { p in
                AreaMark(x: .value("Day", p.day.noon, unit: .day),
                         yStart: .value("Before", low), yEnd: .value("Done", p.total))
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                    .interpolationMethod(.linear)
                LineMark(x: .value("Day", p.day.noon, unit: .day), y: .value("Done", p.total))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
            // A ring on each day a goal reached its total.
            ForEach(points.filter(\.goalReached), id: \.day) { p in
                PointMark(x: .value("Day", p.day.noon, unit: .day), y: .value("Done", p.total))
                    .symbol { Circle().strokeBorder(Color.accentColor, lineWidth: 2).background(Circle().fill(.background)).frame(width: 9, height: 9) }
            }
            if let hovered, let p = points.first(where: { $0.day == hovered }) {
                RuleMark(x: .value("Day", p.day.noon, unit: .day))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        DoneSoFarTip(point: p)
                    }
                PointMark(x: .value("Day", p.day.noon, unit: .day), y: .value("Done", p.total))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(50)
            }
        }
        .chartYScale(domain: low...top)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel().font(.caption2)
            }
        }
        // One label a week for 30 days; a month apart (or more on a long history) for
        // Year and All, so a month is never named twice.
        .chartXAxis {
            if range == .days30 {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.caption2)
                }
            } else {
                AxisMarks(values: .stride(by: .month, count: monthStep)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated)).font(.caption2)
                }
            }
        }
        .chartOverlay { proxy in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if let date: Date = proxy.value(atX: location.x) {
                            hovered = LocalDay(picked: date)
                        }
                    case .ended:
                        hovered = nil
                    }
                }
        }
        .accessibilityLabel(Text(verbatim: DoneSoFarText.spoken(total: total, rise: rise, range: range)))
    }
}

/// The hover tip: "Nov 12 · 642 done · +9 that day".
private struct DoneSoFarTip: View {
    let point: DoneSoFar.Point

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: DoneSoFarText.date(point.day)).font(.caption2).foregroundStyle(.secondary)
            Text(verbatim: point.added > 0
                 ? String(localized: "\(point.total.formatted()) done · +\(point.added) that day")
                 : String(localized: "\(point.total.formatted()) done"))
                .font(.caption.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background).shadow(color: .black.opacity(0.15), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .fixedSize()
    }
}

enum DoneSoFarText {
    /// "Nov 12".
    static func date(_ day: LocalDay) -> String { day.noon.formatted(.dateTime.month(.abbreviated).day()) }

    /// "+364 on 22 days", "+5 on 1 day".
    static func onDays(total: Int, days: Int) -> String {
        days == 1 ? String(localized: "+\(total.formatted()) on 1 day")
                  : String(localized: "+\(total.formatted()) on \(days) days")
    }

    /// "Done so far: 1,284. 232 in the last 30 days."
    static func spoken(total: Int, rise: Int, range: ProgressRange) -> String {
        switch range {
        case .all: String(localized: "Done so far: \(total.formatted()).")
        case .year: String(localized: "Done so far: \(total.formatted()). \(rise.formatted()) in the last year.")
        case .days30: String(localized: "Done so far: \(total.formatted()). \(rise.formatted()) in the last 30 days.")
        }
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// A goal's days in its Details: Bars or Heatmap, chosen with a small switch and
/// remembered for all goals (SPEC 2026-11-18).
struct GoalDaysSection: View {
    let model: AppModel
    let details: ItemDetails

    @State private var chart: GoalChart = .bars

    /// The heatmap's first day: Monday of its first week.
    private var heatFirst: LocalDay {
        heatmapColumns(endingAt: details.today, weeks: Clew.heatmapWeeks).joined().compactMap { $0 }.min() ?? details.today
    }
    private var shown: GoalDays {
        GoalDays(amountByDay: details.stats.amountByDay, today: details.today,
                 count: chart == .bars ? 30 : details.today.ordinal - heatFirst.ordinal + 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(chart == .bars ? "Last 30 days" : "Last 16 weeks")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(selection: $chart) {
                    Text("Bars").tag(GoalChart.bars)
                    Text("Heatmap").tag(GoalChart.heatmap)
                } label: { Text("Show as") }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel(Text("Show as"))
            }
            if chart == .bars {
                GoalBars(days: GoalDays(amountByDay: details.stats.amountByDay, today: details.today))
            } else {
                Heatmap(details: details)
            }
            if shown.total > 0 {
                Text(verbatim: DoneSoFarText.onDays(total: shown.total, days: shown.daysWorked))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { chart = model.goalChart() }
        .onChange(of: chart) { _, new in model.setGoalChart(new) }
    }
}

/// The last 30 days, a bar a day, its height that day's +1s.
struct GoalBars: View {
    let days: GoalDays
    @State private var hovered: LocalDay?

    var body: some View {
        let most = days.most
        Chart {
            ForEach(days.days, id: \.day) { d in
                BarMark(x: .value("Day", d.day.noon, unit: .day), y: .value("+1s", d.amount), width: .ratio(0.7))
                    .foregroundStyle(Color.accentColor.opacity(d.day == hovered ? 1 : 0.55))
                    .cornerRadius(2)
            }
            if let most {
                RuleMark(y: .value("Most", most.amount))
                    .foregroundStyle(.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    // Above the line at its right end, inside the chart (it was cut off).
                    .annotation(position: .top, alignment: .trailing, spacing: 1) {
                        Text(verbatim: "\(most.amount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
            }
            if let hovered, let d = days.days.first(where: { $0.day == hovered }), d.amount > 0 {
                RuleMark(x: .value("Day", d.day.noon, unit: .day))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        HStack(spacing: 6) {
                            Text(verbatim: DoneSoFarText.date(d.day)).font(.caption2).foregroundStyle(.secondary)
                            Text(verbatim: "+\(d.amount)").font(.caption.weight(.semibold).monospacedDigit())
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.background).shadow(color: .black.opacity(0.15), radius: 6, y: 2))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                        .fixedSize()
                    }
            }
        }
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartOverlay { proxy in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if let date: Date = proxy.value(atX: location.x) { hovered = LocalDay(picked: date) }
                    case .ended:
                        hovered = nil
                    }
                }
        }
        .frame(height: 96)
        // The first day at the left, "Today" at the right, under the bars (as axis labels
        // the last one was cut off).
        .overlay(alignment: .bottom) {
            HStack {
                if let first = days.days.first?.day { Text(verbatim: DoneSoFarText.date(first)) }
                Spacer()
                Text("Today")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .offset(y: 14)
            .accessibilityHidden(true)
        }
        .padding(.bottom, 14)
        .accessibilityLabel(Text(verbatim: most.map {
            String(localized: "Last 30 days: \(DoneSoFarText.onDays(total: days.total, days: days.daysWorked)), most \($0.amount) on \(DoneSoFarText.date($0.day))")
        } ?? String(localized: "Last 30 days: nothing yet")))
    }
}
