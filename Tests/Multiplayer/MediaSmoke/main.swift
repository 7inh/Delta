import UIKit
import CoreImage
import QuartzCore

final class MediaSmokeDelegate: UIResponder, UIApplicationDelegate
{
    var window: UIWindow?
    let encoder = MultiplayerVideoEncoder()
    let player = MultiplayerMediaPlayer()
    let decoder = MultiplayerVideoDecoder()
    let context = CIContext()
    var decoded = 0
    var timer: Timer?
    var ticks = 0
    var images = 0
    var encoded = 0
    var audioPackets = 0
    var audioOrigin: UInt64 = 0
    var audioFrames: UInt64 = 0
    var completed = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBlue
        window?.rootViewController = controller
        window?.makeKeyAndVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.run() }
        return true
    }

    func finish(_ message: String, success: Bool)
    {
        guard !completed else { return }
        completed = true
        timer?.invalidate()
        encoder.stop()
        player.stop()
        print(message)
        fflush(stdout)
        let result = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt")
        try? message.write(to: result, atomically: true, encoding: .utf8)
        exit(success ? 0 : 1)
    }

    func run()
    {
        print("MEDIA_SMOKE_START")
        fflush(stdout)
        encoder.onError = { self.finish($0, success: false) }
        player.onError = { self.finish($0, success: false) }
        player.onImage = { image in
            guard image.extent.width == 256, image.extent.height == 240 else { self.finish("Wrong decoded dimensions", success: false); return }
            self.images += 1
            self.window?.rootViewController?.view.layer.contents = self.context.createCGImage(image, from: image.extent)
        }
        decoder.onImage = { _, _ in self.decoded += 1 }
        decoder.onError = { self.finish($0, success: false) }
        encoder.onFrame = { data, timestamp, done in
            self.encoded += 1
            self.decoder.decode(data, timestamp: timestamp)
            self.player.receive(MultiplayerPacket(kind: .video, session: UUID(), sequence: 1, timestamp: timestamp, payload: data))
            done()
        }
        do { try player.start() }
        catch { finish(error.localizedDescription, success: false); return }
        print("MEDIA_SMOKE_AUDIO_STARTED")
        fflush(stdout)
        audioOrigin = UInt64(CACurrentMediaTime() * 1_000_000)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            self.ticks += 1
            let image = CIImage(color: CIColor(red: self.ticks % 2 == 0 ? 1 : 0, green: 0.25, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 240))
            self.encoder.capture(image)
            var samples = [Int16](repeating: 0, count: 735)
            for i in 0..<samples.count { samples[i] = Int16(sin(Double(self.audioFrames + UInt64(i)) * 440 * 2 * .pi / 44100) * 1000) }
            let data = samples.withUnsafeBytes { Data($0) }
            self.player.receive(MultiplayerPacket(kind: .audio, session: UUID(), sequence: 1,
                timestamp: self.audioOrigin + self.audioFrames * 1_000_000 / 44100, payload: data))
            self.audioPackets += 1
            self.audioFrames += 735
            if self.ticks == 60
            {
                self.player.pause()
                self.encoder.requestKeyFrame()
                self.audioOrigin = UInt64(CACurrentMediaTime() * 1_000_000)
                self.audioFrames = 0
                self.player.isMuted = true
            }
            if self.ticks == 90 { self.player.isMuted = false }
            if self.ticks == 120
            {
                // Reproduce packets released together after presentation stalls the main queue.
                for index in 0..<24
                {
                    self.player.receive(MultiplayerPacket(kind: .audio, session: UUID(), sequence: 1,
                        timestamp: self.audioOrigin + (self.audioFrames + UInt64(index * 735)) * 1_000_000 / 44100, payload: data))
                }
                self.audioOrigin = UInt64(CACurrentMediaTime() * 1_000_000)
                self.audioFrames = 0
                self.player.pause()
                self.encoder.requestKeyFrame()
            }
            if self.ticks == 180
            {
                let success = self.decoded >= 90 && self.images > 0 && self.encoded >= 90 && self.audioPackets == 180
                self.finish("MEDIA_SMOKE_\(success ? "PASS" : "FAIL") encoded=\(self.encoded) decoded=\(self.decoded) displayed=\(self.images) audio=\(self.audioPackets) pause/resume/mute/burst exercised", success: success)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { self.finish("MEDIA_SMOKE_TIMEOUT", success: false) }
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(MediaSmokeDelegate.self))
