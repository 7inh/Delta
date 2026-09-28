//
//  SwipeControls.swift
//  Delta
//
//  Created by Tran Quoc Linh on 9/28/26.
//

import SwiftUI

import DeltaFeatures

// MARK: - Option Values -

extension SwipeControlLayout: LocalizedOptionValue
{
    var localizedDescription: Text {
        switch self
        {
        case .fullArea: Text("Swipe Anywhere")
        case .split: Text("Split (Left: Move, Right: Fire)")
        }
    }
}

extension SwipeDirectionMode: LocalizedOptionValue
{
    var localizedDescription: Text {
        switch self
        {
        case .sticky: Text("Sticky (keep running until stopped)")
        case .hold: Text("Hold (move only while swiping)")
        }
    }
}

extension SwipeUpAction: LocalizedOptionValue
{
    var localizedDescription: Text {
        switch self
        {
        case .jump: Text("Jump")
        case .none: Text("Nothing")
        }
    }
}

extension SwipeDownAction: LocalizedOptionValue
{
    var localizedDescription: Text {
        switch self
        {
        case .stop: Text("Stop Moving")
        case .pressDown: Text("Press Down")
        case .none: Text("Nothing")
        }
    }
}

/// Physical-ish button labels offered for jump/fire gestures.
enum SwipeButton: String, CaseIterable, LocalizedOptionValue
{
    case a
    case b

    var localizedDescription: Text {
        switch self
        {
        case .a: Text("A")
        case .b: Text("B")
        }
    }
}

// MARK: - Options -

struct SwipeControlsOptions
{
    @Option(name: "Layout", description: "Where swipe gestures are recognized.", values: SwipeControlLayout.allCases)
    var layout: SwipeControlLayout = .fullArea

    @Option(name: "Direction Mode", description: "Whether movement continues after lifting your finger.", values: SwipeDirectionMode.allCases)
    var directionMode: SwipeDirectionMode = .sticky

    @Option(name: "8-Way Directions", description: "Allow diagonal movement.")
    var isEightWayEnabled: Bool = false

    @Option(name: "Swipe Up", description: "Action triggered by swiping up.", values: SwipeUpAction.allCases)
    var swipeUpAction: SwipeUpAction = .jump

    @Option(name: "Swipe Down", description: "Action triggered by swiping down.", values: SwipeDownAction.allCases)
    var swipeDownAction: SwipeDownAction = .stop

    @Option(name: "Swipe Sensitivity", description: "How far you must swipe before a direction is recognized.", values: [12, 16, 20, 26, 34])
    var swipeThreshold: Int = 20

    @Option(name: "Jump Button", description: "Button pressed by the swipe-up gesture.", values: SwipeButton.allCases)
    var jumpButton: SwipeButton = .a

    @Option(name: "Fire Button", description: "Button pressed by fire gestures/autofire.", values: SwipeButton.allCases)
    var fireButton: SwipeButton = .b

    @Option(name: "Autofire (Always On)", description: "Fire button is pressed automatically.")
    var isAutofireAlwaysEnabled: Bool = true

    @Option(name: "Double-Tap Toggles Autofire", description: "Double-tap the controller area to turn autofire on or off.")
    var isDoubleTapToggleEnabled: Bool = true

    @Option(name: "Autofire Rate", description: "Shots per second while autofiring.", values: Array(stride(from: 2, through: 15, by: 1)))
    var autofireRate: Int = 8

    @Option(name: "Jump Duration", description: "How long the jump button stays pressed after swiping up (in frames).", values: [4, 6, 8, 12, 16, 24, 30])
    var jumpPulseFrames: Int = 8

    @Option(name: "Show Hints", description: "Display indicators for active directions and autofire.")
    var showsHints: Bool = true

    @Option(name: "Haptics", description: "Vibrate on jumps and direction changes.")
    var isHapticsEnabled: Bool = true
}
