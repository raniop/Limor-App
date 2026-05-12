import SwiftUI
import WatchKit

/// "Ask Limor" entry point on the watch. Tapping the mic launches the
/// watchOS system dictation flow (`TextFieldLink`) — Apple doesn't
/// ship the full `Speech` framework on watchOS, so a custom press-
/// and-hold recorder isn't an option. The system flow gives us the
/// same outcome: user taps, talks, watchOS transcribes and hands us
/// back a string, which we ship to the iPhone over WCSession.
struct WatchPTTView: View {
    @State private var status: Status = .idle
    @State private var lastQuestion: String?
    @State private var lastReply: String?

    enum Status: Equatable {
        case idle
        case sending
        case error(String)
    }

    var body: some View {
        VStack(spacing: 8) {
            statusLine

            TextFieldLink(
                prompt: Text("מה לשאול את לימור?"),
                label: {
                    ZStack {
                        Circle()
                            .fill(circleGradient)
                            .frame(width: 90, height: 90)
                            .shadow(color: Color.indigo.opacity(0.6), radius: 8, y: 4)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                },
                onSubmit: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    send(trimmed)
                }
            )

            transcriptOrReply
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Subviews

    private var circleGradient: LinearGradient {
        switch status {
        case .error:
            return LinearGradient(
                colors: [Color.red, Color.orange],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [Color.indigo, Color.purple],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle where lastReply == nil:
            Text("הקש כדי לדבר ללימור")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .idle:
            Text("לימור ענתה")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .sending:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.6)
                Text("שולח ללימור…")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
        case .error(let message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var transcriptOrReply: some View {
        if let reply = lastReply, status == .idle {
            ScrollView {
                VStack(alignment: .center, spacing: 6) {
                    if let q = lastQuestion {
                        Text(q)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(reply)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Send

    private func send(_ text: String) {
        WKInterfaceDevice.current().play(.click)
        lastQuestion = text
        lastReply = nil
        status = .sending
        WatchSyncManager.shared.askLimor(text) { result in
            switch result {
            case .success(let reply):
                lastReply = reply
                status = .idle
                WKInterfaceDevice.current().play(.success)
            case .failure(let error):
                status = .error(error.localizedDescription)
                WKInterfaceDevice.current().play(.failure)
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if case .error = status { status = .idle }
                }
            }
        }
    }
}

#Preview {
    WatchPTTView()
        .environment(\.layoutDirection, .rightToLeft)
}
