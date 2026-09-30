import UIKit
import CoreImage
import DeltaCore
import NESDeltaCore

// Reproduces the app's NearbyGuestViewController: a DeltaCore.GameViewController with
// no game, a standard NES skin, and synthesized video frames. Captures what actually
// renders so the guest black screen can be diagnosed headlessly.
final class GuestVC: DeltaCore.GameViewController
{
    var feedTimer: Timer?
    var ticks = 0
    var loadDetail = ""

    override func viewDidLoad()
    {
        super.viewDidLoad()
        automaticallyPausesWhileInactive = false
        let core = Delta.core(for: GameType.nes)
        let url = core?.resourceBundle.url(forResource: "Standard", withExtension: "deltaskin")
        let skin = url.flatMap { ControllerSkin(fileURL: $0) }
        loadDetail = "core=\(core != nil) url=\(url?.path ?? "nil") skin=\(skin != nil)"
        controllerView.controllerSkin = skin
        controllerView.playerIndex = 1
        view.backgroundColor = .black
        feedTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ticks += 1
            let color = CIColor(red: 0.8, green: 0.3, blue: 0.6)
            let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 240))
            (self.gameViews + self.controllerView.gameViews).forEach { $0.inputImage = image }
        }
    }
}

final class ScreenDelegate: UIResponder, UIApplicationDelegate
{
    var window: UIWindow?
    let vc = GuestVC()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        Delta.register(NES.core)
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = vc
        window?.makeKeyAndVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.check() }
        return true
    }

    func check()
    {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let core = Delta.core(for: GameType.nes)
        let url = core?.resourceBundle.url(forResource: "Standard", withExtension: "deltaskin")
        let loaded = url.flatMap { ControllerSkin(fileURL: $0) }
        let info = "atLoad[\(vc.loadDetail)] "
            + "gameViews=\(vc.gameViews.count) gameViewFrame=\(vc.gameViews.first?.frame ?? .zero) "
            + "skinNow=\(vc.controllerView.controllerSkin != nil) controllerFrame=\(vc.controllerView.frame) ticks=\(vc.ticks)"
        let renderer = UIGraphicsImageRenderer(bounds: window!.bounds)
        let snapshot = renderer.image { context in
            window!.drawHierarchy(in: window!.bounds, afterScreenUpdates: true)
        }
        try? snapshot.pngData()?.write(to: documents.appendingPathComponent("snapshot.png"))
        try? info.write(to: documents.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print(info)
        fflush(stdout)
        exit(0)
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ScreenDelegate.self))
