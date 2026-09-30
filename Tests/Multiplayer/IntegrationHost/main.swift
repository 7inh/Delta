import UIKit
import DeltaCore
import NESDeltaCore

// A protocol-level mini host: real transport + real core, no Delta app UI.
// It advertises the test ROM digest, runs the local-ROM handshake, streams
// localFrames from the real Nestopia core, and performs one pause/resume cycle.
final class HostDelegate: UIResponder, UIApplicationDelegate
{
    var window: UIWindow?
    private let transport = MultiplayerTransport()
    private let bridge = NESEmulatorBridge.shared
    private let video = VideoManager(videoFormat: NES.core.videoFormat, options: [.metal: true])
    private var timer: Timer?
    private var romURL: URL!
    private var frameNumber: UInt64 = 0
    private var sentFrames = 0
    private var player2: UInt8 = 0
    private var sawLocalROM = false
    private var guestReady = false
    private var started = false
    private var paused = false
    private var resumed = false
    private var finished = false
    private var startAt: Date?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController()
        window?.makeKeyAndVisible()
        DispatchQueue.main.async { self.run() }
        return true
    }

    private func documents() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func finish(_ message: String, success: Bool)
    {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        transport.stop()
        print(message)
        fflush(stdout)
        try? message.write(to: documents().appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        exit(success ? 0 : 1)
    }

    private func run()
    {
        Delta.register(NES.core)
        let code = CommandLine.arguments.indices.first { CommandLine.arguments[$0] == "-code" }
            .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "492013"
        do
        {
            romURL = documents().appendingPathComponent("host.nes")
            try TestROM.make().write(to: romURL)
            video.prepare()
            bridge.audioRenderer = nil
            bridge.videoRenderer = video
            bridge.saveUpdateHandler = nil
            bridge.start(withGameURL: romURL)
            bridge.resetCheats()
            let digest = try MultiplayerLocalGame.digest(romURL)
            transport.onDiscoveryNotice = { [weak self] notice in
                if notice == nil { try? "HOST_LISTENING".write(to: self!.documents().appendingPathComponent("status.txt"), atomically: true, encoding: .utf8) }
            }
            transport.onPacket = { [weak self] in self?.receive($0) }
            transport.onReady = { [weak self] _ in
                guard let self else { return }
                self.guestReady = true
                self.transport.send(.pairKey, payload: MultiplayerPairing.returnKey)
                if self.sawLocalROM, !self.started { self.begin() }
            }
            transport.onDisconnect = { [weak self] message in
                // The guest ends its run by design at 15 s and leaves; that is a pass.
                guard let self else { return }
                let completed = self.resumed && self.sentFrames >= 200
                self.finish(completed ? "HOST_PASS frames=\(self.sentFrames) paused=\(self.paused) resumed=\(self.resumed) (guest left)"
                                      : "HOST_FAIL disconnected: \(message) frames=\(self.sentFrames) resumed=\(self.resumed)",
                            success: completed)
            }
            try transport.hostGame(title: "Integration Host", code: code, romDigest: digest)
        }
        catch { finish("HOST_FAIL setup: \(error)", success: false); return }
        startAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 17) {
            self.finish(self.sentFrames >= 200 && self.resumed ? "HOST_PASS frames=\(self.sentFrames) paused=\(self.paused) resumed=\(self.resumed)" : "HOST_FAIL frames=\(self.sentFrames) paused=\(self.paused) resumed=\(self.resumed)", success: self.sentFrames >= 200 && self.resumed)
        }
    }

    private func receive(_ packet: MultiplayerPacket)
    {
        switch packet.kind
        {
        case .localROM:
            sawLocalROM = true
            if guestReady, !started { begin() }
        case .input: player2 = packet.payload.first ?? 0
        case .started: startFrames()
        default: break
        }
    }

    private func begin()
    {
        started = true
        sendStateAnd(.start)
    }

    private func sendStateAnd(_ kind: MultiplayerPacket.Kind)
    {
        frameNumber = 0
        let epoch = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        do
        {
            let state = try MultiplayerLocalGame.snapshot(bridge)
            transport.sendMedia(.localState, payload: state, timestamp: epoch) { [weak self] sent in
                if !sent { self?.finish("HOST_FAIL could not send state", success: false) }
            }
            transport.send(kind, timestamp: epoch)
        }
        catch { finish("HOST_FAIL snapshot: \(error)", success: false) }
    }

    private func startFrames()
    {
        guard started, timer == nil else { return }
        if paused { paused = false; resumed = true }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, self.timer != nil else { return }
            let player1: UInt8 = (self.frameNumber % 60) < 30 ? 0x01 : 0x00
            MultiplayerLocalGame.apply(player1, self.player2, to: self.bridge)
            self.bridge.runFrame(processVideo: true)
            let frame = MultiplayerFrame(number: self.frameNumber, player1: player1, player2: self.player2,
                                         checksum: MultiplayerLocalGame.checksum(self.video))
            self.frameNumber += 1
            self.sentFrames += 1
            let timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
            self.transport.sendMedia(.localFrame, payload: frame.data, timestamp: timestamp) { _ in }
            if !self.paused, let startAt = self.startAt, Date().timeIntervalSince(startAt) > 5, !self.resumed { self.pauseThenResume() }
        }
    }

    private func pauseThenResume()
    {
        paused = true
        timer?.invalidate()
        timer = nil
        transport.send(.pause)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // The guest answers .resume with .started after loading the new state;
            // startFrames() then resumes the timer.
            self.sendStateAnd(.resume)
        }
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(HostDelegate.self))
