import CoreML
import FluidAudio
import Foundation

enum ComputeMode: String, CaseIterable, Identifiable, Sendable {
    case ane = "ANE"
    case cpu = "CPU"
    case gpu = "GPU (control)"

    var id: String { rawValue }

    var units: MLComputeUnits {
        switch self {
        case .ane: .cpuAndNeuralEngine
        case .cpu: .cpuOnly
        case .gpu: .cpuAndGPU
        }
    }
}

struct Transcription: Sendable {
    let text: String
    let wallMs: Double
    let libraryMs: Double
    let audioSeconds: Double
    var rtfx: Double { audioSeconds / (wallMs / 1000) }
}

enum EngineError: LocalizedError {
    case notLoaded
    var errorDescription: String? { "Models are not loaded" }
}

/// Owns the Parakeet TDT v3 models. Everything ASR-related goes through here.
actor AsrEngine {
    private var manager: AsrManager?
    private(set) var loadedMode: ComputeMode?
    private let converter = AudioConverter()

    /// Downloads (first run only) and returns the model directory.
    func download() async throws -> URL {
        try await AsrModels.download(version: .v3)
    }

    func load(mode: ComputeMode, from directory: URL) async throws {
        await unload()
        let config = AsrModels.defaultConfiguration()
        config.computeUnits = mode.units
        let models = try await AsrModels.load(
            from: directory, configuration: config, version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        loadedMode = mode
    }

    func unload() async {
        if let manager { await manager.cleanup() }
        manager = nil
        loadedMode = nil
    }

    /// 16 kHz mono samples in, text out. Fresh decoder state per call, like one dictation.
    func transcribe(_ samples16k: [Float]) async throws -> Transcription {
        guard let manager else { throw EngineError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let start = CFAbsoluteTimeGetCurrent()
        let result = try await manager.transcribe(samples16k, decoderState: &state)
        let wall = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return Transcription(
            text: result.text,
            wallMs: wall,
            libraryMs: result.processingTime * 1000,
            audioSeconds: Double(samples16k.count) / 16_000)
    }

    func resample(_ samples: [Float], from rate: Double) throws -> [Float] {
        try converter.resample(samples, from: rate)
    }

    func loadClip(_ url: URL) throws -> [Float] {
        try converter.resampleAudioFile(url)
    }
}
