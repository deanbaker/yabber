import CoreML
import FluidAudio
import Foundation

enum ComputePreference: String, CaseIterable, Identifiable, Codable {
    case auto = "Auto"
    case ane = "Neural Engine"
    case cpu = "CPU"
    var id: String { rawValue }
}

enum ComputeUnit: String, Sendable {
    case ane = "Neural Engine"
    case cpu = "CPU"
    var units: MLComputeUnits { self == .ane ? .cpuAndNeuralEngine : .cpuOnly }
}

enum ModelState: Equatable, Sendable {
    case notLoaded
    case downloading(Double)
    case loading(ComputeUnit)
    case ready(ComputeUnit)
    case failed(String)

    var label: String {
        switch self {
        case .notLoaded: "Not loaded"
        case .downloading(let f): "Downloading \(Int(f * 100))%"
        case .loading(let u): "Loading on \(u.rawValue)…"
        case .ready(let u): "Ready on \(u.rawValue)"
        case .failed(let m): "Failed: \(m)"
        }
    }

    var isReady: Bool { if case .ready = self { true } else { false } }
}

struct TranscriptionResult: Sendable {
    let text: String
    let audioSeconds: Double
    let latencyMs: Double
    let unit: ComputeUnit
}

/// Parakeet TDT v3 via FluidAudio. In Auto mode it loads on the Neural Engine and falls back
/// to the CPU if loading or a transcription fails there.
actor Transcriber {
    private var manager: AsrManager?
    private var unit: ComputeUnit?
    private var directory: URL?
    private var preparing: Task<Void, Error>?
    private let converter = AudioConverter()
    private var stateHandler: (@Sendable (ModelState) -> Void)?

    func setStateHandler(_ handler: @escaping @Sendable (ModelState) -> Void) {
        stateHandler = handler
    }

    /// Downloads (first run) and loads the models. Safe to call repeatedly.
    func prepare(_ preference: ComputePreference) async throws {
        if let preparing { return try await preparing.value }
        let task = Task { try await self.load(preference) }
        preparing = task
        defer { preparing = nil }
        try await task.value
    }

    private func load(_ preference: ComputePreference) async throws {
        do {
            if directory == nil {
                stateHandler?(.downloading(0))
                let handler = stateHandler
                directory = try await AsrModels.download(version: .v3) { progress in
                    handler?(.downloading(progress.fractionCompleted))
                }
            }
            let first: ComputeUnit = preference == .cpu ? .cpu : .ane
            do {
                try await load(unit: first)
            } catch where preference == .auto {
                SharedLog.write("asr", "Neural Engine load failed (\(error)); falling back to CPU")
                try await load(unit: .cpu)
            }
        } catch {
            stateHandler?(.failed(error.localizedDescription))
            throw error
        }
    }

    private func load(unit: ComputeUnit) async throws {
        guard let directory else { throw EngineError.notLoaded }
        if let manager { await manager.cleanup() }
        manager = nil
        self.unit = nil
        stateHandler?(.loading(unit))
        let start = CFAbsoluteTimeGetCurrent()
        let config = AsrModels.defaultConfiguration()
        config.computeUnits = unit.units
        let models = try await AsrModels.load(from: directory, configuration: config, version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        self.unit = unit
        SharedLog.write("asr", String(format: "loaded on %@ in %.2fs", unit.rawValue, CFAbsoluteTimeGetCurrent() - start))
        stateHandler?(.ready(unit))
    }

    func transcribe(_ samples: [Float], sampleRate: Double, preference: ComputePreference) async throws -> TranscriptionResult {
        if manager == nil { try await prepare(preference) }
        let audio = sampleRate == 16_000 ? samples : try converter.resample(samples, from: sampleRate)
        do {
            return try await run(audio)
        } catch where preference == .auto && unit == .ane {
            SharedLog.write("asr", "Neural Engine transcription failed (\(error)); retrying on CPU")
            try await load(unit: .cpu)
            return try await run(audio)
        }
    }

    private func run(_ audio: [Float]) async throws -> TranscriptionResult {
        guard let manager, let unit else { throw EngineError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await manager.transcribe(audio, decoderState: &state)
        return TranscriptionResult(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            audioSeconds: Double(audio.count) / 16_000,
            latencyMs: (CFAbsoluteTimeGetCurrent() - start) * 1000,
            unit: unit)
    }

    /// Switch compute units without re-downloading.
    func reload(_ preference: ComputePreference) async throws {
        if let manager { await manager.cleanup() }
        manager = nil
        unit = nil
        try await prepare(preference)
    }
}

enum EngineError: LocalizedError {
    case notLoaded
    var errorDescription: String? { "Models are not loaded" }
}
