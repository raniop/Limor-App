import AVFoundation
import CallKit
import Foundation
import Speech

/// Handles live speech-to-text via SFSpeechRecognizer + AVAudioEngine, plus
/// text-to-speech playback via AVSpeechSynthesizer. Used by the chat's voice
/// input sheet so the user can dictate to Limor in Hebrew or English.
@MainActor
final class VoiceService: NSObject, ObservableObject {
    static let shared = VoiceService()

    /// Currently-recognized text (updates live as the user speaks).
    @Published private(set) var transcript: String = ""

    /// True while the recognizer is actively listening.
    @Published private(set) var isRecording: Bool = false

    /// Microphone amplitude 0…1, sampled from the audio engine. UIs can
    /// drive a waveform/pulse off this.
    @Published private(set) var audioLevel: Float = 0

    /// True while a WhatsApp-style voice message is being recorded.
    @Published private(set) var isRecordingVoiceMessage: Bool = false
    /// Seconds elapsed in the current voice-message recording.
    @Published private(set) var voiceMessageDuration: TimeInterval = 0
    /// 0…1 mic amplitude for the voice-message recorder (used to drive
    /// the waveform in the recording overlay).
    @Published private(set) var voiceMessageLevel: Float = 0
    /// Audio file currently being played back via `play(audioAt:)`. The
    /// chat reads this to render a "playing" state on the matching bubble.
    @Published private(set) var playingAudioURL: URL?

    /// Last error surfaced by either authorization or recognition.
    @Published var errorMessage: String?

    enum SpeechLocale: String, CaseIterable, Identifiable {
        case hebrew = "he-IL"
        case english = "en-US"

        var id: String { rawValue }
        var label: String { self == .hebrew ? "עברית" : "English" }
        var localeIdentifier: String { rawValue }
    }

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()

    // Voice-message recorder (separate from live transcription — uses
    // AVAudioRecorder so we get a real M4A file we can upload + replay).
    private var voiceRecorder: AVAudioRecorder?
    private var voiceMessageURL: URL?
    private var voiceMessageStartedAt: Date?
    private var voiceMessageMeterTask: Task<Void, Never>?

    // Audio-message playback.
    private var audioPlayer: AVAudioPlayer?

    // CallKit observer — kept as a long-lived instance so its internal
    // call list stays warm. iOS reports both VoIP and (since iOS 14)
    // cellular calls through CXCallObserver, which is enough for us to
    // tell whether the mic would be useless because the Phone app
    // currently owns the audio session.
    private let callObserver = CXCallObserver()

    /// True when the system is in the middle of a phone or VoIP call —
    /// trying to record audio in that state produces garbage or fails
    /// outright, so we bail before even prompting the user.
    func isPhoneCallActive() -> Bool {
        callObserver.calls.contains { !$0.hasEnded }
    }

    /// Ask the user for both speech recognition + microphone permissions.
    /// Returns true only when both were granted; surfaces an error otherwise.
    func requestPermissions() async -> Bool {
        let speechAuth = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        guard speechAuth == .authorized else {
            errorMessage = "צריך לאשר זיהוי דיבור בהגדרות → לימור."
            return false
        }
        let micAuth = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
        guard micAuth else {
            errorMessage = "צריך לאשר גישה למיקרופון בהגדרות → לימור."
            return false
        }
        return true
    }

    func start(locale: SpeechLocale) async {
        guard !isRecording else { return }
        if isPhoneCallActive() {
            errorMessage = "אי אפשר להקליט בזמן שיחת טלפון. סיימי את השיחה ונסי שוב."
            return
        }
        guard await requestPermissions() else { return }

        // (Re)build the recognizer for the requested locale. Recognizers are
        // locale-scoped — switching between Hebrew/English requires a new one.
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale.localeIdentifier))
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "זיהוי דיבור ל-\(locale.label) לא זמין כרגע."
            return
        }

        // Reset prior state
        task?.cancel()
        task = nil
        transcript = ""

        do {
            try setupAudioSession()
            try startEngine(with: recognizer)
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isRecording = false
        audioLevel = 0
    }

    func reset() {
        stop()
        transcript = ""
        errorMessage = nil
    }

    // MARK: - TTS

    /// Speak Limor's reply aloud. Picks a Hebrew or English voice based on
    /// whether the text contains Hebrew characters.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        let isHebrew = trimmed.unicodeScalars.contains { $0.value >= 0x0590 && $0.value <= 0x05FF }
        utterance.voice = AVSpeechSynthesisVoice(language: isHebrew ? "he-IL" : "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        // Stop any in-flight utterance so we don't overlap.
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        synth.speak(utterance)
    }

    func stopSpeaking() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    // MARK: - Private

    private func setupAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func startEngine(with recognizer: SFSpeechRecognizer) throws {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(iOS 16, *) {
            req.addsPunctuation = true
        }
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        // Tap the mic — feed frames into both the recognizer and our audio
        // level meter. Reused single tap, removed on stop().
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            self?.updateAudioLevel(from: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stop()
                }
            }
        }
    }

    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        var sum: Float = 0
        for i in 0..<frameCount {
            let s = channelData[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frameCount))
        // Convert to a 0…1 perceptual level (RMS rarely exceeds 0.4).
        let level = min(1, max(0, rms * 6))
        Task { @MainActor in self.audioLevel = level }
    }

    // MARK: - Voice messages (WhatsApp-style)

    /// Start recording a voice message to an M4A file in the temp directory.
    /// On success, `isRecordingVoiceMessage` flips true and the publishers
    /// for duration/level start updating. Returns false if the user denied
    /// the mic permission or the session failed to start.
    func startVoiceMessage() async -> Bool {
        // Cellular / VoIP call in flight — refuse to start so we don't
        // briefly take over the audio session and drop the call, and so
        // the user sees a clear message instead of a "recording" UI
        // that produces silence.
        if isPhoneCallActive() {
            errorMessage = "אי אפשר להקליט הודעה קולית בזמן שיחת טלפון. סיימי את השיחה ונסי שוב."
            return false
        }
        let micAuth = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
        guard micAuth else {
            errorMessage = "צריך לאשר גישה למיקרופון בהגדרות → לימור."
            return false
        }

        // Use the same session category as the live transcription path so we
        // play nicely with any TTS / dictation already in flight.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "לא הצלחתי להפעיל אודיו: \(error.localizedDescription)"
            return false
        }

        // Record into the persistent voice-messages directory (not
        // tempDirectory) so the audio file survives the chat tab being
        // closed and re-opened — that's what lets the bubble keep its
        // play button after a history reload instead of degrading into
        // a transcript-only text bubble.
        let url = ChatMessage.voiceMessagesDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22050,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                errorMessage = "לא הצלחתי להתחיל הקלטה."
                return false
            }
            voiceRecorder = recorder
            voiceMessageURL = url
            voiceMessageStartedAt = Date()
            voiceMessageDuration = 0
            voiceMessageLevel = 0
            isRecordingVoiceMessage = true

            // Poll the meter + clock at 10 Hz so the recording UI can draw a
            // pulsing waveform and a running timer.
            voiceMessageMeterTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    await MainActor.run {
                        guard let self, let rec = self.voiceRecorder else { return }
                        rec.updateMeters()
                        let avg = rec.averagePower(forChannel: 0)
                        // AVAudioRecorder reports power in dB, -160…0. Map
                        // -60…0 to 0…1 — anything quieter is "silent" for
                        // our purposes.
                        self.voiceMessageLevel = max(0, min(1, (avg + 60) / 60))
                        if let started = self.voiceMessageStartedAt {
                            self.voiceMessageDuration = Date().timeIntervalSince(started)
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

    /// Stop the current voice-message recording. Returns the recorded URL
    /// and its duration on success; nil when the user cancelled, when the
    /// clip is too short to be useful (< 0.3s), or when no recording was
    /// in progress. The caller is responsible for deleting the file once
    /// it has been sent.
    @discardableResult
    func stopVoiceMessage(cancel: Bool) -> (url: URL, duration: TimeInterval)? {
        voiceMessageMeterTask?.cancel()
        voiceMessageMeterTask = nil

        let duration = voiceMessageDuration
        let url = voiceMessageURL

        voiceRecorder?.stop()
        voiceRecorder = nil
        voiceMessageURL = nil
        voiceMessageStartedAt = nil
        voiceMessageDuration = 0
        voiceMessageLevel = 0
        isRecordingVoiceMessage = false

        guard let url else { return nil }
        if cancel || duration < 0.3 {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return (url: url, duration: duration)
    }

    /// Run offline-friendly speech recognition over a recorded M4A file.
    /// Returns the transcript or nil when recognition wasn't available /
    /// finished without a result within 8 seconds.
    func transcribeAudioFile(url: URL, locale: SpeechLocale = .hebrew) async -> String? {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale.localeIdentifier))
        guard let recognizer, recognizer.isAvailable else { return nil }

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let lock = NSLock()
            var resolved = false
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            // Insert commas / periods between dictation pauses — without
            // this the chat-side `ShoppingDetector` sees "ביצים חלב
            // גבינה" as a single 4-word grocery item rather than four
            // separate items, and the dictated list gets merged.
            if #available(iOS 16, *) {
                request.addsPunctuation = true
            }

            let task = recognizer.recognitionTask(with: request) { result, error in
                lock.lock(); defer { lock.unlock() }
                guard !resolved else { return }
                if let result, result.isFinal {
                    resolved = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    resolved = true
                    cont.resume(returning: nil)
                }
            }

            Task {
                try? await Task.sleep(for: .seconds(8))
                lock.lock(); defer { lock.unlock() }
                guard !resolved else { return }
                resolved = true
                task.cancel()
                cont.resume(returning: nil)
            }
        }
    }

    // MARK: - Audio message playback

    /// Play (or pause) the audio file at `url`. Tapping a bubble's play
    /// button twice pauses, and starting a new clip while another is
    /// playing stops the previous one — only one clip at a time.
    func toggleAudioPlayback(url: URL) {
        if playingAudioURL == url, let player = audioPlayer, player.isPlaying {
            player.stop()
            audioPlayer = nil
            playingAudioURL = nil
            return
        }
        audioPlayer?.stop()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            guard player.play() else {
                errorMessage = "לא הצלחתי להפעיל את ההקלטה."
                return
            }
            audioPlayer = player
            playingAudioURL = url
        } catch {
            errorMessage = "לא הצלחתי להפעיל את ההקלטה: \(error.localizedDescription)"
        }
    }

    func stopAudioPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playingAudioURL = nil
    }
}

extension VoiceService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.audioPlayer = nil
            self.playingAudioURL = nil
        }
    }
}
