import AVFoundation
import Foundation
import os
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
///
/// One run of dictation is several recognition tasks, not one. A task ends
/// itself at the first real pause, and again when it has heard as much
/// audio as it will take at a stretch — neither of which means the person
/// has finished talking. Each ending closes a *segment*: what it heard is
/// settled into the transcript and a fresh segment opens on the same
/// running engine, so thinking mid-sentence costs a comma rather than the
/// rest of the check-in. Only a press of stop, or `silenceLimit` of nothing
/// being said, ends the run.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var isListening = false
    /// What's been heard in this run. The panel appends it to whatever the
    /// field already held, so a second dictation adds to the first.
    @Published private(set) var transcript = ""
    /// Why dictation can't run, phrased for display; nil when it can.
    @Published private(set) var unavailableReason: String?

    /// How long the microphone stays open hearing nothing before the run
    /// ends on its own. Generous enough to cover looking out of the window
    /// mid-thought, short enough that a panel left open doesn't listen all
    /// afternoon.
    private static let silenceLimit: TimeInterval = 30
    /// Backstop for a segment that ends the instant it starts: a recogniser
    /// that has broken rather than gone quiet would otherwise be restarted
    /// as fast as it could fail, for the whole of `silenceLimit`.
    private static let emptyRestartLimit = 10

    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    /// Stands between the audio tap and whichever request is current.
    private let sink = AudioSink()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// The run's transcript in two halves: what closed segments settled on,
    /// and what the open one has heard so far. Split because a segment's
    /// text is rewritten in place as it firms up, and must not overwrite
    /// the segments before it.
    private var settled = ""
    private var pending = ""

    /// Bumped by every start and every stop. `isListening` doesn't turn
    /// true until the engine is running, and the permission check before
    /// that suspends — long enough for a second press to walk in behind the
    /// first. Each start remembers the number it took, and only the newest
    /// one is allowed to touch the engine, so a run that has been overtaken
    /// or stopped bows out instead of installing a second tap on the input.
    ///
    /// A counter rather than a flag because a flag would have to be held
    /// for the whole permission prompt — which can sit on screen for as
    /// long as it likes — and every press during it would be swallowed.
    private var generation = 0
    /// Which segment's results are still wanted. A task keeps reporting
    /// after it has closed, and a task left running to deliver its tail
    /// (see `stop()`) is disowned by the next run bumping this.
    private var segment = 0
    /// When something was last actually heard, which is what `silenceLimit`
    /// is measured from — not when the last segment happened to end.
    private var lastHeard = Date()
    private var emptyRestarts = 0

    func start() async {
        guard !isListening else { return }
        generation += 1
        let thisStart = generation
        // A previous run's task may still be finishing its tail. This run
        // supersedes it, so its words belong to nobody.
        segment += 1
        task?.cancel()
        task = nil
        transcript = ""
        settled = ""
        pending = ""
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

        // Asking for permission suspends. A stop, or a newer start, while
        // that was happening means this run is no longer the one wanted —
        // checked before anything is built, so a cancelled run leaves
        // nothing of itself behind.
        guard thisStart == generation else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            unavailableReason = "No microphone is available."
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [sink] buffer, _ in
            sink.append(buffer)
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
        lastHeard = Date()
        emptyRestarts = 0
        beginSegment()
    }

    /// Safe to call at any point, including while a start is still waiting
    /// on permission: bumping the counter is what tells that run to stand
    /// down, and everything below is cleared whether or not the engine ever
    /// got going.
    ///
    /// The recognition task is left running rather than cancelled. What was
    /// said in the last moment before the press is still in audio the
    /// recogniser hasn't worked through, and cancelling discards it —
    /// sentences ended a word or two early. Ending the audio instead makes
    /// it transcribe what it has and report one last time, so the tail
    /// lands in `transcript` shortly after the microphone has gone quiet.
    func stop() {
        generation += 1
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        sink.use(nil)
        request?.endAudio()
        request = nil
        isListening = false
    }

    /// Opens a recognition request on the already-running engine and points
    /// the tap at it. Audio recorded between one segment closing and this
    /// running is dropped, which is the hop back to the main actor and no
    /// more — a pause is what closed the segment, so there is nothing in it
    /// to lose.
    private func beginSegment() {
        guard let recognizer else { return }
        segment += 1
        let thisSegment = segment

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request
        sink.use(request)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Results arrive off the main actor; everything published here
            // drives the panel, so it all hops back first.
            Task { @MainActor [weak self] in
                guard let self, thisSegment == self.segment else { return }
                if let result {
                    self.pending = result.bestTranscription.formattedString
                    if !self.pending.isEmpty { self.lastHeard = Date() }
                    self.transcript = self.combined
                }
                guard result?.isFinal == true || error != nil else { return }
                self.endSegment()
            }
        }
    }

    /// The segment has said all it's going to. Settle its words, then open
    /// another unless the run is over — either because stop was pressed, or
    /// because nothing has been said for long enough that nobody is there.
    private func endSegment() {
        // Disowns the closed task before anything else: it can report again
        // on its way out, and those reports are this segment's words a
        // second time.
        segment += 1
        request = nil
        task = nil
        sink.use(nil)

        settled = combined
        transcript = settled
        emptyRestarts = pending.isEmpty ? emptyRestarts + 1 : 0
        pending = ""

        guard isListening else { return }
        guard Date().timeIntervalSince(lastHeard) < Self.silenceLimit,
              emptyRestarts < Self.emptyRestartLimit
        else {
            stop()
            return
        }
        beginSegment()
    }

    /// Settled segments and the open one, as one piece of speech.
    private var combined: String {
        guard !pending.isEmpty else { return settled }
        return settled.isEmpty ? pending : settled + " " + pending
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

/// Carries buffers from the audio tap to the request that wants them.
///
/// The tap is installed once and runs on an audio thread, while the request
/// underneath it is replaced at every segment boundary — so the two can't
/// simply be captured together, and the tap can't reach through the
/// main-actor-isolated `Dictation` to find the current one. This hands the
/// tap whichever request is open, and hands it nothing once dictation has
/// stopped.
///
/// The caller is a real-time audio thread, which shapes both halves. The
/// lock is `os_unfair_lock`, whose owner inherits the waiter's priority —
/// a plain mutex has no such thing, so the audio thread could be left
/// waiting on a main thread the scheduler had put down. And it's held only
/// long enough to read the reference: handing the buffer over is the
/// expensive part and happens outside, so neither side can be stalled by
/// the other doing real work.
///
/// Buffers are never dropped to avoid waiting. What arrives here is speech,
/// and a buffer discarded at a segment boundary is a word missing from the
/// seam — the failure this whole file exists to stop.
private final class AudioSink: @unchecked Sendable {
    private let current = OSAllocatedUnfairLock<SFSpeechAudioBufferRecognitionRequest?>(uncheckedState: nil)

    func use(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        current.withLockUnchecked { $0 = request }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Appending outside the lock leaves a hair's-breadth window where a
        // buffer already in flight reaches a request that `stop()` has just
        // ended. An ended request ignores what arrives after it, so that
        // costs a buffer nobody was waiting on, and it buys a lock the
        // audio thread can never be caught behind.
        let request = current.withLockUnchecked { $0 }
        request?.append(buffer)
    }
}
