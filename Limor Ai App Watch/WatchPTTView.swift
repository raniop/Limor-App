import SwiftUI
import WatchKit

/// "Ask Limor" tab — tap the mic to start recording, tap again to
/// stop and send. The watch records via `AVAudioRecorder`, ships the
/// bytes to the iPhone over WCSession, and the iPhone handles
/// transcription + chat. Reply text comes back inline.
struct WatchPTTView: View {
    @StateObject private var recorder = WatchAudioRecorder.shared
    @State private var status: Status = .idle
    @State private var lastReply: String?

    enum Status: Equatable {
        case idle
        case sending
        case error(String)
    }

    var body: some View {
        VStack(spacing: 8) {
            statusLine

            Button(action: toggle) {
                ZStack {
                    Circle()
                        .fill(circleGradient)
                        .frame(width: 90, height: 90)
                        .shadow(color: recorder.isRecording ? Color.red.opacity(0.5) : Color.indigo.opacity(0.5),
                                radius: recorder.isRecording ? 16 : 8, y: 4)
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                        .scaleEffect(recorder.isRecording ? 1.08 : 1)
                        .animation(
                            recorder.isRecording
                                ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                                : .default,
                            value: recorder.isRecording
                        )
                }
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: recorder.isRecording)

            if recorder.isRecording {
                Text(String(format: "%.1fs", recorder.elapsed))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.red)
            }

            transcriptOrReply
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Subviews

    private var circleGradient: LinearGradient {
        if recorder.isRecording {
            return LinearGradient(
                colors: [Color.red, Color.pink],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        if case .error = status {
            return LinearGradient(
                colors: [Color.red, Color.orange],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color.indigo, Color.purple],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        if let errorText = recorder.errorMessage {
            Text(errorText)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else {
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
                    Text("מתמלל ושולח…")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            case .error(let m):
                Text(m).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var transcriptOrReply: some View {
        if let reply = lastReply, status == .idle, !recorder.isRecording {
            ScrollView {
                Text(reply)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Actions

    private func toggle() {
        if recorder.isRecording {
            sendCurrentRecording()
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        lastReply = nil
        status = .idle
        Task { await recorder.start() }
    }

    private func sendCurrentRecording() {
        guard let url = recorder.stop() else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url) else {
            status = .error("לא הצלחתי לקרוא את ההקלטה")
            return
        }
        status = .sending
        WatchSyncManager.shared.askLimorVoice(data) { result in
            switch result {
            case .success(let reply):
                lastReply = reply
                status = .idle
                WKInterfaceDevice.current().play(.success)
            case .failure(let err):
                status = .error(err.localizedDescription)
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
