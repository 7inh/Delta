//
//  SwipeGameController.swift
//  Delta
//
//  Created by Tran Quoc Linh on 9/28/26.
//
//  A GameController that emits inputs on behalf of SwipeControlsOverlayView.
//  Emits inputs in the .controller(.swipe) domain; SwipeInputMapping converts
//  them to the active system's game inputs (same pattern as ControllerView's
//  ControllerViewInputMapping), so DefaultInputMapping in GameViewController
//  picks it up without special-casing.
//

import DeltaCore

public final class SwipeGameController: NSObject, GameController
{
    public static let inputType = GameControllerInputType("com.leelinh.DeltaSwipe.input.swipe")

    public var name: String { "Swipe Controls" }

    public var inputType: GameControllerInputType {
        return Self.inputType
    }

    public var playerIndex: Int?

    public lazy var defaultInputMapping: GameControllerInputMappingProtocol? = SwipeInputMapping()

    // MARK: - Input Emission -

    func activate(swipeInput stringValue: String)
    {
        let input = AnyInput(stringValue: stringValue, intValue: nil, type: .controller(Self.inputType))
        self.activate(input)
    }

    func deactivate(swipeInput stringValue: String)
    {
        let input = AnyInput(stringValue: stringValue, intValue: nil, type: .controller(Self.inputType))
        self.deactivate(input)
    }
}

/// Converts swipe-domain inputs ("left", "a", "b", ...) into the active
/// system's game inputs (e.g. NESGameInput.a). Class (not struct) because
/// GameControllerStateManager stores mappings as AnyObject — mutations to
/// gameType must stay visible to existing receivers.
public final class SwipeInputMapping: GameControllerInputMappingProtocol
{
    public var gameType: GameType?

    public var name: String { "Swipe" }

    public var gameControllerInputType: GameControllerInputType {
        return SwipeGameController.inputType
    }

    public init(gameType: GameType? = nil)
    {
        self.gameType = gameType
    }

    public func input(forControllerInput controllerInput: Input) -> Input?
    {
        guard controllerInput.type == .controller(SwipeGameController.inputType),
              let gameType = self.gameType,
              let deltaCore = Delta.core(for: gameType)
        else { return nil }

        return deltaCore.gameInputType.init(stringValue: controllerInput.stringValue)
    }
}
