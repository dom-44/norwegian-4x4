import AVFoundation
import FourByFourCore
import os

/// Spoken coaching and transition tones.
///
/// Audio session policy:
/// * Category `.playback` so cues are audible with the silent switch on and
///   while the screen is locked (requires the `audio` background mode).
/// * `.duckOthers` + `.interruptSpokenAudioAndMixWithOthers`: Spotify / YouTube
///   keep playing, lowered while a cue is spoken; podcasts pause briefly.
/// * The session is only active while a cue plays and is deactivated with
///   `.notifyOthersOnDeactivation` so other apps return to full volume.
/// * The app never plays silent audio to keep itself alive.
@MainActor
final class CoachingAudio: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var tonePlayers: [AVAudioPlayer] = []
    private var interrupted = false
    private var deactivateTask: Task<Void, Never>?
    private let log = Logger(subsystem: "Norwegian4x4", category: "Audio")
    var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        synthesizer.delegate = self
        let center = NotificationCenter.default
        // AVAudioSession may post on background threads; hop to main.
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.handleInterruption(note) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.handleRouteChange(note) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleMediaServicesReset() }
            }
        ]
    }

    func perform(_ action: CoachingAction) {
        guard !action.isEmpty, !interrupted else { return }
        if action.sound != nil || action.speech != nil {
            guard activateSession() else { return }
        }
        if let sound = action.sound { play(sound) }
        if let speech = action.speech { speak(speech, delay: action.sound == nil ? 0 : 0.45) }
        if action.speech == nil { scheduleDeactivation(after: 1.2) }
    }

    func speak(_ text: String, delay: TimeInterval = 0) {
        guard !interrupted, activateSession() else { return }
        deactivateTask?.cancel()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = speechRate
        utterance.preUtteranceDelay = delay
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first?.hasPrefix("en") == true ? Locale.preferredLanguages.first : "en-US")
        synthesizer.speak(utterance)
    }

    func stopAll() {
        synthesizer.stopSpeaking(at: .immediate)
        tonePlayers.forEach { $0.stop() }
        tonePlayers.removeAll()
        scheduleDeactivation(after: 0)
    }

    // MARK: Session

    private func activateSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
            return true
        } catch {
            // E.g. during a phone call. The workout continues silently.
            log.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func scheduleDeactivation(after delay: TimeInterval) {
        deactivateTask?.cancel()
        deactivateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.synthesizer.isSpeaking else { return }
            if self.tonePlayers.contains(where: \.isPlaying) { return self.scheduleDeactivation(after: 0.5) }
            self.tonePlayers.removeAll()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Tones

    private func play(_ sound: SoundCue) {
        let data: Data
        switch sound {
        case .transition(let tone):
            switch tone {
            case .none: return
            case .rising: data = ToneSynth.wav(notes: [(660, 0.12), (880, 0.12), (1_175, 0.22)])
            case .falling: data = ToneSynth.wav(notes: [(1_175, 0.12), (880, 0.12), (660, 0.22)])
            case .chime: data = ToneSynth.wav(notes: [(988, 0.15), (1_319, 0.3)])
            }
        case .countdownTick:
            data = ToneSynth.wav(notes: [(1_047, 0.09)])
        case .completed:
            data = ToneSynth.wav(notes: [(784, 0.14), (988, 0.14), (1_175, 0.14), (1_568, 0.35)])
        }
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = 0.9
        player.play()
        tonePlayers.append(player)
    }

    // MARK: Notifications

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // Phone call, Siri, alarm: stay quiet; the timer keeps running.
            interrupted = true
            synthesizer.stopSpeaking(at: .immediate)
        case .ended:
            interrupted = false
        @unknown default:
            interrupted = false
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable {
            // Headphones removed: cut the current cue rather than blasting it
            // from the speaker mid-sentence. Future cues use the new route.
            synthesizer.stopSpeaking(at: .word)
        }
    }

    private func handleMediaServicesReset() {
        tonePlayers.removeAll()
        interrupted = false
    }
}

extension CoachingAudio: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.scheduleDeactivation(after: 0.4) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.scheduleDeactivation(after: 0.2) }
    }
}

/// Generates short sine-tone sequences as in-memory WAV files, so the app
/// ships no audio assets.
enum ToneSynth {
    static func wav(notes: [(frequency: Double, duration: Double)], sampleRate: Double = 44_100) -> Data {
        var samples: [Int16] = []
        for note in notes {
            let count = Int(note.duration * sampleRate)
            let fade = min(count / 4, Int(0.01 * sampleRate))
            for i in 0..<count {
                var amplitude = 0.45
                if i < fade { amplitude *= Double(i) / Double(fade) }
                if i > count - fade { amplitude *= Double(count - i) / Double(fade) }
                let value = sin(2 * .pi * note.frequency * Double(i) / sampleRate) * amplitude
                samples.append(Int16(value * Double(Int16.max)))
            }
            samples += [Int16](repeating: 0, count: Int(0.03 * sampleRate))
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate) * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        for s in samples { append(s) }
        return data
    }
}

/// Voice preview from Settings (outside a workout).
@MainActor
enum CoachingPreview {
    private static let synthesizer = AVSpeechSynthesizer()

    static func speak(_ text: String, rate: Double) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(rate)
        synthesizer.speak(utterance)
    }
}
