import SwiftUI

enum Clock {
    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Large count-up clock with a caption, used while launching and cleaning up.
struct ElapsedClock: View {
    let since: Date
    let caption: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 4) {
                Text(Clock.format(context.date.timeIntervalSince(since)))
                    .font(.system(size: 56, weight: .light, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small coloured dot + label, e.g. "● Ready".
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct DemoBadge: View {
    var body: some View {
        Text("DEMO")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.15), in: Capsule())
            .foregroundStyle(.purple)
    }
}
