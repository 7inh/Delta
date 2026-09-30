import UIKit
import DeltaCore
import NESDeltaCore

final class ReplicaSmokeDelegate: UIResponder, UIApplicationDelegate
{
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController()
        window?.makeKeyAndVisible()
        DispatchQueue.main.async { self.run() }
        return true
    }
    func run()
    {
        Delta.register(NES.core)
        var checks = 0
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(name)") }
        }
        let message: String
        do
        {
            let bridge = NESEmulatorBridge.shared
            let video = VideoManager(videoFormat: NES.core.videoFormat, options: [.metal: true])
            video.prepare()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReplicaSmoke", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let romURL = directory.appendingPathComponent("game.nes")
            try TestROM.make().write(to: romURL)
            bridge.audioRenderer = nil
            bridge.videoRenderer = video
            bridge.saveUpdateHandler = nil
            bridge.start(withGameURL: romURL)
            bridge.resetCheats()
            check(bridge.gameURL == romURL, "test ROM starts")

            let stateURL = directory.appendingPathComponent("session.state")
            func replay(_ state: Data, _ script: [(UInt8, UInt8)]) throws -> ([UInt64], [UInt8]) {
                try state.write(to: stateURL, options: .atomic)
                bridge.loadSaveState(from: stateURL)
                bridge.resetInputs()
                var checksums = [UInt64]()
                var counters = [UInt8]()
                for (player1, player2) in script {
                    MultiplayerLocalGame.apply(player1, player2, to: bridge)
                    bridge.runFrame(processVideo: true)
                    checksums.append(MultiplayerLocalGame.checksum(video))
                    counters.append(bridge.readMemory(at: 0x20, size: 1)?.first ?? 0)
                }
                return (checksums, counters)
            }

            let state = try MultiplayerLocalGame.snapshot(bridge)
            check(state.count >= 32 && state.count <= MultiplayerPacket.maximumPayloadSize, "snapshot size is portable")

            // The core repeats the previous frame's video for the first frame after loading a
            // state into a machine that has already run frames (the machine state itself still
            // advances correctly), mirroring the guest after a host pause/resume. CPU-side
            // counters must therefore match on every frame, video checksums from frame 1 on.
            let idle = [(UInt8, UInt8)](repeating: (0, 0), count: 12)
            let idleFirst = try replay(state, idle)
            let idleSecond = try replay(state, idle)
            check(idleFirst.1 == idleSecond.1, "machine state replays identically on every frame")
            check(Array(idleFirst.0.dropFirst()) == Array(idleSecond.0.dropFirst()), "video replays identically from frame 1")

            var script = [(UInt8, UInt8)]()
            for index in 0..<12 {
                script.append((index >= 4 ? 0x01 : 0x00, index >= 8 ? 0x80 : 0x00)) // A from frame 4, Up from frame 8
            }
            let first = try replay(state, script)
            let second = try replay(state, script)
            check(first.1 == second.1, "input-driven replays advance the machine identically")
            check(Array(first.0.dropFirst()) == Array(second.0.dropFirst()), "same state and inputs replay identically from frame 1")
            check(Set(first.0).count > 1, "frames produce changing video")

            let passive = script.map { (UInt8(0), $0.1) } // never press A
            let third = try replay(state, passive)
            check(Array(third.0.dropFirst()) != Array(first.0.dropFirst()) || third.1 != first.1, "different inputs produce a different replay")

            // ROM headers carry mapper and timing configuration and must affect matching.
            var changed = TestROM.make()
            changed[6] ^= 0x10
            let changedURL = directory.appendingPathComponent("other.nes")
            try changed.write(to: changedURL)
            let originalDigest = try MultiplayerLocalGame.digest(romURL)
            let changedDigest = try MultiplayerLocalGame.digest(changedURL)
            check(originalDigest != changedDigest, "different cartridge configuration cannot negotiate local replay")

            bridge.resetInputs()
            bridge.stop()
            bridge.videoRenderer = nil
            // Queue native work, then immediately leave and start a second session. Cleanup
            // must complete before another owner can use the singleton NES bridge.
            let replica = try MultiplayerLocalReplica(romURL: romURL)
            let scratch = bridge.gameURL!.deletingLastPathComponent()
            try replica.load(state) {}
            for index in 0..<30 {
                replica.receive(MultiplayerFrame(number: UInt64(index), player1: 0, player2: 0, checksum: 0), timestamp: UInt64(index))
            }
            replica.stop()
            check(bridge.gameURL == nil, "leaving immediately releases the NES bridge")
            check(!FileManager.default.fileExists(atPath: scratch.path), "leaving removes the temporary ROM and states")
            let next = try MultiplayerLocalReplica(romURL: romURL)
            check(bridge.gameURL != nil, "immediate rejoin can acquire the NES bridge")
            next.stop()
            check(bridge.gameURL == nil, "repeated cleanup releases the NES bridge")
            try? FileManager.default.removeItem(at: directory)
            message = failures == 0 ? "REPLICA_SMOKE \(checks)/\(checks) passed"
                                    : "REPLICA_SMOKE \(checks - failures)/\(checks) passed"
        }
        catch {
            message = "REPLICA_SMOKE threw: \(error)"
            failures += 1
        }
        print(message)
        fflush(stdout)
        let result = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt")
        try? message.write(to: result, atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ReplicaSmokeDelegate.self))
