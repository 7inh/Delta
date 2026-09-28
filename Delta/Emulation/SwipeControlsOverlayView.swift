//
//  SwipeControlsOverlayView.swift
//  Delta
//
//  Created by Tran Quoc Linh on 9/28/26.
//
//  Transparent view laid over ControllerView that converts touches into
//  swipe gestures (movement, jump, autofire). Touches that begin on
//  "passthrough" skin items (Start/Select/Menu, touch screens, and any
//  buttons not handled by gestures) fall through to ControllerView below.
//

import UIKit
import DeltaCore
import DeltaFeatures

final class SwipeControlsOverlayView: UIView
{
    // MARK: - Properties -

    private(set) var swipeController: SwipeGameController?

    /// The controller view we mirror (for skin item passthrough frames).
    private weak var controllerView: ControllerView?

    let engine = SwipeInputEngine()

    private var passthroughFrames: [CGRect] = []
    private var passthroughCacheKey: String?
    private var displayLink: CADisplayLink?
    private var nextTouchID = 0
    private var touchIDs = [ObjectIdentifier: Int]()

    private var isActive: Bool {
        return !self.isHidden && self.superview != nil
    }

    // Hints
    private var hintsSize: CGSize = .zero
    private var hintLayers: [String: CAShapeLayer] = [:]
    private var fireHintLayer: CAShapeLayer?
    private var splitHintLayer: CAShapeLayer?

    private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)

    // MARK: - Init -

    init(controllerView: ControllerView, swipeController: SwipeGameController)
    {
        self.controllerView = controllerView
        self.swipeController = swipeController

        super.init(frame: .zero)

        self.backgroundColor = .clear
        self.isMultipleTouchEnabled = true
        self.isUserInteractionEnabled = true

        self.engine.onActivate = { [weak self] input in
            self?.swipeController?.activate(swipeInput: input)
        }
        self.engine.onDeactivate = { [weak self] input in
            self?.swipeController?.deactivate(swipeInput: input)
        }
        self.engine.onEvent = { [weak self] event in
            self?.handleEngineEvent(event)
        }

        self.applyConfiguration()

        NotificationCenter.default.addObserver(self, selector: #selector(SwipeControlsOverlayView.settingsDidChange(_:)), name: .settingsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(SwipeControlsOverlayView.didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(SwipeControlsOverlayView.willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder)
    {
        fatalError("init(coder:) is not supported")
    }

    deinit
    {
        self.displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Configuration -

    func applyConfiguration()
    {
        let feature = Settings.features.swipeControls
        guard feature.isEnabled else { return }

        var config = SwipeInputEngine.Configuration()
        config.layout = feature.layout
        config.directionMode = feature.directionMode
        config.isEightWayEnabled = feature.isEightWayEnabled
        config.swipeThreshold = CGFloat(feature.swipeThreshold)
        config.swipeUpAction = feature.swipeUpAction
        config.swipeDownAction = feature.swipeDownAction
        config.jumpButton = feature.jumpButton.rawValue
        config.fireButton = feature.fireButton.rawValue
        config.isAutofireAlwaysEnabled = feature.isAutofireAlwaysEnabled
        config.isTapOppositeSideToTurnEnabled = feature.isTapOppositeSideToTurnEnabled
        config.autofireRate = feature.autofireRate
        config.jumpPulseFrames = feature.jumpPulseFrames
        config.showsHints = feature.showsHints
        config.isHapticsEnabled = feature.isHapticsEnabled

        self.engine.configuration = config
        self.engine.beginSession()
        self.engine.setViewportWidth(self.bounds.width)

        self.updatePassthroughFrames()
        self.rebuildHintLayers()
    }

    @objc private func settingsDidChange(_ notification: Notification)
    {
        guard self.isActive else { return }

        let name = notification.userInfo?[SettingsUserInfoKey.name] as? SettingsName
        if name == nil || name?.rawValue.contains("swipeControls") == true || name?.rawValue.contains("SwipeControls") == true
        {
            self.engine.reset()
            self.applyConfiguration()
            self.updateDisplayLink()
        }
    }

    @objc private func didEnterBackground()
    {
        self.pauseSession()
    }

    @objc private func willResignActive()
    {
        self.pauseSession()
    }

    /// Called by GameViewController when emulation pauses (or game changes).
    func pauseSession()
    {
        self.engine.reset()
        self.updateDisplayLink()
        self.updateHints()
    }

    /// Called by GameViewController when emulation (re)starts so autofire
    /// resumes without requiring a touch.
    func resumeSession()
    {
        self.updateDisplayLink()
    }

    // MARK: - Passthrough -

    func updatePassthroughFrames()
    {
        self.passthroughCacheKey = nil
        self.recomputePassthroughFrames()
    }

    /// Recomputes passthrough frames only when the skin, traits or view size
    /// changed. The skin often loads *after* the overlay is created, so this
    /// must not be a one-shot computation or Start/Select/Menu stop working.
    func ensurePassthroughFrames()
    {
        guard let controllerView = self.controllerView else { return }

        let skinID = controllerView.controllerSkin?.identifier ?? "-"
        let traitsID = controllerView.controllerSkinTraits.map { String(describing: $0) } ?? "-"
        let key = "\(skinID)|\(traitsID)|\(controllerView.bounds.size.width)x\(controllerView.bounds.size.height)"

        guard key != self.passthroughCacheKey else { return }

        self.passthroughCacheKey = key
        self.recomputePassthroughFrames()
    }

    private func recomputePassthroughFrames()
    {
        guard let controllerView = self.controllerView, let traits = controllerView.controllerSkinTraits else { return }

        guard let controllerSkin = controllerView.controllerSkin, let items = controllerSkin.items(for: traits), controllerView.bounds.width > 0 else {
            self.passthroughFrames = []
            return
        }

        // Item frames are normalized; scale into controllerView coordinates
        // (which match our coordinates, since we pin to controllerView).
        let scale = CGAffineTransform(scaleX: controllerView.bounds.width, y: controllerView.bounds.height)

        let gestureInputs: Set<String> = [
            Direction.up, Direction.down, Direction.left, Direction.right,
            self.engine.configuration.jumpButton, self.engine.configuration.fireButton
        ]

        self.passthroughFrames = items.compactMap { item -> CGRect? in
            // Touch screens (Nintendo DS) always pass through.
            if item.kind == .touchScreen { return item.frame.applying(scale) }

            // Pass through items whose inputs aren't handled by gestures
            // (Start/Select/Menu, quick save/load, fast forward, L/R, ...).
            let inputStrings = item.inputs.allInputs.map(\.stringValue)
            let handlesItem = inputStrings.contains { gestureInputs.contains($0) }

            let frame = item.frame.applying(scale)

            return handlesItem ? nil : self.convert(frame, from: controllerView)
        }
    }

    // MARK: - Touch Routing -

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView?
    {
        guard self.isActive, self.bounds.contains(point) else { return nil }

        self.ensurePassthroughFrames()

        for frame in self.passthroughFrames where frame.contains(point)
        {
            // Fall through to the controller skin beneath.
            return nil
        }

        return self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?)
    {
        super.touchesBegan(touches, with: event)
        self.handleTouches(touches) { id, point, _ in
            self.engine.touchBegan(id: id, at: point, time: CACurrentMediaTime())
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?)
    {
        super.touchesMoved(touches, with: event)
        self.handleTouches(touches) { id, point, _ in
            self.engine.touchMoved(id: id, at: point)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?)
    {
        super.touchesEnded(touches, with: event)
        self.handleTouches(touches) { id, point, _ in
            self.engine.touchEnded(id: id, at: point, time: CACurrentMediaTime())
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?)
    {
        super.touchesCancelled(touches, with: event)
        self.handleTouches(touches) { id, _, _ in
            self.engine.touchCancelled(id: id)
        }
    }

    private func handleTouches(_ touches: Set<UITouch>, handler: (Int, CGPoint, UITouch) -> Void)
    {
        guard self.isActive else { return }

        for touch in touches
        {
            let identifier = ObjectIdentifier(touch)
            if self.touchIDs[identifier] == nil
            {
                self.nextTouchID += 1
                self.touchIDs[identifier] = self.nextTouchID
            }

            let location = touch.location(in: self)
            handler(self.touchIDs[identifier]!, location, touch)
        }

        self.engine.setViewportWidth(self.bounds.width)
        self.updateDisplayLink()
    }

    // MARK: - Display Link -

    func updateDisplayLink()
    {
        let shouldBeRunning = !self.engine.isIdle

        if shouldBeRunning && self.displayLink == nil
        {
            let displayLink = CADisplayLink(target: self, selector: #selector(SwipeControlsOverlayView.step(_:)))
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }
        else if !shouldBeRunning, let displayLink = self.displayLink
        {
            displayLink.invalidate()
            self.displayLink = nil
        }
    }

    @objc private func step(_ displayLink: CADisplayLink)
    {
        self.engine.tick()
        self.updateHints()
        self.updateDisplayLink()
    }

    // MARK: - Events & Haptics -

    private func handleEngineEvent(_ event: SwipeInputEngine.Event)
    {
        let isHapticsEnabled = self.engine.configuration.isHapticsEnabled

        switch event
        {
        case .jumpTriggered:
            if isHapticsEnabled { self.hapticGenerator.impactOccurred() }

        case .directionChanged:
            if isHapticsEnabled { self.hapticGenerator.impactOccurred(intensity: 0.6) }

        case .fireToggled:
            if isHapticsEnabled
            {
                let generator = UIImpactFeedbackGenerator(style: .rigid)
                generator.impactOccurred()
            }

        case .stopped:
            break
        }

        self.updateHints()
    }

    // MARK: - Hints -

    private func rebuildHintLayers()
    {
        self.hintLayers.values.forEach { $0.removeFromSuperlayer() }
        self.hintLayers.removeAll()
        self.fireHintLayer?.removeFromSuperlayer()
        self.fireHintLayer = nil
        self.splitHintLayer?.removeFromSuperlayer()
        self.splitHintLayer = nil

        guard self.engine.configuration.showsHints else { return }

        self.hintsSize = self.bounds.size

        // Direction arrows along the edges.
        let arrowSpecs: [(String, UIBezierPath)] = [
            (Direction.left, self.arrowPath(center: CGPoint(x: 40, y: self.bounds.midY), direction: .pi)),
            (Direction.right, self.arrowPath(center: CGPoint(x: self.bounds.width - 40, y: self.bounds.midY), direction: 0)),
            (Direction.up, self.arrowPath(center: CGPoint(x: self.bounds.midX, y: 40), direction: -.pi / 2)),
            (Direction.down, self.arrowPath(center: CGPoint(x: self.bounds.midX, y: self.bounds.height - 40), direction: .pi / 2))
        ]

        for (name, path) in arrowSpecs
        {
            let layer = CAShapeLayer()
            layer.path = path.cgPath
            layer.fillColor = UIColor.white.withAlphaComponent(0.85).cgColor
            layer.opacity = 0
            self.layer.addSublayer(layer)
            self.hintLayers[name] = layer
        }

        // Fire indicator dot (top-leading).
        let fireLayer = CAShapeLayer()
        fireLayer.path = UIBezierPath(ovalIn: CGRect(x: 24, y: 24, width: 14, height: 14)).cgPath
        fireLayer.fillColor = UIColor.systemRed.cgColor
        fireLayer.opacity = 0
        self.layer.addSublayer(fireLayer)
        self.fireHintLayer = fireLayer

        // Split-mode divider.
        if self.engine.configuration.layout == .split
        {
            let divider = CAShapeLayer()
            let path = UIBezierPath()
            let x = self.bounds.width * self.engine.configuration.fireZoneFraction
            path.move(to: CGPoint(x: x, y: 10))
            path.addLine(to: CGPoint(x: x, y: self.bounds.height - 10))
            divider.path = path.cgPath
            divider.strokeColor = UIColor.white.withAlphaComponent(0.25).cgColor
            divider.lineWidth = 1
            divider.lineDashPattern = [4, 6]
            self.layer.addSublayer(divider)
            self.splitHintLayer = divider
        }

        self.updateHints()
    }

    private func arrowPath(center: CGPoint, direction: CGFloat) -> UIBezierPath
    {
        let path = UIBezierPath()
        let length: CGFloat = 12
        let spread: CGFloat = 10

        let tip = CGPoint(x: center.x + cos(direction) * length, y: center.y + sin(direction) * length)
        let backLeft = CGPoint(x: center.x - cos(direction) * length + cos(direction + .pi / 2) * spread, y: center.y - sin(direction) * length + sin(direction + .pi / 2) * spread)
        let backRight = CGPoint(x: center.x - cos(direction) * length + cos(direction - .pi / 2) * spread, y: center.y - sin(direction) * length + sin(direction - .pi / 2) * spread)

        path.move(to: tip)
        path.addLine(to: backLeft)
        path.addLine(to: backRight)
        path.close()

        return path
    }

    private func updateHints()
    {
        func setOpacity(_ layer: CALayer?, _ visible: Bool)
        {
            guard let layer else { return }
            let target = Float(visible ? 0.5 : 0.0)
            guard layer.opacity != target else { return }

            let animation = CABasicAnimation(keyPath: "opacity")
            animation.toValue = target
            animation.duration = 0.12
            layer.add(animation, forKey: "opacity")
            layer.opacity = target
        }

        for (name, layer) in self.hintLayers
        {
            setOpacity(layer, self.engine.activeDirections.contains(name))
        }

        setOpacity(self.fireHintLayer, self.engine.isFireEffective)
    }

    // MARK: - Layout -

    override func layoutSubviews()
    {
        super.layoutSubviews()

        self.engine.setViewportWidth(self.bounds.width)
        self.ensurePassthroughFrames()

        // Only rebuild hint layers when the size actually changes — rebuilding
        // every layout pass mutates the layer tree, which invalidates layout
        // again and spins CPU forever.
        if self.engine.configuration.showsHints, self.hintsSize != self.bounds.size
        {
            self.hintsSize = self.bounds.size
            self.rebuildHintLayers()
        }
    }
}
