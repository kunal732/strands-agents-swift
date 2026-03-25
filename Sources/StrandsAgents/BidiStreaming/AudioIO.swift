#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Captures audio from the device microphone as a stream of PCM data chunks.
///
/// ```swift
/// let mic = MicrophoneInput(format: .mlxDefault)
/// try mic.start()
///
/// for await chunk in mic.audioStream {
///     try await session.send(.audio(chunk, format: .mlxDefault))
/// }
///
/// mic.stop()
/// ```
public final class MicrophoneInput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let format: AudioFormat
    private let bufferSize: AVAudioFrameCount
    private var continuation: AsyncStream<Data>.Continuation?

    /// Stream of audio data chunks from the microphone.
    public private(set) var audioStream: AsyncStream<Data>!

    public init(format: AudioFormat = .mlxDefault, bufferSize: AVAudioFrameCount = 4096) {
        self.format = format
        self.bufferSize = bufferSize

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.audioStream = stream
        self.continuation = continuation
    }

    /// Start capturing audio from the microphone.
    public func start() throws {
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: recordingFormat) { [weak self] buffer, _ in
            guard let self, let continuation = self.continuation else { return }

            // Convert to PCM16 data
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            var pcmData = Data(capacity: frameCount * 2)

            for i in 0..<frameCount {
                let sample = channelData[0][i]
                let clamped = max(-1.0, min(1.0, sample))
                var int16 = Int16(clamped * Float(Int16.max))
                pcmData.append(Data(bytes: &int16, count: 2))
            }

            continuation.yield(pcmData)
        }

        engine.prepare()
        try engine.start()
    }

    /// Stop capturing audio.
    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}

/// Plays audio data chunks through the device speaker.
///
/// ```swift
/// let speaker = SpeakerOutput(format: .mlxDefault)
/// speaker.start()
///
/// for try await event in session.events {
///     if case .audio(let data, let format) = event {
///         speaker.play(data)
///     }
/// }
///
/// speaker.stop()
/// ```
public final class SpeakerOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AudioFormat

    public init(format: AudioFormat = .mlxDefault) {
        self.format = format
    }

    /// Start the audio playback engine.
    public func start() throws {
        engine.attach(playerNode)

        let avFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        )!

        engine.connect(playerNode, to: engine.mainMixerNode, format: avFormat)
        engine.prepare()
        try engine.start()
        playerNode.play()
    }

    /// Play a chunk of audio data.
    public func play(_ data: Data) {
        let avFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        )!

        let frameCount = AVAudioFrameCount(data.count / (2 * format.channels))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        data.withUnsafeBytes { rawBuffer in
            guard let src = rawBuffer.baseAddress else { return }
            if let dst = buffer.int16ChannelData?[0] {
                memcpy(dst, src, data.count)
            }
        }

        playerNode.scheduleBuffer(buffer)
    }

    /// Stop playback.
    public func stop() {
        playerNode.stop()
        engine.stop()
    }

    /// Interrupt current playback (for when user starts speaking).
    public func interrupt() {
        playerNode.stop()
        playerNode.play()
    }
}
#endif
