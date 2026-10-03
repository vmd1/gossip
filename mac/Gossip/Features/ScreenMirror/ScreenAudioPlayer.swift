import AVFoundation

/// Plays the phone's captured audio (raw interleaved s16le PCM from the bridge) through the Mac's
/// default output. Keeps latency low by letting playback start after a small prebuffer and
/// dropping incoming audio instead of queueing when playback falls behind.
/// Not thread-safe: call `enqueue` from one queue (`ScreenBridgeClient`'s).
final class ScreenAudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let channels: Int
    private let sampleRate: Int
    private let lock = NSLock()
    private var queuedFrames = 0
    private var playing = false

    private var prebufferFrames: Int { sampleRate * 60 / 1000 }   // start after ~60 ms
    private var maxQueuedFrames: Int { sampleRate * 250 / 1000 }  // never lag more than ~250 ms

    init?(sampleRate: Int, channels: Int) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                         channels: AVAudioChannelCount(channels), interleaved: false) else { return nil }
        self.format = format
        self.channels = channels
        self.sampleRate = sampleRate
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch {
            gossipError("Gossip: audio engine failed to start: \(error)")
            return nil
        }
    }

    func enqueue(pcm: Data) {
        let frames = pcm.count / (2 * channels)
        guard frames > 0 else { return }
        lock.lock(); let backlog = queuedFrames; lock.unlock()
        if backlog > maxQueuedFrames { return } // fell behind: drop to catch up

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for f in 0..<frames {
                for c in 0..<channels {
                    out[c][f] = Float(Int16(littleEndian: samples[f * channels + c])) / 32768
                }
            }
        }
        lock.lock(); queuedFrames += frames; let total = queuedFrames; lock.unlock()
        node.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queuedFrames -= frames; self.lock.unlock()
        }
        if !playing, total >= prebufferFrames {
            playing = true
            node.play()
        }
    }

    func stop() {
        node.stop()
        engine.stop()
    }
}
