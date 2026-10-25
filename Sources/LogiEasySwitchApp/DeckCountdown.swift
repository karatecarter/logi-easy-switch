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
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let now = ContinuousClock.now
            VStack(spacing: 5) {
                HStack {
                    Label(countdown.title, systemImage: "timer").lineLimit(1)
                    Spacer()
                    Text("\(countdown.remaining(at: now), specifier: "%.1f")s")
                        .monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
                ProgressView(value: countdown.fractionRemaining(at: now))
                    .progressViewStyle(.linear)
                    .accessibilityLabel(countdown.title)
                    .accessibilityValue("\(Int(ceil(countdown.remaining(at: now)))) seconds remaining")
            }
        }
    }
}
