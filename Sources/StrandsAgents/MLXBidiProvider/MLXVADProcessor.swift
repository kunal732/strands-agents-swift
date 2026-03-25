import Foundation
import MLX
import MLXAudioVAD

/// Voice activity detection using MLX Audio's Sortformer model.
///
/// Detects whether an audio chunk contains speech, allowing the bidi pipeline
/// to skip STT processing on silence and reduce compute.
///
/// ```swift
/// let sortformer = try await SortformerModel.fromPretrained(
///     "mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16"
/// )
/// let vad = MLXVADProcessor(model: sortformer)
/// ```
public final class MLXVADProcessor: VADProcessor, @unchecked Sendable {
    private let model: SortformerModel
    private let threshold: Float

    public init(model: SortformerModel, threshold: Float = 0.5) {
        self.model = model
        self.threshold = threshold
    }

    public func detectSpeech(audio: Data, format: AudioFormat) async throws -> Bool {
        let floats = pcm16ToFloats(audio)
        let audioArray = MLXArray(floats, [floats.count])

        let result = try await model.generate(audio: audioArray, threshold: threshold)
        return !result.segments.isEmpty
    }

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
