import Foundation
import SwiftUI

struct DeckCountdown {
    let title: String
    let duration: Double
    let deadline: ContinuousClock.Instant

    init(title: String, seconds: Double, now: ContinuousClock.Instant = .now) {
        self.title = title
        duration = seconds.isFinite ? min(86400, max(0, seconds)) : 0
        deadline = now.advanced(by: .seconds(duration))
    }
    func remaining(at now: ContinuousClock.Instant = .now) -> Double {
        let parts = now.duration(to: deadline).components
        return min(duration, max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18))
    }
    func fractionRemaining(at now: ContinuousClock.Instant = .now) -> Double {
        duration > 0 ? remaining(at: now) / duration : 0
    }
}

struct DeckCountdownView: View {
    let countdown: DeckCountdown
    var status: String? = nil
    var body: some View {
        VStack(spacing: 5) {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let remaining = countdown.remaining()
                HStack {
                    Label(status ?? countdown.title, systemImage: "timer").lineLimit(1)
                    Spacer()
                    Text("\(remaining, specifier: "%.1f")s")
                        .monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
            }
            // Draw directly at display cadence. AppKit's native progress indicator
            // can quantize updates even when its input value changes more often.
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
                let now = ContinuousClock.now
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Color.accentColor)
                            .frame(width: geometry.size.width * countdown.fractionRemaining(at: now))
                    }
                }
                .frame(height: 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(countdown.title)
                .accessibilityValue("\(Int(ceil(countdown.remaining(at: now)))) seconds remaining")
            }
        }
    }
}
