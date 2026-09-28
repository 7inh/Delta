//
//  SwipeInputEngine.swift
//  Delta
//
//  Created by Tran Quoc Linh on 9/28/26.
//
//  Pure gesture-to-input logic for Swipe Controls. No UIKit dependencies so it
//  can be unit tested headlessly. Driven by touch events from
//  SwipeControlsOverlayView and a 60Hz tick (CADisplayLink).
//

import Foundation
import CoreGraphics

final class SwipeInputEngine
{
    // MARK: - Types -

    struct Configuration
    {
        var layout: SwipeControlLayout = .fullArea
        var directionMode: SwipeDirectionMode = .sticky
        var isEightWayEnabled = false
        var swipeThreshold: CGFloat = 20
        var swipeUpAction: SwipeUpAction = .jump
        var swipeDownAction: SwipeDownAction = .stop
        var jumpButton = "a"
        var fireButton = "b"
        var isAutofireAlwaysEnabled = true
        var isTapOppositeSideToTurnEnabled = true
        var autofireRate = 8 // Hz
        var jumpPulseFrames = 8
        var doubleTapWindow: TimeInterval = 0.3
        var tapMaximumDuration: TimeInterval = 0.25
        var fireZoneFraction: CGFloat = 0.5 // split layout: right fraction of width
        var showsHints = true
        var isHapticsEnabled = true
    }

    enum Event
    {
        case jumpTriggered
        case directionChanged(String?) // current direction name, if any
        case stopped
        case fireToggled(Bool)
    }

    // MARK: - Callbacks -

    var onActivate: (String) -> Void = { _ in }
    var onDeactivate: (String) -> Void = { _ in }
    var onEvent: (Event) -> Void = { _ in }

    // MARK: - State -

    var configuration = Configuration() {
        didSet {
            // Keep constant-fire consistent when options change mid-session.
            self.isFireBaseOn = self.configuration.isAutofireAlwaysEnabled
        }
    }

    /// Set by overlay when applying configuration; toggled by double-tap.
    private var isFireBaseOn = false

    private(set) var activeDirections = Set<String>()

    private struct TouchRecord
    {
        var start: CGPoint
        var current: CGPoint
        var startDate: TimeInterval
        var didTriggerJump = false
    }

    private var touches: [Int: TouchRecord] = [:]
    private var jumpPulseRemaining = 0
    private var fireEmitting = false
    private var firePulsePhase = 0
    private var lastTap: (id: Int, endDate: TimeInterval)?
    private var reversingTouchIDs = Set<Int>()
    private var viewportWidth: CGFloat = 0

    /// Whether the display link can be paused (nothing dynamic in progress).
    /// Note: sticky direction latches are static, so they don't require ticking,
    /// but autofire must keep pulsing even when no finger is on the screen.
    var isIdle: Bool
    {
        return self.touches.isEmpty && self.jumpPulseRemaining <= 0 && !self.isFireEffective
    }

    var isFireEffective: Bool
    {
        return self.isFireBaseOn || self.isHoldFireActive
    }

    /// Whether the fire button is currently being pulsed (for visuals).
    var isFirePressed: Bool
    {
        return self.fireEmitting
    }

    /// Whether the jump button is currently being pulsed (for visuals).
    var isJumpPressed: Bool
    {
        return self.jumpPulseRemaining > 0
    }

    /// Split layout: any touch that began in the right-hand fire zone.
    private var isHoldFireActive: Bool
    {
        guard self.configuration.layout == .split, self.viewportWidth > 0 else { return false }

        let fireX = self.viewportWidth * self.configuration.fireZoneFraction
        return self.touches.values.contains { $0.start.x >= fireX }
    }

    // MARK: - Session -

    func setViewportWidth(_ width: CGFloat)
    {
        self.viewportWidth = width
    }

    func beginSession()
    {
        // Start (or restart) constant fire from the current configuration.
        self.isFireBaseOn = self.configuration.isAutofireAlwaysEnabled
    }

    /// Release every output and forget transient state (used when emulation pauses).
    /// Preserves the double-tap fire toggle so resuming doesn't reset user preference.
    func reset()
    {
        self.touches.removeAll()
        self.lastTap = nil
        self.reversingTouchIDs.removeAll()

        for direction in self.activeDirections
        {
            self.onDeactivate(direction)
        }
        self.activeDirections.removeAll()

        self.jumpPulseRemaining = 0
        self.firePulsePhase = 0

        if self.fireEmitting
        {
            self.onDeactivate(self.configuration.fireButton)
            self.fireEmitting = false
        }
    }

    // MARK: - Touch Events -

    func touchBegan(id: Int, at point: CGPoint, time: TimeInterval)
    {
        self.touches[id] = TouchRecord(start: point, current: point, startDate: time)

        // Tap the opposite side of the screen to turn around instantly —
        // no swipe required.
        if self.configuration.isTapOppositeSideToTurnEnabled, self.viewportWidth > 0,
           let currentDirection = self.currentHorizontalDirection()
        {
            let tapDirection = point.x >= self.viewportWidth / 2 ? Direction.right : Direction.left
            if tapDirection != currentDirection
            {
                self.reversingTouchIDs.insert(id)
                self.setDirections([tapDirection])
            }
        }

        // Double-tap toggles constant fire.
        if let lastTap = self.lastTap, lastTap.id != id, time - lastTap.endDate <= self.configuration.doubleTapWindow
        {
            self.lastTap = nil

            self.isFireBaseOn.toggle()
            self.onEvent(.fireToggled(self.isFireBaseOn))
        }

        self.updateDirections()
    }

    func touchMoved(id: Int, at point: CGPoint)
    {
        guard self.touches[id] != nil else { return }

        self.touches[id]?.current = point
        self.updateDirections()
    }

    func touchEnded(id: Int, at point: CGPoint, time: TimeInterval)
    {
        guard let record = self.touches[id] else { return }

        self.touches[id] = nil

        let displacement = hypot(point.x - record.start.x, point.y - record.start.y)
        let duration = time - record.startDate
        let isTap = duration <= self.configuration.tapMaximumDuration && displacement <= self.configuration.swipeThreshold

        if isTap, !self.reversingTouchIDs.contains(id)
        {
            self.lastTap = (id, time)

            // Quick tap stops movement (sticky mode).
            if self.configuration.directionMode == .sticky
            {
                self.setDirections([])
                self.onEvent(.stopped)
            }
        }
        else if !isTap
        {
            self.lastTap = nil
        }

        self.reversingTouchIDs.remove(id)

        self.updateDirections()
    }

    func touchCancelled(id: Int)
    {
        guard self.touches[id] != nil else { return }

        self.touches[id] = nil
        self.reversingTouchIDs.remove(id)
        self.updateDirections()
    }

    // MARK: - Tick (60Hz) -

    func tick()
    {
        self.updateJumpPulse()
        self.updateFire()
    }

    private func updateJumpPulse()
    {
        if self.jumpPulseRemaining > 0
        {
            // Holding the finger up keeps jump pressed (variable-height feel).
            let isHoldingUp = self.touches.values.contains { $0.current.y - $0.start.y < -self.configuration.swipeThreshold }
            if isHoldingUp
            {
                self.jumpPulseRemaining = max(self.jumpPulseRemaining, self.configuration.jumpPulseFrames)
            }

            self.jumpPulseRemaining -= 1
        }

        // Activate/deactivate only on state edges.
        if self.jumpPulseRemaining > 0
        {
            self.activate(self.configuration.jumpButton)
        }
        else
        {
            self.deactivate(self.configuration.jumpButton)
        }
    }

    private func updateFire()
    {
        if self.isFireEffective
        {
            let period = max(2, Int((60.0 / Double(self.configuration.autofireRate)).rounded()))
            self.firePulsePhase = (self.firePulsePhase + 1) % period

            // Fire in pulses so games that react to button *edges* register each shot.
            let shouldEmit = self.firePulsePhase < period / 2
            self.setFireEmitting(shouldEmit)
        }
        else
        {
            self.firePulsePhase = 0
            self.setFireEmitting(false)
        }
    }

    private func setFireEmitting(_ emitting: Bool)
    {
        guard emitting != self.fireEmitting else { return }

        self.fireEmitting = emitting
        emitting ? self.activate(self.configuration.fireButton) : self.deactivate(self.configuration.fireButton)
    }

    // MARK: - Direction Handling -

    private func updateDirections()
    {
        var desired = Set<String>()
        var shouldStop = false

        for (id, var record) in self.touches
        {
            let dx = record.current.x - record.start.x
            let dy = record.current.y - record.start.y

            guard hypot(dx, dy) >= self.configuration.swipeThreshold else { continue }

            if abs(dx) >= abs(dy)
            {
                desired.insert(dx < 0 ? Direction.left : Direction.right)

                if self.configuration.isEightWayEnabled, abs(dy) >= self.configuration.swipeThreshold
                {
                    desired.insert(dy < 0 ? Direction.up : Direction.down)
                }
            }
            else if dy < 0
            {
                // Swipe up.
                if self.configuration.swipeUpAction == .jump, !record.didTriggerJump
                {
                    record.didTriggerJump = true
                    self.touches[id] = record
                    self.triggerJump()
                }

                if self.configuration.isEightWayEnabled
                {
                    desired.insert(Direction.up)
                }
            }
            else
            {
                // Swipe down.
                switch self.configuration.swipeDownAction
                {
                case .stop: shouldStop = true
                case .pressDown: desired.insert(Direction.down)
                case .none: break
                }

                if self.configuration.isEightWayEnabled
                {
                    desired.insert(Direction.down)
                }
            }
        }

        if shouldStop
        {
            self.setDirections([])
            self.onEvent(.stopped)
        }
        else if desired.isEmpty, self.configuration.directionMode == .sticky
        {
            // No active touch selects a direction: keep the sticky latch
            // (movement persists until reversed or explicitly stopped).
            return
        }
        else
        {
            self.setDirections(desired)
        }
    }

    /// The single horizontal direction currently latched, if any.
    private func currentHorizontalDirection() -> String?
    {
        let horizontal = self.activeDirections.intersection([Direction.left, Direction.right])
        guard horizontal.count == 1 else { return nil }
        return horizontal.first
    }

    private func setDirections(_ desired: Set<String>)
    {
        guard desired != self.activeDirections else { return }

        for direction in self.activeDirections.subtracting(desired)
        {
            self.onDeactivate(direction)
        }
        for direction in desired.subtracting(self.activeDirections)
        {
            self.onActivate(direction)
        }

        self.activeDirections = desired
        self.onEvent(.directionChanged(desired.sorted().first))
    }

    private func triggerJump()
    {
        self.jumpPulseRemaining = max(self.jumpPulseRemaining, self.configuration.jumpPulseFrames)
        self.onEvent(.jumpTriggered)
    }

    private func activate(_ input: String)
    {
        self.onActivate(input)
    }

    private func deactivate(_ input: String)
    {
        // Deactivations may be requested every tick; controllers deduplicate.
        self.onDeactivate(input)
    }
}

// MARK: - Supporting Types -

enum SwipeControlLayout: String, CaseIterable
{
    case fullArea
    case split
}

enum SwipeDirectionMode: String, CaseIterable
{
    case sticky // keep running until reversed/stopped
    case hold   // only while finger stays displaced
}

enum SwipeUpAction: String, CaseIterable
{
    case jump
    case none
}

enum SwipeDownAction: String, CaseIterable
{
    case stop
    case pressDown
    case none
}

enum Direction
{
    static let up = "up"
    static let down = "down"
    static let left = "left"
    static let right = "right"
}
