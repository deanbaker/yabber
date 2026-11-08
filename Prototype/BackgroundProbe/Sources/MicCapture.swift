import AVFoundation
import Foundation

/// Keeps the audio session (and therefore the app) alive and buffers the last few seconds of mic audio.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var ring: [Float] = []
    private var framesCaptured = 0
    private var tapInstalled = false
    private(set) var sampleRate: Double = 48_000
    private let maxSeconds: Double = 15

    var onEvent: (@Sendable (String) -> Void)?

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            self?.onEvent?(
                "audio interruption \(type == .began ? "BEGAN" : "ENDED") reason=\(reason.map(String.init) ?? "-")")
        }
        nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.onEvent?("media services were RESET") }
        nc.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.onEvent?("audio engine configuration changed") }
    }

    var isRunning: Bool { engine.isRunning }

    var totalFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return framesCaptured
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // Mixable, so the final keyboard won't stop the user's music.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.append(buffer)
            }
            tapInstalled = true
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops the engine but leaves the session active (what an idle dictation app would like to do).
    func pauseEngine() {
        engine.pause()
    }

    func resumeEngine() throws {
        try engine.start()
    }

    func stop() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Native-rate samples from the end of the buffer, plus their RMS level.
    func lastSeconds(_ seconds: Double) -> (samples: [Float], rms: Float) {
        lock.lock()
        let n = min(ring.count, Int(seconds * sampleRate))
        let out = Array(ring.suffix(n))
        lock.unlock()
        let rms = out.isEmpty ? 0 : sqrt(out.reduce(0) { $0 + $1 * $1 } / Float(out.count))
        return (out, rms)
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        lock.lock()
        ring.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        let limit = Int(maxSeconds * sampleRate)
        if ring.count > limit { ring.removeFirst(ring.count - limit) }
        framesCaptured += count
        lock.unlock()
    }
}
