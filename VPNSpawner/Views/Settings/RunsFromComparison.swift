import SwiftUI

/// Side-by-side facts for the two execution modes; plain footer text, the selected column emphasized.
struct RunsFromComparison: View {
    let selected: ExecutionMode
    @State private var expanded = false

    private static let rows: [(label: String, phone: String, cloud: String)] = [
        ("Who does the work", "This iPhone", "A small function in your Tencent account"),
        ("If the phone closes", "Pauses, resumes when reopened", "Keeps going"),
        ("Safety net", "Self-destruct timer", "Self-destruct timer + 10-min watchdog"),
        ("Cost", "Free", "Under ¥0.01 per session"),
        ("Setup", "None", "One-time, about 10 minutes"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selected == .direct
                 ? "The app talks to Tencent Cloud directly with the key below."
                 : "The app only sends requests; the function launches, guards and deletes servers inside Tencent.")
                .lineLimit(expanded ? nil : 2)
            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("")
                        column("This iPhone", .direct, header: true)
                        column("Cloud function", .controller, header: true)
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Self.rows, id: \.label) { row in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(row.label).foregroundStyle(.secondary)
                            column(row.phone, .direct)
                            column(row.cloud, .controller)
                        }
                    }
                }
                .font(.caption)
                Text("Either way, every server deletes itself when its time runs out, even if this app is deleted.")
            }
            Button(expanded ? "Less" : "More") {
                withAnimation(.snappy) { expanded.toggle() }
            }
            .font(.footnote.weight(.semibold))
            .textCase(nil)
        }
    }

    private func column(_ text: String, _ mode: ExecutionMode, header: Bool = false) -> some View {
        Text(text)
            .fontWeight(header || mode == selected ? .semibold : .regular)
            .foregroundStyle(mode == selected ? Color.primary : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
