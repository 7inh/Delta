import Foundation
import CoreImage
import VideoToolbox
import AVFoundation
import QuartzCore

private func mediaTime() -> UInt64 { UInt64(CACurrentMediaTime() * 1_000_000) }

// A single frame may be encoding/sending at a time; capture never waits for the network.
final class MultiplayerVideoEncoder
{
    var onFrame: ((Data, UInt64, @escaping () -> Void) -> Void)?
    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.deltaswipe.multiplayer.encoder", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    private var stopped = false
    private var needsKeyFrame = true
    private var session: VTCompressionSession?
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    func capture(_ image: CIImage)
    {
        lock.lock()
        guard !busy, !stopped else { lock.unlock(); return }
        busy = true
        let keyFrame = needsKeyFrame
        needsKeyFrame = false
        lock.unlock()
        let timestamp = mediaTime()
        queue.async { [weak self] in
            guard let self else { return }
            do
            {
                if self.session == nil { try self.prepare() }
                guard let session = self.session, let pool = VTCompressionSessionGetPixelBufferPool(session) else { throw MultiplayerProtocolError.invalidPacket }
                var pixelBuffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { throw MultiplayerProtocolError.invalidPacket }
                let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                let scaled = normalized.transformed(by: CGAffineTransform(scaleX: 256 / normalized.extent.width, y: 240 / normalized.extent.height))
                self.context.render(scaled, to: pixelBuffer, bounds: CGRect(x: 0, y: 0, width: 256, height: 240), colorSpace: CGColorSpaceCreateDeviceRGB())
                let properties = keyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
                let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
                    presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 1_000_000),
                    duration: CMTime(value: 1, timescale: 60), frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil)
                guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            }
            catch { self.finish(); self.report(error) }
        }
    }

    func requestKeyFrame()
    {
        lock.lock(); needsKeyFrame = true; lock.unlock()
    }

    func stop()
    {
        lock.lock(); stopped = true; lock.unlock()
        queue.async { [self] in
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
        }
    }

    private func finish() { lock.lock(); busy = false; lock.unlock() }

    private func prepare() throws
    {
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = VTCompressionSessionCreate(allocator: nil, width: 256, height: 240, codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sample in
                guard let refcon else { return }
                let encoder = Unmanaged<MultiplayerVideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
                guard status == noErr else {
                    encoder.finish()
                    encoder.report(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
                    return
                }
                guard let sample else { encoder.finish(); encoder.requestKeyFrame(); return }
                encoder.output(sample)
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard status == noErr, let session else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        for (key, value) in [kVTCompressionPropertyKey_RealTime: true as CFTypeRef,
                             kVTCompressionPropertyKey_AllowFrameReordering: false as CFTypeRef,
                             kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
                             kVTCompressionPropertyKey_ExpectedFrameRate: 60 as CFTypeRef,
                             kVTCompressionPropertyKey_MaxKeyFrameInterval: 60 as CFTypeRef,
                             kVTCompressionPropertyKey_AverageBitRate: 1_500_000 as CFTypeRef]
        {
            let result = VTSessionSetProperty(session, key: key, value: value)
            guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepared == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(prepared)) }
    }

    private func output(_ sample: CMSampleBuffer)
    {
        do
        {
            guard let format = CMSampleBufferGetFormatDescription(sample), let block = CMSampleBufferGetDataBuffer(sample) else { throw MultiplayerProtocolError.invalidPacket }
            var payload = Data()
            // Include parameter sets with every frame so decoder reconfiguration is self-contained.
            for index in 0..<2
            {
                var pointer: UnsafePointer<UInt8>?
                var length = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &length, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                    let pointer, length <= Int(UInt16.max) else { throw MultiplayerProtocolError.invalidPacket }
                payload.appendInteger(UInt16(length))
                payload.append(pointer, count: length)
            }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == noErr else { throw MultiplayerProtocolError.invalidPacket }
            payload.append(bytes)
            let timestamp = UInt64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1_000_000)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
                guard !stopped, let onFrame = self.onFrame else { self.finish(); return }
                onFrame(payload, timestamp) { [weak self] in self?.finish() }
            }
        }
        catch { finish(); report(error) }
    }

    private func report(_ error: Error)
    {
        DispatchQueue.main.async { [weak self] in self?.onError?("Video streaming failed: \(error.localizedDescription)") }
    }

    deinit { if let session { VTCompressionSessionInvalidate(session) } }
}

final class MultiplayerVideoDecoder
{
    var onImage: ((CIImage, UInt64) -> Void)?
    var onError: ((String) -> Void)?
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameters = Data()
    private var needsKeyFrame = true
    private var generation = 0

    // Decoding is synchronous on the main queue at NES resolution; no queued compressed frames accumulate.
    func decode(_ payload: Data, timestamp: UInt64)
    {
        do
        {
            var offset = 0
            func readParameter() throws -> Data
            {
                guard offset + 2 <= payload.count else { throw MultiplayerProtocolError.invalidPacket }
                let length = Int(payload.integer(at: offset, as: UInt16.self))
                offset += 2
                guard length > 0, offset + length <= payload.count else { throw MultiplayerProtocolError.invalidPacket }
                defer { offset += length }
                return Data(payload[offset..<(offset + length)])
            }
            let sps = try readParameter()
            let pps = try readParameter()
            let newParameters = Data(payload.prefix(offset))
            guard offset < payload.count else { throw MultiplayerProtocolError.invalidPacket }
            if newParameters != parameters || session == nil
            {
                stop()
                let status = sps.withUnsafeBytes { spsBytes in
                    pps.withUnsafeBytes { ppsBytes in
                        let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                        let lengths = [sps.count, pps.count]
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                            parameterSetPointers: pointers, parameterSetSizes: lengths, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                    }
                }
                guard status == noErr, let format else { throw MultiplayerProtocolError.invalidPacket }
                let size = CMVideoFormatDescriptionGetDimensions(format)
                guard size.width == 256, size.height == 240 else { throw MultiplayerProtocolError.invalidPacket }
                let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
                guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                    imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session) == noErr else { throw MultiplayerProtocolError.invalidPacket }
                parameters = newParameters
            }
            guard let session, let format else { throw MultiplayerProtocolError.invalidPacket }
            let bytes = Data(payload.dropFirst(offset))
            var cursor = 0
            var isKeyFrame = false
            while cursor < bytes.count
            {
                guard cursor + 4 <= bytes.count else { throw MultiplayerProtocolError.invalidPacket }
                let length = Int(bytes.integer(at: cursor, as: UInt32.self))
                cursor += 4
                guard length > 0, length <= bytes.count - cursor else { throw MultiplayerProtocolError.invalidPacket }
                isKeyFrame = isKeyFrame || (bytes[cursor] & 0x1f == 5)
                cursor += length
            }
            // A frame already in flight when pause occurred can precede the requested IDR.
            if needsKeyFrame && !isKeyFrame { return }
            needsKeyFrame = false
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr,
                let block else { throw MultiplayerProtocolError.invalidPacket }
            let copied = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
            guard copied == noErr else { throw MultiplayerProtocolError.invalidPacket }
            var sample: CMSampleBuffer?
            var sampleSize = bytes.count
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 1_000_000), decodeTimeStamp: .invalid)
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
                let sample else { throw MultiplayerProtocolError.invalidPacket }
            let generation = self.generation
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
                let deliver = { [weak self] in
                    guard let self, self.generation == generation else { return }
                    guard status == noErr else { self.onError?("The video stream could not be decoded."); return }
                    if let image { self.onImage?(CIImage(cvPixelBuffer: image), timestamp) }
                }
                // Never invalidate the decoder from inside its output callback (including errors).
                DispatchQueue.main.async(execute: deliver)
            }
            guard status == noErr else { throw MultiplayerProtocolError.invalidPacket }
        }
        catch { onError?("The video stream could not be decoded.") }
    }

    func stop()
    {
        generation += 1
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        parameters = Data()
        needsKeyFrame = true
    }

    deinit { stop() }
}

// Both streams use this host-to-local clock, with a small jitter allowance.
final class MultiplayerMediaPlayer
{
    var onImage: ((CIImage) -> Void)?
    var onError: ((String) -> Void)?
    var isMuted = false { didSet { node.volume = isMuted ? 0 : 1 } }
    private(set) var scheduledAudioBuffers = 0
    private let decoder = MultiplayerVideoDecoder()
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var origin: (host: UInt64, local: Double)?
    private var displayLink: CADisplayLink?
    private var images = [(time: Double, image: CIImage)]()
    private var audioBuffers = 0
    // Next free instant on the audio timeline; buffers never overlap, so a late burst
    // keeps its spacing instead of playing back-to-back.
    private var audioCursor = 0.0
    private var generation = 0
    private var started = false
    private var playbackDelay = 0.035

    init()
    {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        decoder.onImage = { [weak self] image, timestamp in self?.receiveImage(image, timestamp: timestamp) }
        decoder.onError = { [weak self] message in self?.onError?(message) }
    }

    func receiveImage(_ image: CIImage, timestamp: UInt64)
    {
        guard started else { return }
        images.append((localTime(timestamp), image))
        if images.count > 4 { images.removeFirst(images.count - 4) }
    }

    func start(playbackDelay: Double = 0.035) throws
    {
        guard !started else { return }
        self.playbackDelay = playbackDelay
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.005)
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start()
        node.play()
        started = true
        let link = CADisplayLink(target: self, selector: #selector(displayFrame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func receive(_ packet: MultiplayerPacket)
    {
        guard started else { return }
        if packet.kind == .video { decoder.decode(packet.payload, timestamp: packet.timestamp); return }
        guard packet.kind == .audio else { return }
        var time = localTime(packet.timestamp)
        let now = CACurrentMediaTime()
        // Presentation/route changes can delay the first packet and then deliver a burst.
        // Keep the newest sound and re-anchor both streams rather than accumulating latency.
        guard time >= now - 0.08 else { return }
        time = max(time, audioCursor)
        if audioBuffers >= 8 || time > now + 0.1
        {
            generation += 1
            node.stop()
            audioBuffers = 0
            images.removeAll()
            origin = (packet.timestamp, now + playbackDelay)
            time = now + playbackDelay
            do { if !engine.isRunning { try engine.start() }; node.play() }
            catch { onError?("Audio playback could not restart: \(error.localizedDescription)"); return }
        }
        else if time - localTime(packet.timestamp) > 0.06
        {
            // The cursor is lagging the host schedule by more than jitter margin; skip this
            // frame's sound to shed the absorbed delay one frame at a time.
            return
        }
        if time < now { time = now }
        let count = AVAudioFrameCount(packet.payload.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count), let pointer = buffer.floatChannelData else { return }
        buffer.frameLength = count
        packet.payload.withUnsafeBytes { bytes in
            for index in 0..<Int(count)
            {
                let sample = UInt16(bytes[index * 2]) | (UInt16(bytes[index * 2 + 1]) << 8)
                pointer[0][index] = Float(Int16(bitPattern: sample)) / 32768
            }
        }
        audioBuffers += 1
        scheduledAudioBuffers += 1
        audioCursor = time + Double(count) / format.sampleRate
        let generation = self.generation
        node.scheduleBuffer(buffer, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: time)), options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.audioBuffers = max(0, self.audioBuffers - 1)
            }
        }
    }

    func pause()
    {
        generation += 1
        node.stop()
        images.removeAll()
        audioBuffers = 0
        audioCursor = 0
        origin = nil
        decoder.stop()
        if started { node.play() }
    }

    func stop()
    {
        started = false
        displayLink?.invalidate()
        displayLink = nil
        pause()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func localTime(_ timestamp: UInt64) -> Double
    {
        if origin == nil { origin = (timestamp, CACurrentMediaTime() + playbackDelay) }
        let origin = origin!
        return origin.local + (Double(timestamp) - Double(origin.host)) / 1_000_000
    }

    @objc private func displayFrame()
    {
        let now = CACurrentMediaTime()
        var latest: CIImage?
        while let frame = images.first, frame.time <= now
        {
            latest = frame.image
            images.removeFirst()
        }
        if let latest { onImage?(latest) }
    }

    deinit { displayLink?.invalidate() }
}
