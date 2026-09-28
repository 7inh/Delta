//
//  Standalone tests for SwipeInputEngine.
//  The engine is deliberately UIKit-free, so these run on macOS via
//  Tests/SwipeControls/run-tests.sh (swiftc compile + execute).
//  No XCTest target required; failures exit non-zero.
//

import Foundation
import CoreGraphics

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String)
{
    checks += 1
    if !condition
    {
        failures += 1
        print("FAIL: \(label)")
    }
}

func makeEngine(configure: (inout SwipeInputEngine.Configuration) -> Void = { _ in }) -> (SwipeInputEngine, () -> [String], () -> [String])
{
    var engine = SwipeInputEngine()
    configure(&engine.configuration)

    var active: [String] = []
    var events: [SwipeInputEngine.Event] = []

    engine.onActivate = { active.append("+\($0)") }
    engine.onDeactivate = { active.append("-\($0)") }
    engine.onEvent = { events.append($0) }

    // Rebuild closures so the test can read current input state.
    var currentInputs = Set<String>()
    engine.onActivate = { currentInputs.insert($0); active.append("+\($0)") }
    engine.onDeactivate = { currentInputs.remove($0); active.append("-\($0)") }
    engine.onEvent = { events.append($0) }

    return (engine, { active }, { Array(currentInputs) })
}

func frameTick(_ engine: SwipeInputEngine, count: Int)
{
    for _ in 0..<count { engine.tick() }
}

// MARK: - 1. Sticky direction: swipe left latches, persists after release -

do
{
    let (engine, log, inputs) = makeEngine()
    engine.configuration.directionMode = .sticky

    engine.touchBegan(id: 1, at: CGPoint(x: 200, y: 400), time: 0)
    engine.touchMoved(id: 1, at: CGPoint(x: 200 - 40, y: 400))
    check(inputs().contains("left"), "sticky: left activates after swipe past threshold")

    engine.touchEnded(id: 1, at: CGPoint(x: 200 - 60, y: 400), time: 0.2)
    check(inputs().contains("left"), "sticky: left persists after finger lifts")

    // Opposite swipe reverses.
    engine.touchBegan(id: 2, at: CGPoint(x: 100, y: 400), time: 1.0)
    engine.touchMoved(id: 2, at: CGPoint(x: 100 + 40, y: 400))
    check(inputs() == ["right"], "sticky: opposite swipe reverses direction")
    engine.touchEnded(id: 2, at: CGPoint(x: 100 + 60, y: 400), time: 1.2)
    check(inputs() == ["right"], "sticky: still right after release")

    // Tap stops.
    engine.touchBegan(id: 3, at: CGPoint(x: 150, y: 400), time: 2.0)
    engine.touchEnded(id: 3, at: CGPoint(x: 152, y: 401), time: 2.1)
    check(inputs().isEmpty, "sticky: quick tap stops movement")
}

// MARK: - 2. Hold direction: released when finger lifts -

do
{
    let (engine, _, inputs) = makeEngine()
    engine.configuration.directionMode = .hold

    engine.touchBegan(id: 1, at: CGPoint(x: 200, y: 400), time: 0)
    engine.touchMoved(id: 1, at: CGPoint(x: 160, y: 400))
    check(inputs().contains("left"), "hold: left active while swiping")

    engine.touchEnded(id: 1, at: CGPoint(x: 160, y: 400), time: 0.3)
    check(inputs().isEmpty, "hold: direction released when finger lifts")
}

// MARK: - 3. Swipe up triggers jump pulse (default 'a') -

do
{
    let (engine, _, inputs) = makeEngine()
    engine.touchBegan(id: 1, at: CGPoint(x: 200, y: 400), time: 0)
    engine.touchMoved(id: 1, at: CGPoint(x: 200, y: 400 - 50))
    engine.tick()

    check(inputs().contains("a"), "swipe up: jump button activated")

    engine.touchEnded(id: 1, at: CGPoint(x: 200, y: 400 - 50), time: 0.1)
    frameTick(engine, count: 20)
    check(!inputs().contains("a"), "swipe up: jump released after pulse expires")
}

// MARK: - 4. Autofire pulses fire button at configured rate -

do
{
    let (engine, log, inputs) = makeEngine()
    engine.configuration.isAutofireAlwaysEnabled = true
    engine.configuration.autofireRate = 10 // period = 6 frames: 3 on, 3 off

    frameTick(engine, count: 1)
    check(inputs().contains("b"), "autofire: fire on during 'on' phase")

    frameTick(engine, count: 3) // now in 'off' phase
    check(!inputs().contains("b"), "autofire: fire off during 'off' phase")

    frameTick(engine, count: 3) // back on
    check(inputs().contains("b"), "autofire: pulse repeats")
}

// MARK: - 5. Double-tap toggles autofire latch -

do
{
    let (engine, log2, inputs) = makeEngine()
    engine.configuration.isAutofireAlwaysEnabled = true // starts ON
    engine.beginSession()

    frameTick(engine, count: 1)
    check(inputs().contains("b"), "toggle: firing initially")

    // First tap (quick, no movement).
    engine.touchBegan(id: 1, at: CGPoint(x: 200, y: 400), time: 0)
    engine.touchEnded(id: 1, at: CGPoint(x: 201, y: 400), time: 0.1)
    // Second tap within window.
    engine.touchBegan(id: 2, at: CGPoint(x: 200, y: 400), time: 0.25)
    engine.touchEnded(id: 2, at: CGPoint(x: 201, y: 400), time: 0.35)

    frameTick(engine, count: 2)
    check(!inputs().contains("b"), "toggle: double-tap turns autofire OFF")

    // Double-tap again re-enables.
    engine.touchBegan(id: 3, at: CGPoint(x: 200, y: 400), time: 1.0)
    engine.touchEnded(id: 3, at: CGPoint(x: 201, y: 400), time: 1.1)
    engine.touchBegan(id: 4, at: CGPoint(x: 200, y: 400), time: 1.2)
    engine.touchEnded(id: 4, at: CGPoint(x: 201, y: 400), time: 1.3)

    check(engine.isFireEffective, "toggle: double-tap turns autofire back ON")
    frameTick(engine, count: 16)
    check(log2().contains("+b"), "toggle: firing pulses resume after re-enable")
}

// MARK: - 6. Double-tap window: slow taps don't toggle -

do
{
    let (engine, _, inputs) = makeEngine()
    engine.configuration.isAutofireAlwaysEnabled = true
    engine.beginSession()

    engine.touchBegan(id: 1, at: CGPoint(x: 200, y: 400), time: 0)
    engine.touchEnded(id: 1, at: CGPoint(x: 201, y: 400), time: 0.1)
    engine.touchBegan(id: 2, at: CGPoint(x: 200, y: 400), time: 0.9) // too late
    engine.touchEnded(id: 2, at: CGPoint(x: 201, y: 400), time: 1.0)

    check(engine.isFireEffective, "window: taps outside double-tap window don't toggle")
}

// MARK: - 7. Reset releases everything -

do
{
    let (engine, log, inputs) = makeEngine()
    engine.touchBegan(id: 1, at: CGPoint(x: 200, y: 400), time: 0)
    engine.touchMoved(id: 1, at: CGPoint(x: 160, y: 400))
    check(inputs().contains("left"), "reset: left held before reset")

    engine.reset()
    check(inputs().isEmpty, "reset: all inputs released")
}

// MARK: - 8. isIdle: display link can sleep when nothing dynamic -

do
{
    let (engine, _, _) = makeEngine()
    engine.configuration.isAutofireAlwaysEnabled = false
    engine.configuration.isEightWayEnabled = false

    check(engine.isIdle, "idle: fresh engine is idle")

    engine.touchBegan(id: 1, at: CGPoint(x: 200, y: 400), time: 0)
    check(!engine.isIdle, "idle: touch in progress -> not idle")

    // Sticky latched direction alone is static -> idle.
    engine.touchMoved(id: 1, at: CGPoint(x: 240, y: 400))
    engine.touchEnded(id: 1, at: CGPoint(x: 240, y: 400), time: 0.2)
    check(engine.activeDirections.contains("right"), "idle: direction latched")
    check(engine.isIdle, "idle: latched direction alone keeps engine idle")
}

// MARK: - 9. Swipe down action -

do
{
    // .stop (default)
    do
    {
        let (engine, _, inputs) = makeEngine()
        engine.configuration.directionMode = .sticky

        engine.touchBegan(id: 1, at: CGPoint(x: 200, y: 400), time: 0)
        engine.touchMoved(id: 1, at: CGPoint(x: 160, y: 400))
        check(inputs().contains("left"), "down/stop: moving left first")

        engine.touchMoved(id: 1, at: CGPoint(x: 160, y: 400 + 60))
        check(inputs().isEmpty, "down/stop: swipe down stops movement")
    }

    // .pressDown holds "down"
    do
    {
        let (engine, _, inputs) = makeEngine()
        engine.configuration.swipeDownAction = .pressDown

        engine.touchBegan(id: 1, at: CGPoint(x: 200, y: 400), time: 0)
        engine.touchMoved(id: 1, at: CGPoint(x: 200, y: 400 + 60))
        check(inputs().contains("down"), "down/press: down input held")
    }
}

// MARK: - 10. Split layout: fire-zone touch triggers autofire -

do
{
    let (engine, _, inputs) = makeEngine()
    engine.configuration.layout = .split
    engine.configuration.isAutofireAlwaysEnabled = false
    engine.beginSession()
    engine.setViewportWidth(400)

    engine.touchBegan(id: 1, at: CGPoint(x: 350, y: 400), time: 0) // right half
    frameTick(engine, count: 2)
    check(inputs().contains("b"), "split: hold right half fires")

    engine.touchEnded(id: 1, at: CGPoint(x: 350, y: 400), time: 0.3)
    frameTick(engine, count: 2)
    check(!inputs().contains("b"), "split: releasing right half stops firing")

    engine.touchBegan(id: 2, at: CGPoint(x: 50, y: 400), time: 1.0) // left half
    frameTick(engine, count: 4)
    check(!inputs().contains("b"), "split: left half doesn't fire")
}

// MARK: - 11. 8-way: diagonal activates two directions -

do
{
    let (engine, _, inputs) = makeEngine()
    engine.configuration.isEightWayEnabled = true
    engine.configuration.directionMode = .hold

    engine.touchBegan(id: 1, at: CGPoint(x: 200, y: 400), time: 0)
    engine.touchMoved(id: 1, at: CGPoint(x: 200 - 45, y: 400 - 45))
    check(inputs().contains("left") && inputs().contains("up"), "8-way: diagonal -> left+up")
}

// MARK: - 12. Tap opposite side to turn (default on) -

do
{
    let (engine, _, inputs) = makeEngine()
    engine.configuration.directionMode = .sticky
    engine.setViewportWidth(400)

    // Start running left (swipe left).
    engine.touchBegan(id: 1, at: CGPoint(x: 200, y: 400), time: 0)
    engine.touchMoved(id: 1, at: CGPoint(x: 150, y: 400))
    engine.touchEnded(id: 1, at: CGPoint(x: 140, y: 400), time: 0.3)
    check(inputs() == ["left"], "turn: running left first")

    // Tap on the RIGHT side -> instantly turns right, no swipe needed.
    engine.touchBegan(id: 2, at: CGPoint(x: 320, y: 400), time: 1.0)
    check(inputs() == ["right"], "turn: opposite-side tap flips direction immediately")

    // Releasing that tap must NOT stop movement (it was a reversing tap).
    engine.touchEnded(id: 2, at: CGPoint(x: 320, y: 400), time: 1.08)
    check(inputs() == ["right"], "turn: reversing tap doesn't stop movement")

    // And it must not register as a fire-toggle tap either.
    engine.touchBegan(id: 3, at: CGPoint(x: 320, y: 400), time: 1.2)
    engine.touchEnded(id: 3, at: CGPoint(x: 320, y: 400), time: 1.3)
    check(engine.isFireEffective, "turn: reversing tap excluded from double-tap toggle")
}

do
{
    // Tapping the SAME side does not reverse.
    let (engine, _, inputs) = makeEngine()
    engine.configuration.directionMode = .sticky
    engine.setViewportWidth(400)

    engine.touchBegan(id: 1, at: CGPoint(x: 100, y: 400), time: 0)
    engine.touchMoved(id: 1, at: CGPoint(x: 40, y: 400))
    engine.touchEnded(id: 1, at: CGPoint(x: 40, y: 400), time: 0.3)
    check(inputs() == ["left"], "turn-same: running left")

    engine.touchBegan(id: 2, at: CGPoint(x: 80, y: 400), time: 1.0) // still left half
    check(inputs() == ["left"], "turn-same: same-side tap doesn't flip")
    engine.touchEnded(id: 2, at: CGPoint(x: 80, y: 400), time: 1.1)
    check(inputs().isEmpty, "turn-same: normal tap still stops (sticky)")
}

do
{
    // Option disabled restores swipe-only behavior.
    let (engine, _, inputs) = makeEngine()
    engine.configuration.directionMode = .sticky
    engine.configuration.isTapOppositeSideToTurnEnabled = false
    engine.setViewportWidth(400)

    engine.touchBegan(id: 1, at: CGPoint(x: 200, y: 400), time: 0)
    engine.touchMoved(id: 1, at: CGPoint(x: 150, y: 400))
    engine.touchEnded(id: 1, at: CGPoint(x: 140, y: 400), time: 0.3)

    engine.touchBegan(id: 2, at: CGPoint(x: 320, y: 400), time: 1.0)
    check(inputs() == ["left"], "turn-off: opposite tap does nothing when disabled")
    engine.touchEnded(id: 2, at: CGPoint(x: 320, y: 400), time: 1.1)
    check(inputs().isEmpty, "turn-off: tap stops movement as before")
}

// MARK: - Report -

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
