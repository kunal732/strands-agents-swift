import Foundation
import MLX
import MLXAudioSTT

/// Speech-to-text processor using MLX Audio STT models (GLMASR, Parakeet, Qwen3-ASR, etc.).
///
/// ```swift
/// let model = try await GLMASRModel.fromPretrained("mlx-community/GLM-ASR-Nano-2512-4bit")
/// let stt = MLXSTTProcessor(model: model)
/// let text = try await stt.transcribe(audio: audioData, format: .mlxDefault)
/// ```
public final class MLXSTTProcessor: STTProcessor, @unchecked Sendable {
    private let model: any STTGenerationModel
    private let parameters: STTGenerateParameters

    public init(model: any STTGenerationModel, parameters: STTGenerateParameters? = nil) {
        self.model = model
        self.parameters = parameters ?? model.defaultGenerationParameters
    }

    public func transcribe(audio: Data, format: AudioFormat) async throws -> String {
        let floats = pcm16ToFloats(audio)
        let audioArray = MLXArray(floats, [floats.count])

        let output = model.generate(audio: audioArray, generationParameters: parameters)
        return output.text
    }

    // MARK: - Private

    private func pcm16ToFloats(_ data: Data) -> [Float] {
        let sampleCount = data.count / 2
        var floats = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                floats[i] = Float(int16Buffer[i]) / Float(Int16.max)
            }
        }
        return floats
    }
}
