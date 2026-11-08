import AVFoundation
import Foundation

/// Owns the mic. While a session is active the engine runs continuously (that is what keeps
/// the app alive in the background); samples are only kept while a dictation is recording,
/// plus a short pre-roll so the first syllable isn't clipped.
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var preroll: [Float] = []
    private var recording: [Float] = []
    private var isRecording = false
    private var tapInstalled = false
    private(set) var sampleRate: Double = 48_000

    private let prerollSeconds = 0.4
    /// Hard cap so a forgotten dictation can't eat memory (~110 MB at 48 kHz).
    let maxRecordingSeconds: Double = 600

    /// Called (on an arbitrary queue) when iOS takes the mic away or the route changes.
    var onEvent: (@Sendable (Event) -> Void)?

    enum Event {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case configurationChanged
        case mediaServicesReset
    }

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .began {
                self?.onEvent?(.interruptionBegan)
            } else {
                let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                self?.onEvent?(.interruptionEnded(
                    shouldResume: AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume)))
            }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.onEvent?(.configurationChanged)
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            self?.onEvent?(.mediaServicesReset)
        }
    }

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers: don't stop the user's music. No Bluetooth HFP: it would drop AirPods
        // to call quality for the whole idle window, so the built-in mic is used.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        try startEngine()
    }

    /// (Re)installs the tap with the current hardware format and starts the engine.
    func startEngine() throws {
        let input = engine.inputNode
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        lock.lock()
        sampleRate = format.sampleRate
        preroll = []
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        lock.lock()
        isRecording = false
        recording = []
        preroll = []
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func beginRecording() {
        lock.lock()
        recording = preroll
        isRecording = true
        lock.unlock()
    }

    /// Returns the native-rate samples recorded since `beginRecording`.
    func endRecording() -> (samples: [Float], sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        isRecording = false
        let out = recording
        recording = []
        return (out, sampleRate)
    }

    func cancelRecording() {
        lock.lock()
        isRecording = false
        recording = []
        lock.unlock()
    }

    var recordedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(recording.count) / sampleRate
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        lock.lock()
        if isRecording {
            if Double(recording.count) < maxRecordingSeconds * sampleRate {
                recording.append(contentsOf: samples)
            }
        } else {
            preroll.append(contentsOf: samples)
            let limit = Int(prerollSeconds * sampleRate)
            if preroll.count > limit { preroll.removeFirst(preroll.count - limit) }
        }
        lock.unlock()
    }
}
