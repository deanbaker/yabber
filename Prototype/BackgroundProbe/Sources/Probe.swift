import AVFoundation
import Foundation
import UIKit

enum BackgroundPlan: String, CaseIterable, Identifiable {
    case quick = "1 min"
    case full = "6 min"

    var id: String { rawValue }

    /// Seconds after backgrounding at which to run a benchmark round.
    var checkpoints: [Double] {
        switch self {
        case .quick: [3, 30, 60]
        case .full: [3, 60, 180, 300, 360]
        }
    }
}

struct BenchRecord {
    let round: String
    let clip: String
    let inBackground: Bool
    let result: Transcription?
    let wer: Double?
    let error: String?
    let footprintMB: Double
}

/// Runs the whole experiment and writes a log to Documents/.
@MainActor
final class Probe: ObservableObject {
    @Published var mode: ComputeMode = .ane
    @Published var plan: BackgroundPlan = .full
    @Published var reloadInBackground = true
    @Published var micRestartTest = true
    @Published private(set) var status = "Idle. Pick a compute mode and run."
    @Published private(set) var lines: [String] = []
    @Published private(set) var running = false
    @Published private(set) var logURL: URL?

    private let engine = AsrEngine()
    private let mic = MicCapture()
    private var task: Task<Void, Never>?
    private var logHandle: FileHandle?
    private var t0 = Date()
    private var isBackground = UIApplication.shared.applicationState == .background
    private var records: [BenchRecord] = []
    private var clips: [(name: String, samples: [Float], reference: String)] = []
    private var benchInProgress = false
    private var peakFootprint = 0.0
    private var minAvailable = Double.greatestFiniteMagnitude

    static let shortText = "Please send the quarterly report to Sarah before Friday afternoon."
    static let longText =
        "I wanted to follow up on yesterday's meeting about the new onboarding flow. The team agreed to simplify the sign up screen, remove the optional survey, and add a short tutorial that explains the three main features. We still need final copy from marketing, and engineering estimates about two weeks of work. Let's review the designs together on Thursday morning."

    init() {
        mic.onEvent = { [weak self] message in
            Task { @MainActor in self?.log("AUDIO: \(message)") }
        }
        let nc = NotificationCenter.default
        let events: [(Notification.Name, String, Bool?)] = [
            (UIApplication.didEnterBackgroundNotification, "app → BACKGROUND", true),
            (UIApplication.willEnterForegroundNotification, "app → FOREGROUND", false),
            (UIApplication.willResignActiveNotification, "app will resign active", nil),
            (UIApplication.didBecomeActiveNotification, "app did become active", nil),
            (UIApplication.didReceiveMemoryWarningNotification, "MEMORY WARNING", nil),
            (ProcessInfo.thermalStateDidChangeNotification, "thermal state changed", nil),
        ]
        for (name, label, background) in events {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let background { self.isBackground = background }
                    self.log(label + (name == ProcessInfo.thermalStateDidChangeNotification ? ": \(Metrics.thermal())" : ""))
                }
            }
        }

        // `-autorun` lets scripts/probe.sh start a run with no taps: -autorun -mode CPU -plan "1 min"
        let defaults = UserDefaults.standard
        if ProcessInfo.processInfo.arguments.contains("-autorun") {
            if let m = defaults.string(forKey: "mode").flatMap(ComputeMode.init(rawValue:)) { mode = m }
            if let p = defaults.string(forKey: "plan").flatMap(BackgroundPlan.init(rawValue:)) { plan = p }
            Task { @MainActor in self.start() }
        }
    }

    func start() {
        guard !running else { return }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Experiment

    private func run() async {
        running = true
        records = []
        peakFootprint = 0
        minAvailable = .greatestFiniteMagnitude
        openLog()
        defer {
            mic.stop()
            running = false
            try? logHandle?.close()
            logHandle = nil
        }

        let device = UIDevice.current
        log("=== BackgroundProbe: \(Metrics.deviceModel()) \(device.systemName) \(device.systemVersion)")
        log("mode=\(mode.rawValue) plan=\(plan.rawValue) reloadInBg=\(reloadInBackground) micRestart=\(micRestartTest)")
        log("FluidAudio 0.18.3, Parakeet TDT v3 int8 encoder; lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) thermal=\(Metrics.thermal())")

        guard await AVAudioApplication.requestRecordPermission() else {
            log("Microphone permission denied. Enable it in Settings and rerun.")
            status = "Microphone permission denied."
            return
        }

        do {
            status = "Downloading models (first run only, about 0.5 GB)…"
            var t = Date()
            let directory = try await engine.download()
            log("models ready in \(secs(t)) at \(directory.lastPathComponent)")

            status = "Loading models on \(mode.rawValue)…"
            let before = Metrics.footprintMB()
            t = Date()
            try await engine.load(mode: mode, from: directory)
            log(String(format: "LOAD %@: %@, footprint %.0f → %.0f MB", mode.rawValue, secs(t), before, Metrics.footprintMB()))

            clips = [
                ("short", try await engine.loadClip(resource("short")), Self.shortText),
                ("long", try await engine.loadClip(resource("long")), Self.longText),
            ]
            log(String(format: "clips: short %.1fs, long %.1fs", seconds(clips[0].samples), seconds(clips[1].samples)))

            status = "Foreground benchmark…"
            await bench("fg-warmup", reps: ["short": 1, "long": 1])
            await bench("fg", reps: ["short": 5, "long": 3])
            try Task.checkCancellation()

            try mic.start()
            log(String(format: "mic running at %.0f Hz (session: playAndRecord, mixWithOthers)", mic.sampleRate))
            status = "Swipe up to go home now (or lock the phone). Talk while you're away. Come back after \(plan.rawValue)."
            log("waiting for the app to be backgrounded…")
            while !isBackground {
                try await Task.sleep(for: .milliseconds(250))
            }

            let backgroundStart = Date()
            let heartbeat = Task { await heartbeatLoop() }
            let live = Task { await liveMicLoop() }
            defer {
                heartbeat.cancel()
                live.cancel()
            }

            for checkpoint in plan.checkpoints {
                let wait = checkpoint - Date().timeIntervalSince(backgroundStart)
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                if !isBackground { log("note: app is in the foreground for round bg+\(Int(checkpoint))s") }
                await bench("bg+\(Int(checkpoint))s", reps: ["short": 3, "long": 2])
            }

            if reloadInBackground {
                await reloadWhileBackgrounded(directory: directory)
            }
            live.cancel()

            if micRestartTest {
                await micRestart()
            }

            summarize()
            status = "Done. Log: \(logURL?.lastPathComponent ?? "-")"
        } catch is CancellationError {
            log("cancelled")
            status = "Cancelled."
        } catch {
            log("ERROR: \(error.localizedDescription) (\(error))")
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func bench(_ round: String, reps: [String: Int]) async {
        benchInProgress = true
        defer { benchInProgress = false }
        for clip in clips {
            for i in 0..<(reps[clip.name] ?? 0) {
                let background = isBackground
                do {
                    let r = try await engine.transcribe(clip.samples)
                    let wer = Metrics.wer(reference: clip.reference, hypothesis: r.text)
                    records.append(.init(round: round, clip: clip.name, inBackground: background, result: r, wer: wer, error: nil, footprintMB: Metrics.footprintMB()))
                    var line = String(format: "%@ %@#%d: %.0f ms (lib %.0f), RTFx %.1f, WER %.0f%%", round, clip.name, i + 1, r.wallMs, r.libraryMs, r.rtfx, wer * 100)
                    if i == 0 && wer > 0 { line += " text=\"\(r.text)\"" }
                    log(line)
                } catch {
                    records.append(.init(round: round, clip: clip.name, inBackground: background, result: nil, wer: nil, error: "\(error)", footprintMB: Metrics.footprintMB()))
                    log("\(round) \(clip.name)#\(i + 1): FAILED \(error.localizedDescription) | \(error)")
                }
            }
        }
    }

    private func reloadWhileBackgrounded(directory: URL) async {
        log("reload test: unloading models while \(isBackground ? "backgrounded" : "in FOREGROUND")")
        let before = Metrics.footprintMB()
        await engine.unload()
        log(String(format: "unloaded: footprint %.0f → %.0f MB", before, Metrics.footprintMB()))
        let t = Date()
        do {
            try await engine.load(mode: mode, from: directory)
            log("RELOAD in background: \(secs(t)), footprint \(Int(Metrics.footprintMB())) MB")
            await bench("bg-reloaded", reps: ["short": 2, "long": 1])
        } catch {
            log("RELOAD in background FAILED after \(secs(t)): \(error)")
        }
    }

    /// Can we stop the mic while idle and start it again from the background?
    private func micRestart() async {
        log("mic restart test: pausing engine; session stays active")
        mic.pauseEngine()
        let asked = 20.0
        let t = Date()
        try? await Task.sleep(for: .seconds(asked))
        let elapsed = Date().timeIntervalSince(t)
        log(String(format: "woke after %.1fs (asked %.0fs)%@", elapsed, asked, elapsed > asked + 2 ? " → we were SUSPENDED while the mic was paused" : ""))
        let framesAtResume = mic.totalFrames
        do {
            try mic.resumeEngine()
            log("engine.start() from \(isBackground ? "background" : "foreground"): OK")
        } catch {
            log("engine.start() from \(isBackground ? "background" : "foreground"): FAILED \(error)")
        }
        try? await Task.sleep(for: .seconds(3))
        log("mic frames in 3 s after resume: \(mic.totalFrames - framesAtResume)")
    }

    private func heartbeatLoop() async {
        var last = Date()
        var lastFrames = mic.totalFrames
        var ticks = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let gap = Date().timeIntervalSince(last)
            if gap > 2.5 { log(String(format: "HEARTBEAT GAP %.1fs → process was suspended", gap)) }
            last = Date()
            ticks += 1
            if ticks % 30 == 0 {
                let frames = mic.totalFrames
                log("alive; mic frames in last 30 s: \(frames - lastFrames), engine running: \(mic.isRunning)")
                lastFrames = frames
            }
        }
    }

    /// The real use case: transcribe what was just said, from the background.
    private func liveMicLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, !benchInProgress else { continue }
            let (native, rms) = mic.lastSeconds(5)
            guard !native.isEmpty else { log("live: no mic samples"); continue }
            do {
                let samples = try await engine.resample(native, from: mic.sampleRate)
                let r = try await engine.transcribe(samples)
                log(String(format: "live (%@) 5s: %.0f ms, rms %.3f: \"%@\"", isBackground ? "bg" : "fg", r.wallMs, rms, r.text))
            } catch {
                log("live: FAILED \(error)")
            }
        }
    }

    private func summarize() {
        log("=== SUMMARY (\(mode.rawValue))")
        var seen: [String] = []
        for r in records where !seen.contains(r.round) { seen.append(r.round) }
        log("round          bg  short-ms(med)  long-ms(med)  long-RTFx  WER(mean)  fails  peakMB")
        for round in seen {
            let rs = records.filter { $0.round == round }
            let ok = rs.compactMap(\.result)
            let short = median(rs.filter { $0.clip == "short" }.compactMap { $0.result?.wallMs })
            let long = median(rs.filter { $0.clip == "long" }.compactMap { $0.result?.wallMs })
            let longRtfx = median(rs.filter { $0.clip == "long" }.compactMap { $0.result?.rtfx })
            let wers = rs.compactMap(\.wer)
            let wer = wers.isEmpty ? Double.nan : wers.reduce(0, +) / Double(wers.count)
            let bg = rs.allSatisfy(\.inBackground) ? "Y" : (rs.contains(where: \.inBackground) ? "~" : "N")
            log(round.padding(toLength: 14, withPad: " ", startingAt: 0) + String(format: " %@  %13.0f  %12.0f  %9.1f  %8.1f%%  %5d  %6.0f",
                       bg, short, long, longRtfx, wer * 100, rs.count - ok.count,
                       rs.map(\.footprintMB).max() ?? 0))
        }
        log(String(format: "peak footprint %.0f MB, min available %.0f MB", peakFootprint, minAvailable))
    }

    // MARK: - Logging

    private func openLog() {
        t0 = Date()
        lines = []
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "probe-\(mode == .gpu ? "GPU" : mode.rawValue)-\(f.string(from: t0)).log"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
        logURL = url
    }

    private func log(_ message: String) {
        let footprint = Metrics.footprintMB()
        let available = Metrics.availableMB()
        peakFootprint = max(peakFootprint, footprint)
        minAvailable = min(minAvailable, available)
        let line = String(format: "+%7.1fs %@ mem %4.0f/avail %5.0f  %@",
                          Date().timeIntervalSince(t0), isBackground ? "BG" : "fg", footprint, available, message)
        lines.append(line)
        if lines.count > 3000 { lines.removeFirst(500) }
        if let data = (line + "\n").data(using: .utf8) {
            try? logHandle?.write(contentsOf: data)
            try? logHandle?.synchronize()  // survive a jetsam kill
        }
    }

    private func resource(_ name: String) -> URL {
        Bundle.main.url(forResource: name, withExtension: "wav")!
    }

    private func secs(_ since: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(since))
    }

    private func seconds(_ samples: [Float]) -> Double { Double(samples.count) / 16_000 }
}
