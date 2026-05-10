import AVFoundation
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
}
