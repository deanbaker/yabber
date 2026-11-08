import AVFoundation
import Foundation
import UIKit

struct HistoryItem: Codable, Identifiable {
    var id: UUID
    var date: Date
    var text: String
    var audioSeconds: Double
    var latencyMs: Double
    var unit: String
}

/// The app side of the keyboard protocol: holds the mic session, records on request,
/// transcribes, publishes status to the App Group, and ends the session when idle.
@MainActor
final class DictationService: ObservableObject {
    @Published private(set) var status = AppStatus()
    @Published private(set) var modelState: ModelState = .notLoaded
    @Published private(set) var history: [HistoryItem] = []
    /// True while a dictation started by the keyboard's "open app" jump is in progress.
    @Published private(set) var openedFromKeyboard = false
    @Published private(set) var lastError: String?

    @Published var idleMinutes: Double {
        didSet {
            UserDefaults.standard.set(idleMinutes, forKey: "idleMinutes")
            if status.sessionActive { touch() }
        }
    }

    @Published var computePreference: ComputePreference {
        didSet {
            UserDefaults.standard.set(computePreference.rawValue, forKey: "computePreference")
            Task { try? await transcriber.reload(computePreference) }
        }
    }

    static let idleChoices: [Double] = [1, 2, 5, 10, 15, 30]

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private var idleDeadline: Date?
    private var idleTask: Task<Void, Never>?
    private var transcribing: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        idleMinutes = defaults.object(forKey: "idleMinutes") as? Double ?? 5
        computePreference = defaults.string(forKey: "computePreference").flatMap(ComputePreference.init(rawValue:)) ?? .auto
        history = Self.loadHistory()

        let darwin = DarwinCenter.shared
        darwin.observe(.start) { [weak self] in self?.handleStart() }
        darwin.observe(.stop) { [weak self] in self?.handleStop() }
        darwin.observe(.cancel) { [weak self] in self?.handleCancel() }
        darwin.observe(.ping) { [weak self] in self?.publish() }

        recorder.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleAudioEvent(event) }
        }

        Task {
            await transcriber.setStateHandler { [weak self] state in
                Task { @MainActor in
                    self?.modelState = state
                    self?.status.modelReady = state.isReady
                    self?.publish()
                }
            }
            try? await transcriber.prepare(computePreference)
        }

        SharedLog.write("app", "launched")
        publish()
    }

    // MARK: - Session

    func startSession() {
        guard !status.sessionActive else { return }
        do {
            try recorder.start()
            status.sessionActive = true
            lastError = nil
            touch()
            startIdleWatch()
            SharedLog.write("app", "session started (\(Int(recorder.sampleRate)) Hz, idle stop \(Int(idleMinutes)) min)")
        } catch {
            lastError = "Couldn't start the microphone: \(error.localizedDescription)"
            SharedLog.write("app", "session start FAILED: \(error)")
        }
        publish()
    }

    func endSession(_ reason: String) {
        guard status.sessionActive else { return }
        if status.phase == .recording { recorder.cancelRecording() }
        recorder.stop()
        idleTask?.cancel()
        idleTask = nil
        idleDeadline = nil
        status.sessionActive = false
        if status.phase == .recording {
            status.phase = .failed
            status.message = "Session ended: \(reason)"
        }
        openedFromKeyboard = false
        SharedLog.write("app", "session ended: \(reason)")
        publish()
    }

    var sessionEndsAt: Date? { idleDeadline }

    /// Pushes the idle deadline out from now.
    private func touch() {
        idleDeadline = Date().addingTimeInterval(idleMinutes * 60)
    }

    private func startIdleWatch() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if self.status.phase == .recording {
                    if self.recorder.recordedSeconds >= self.recorder.maxRecordingSeconds - 1 {
                        SharedLog.write("app", "max recording length reached; stopping")
                        self.handleStop()
                    }
                    continue
                }
                if self.status.phase == .transcribing { continue }
                if let deadline = self.idleDeadline, Date() >= deadline {
                    self.endSession("idle for \(Int(self.idleMinutes)) min")
                    return
                }
            }
        }
    }

    // MARK: - Keyboard commands

    /// `wisprfree://dictate`: the keyboard couldn't reach a live session, so it opened us.
    func handleURL(_ url: URL) {
        guard url.scheme == WF.urlScheme else { return }
        SharedLog.write("app", "opened by URL \(url.absoluteString)")
        if url.host == "dictate" {
            openedFromKeyboard = true
            startSession()
            handleStart()
        }
    }

    private func handleStart() {
        guard let request = SharedStore.read(DictationRequest.self, from: .request) else {
            SharedLog.write("app", "start: no request.json")
            return
        }
        if !status.sessionActive {
            // We can only start the mic while in the foreground.
            if UIApplication.shared.applicationState == .active {
                startSession()
            } else {
                SharedLog.write("app", "start \(short(request.id)) ignored: no session and app not in foreground")
                publish()
                return
            }
        }
        guard status.sessionActive else { publish(); return }
        if status.phase == .recording {
            if status.requestID == request.id { publish(); return }
            recorder.cancelRecording()  // superseded by a newer request
        }
        recorder.beginRecording()
        status.phase = .recording
        status.requestID = request.id
        status.text = nil
        status.message = nil
        status.recordingStartedAt = Date()
        SharedLog.write("app", "recording \(short(request.id)) (\(Int(Date().timeIntervalSince(request.createdAt) * 1000)) ms after tap, \(appState))")
        publish()
    }

    func handleStop() {
        guard status.phase == .recording, let id = status.requestID else { publish(); return }
        let (samples, rate) = recorder.endRecording()
        status.phase = .transcribing
        publish()
        let preference = computePreference
        transcribing = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.transcriber.transcribe(samples, sampleRate: rate, preference: preference)
                self.finish(id: id, result: result)
            } catch {
                SharedLog.write("app", "transcription FAILED: \(error)")
                guard self.status.requestID == id else { return }
                self.status.phase = .failed
                self.status.message = "Transcription failed: \(error.localizedDescription)"
                self.touch()
                self.publish()
            }
        }
    }

    func handleCancel() {
        guard status.phase == .recording || status.phase == .transcribing else { publish(); return }
        recorder.cancelRecording()
        transcribing?.cancel()
        status.phase = .idle
        status.text = nil
        openedFromKeyboard = false
        touch()
        SharedLog.write("app", "cancelled \(status.requestID.map(short) ?? "-")")
        publish()
    }

    private func finish(id: UUID, result: TranscriptionResult) {
        SharedLog.write("app", String(format: "transcribed %@: %.1fs audio in %.0f ms on %@ (%@): \"%@\"",
                                      short(id), result.audioSeconds, result.latencyMs, result.unit.rawValue,
                                      appState, String(result.text.prefix(80))))
        if !result.text.isEmpty {
            history.insert(.init(id: id, date: Date(), text: result.text, audioSeconds: result.audioSeconds,
                                 latencyMs: result.latencyMs, unit: result.unit.rawValue), at: 0)
            if history.count > 50 { history.removeLast(history.count - 50) }
            saveHistory()
        }
        guard status.requestID == id else { return }  // cancelled or superseded meanwhile
        status.phase = .done
        status.text = result.text
        status.message = result.text.isEmpty ? "No speech detected" : nil
        openedFromKeyboard = false
        touch()
        publish()
    }

    private func handleAudioEvent(_ event: AudioRecorder.Event) {
        switch event {
        case .interruptionBegan:
            SharedLog.write("app", "audio interruption began (\(appState))")
            endSession("audio interrupted (call, Siri or another app took the mic)")
        case .interruptionEnded(let shouldResume):
            SharedLog.write("app", "audio interruption ended, shouldResume=\(shouldResume)")
        case .configurationChanged:
            guard status.sessionActive else { return }
            SharedLog.write("app", "audio route/config changed; restarting engine (\(appState))")
            do {
                try recorder.startEngine()
            } catch {
                SharedLog.write("app", "engine restart FAILED: \(error)")
                endSession("audio route changed and the mic couldn't restart")
            }
        case .mediaServicesReset:
            endSession("media services were reset")
        }
    }

    // MARK: - Status publishing

    private func publish() {
        status.updatedAt = Date()
        status.sessionEndsAt = idleDeadline
        SharedStore.write(status, to: .status)
        DarwinCenter.shared.post(.status)
    }

    private var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: "foreground"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    private func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    // MARK: - History

    private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("history.json")
    }

    private static func loadHistory() -> [HistoryItem] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? JSONDecoder().decode([HistoryItem].self, from: data)) ?? []
    }

    private func saveHistory() {
        try? FileManager.default.createDirectory(at: Self.historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(history).write(to: Self.historyURL, options: .atomic)
    }

    func clearHistory() {
        history = []
        saveHistory()
    }
}
