import Foundation
import CoreImage
import CryptoKit
import DeltaCore
import NESDeltaCore

// Both peers use exactly the same ROM bytes and the host's frame-boundary inputs.
// No guest library save is ever loaded or written; the replica owns a temporary ROM copy.
enum MultiplayerLocalGame
{
    static func digest(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // Mapper, mirroring, trainer and timing flags affect emulation. Equal cartridge
        // data with different headers is not enough to guarantee deterministic replay.
        return Data(SHA256.hash(data: data))
    }

    static func apply(_ p1: UInt8, _ p2: UInt8, to bridge: NESEmulatorBridge) {
        bridge.resetInputs()
        for (player, buttons) in [p1, p2].enumerated() {
            for bit in 0..<8 where buttons & UInt8(1 << bit) != 0 {
                bridge.activateInput(1 << bit, value: 1, playerIndex: player)
            }
        }
    }

    static func checksum(_ video: VideoManager) -> UInt64 {
        guard let buffer = video.videoBuffer else { return 0 }
        let format = video.videoFormat
        guard case .bitmap(let pixel) = format.format else { return 0 }
        let count = Int(format.dimensions.width) * Int(format.dimensions.height) * pixel.bytesPerPixel
        return Data(SHA256.hash(data: Data(bytes: buffer, count: count))).integer(at: 0)
    }

    static func snapshot(_ bridge: NESEmulatorBridge) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        bridge.saveSaveState(to: url)
        let data = try Data(contentsOf: url)
        guard data.count >= 32, data.count <= MultiplayerPacket.maximumPayloadSize else { throw MultiplayerProtocolError.invalidPacket }
        return data
    }
}

final class MultiplayerFrameCapture
{
    var onFrame: ((MultiplayerFrame, UInt64, @escaping () -> Void) -> Void)?
    var onError: (() -> Void)?
    private let lock = NSLock()
    private var buttons: (UInt8, UInt8) = (0, 0)
    private var applied: (UInt8, UInt8) = (0, 0)
    private var number: UInt64 = 0
    private var pending = 0
    private var enabled = false
    private var stopped = false
    private var epoch: UInt64 = 0

    func setButtons(_ buttons: UInt8, player: Int) {
        lock.lock(); defer { lock.unlock() }
        if player == 0 { self.buttons.0 = buttons } else { self.buttons.1 = buttons }
    }
    func setEnabled(_ enabled: Bool) { lock.lock(); self.enabled = enabled; lock.unlock() }
    // Congestion gating: while sends are backed up, stop producing frames (the host game
    // briefly freezes) instead of accumulating a backlog that would end the session.
    var shouldRun: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && !stopped && pending < 30
    }
    func reset(epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        self.epoch = epoch; number = 0; buttons = (0, 0); enabled = false
    }
    func beforeFrame(_ bridge: NESEmulatorBridge) {
        lock.lock(); applied = buttons; lock.unlock()
        MultiplayerLocalGame.apply(applied.0, applied.1, to: bridge)
    }
    func afterFrame(_ video: VideoManager) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        guard pending < 64 else {
            stopped = true; lock.unlock()
            DispatchQueue.main.async { [weak self] in self?.onError?() }
            return
        }
        let number = self.number
        self.number += 1
        pending += 1
        let epoch = self.epoch
        lock.unlock()
        let frame = MultiplayerFrame(number: number, player1: applied.0, player2: applied.1, checksum: MultiplayerLocalGame.checksum(video))
        let timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let done = { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.pending -= 1; self.lock.unlock()
            }
            self.lock.lock(); let valid = !self.stopped && self.epoch == epoch; self.lock.unlock()
            guard valid, let onFrame = self.onFrame else { done(); return }
            onFrame(frame, timestamp, done)
        }
    }
    func stop() { lock.lock(); stopped = true; enabled = false; lock.unlock() }
}

final class MultiplayerLocalReplica
{
    var onFrame: ((CIImage?, Data, UInt64) -> Void)?
    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.deltaswipe.multiplayer.replica", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let bridge = NESEmulatorBridge.shared
    private let video = VideoManager(videoFormat: NES.core.videoFormat, options: [.metal: true])
    private let directory: URL
    private var image: CIImage?
    private var audio = Data()
    private var nextFrame: UInt64 = 0
    // Main-queue admission state keeps native work and delivery bounded together.
    private var pending = 0
    private let generationLock = NSLock()
    private var generation = 0

    private func advanceGeneration() -> Int {
        generationLock.lock(); defer { generationLock.unlock() }
        generation += 1
        return generation
    }
    private func isCurrent(_ value: Int) -> Bool {
        generationLock.lock(); defer { generationLock.unlock() }
        return generation == value
    }
    private var stopped = false

    init(romURL: URL) throws {
        queue.setSpecific(key: queueKey, value: true)
        guard bridge.gameURL == nil else { throw MultiplayerProtocolError.unexpectedMessage }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Nearby-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let copy = directory.appendingPathComponent("game.nes")
            try FileManager.default.copyItem(at: romURL, to: copy)
            video.prepare()
            bridge.audioRenderer = nil
            bridge.videoRenderer = video
            bridge.saveUpdateHandler = nil
            bridge.start(withGameURL: copy)
            bridge.resetCheats()
            video.frameHandler = { [weak self] in self?.image = $0 }
            bridge.audioFrameHandler = { [weak self] in self?.audio.append($0) }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func load(_ state: Data, completion: @escaping () -> Void) throws {
        guard !stopped, state.count >= 32, state.count <= MultiplayerPacket.maximumPayloadSize else { throw MultiplayerProtocolError.invalidPacket }
        let generation = advanceGeneration()
        let url = directory.appendingPathComponent("session-\(generation).state")
        try state.write(to: url, options: .atomic)
        // Core state loads must never block the main thread; ordering on the serial
        // queue still guarantees frames cannot run before the load completes.
        queue.async { [weak self] in
            defer { try? FileManager.default.removeItem(at: url) }
            guard let self, self.isCurrent(generation) else { return }
            self.bridge.loadSaveState(from: url)
            self.bridge.resetInputs()
            self.nextFrame = 0
            self.image = nil
            self.audio.removeAll(keepingCapacity: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.isCurrent(generation) else { return }
                completion()
            }
        }
    }

    func receive(_ frame: MultiplayerFrame, timestamp: UInt64) {
        guard !stopped else { return }
        // One second of frame backlog: bursts after Wi-Fi jitter are replayed in a fast
        // catch-up rather than dropping the session.
        guard pending < 60 else { onError?("The local game cannot keep up with the host. Please reconnect."); return }
        pending += 1
        let generation = self.generation
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isCurrent(generation) else {
                DispatchQueue.main.async { [weak self] in self?.pending -= 1 }
                return
            }
            guard frame.number == self.nextFrame else {
                self.deliverError("The local game lost frame synchronization. Please reconnect.", generation: generation)
                return
            }
            self.nextFrame += 1
            self.audio.removeAll(keepingCapacity: true)
            MultiplayerLocalGame.apply(frame.player1, frame.player2, to: self.bridge)
            self.bridge.runFrame(processVideo: true)
            // The core repeats the previous frame's video for the first frame after a state
            // load while still advancing the machine correctly, so frame 0 cannot be compared.
            if frame.number > 0, MultiplayerLocalGame.checksum(self.video) != frame.checksum {
                self.deliverError("The local game differs from the host. Check that both devices use the same app build.", generation: generation)
                return
            }
            let image = self.image, audio = self.audio
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending -= 1
                guard !self.stopped, self.isCurrent(generation) else { return }
                self.onFrame?(image, audio, timestamp)
            }
        }
    }

    private func deliverError(_ message: String, generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending -= 1
            guard !self.stopped, self.isCurrent(generation) else { return }
            self.onError?(message)
        }
    }

    func pause() {
        let generation = advanceGeneration()
        queue.async { [weak self] in
            guard let self, self.isCurrent(generation) else { return }
            self.bridge.resetInputs()
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        _ = advanceGeneration()
        // Cancel queued frames before waiting for the one native operation already running.
        // The NES bridge is a singleton: teardown must finish before solo play or a new
        // session can claim it, otherwise delayed cleanup can stop the new game.
        let cleanup = { [bridge, video, directory] in
            bridge.audioFrameHandler = nil
            video.frameHandler = nil
            bridge.resetInputs()
            bridge.stop()
            bridge.audioRenderer = nil
            bridge.videoRenderer = nil
            try? FileManager.default.removeItem(at: directory)
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { cleanup() }
        else { queue.sync(execute: cleanup) }
    }

    deinit { stop() }
}
