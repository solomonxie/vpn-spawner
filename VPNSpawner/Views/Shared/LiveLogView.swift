import SwiftUI

/// What the app is doing right now, newest at the bottom.
struct LiveLogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(index == lines.count - 1 ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    if lines.isEmpty {
                        Text("Waiting for the first step…")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
            }
            .frame(height: 150)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            .onChange(of: lines.count) { _, count in
                withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Activity log")
    }
}
