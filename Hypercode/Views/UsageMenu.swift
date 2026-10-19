import Charts
import SwiftUI

/// The status-bar glyph: this week's daily bars, then the 5-hour session percentage.
/// Status items only take an image and text, so the bars are rendered into a template image.
struct UsageMenuLabel: View {
    let monitor: UsageMonitor

    var body: some View {
        Image(nsImage: glyph)
    }

    private var glyph: NSImage {
        let renderer = ImageRenderer(content: Glyph(days: monitor.days, percent: monitor.session?.percent))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }

    private struct Glyph: View {
        let days: [UsageMonitor.Day]
        let percent: Double?

        var body: some View {
            let peak = max(days.map(\.tokens).max() ?? 0, 1)
            HStack(spacing: 4) {
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(days) { day in
                        RoundedRectangle(cornerRadius: 1)
                            .frame(width: 2.5, height: max(2, 13 * CGFloat(day.tokens) / CGFloat(peak)))
                    }
                }
                .frame(height: 13, alignment: .bottom)
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(.black)
            .padding(.vertical, 2)
        }
    }
}

struct UsageMenu: View {
    let monitor: UsageMonitor
    @Environment(\.openWindow) private var openWindow
    @State private var selectedDay: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Claude Usage").font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await monitor.refresh() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .symbolEffect(.rotate, isActive: monitor.isRefreshing)
                    .disabled(monitor.isRefreshing)
            }

            if let session = monitor.session { LimitRow(title: "Session", window: session) }
            if let weekly = monitor.weekly { LimitRow(title: "Weekly", window: weekly) }
            ForEach(monitor.weeklyByModel, id: \.name) { LimitRow(title: "Weekly · \($0.name)", window: $0.window) }
            if let error = monitor.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            week

            Divider()

            HStack {
                Button("Open Hypercode") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                if let updatedAt = monitor.updatedAt {
                    Text("Updated \(updatedAt, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 320)
        .task { await monitor.refresh() }
    }

    private var week: some View {
        let selected = monitor.days.first { Calendar.current.isDate($0.date, inSameDayAs: selectedDay ?? .distantPast) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if let selected {
                    Text(selected.date, format: .dateTime.weekday(.wide).day().month())
                    Spacer()
                    Text("\(compact(selected.tokens)) tokens · \(selected.messages) replies")
                        .foregroundStyle(.secondary)
                } else {
                    Text("This Week")
                    Spacer()
                    Text("\(compact(monitor.weekTokens)) tokens")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .monospacedDigit()

            Chart(monitor.days) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.tokens))
                    .foregroundStyle(highlight(day, selected: selected) ? Color.accentColor : Color.secondary.opacity(0.35))
                    .clipShape(.rect(cornerRadius: 3))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) {
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .chartYAxis(.hidden)
            .chartXSelection(value: $selectedDay)
            .frame(height: 96)
        }
    }

    private func highlight(_ day: UsageMonitor.Day, selected: UsageMonitor.Day?) -> Bool {
        selected.map { $0.date == day.date } ?? Calendar.current.isDateInToday(day.date)
    }

    private func compact(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

private struct LimitRow: View {
    let title: String
    let window: UsageMonitor.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text("\(Int(window.percent.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(window.percent, 100), total: 100)
                .tint(window.percent >= 90 ? .red : window.percent >= 70 ? .orange : .accentColor)
            if let resetsAt = window.resetsAt {
                Text("Resets \(resetsAt, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

#if DEBUG
extension UsageMonitor {
    func writeSnapshots(to dir: URL) {
        func write(_ view: some View, _ name: String, dark: Bool) {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light)
                .background(dark ? Color(white: 0.16) : .white))
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: dir.appending(path: name))
        }
        write(UsageMenuLabel(monitor: self).padding(6), "label.png", dark: false)
        write(UsageMenu(monitor: self), "menu-light.png", dark: false)
        write(UsageMenu(monitor: self), "menu-dark.png", dark: true)
    }
}
#endif
