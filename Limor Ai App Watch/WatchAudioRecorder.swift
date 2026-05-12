import AVFoundation
import Foundation
import WatchKit

/// Tap-to-talk audio recorder for the watch. Apple's `Speech`
/// framework isn't available on watchOS, and `TextFieldLink` shows
/// a 4-tab system picker the user has to fight through to find the
/// mic — neither delivers the "tap, talk, send" experience. Instead
/// we capture raw audio with `AVAudioRecorder` into a small AAC file
/// in the temp dir, hand the bytes off to the iPhone over WCSession,
/// and let the iPhone do the heavy lifting (transcribe + chat-backend
/// roundtrip + reply).
///
/// Tap to start. Tap again to stop. No press-and-hold gymnastics —
/// which never works well through a sleeve on a real watch anyway.
@MainActor
final class WatchAudioRecorder: NSObject, ObservableObject {
    static let shared = WatchAudioRecorder()

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var startedAt: Date?
    private var ticker: Task<Void, Never>?

    /// Auto-cap so a forgotten recording doesn't grow past the
    /// `sendMessage` payload limit (~65KB; at 24kbps AAC ~16s gives
    /// us a comfortable margin). UI also exposes a stop button so
    /// the user rarely hits this.
    private let maxRecordingSeconds: TimeInterval = 15

    func requestPermissionIfNeeded() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// Begin a new recording. Idempotent — returns the current state
    /// if already recording. Returns `false` on permission denial or
    /// audio-session error and sets `errorMessage` for the UI.
    @discardableResult
    func start() async -> Bool {
        guard !isRecording else { return true }
        guard await requestPermissionIfNeeded() else {
            errorMessage = "צריך לאשר גישה למיקרופון בהגדרות"
            return false
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "לא הצלחתי להפעיל אודיו"
            return false
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-voice-\(UUID().uuidString).m4a")
        // 16kHz mono AAC at low quality keeps the file tiny — short
        // dictations land well under WCSession's sendMessage cap.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue,
            AVEncoderBitRateKey: 24000,
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            guard rec.record() else {
                errorMessage = "ההקלטה לא התחילה"
                return false
            }
            recorder = rec
            recordingURL = url
            startedAt = Date()
            elapsed = 0
            errorMessage = nil
            isRecording = true
            WKInterfaceDevice.current().play(.start)
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    await MainActor.run {
                        guard let self, self.isRecording else { return }
                        if let started = self.startedAt {
                            self.elapsed = Date().timeIntervalSince(started)
                            if self.elapsed >= self.maxRecordingSeconds {
                                _ = self.stop()
                            }
                        }
                    }
                }
            }
            return true
        } catch {
            errorMessage = "לא הצלחתי להתחיל הקלטה: \(error.localizedDescription)"
            return false
        }
    }

    /// Stop the recording and return the file URL. The caller is
    /// expected to read the bytes, ship them to the iPhone, and then
    /// delete the file.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        let url = recordingURL
        recorder = nil
        recordingURL = nil
        startedAt = nil
        isRecording = false
        WKInterfaceDevice.current().play(.stop)
        return url
    }

    func cancel() {
        guard let url = stop() else { return }
        try? FileManager.default.removeItem(at: url)
        WKInterfaceDevice.current().play(.failure)
    }
}
