import Foundation
import DeltaCore
import NESDeltaCore

final class MultiplayerGameController: NSObject, GameController
{
    static let controllerType = GameControllerInputType("com.deltaswipe.nearby.controller")
    var name: String { "Nearby Player" }
    var playerIndex: Int?
    var inputType: GameControllerInputType { Self.controllerType }
    var defaultInputMapping: GameControllerInputMappingProtocol? { Mapping() }
    private var buttons: UInt8 = 0

    init(playerIndex: Int) { self.playerIndex = playerIndex }

    func setButtons(_ buttons: UInt8)
    {
        for bit in 0..<8
        {
            let mask = UInt8(1 << bit)
            guard (self.buttons & mask) != (buttons & mask) else { continue }
            let input = AnyInput(stringValue: String(mask), intValue: Int(mask), type: .controller(Self.controllerType))
            if buttons & mask != 0 { activate(input) }
            else { deactivate(input) }
        }
        self.buttons = buttons
    }

    private struct Mapping: GameControllerInputMappingProtocol
    {
        var gameControllerInputType: GameControllerInputType { MultiplayerGameController.controllerType }
        func input(forControllerInput input: Input) -> Input? { input.intValue.flatMap(NESGameInput.init(rawValue:)) }
    }
}

// Aggregation prevents releasing touch A from cancelling A still held on a physical controller.
final class MultiplayerInputForwarder: GameControllerReceiver
{
    var onButtons: ((UInt8) -> Void)?
    var onMenu: (() -> Void)?
    var isEnabled = true {
        didSet { if !isEnabled { reset() } }
    }
    private var state = MultiplayerInputState()
    private var active = [ObjectIdentifier: [String: UInt8]]()

    func gameController(_ controller: GameController, didActivate input: Input, value: Double)
    {
        guard isEnabled, let button = nesButton(input) else { return }
        let id = ObjectIdentifier(controller)
        // Preserve each mapped input separately (e.g. d-pad and analog-stick aliases).
        active[id, default: [:]][input.type.rawValue + ":" + input.stringValue] = value >= 0.33 ? button : nil
        update(id)
    }

    func gameController(_ controller: GameController, didDeactivate input: Input)
    {
        if StandardGameControllerInput(input: input) == .menu { onMenu?(); return }
        let id = ObjectIdentifier(controller)
        active[id]?[input.type.rawValue + ":" + input.stringValue] = nil
        update(id)
    }

    func remove(_ controller: GameController)
    {
        let id = ObjectIdentifier(controller)
        active[id] = nil
        update(id)
    }

    func reset()
    {
        active.removeAll()
        state.reset()
        onButtons?(0)
    }

    private func update(_ id: ObjectIdentifier)
    {
        let previous = state.buttons
        state.set(active[id]?.values.reduce(0, |) ?? 0, for: String(describing: id))
        if state.buttons != previous { onButtons?(state.buttons) }
    }

    private func nesButton(_ input: Input) -> UInt8?
    {
        let mapped = StandardGameControllerInput(input: input)?.input(for: .nes) ?? input
        guard mapped.type == .game(.nes), let nes = NESGameInput(input: mapped) else { return nil }
        return UInt8(nes.rawValue)
    }
}
