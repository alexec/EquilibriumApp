import AVFoundation
import Foundation
import Speech

/// Speech-to-text for the day panel, which takes intentions and check-ins
/// by voice rather than by typing.
///
/// Recognition is pinned on-device (`requiresOnDeviceRecognition`). That's
/// not a preference: the app ships no network entitlement and tells people
/// nothing leaves their Mac, and the server-side path would both break that
/// promise and fail without networking. A language whose on-device model
/// isn't downloaded is reported as unavailable rather than quietly falling
/// back to Apple's servers.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var isListening = false
    /// What's been heard in this run. The panel appends it to whatever the
    /// field already held, so a second dictation adds to the first.
    @Published private(set) var transcript = ""
    /// Why dictation can't run, phrased for display; nil when it can.
    @Published private(set) var unavailableReason: String?

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async {
        guard !isListening else { return }
        transcript = ""
        unavailableReason = nil

        guard let recognizer else {
            unavailableReason = "Dictation doesn't support this Mac's language."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            unavailableReason = "This language has no on-device dictation downloaded. System Settings › Keyboard › Dictation."
            return
        }
        guard await requestAuthorisation() else {
            unavailableReason = "Dictation needs the microphone and speech recognition. System Settings › Privacy & Security."
            return
        }
        guard recognizer.isAvailable else {
            unavailableReason = "Dictation isn't available at the moment."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            unavailableReason = "No microphone is available."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            unavailableReason = "The microphone wouldn't start."
            return
        }

        isListening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Results arrive off the main actor; everything published here
            // drives the panel, so it all hops back first.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        guard isListening || engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
    }

    /// Both permissions, in the order the user meets them: speech first
    /// (the feature), then the microphone (how it hears you).
    private func requestAuthorisation() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}
