import UIKit
import DeltaCore
import NESDeltaCore

final class Probe: GameControllerReceiver
{
    var inputs = [Int: Set<Int>]()
    func gameController(_ controller: GameController, didActivate input: Input, value: Double) {
        if let player = controller.playerIndex, let button = input.intValue { inputs[player, default: []].insert(button) }
    }
    func gameController(_ controller: GameController, didDeactivate input: Input) {
        if let player = controller.playerIndex, let button = input.intValue { inputs[player]?.remove(button) }
    }
}

final class ControllerSmokeDelegate: UIResponder, UIApplicationDelegate
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
        let touch = MultiplayerGameController(playerIndex: 0)
        let physical = MultiplayerGameController(playerIndex: 0)
        let remote = MultiplayerGameController(playerIndex: 1)
        let forwarder = MultiplayerInputForwarder()
        let probe = Probe()
        remote.addReceiver(probe)
        touch.addReceiver(forwarder)
        physical.addReceiver(forwarder)
        forwarder.onButtons = { remote.setButtons($0) }
        touch.setButtons(0x09)
        check(probe.inputs[1] == [1, 8], "A and Start reach Player 2")
        check(probe.inputs[0] == nil, "guest never reaches Player 1")
        physical.setButtons(0x01)
        touch.setButtons(0)
        check(probe.inputs[1] == [1], "overlapping A survives touch release")
        physical.setButtons(0x85)
        check(probe.inputs[1] == [1, 4, 128], "Select and direction snapshot")
        forwarder.isEnabled = false
        check(probe.inputs[1]?.isEmpty == true, "guest menu releases all buttons")
        touch.setButtons(0xff)
        check(probe.inputs[1]?.isEmpty == true, "disabled input ignored")
        forwarder.isEnabled = true
        touch.setButtons(0)
        physical.setButtons(0)
        touch.setButtons(0x02)
        check(probe.inputs[1] == [2], "input resumes")
        forwarder.remove(touch)
        check(probe.inputs[1]?.isEmpty == true, "controller disconnect releases buttons")
        forwarder.gameController(physical, didActivate: StandardGameControllerInput.menu, value: 1)
        check(probe.inputs[1]?.isEmpty == true, "menu never forwarded to NES")
        remote.setButtons(0xff)
        remote.setButtons(0)
        check(probe.inputs[1]?.isEmpty == true, "session cleanup releases all eight buttons")
        let message = "CONTROLLER_SMOKE \(checks - failures)/\(checks) passed"
        print(message)
        fflush(stdout)
        let result = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt")
        try? message.write(to: result, atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ControllerSmokeDelegate.self))
