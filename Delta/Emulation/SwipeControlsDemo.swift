//
//  SwipeControlsDemo.swift
//  Delta
//
//  Created by Tran Quoc Linh on 9/28/26.
//
//  DEBUG-only scripted gesture driver used to demo/verify Swipe Controls in
//  the simulator (launch argument: -DeltaSwipeDemo). It drives the same
//  SwipeInputEngine entry points the overlay's touch handlers call, so the
//  full pipeline (engine -> SwipeGameController -> emulator) is exercised.
//

#if DEBUG

import UIKit
import DeltaCore

extension SwipeControlsOverlayView
{
    func startDemoIfNeeded()
    {
        guard ProcessInfo.processInfo.arguments.contains("-DeltaSwipeDemo") else { return }

        let start = CACurrentMediaTime()
        let schedule = { (delay: TimeInterval, action: @escaping () -> Void) in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }

        // Synthetic swipe: began -> moved past threshold -> ended.
        func swipe(_ id: Int, _ from: CGPoint, _ to: CGPoint)
        {
            self.engine.touchBegan(id: id, at: from, time: CACurrentMediaTime() - start)
            self.updateDisplayLink()

            let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            self.engine.touchMoved(id: id, at: mid)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)
            {
                self.engine.touchMoved(id: id, at: to)
                self.engine.touchEnded(id: id, at: to, time: CACurrentMediaTime() - start)
                self.updateDisplayLink()
            }
        }

        // Synthetic quick tap.
        func tap(_ id: Int, _ at: CGPoint)
        {
            self.engine.touchBegan(id: id, at: at, time: CACurrentMediaTime() - start)
            self.updateDisplayLink()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06)
            {
                self.engine.touchEnded(id: id, at: at, time: CACurrentMediaTime() - start)
                self.updateDisplayLink()
            }
        }

        // Press Start through: title screen -> intro cutscene pages ->
        // Round 1 card, until gameplay begins.
        for (index, delay) in [1.2, 2.6, 4.0, 5.5, 7.0, 8.5, 10.0, 12.0, 14.0, 16.0, 18.0].enumerated()
        {
            schedule(delay) { self.pressStart(repeatCount: index) }
        }

        // 2. Swipe left -> runs left (sticky).
        schedule(20.0) { swipe(101, CGPoint(x: 220, y: 520), CGPoint(x: 110, y: 520)) }
        // 3. Tap -> stop.
        schedule(21.7) { tap(102, CGPoint(x: 160, y: 520)) }
        // 4. Swipe right -> runs right.
        schedule(22.4) { swipe(103, CGPoint(x: 140, y: 520), CGPoint(x: 250, y: 520)) }
        // 5. Tap -> stop.
        schedule(24.1) { tap(104, CGPoint(x: 200, y: 520)) }
        // 6. Swipe up -> jump.
        schedule(24.8) { swipe(105, CGPoint(x: 200, y: 480), CGPoint(x: 200, y: 380)) }
        // 7. Jump again while running.
        schedule(25.8) { swipe(106, CGPoint(x: 200, y: 480), CGPoint(x: 200, y: 380)) }
        // 8. Double-tap -> autofire OFF.
        schedule(27.0)
        {
            tap(107, CGPoint(x: 200, y: 400))
            schedule(0.12) { tap(108, CGPoint(x: 200, y: 400)) }
        }
        // 9. Double-tap -> autofire ON.
        schedule(28.6)
        {
            tap(109, CGPoint(x: 200, y: 400))
            schedule(0.12) { tap(110, CGPoint(x: 200, y: 400)) }
        }
        // 10. Toggle the pause menu (same path as tapping the MENU button).
        schedule(31.0)
        {
            self.onMenuToggle?()
        }
    }

    private func pressStart(repeatCount: Int = 0)
    {
        self.swipeController?.activate(swipeInput: "start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25)
        {
            self.swipeController?.deactivate(swipeInput: "start")
        }
    }
}

#endif
