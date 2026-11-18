import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Converts any PCM buffer to 16 kHz mono Float32 (what the speech model expects).
final class MonoResampler {
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if inFormat == nil || inFormat! != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            converter?.downmix = true
            inFormat = buffer.format
        }
        guard let converter, buffer.frameLength > 0 else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

enum CaptureError: LocalizedError {
    case noMicrophone, coreAudio(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone found."
        case let .coreAudio(step, status): return "System audio capture failed at \(step) (error \(status))."
        }
    }
}

/// Your side of the call: the default microphone.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let resampler = MonoResampler()

    func start(_ onSamples: @escaping ([Float]) -> Void, voiceProcessingEnabled: Bool = true) throws {
        let input = engine.inputNode
        if voiceProcessingEnabled {
            // Voice processing is best-effort: some input devices do not expose it,
            // but recording should still work when the user leaves the setting on.
            try? input.setVoiceProcessingEnabled(true)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [resampler] buffer, _ in
            onSamples(resampler.convert(buffer))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// The other side of the call: everything the Mac plays (Zoom, Meet, Teams), via a Core Audio process tap (macOS 14.2+).
/// No bot joins the call and no virtual audio driver is needed.
final class SystemAudioCapture {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let resampler = MonoResampler()
    private let queue = DispatchQueue(label: "ai.inferoid.notes.systemaudio", qos: .userInitiated)

    func start(_ onSamples: @escaping ([Float]) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Inferoid"
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CaptureError.coreAudio("create tap", status) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.coreAudio("read tap format", status)
        }

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Inferoid Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw CaptureError.coreAudio("create aggregate device", status) }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [resampler] _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            onSamples(resampler.convert(buffer))
        }
        guard status == noErr else { throw CaptureError.coreAudio("create IO proc", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw CaptureError.coreAudio("start", status) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw CaptureError.coreAudio("find output device", status) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw CaptureError.coreAudio("read output device id", status) }
        return uid.takeRetainedValue() as String
    }
}

/// Splits a 16 kHz stream into utterances at pauses (energy-based), so each line of the live transcript
/// appears about a second after the speaker stops.
final class Segmenter {
    static let rate = 16_000
    private let frame = 480                      // 30 ms
    private let maxSamples = 16_000 * 14         // force a line every 14 s of continuous speech
    private var pending: [Float] = []
    private var current: [Float] = []
    private var preroll: [Float] = []
    private var inSpeech = false
    private var silentFrames = 0
    private var speechFrames = 0
    private var seen = 0
    private var start = 0
    private var noiseFloor: Float = 0.002
    private(set) var level: Float = 0
    private let onUtterance: ([Float], Double, Double) -> Void   // samples, start s, end s

    init(onUtterance: @escaping ([Float], Double, Double) -> Void) { self.onUtterance = onUtterance }

    func push(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= frame {
            process(pending[offset ..< offset + frame])
            offset += frame
        }
        pending.removeFirst(offset)
    }

    func flush() {
        if inSpeech, speechFrames >= 8 {
            onUtterance(current, Double(start) / Double(Self.rate), Double(seen) / Double(Self.rate))
        }
        inSpeech = false; current = []; silentFrames = 0; speechFrames = 0
    }

    private func process(_ f: ArraySlice<Float>) {
        var sum: Float = 0
        for x in f { sum += x * x }
        let rms = (sum / Float(f.count)).squareRoot()
        level = rms
        let speech = rms > max(0.006, noiseFloor * 3)
        if !speech { noiseFloor = noiseFloor * 0.99 + rms * 0.01 }
        seen += f.count
        if inSpeech {
            current.append(contentsOf: f)
            if speech { silentFrames = 0; speechFrames += 1 } else { silentFrames += 1 }
            if silentFrames >= 23 || current.count >= maxSamples { flush() }   // ~700 ms pause
        } else {
            preroll.append(contentsOf: f)
            if preroll.count > frame * 8 { preroll.removeFirst(preroll.count - frame * 8) }
            if speech {
                inSpeech = true; speechFrames = 1; silentFrames = 0
                start = seen - preroll.count
                current = preroll; preroll = []
            }
        }
    }
}
