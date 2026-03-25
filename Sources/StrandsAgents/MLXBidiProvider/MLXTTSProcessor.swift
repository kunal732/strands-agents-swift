import Foundation
import MLX
import MLXAudioTTS

/// Text-to-speech processor using MLX Audio TTS models (Soprano, Orpheus, Qwen3-TTS, etc.).
///
/// Supports streaming audio output -- chunks are yielded as they're generated,
/// allowing playback to begin before the full utterance is synthesized.
///
/// ```swift
/// let tts = MLXTTSProcessor(model: sopranoModel)
/// for try await audioChunk in tts.synthesize(text: "Hello!", voice: nil) {
///     speaker.play(audioChunk)
/// }
/// ```
public final class MLXTTSProcessor: TTSProcessor, @unchecked Sendable {
    private let model: any SpeechGenerationModel
    private let outputSampleRate: Int

    public init(model: any SpeechGenerationModel) {
        self.model = model
        self.outputSampleRate = model.sampleRate
    }

    public func synthesize(text: String, voice: String?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let stream = self.model.generateStream(
                        text: text,
                        voice: voice,
                        refAudio: nil,
                        refText: nil,
                        language: nil,
                        generationParameters: self.model.defaultGenerationParameters
                    )

                    for try await generation in stream {
                        // AudioGeneration is an enum: .token, .info, .audio(MLXArray)
                        if case .audio(let audioArray) = generation {
                            let floats = audioArray.asArray(Float.self)
                            let pcmData = self.floatsToPCM16(floats)
                            continuation.yield(pcmData)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    /// Convert Float array [-1, 1] to PCM16 little-endian Data.
    private func floatsToPCM16(_ floats: [Float]) -> Data {
        var data = Data(capacity: floats.count * 2)
        for sample in floats {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * Float(Int16.max))
            data.append(Data(bytes: &int16, count: 2))
        }
        return data
    }
}
