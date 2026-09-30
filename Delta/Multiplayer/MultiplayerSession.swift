import UIKit
import Combine
import AVFoundation
import DeltaCore
import NESDeltaCore
import CoreData

// A process-wide lease also prevents a second iPad scene from starting another session.
final class MultiplayerSession: ObservableObject
{
    static weak var current: MultiplayerSession?

    @Published private(set) var state = MultiplayerSessionState()
    @Published private(set) var games = [NearbyGame]()
    @Published private(set) var title = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var pairingCode = ""
    @Published private(set) var isHost = false
    @Published private(set) var usesLocalROM = false
    var playbackDescription: String { usesLocalROM ? "Local video and audio · Matching ROM" : "Streamed video and audio" }
    private var localROM: URL?
    private var replica: MultiplayerLocalReplica?
    private var frameCapture: MultiplayerFrameCapture?
    private var pendingLocalState: MultiplayerPacket?
    private var guestAwaitingState = false

    var onEnd: (() -> Void)?
    var onStart: (() -> Void)?
    let input = MultiplayerInputForwarder()
    let player = MultiplayerMediaPlayer()
    private let remoteController = MultiplayerGameController(playerIndex: 1)
    private let hostController = MultiplayerGameController(playerIndex: 0)
    private let hostInput = MultiplayerInputForwarder()
    private var transport: MultiplayerTransport?
    private var encoder: MultiplayerVideoEncoder?
    private weak var core: EmulatorCore?
    private var coreObservation: NSKeyValueObservation?
    private var heartbeat: Timer?
    private var currentButtons: UInt8 = 0
    private var savedControllers = [ObjectIdentifier: (GameController, Int?)]()
    private var routedControllers = [GameController]()
    private var savedLocalIndex: Int?
    private var savedRate: Double = 1
    private var audioCapture: MultiplayerAudioCapture?
    private var observers = [NSObjectProtocol]()
    private var finished = false
    private var hasStarted = false
    private var awaitingMediaReady = false
    private var mediaReadyDeadline: TimeInterval = 0
    private var mediaMinimumTimestamp: UInt64 = 0
    private var lastInputAt = ProcessInfo.processInfo.systemUptime
    private var joinedWithRememberedKey = false
    private var mediaWatchdog: Timer?
    private var lastMediaAt = ProcessInfo.processInfo.systemUptime
    // True when a remembered-key rejoin could not connect; the join view then asks for the code.
    @Published private(set) var lastRejoinFailed = false
    // Media received since play began; shown on the guest screen to diagnose dead links.
    @Published private(set) var receivedFrames = 0

    var isActive: Bool { state.phase != .idle && state.phase != .disconnected }

    // A guest that is playing but receives nothing must not sit on a black screen forever.
    private func startMediaWatchdog()
    {
        lastMediaAt = ProcessInfo.processInfo.systemUptime
        mediaWatchdog?.invalidate()
        mediaWatchdog = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.isHost, self.state.phase == .playing else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastMediaAt > 8
            {
                self.end(message: "The host stopped sending the game. Please reconnect.")
            }
        }
        if let mediaWatchdog { RunLoop.main.add(mediaWatchdog, forMode: .common) }
    }

    private func noteMediaReceived()
    {
        lastMediaAt = ProcessInfo.processInfo.systemUptime
    }

    init()
    {
        input.onButtons = { [weak self] buttons in
            guard let self else { return }
            self.currentButtons = buttons
            if self.state.phase == .playing { self.transport?.send(.input, payload: Data([buttons])) }
        }
        player.onError = { [weak self] message in self?.end(message: message) }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isActive else { return }
            self.end(message: "Multiplayer ended because the app entered the background.")
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isActive else { return }
            self.end(message: "Multiplayer ended because audio was interrupted.")
        })
    }

    private func claim() -> Bool
    {
        if let current = Self.current, current !== self, current.isActive
        {
            errorMessage = "Another window already has an active multiplayer session."
            return false
        }
        Self.current = self
        errorMessage = nil
        games = []
        input.isEnabled = true
        usesLocalROM = false
        localROM = nil
        guestAwaitingState = false
        pendingLocalState = nil
        finished = false
        return true
    }

    func host(core: EmulatorCore, title: String)
    {
        guard core.game.type == .nes, claim() else { return }
        isHost = true
        self.core = core
        self.title = title
        savedLocalIndex = Settings.localControllerPlayerIndex
        savedRate = core.rate
        core.pause()
        core.rate = 1
        core.deltaCore.emulatorBridge.resetInputs()
        pairingCode = String(format: "%06d", Int.random(in: 0...999999))
        state.transition(to: .hosting)
        let transport = makeTransport()
        // Active cheats are not part of the portable state; stream those sessions.
        let hasCheats = (core.game as? Game)?.cheats.contains(where: { $0.isEnabled }) == true
        let digest = hasCheats ? nil : try? MultiplayerLocalGame.digest(core.game.fileURL)
        do { try transport.hostGame(title: title, code: pairingCode, romDigest: digest) }
        catch { end(message: error.localizedDescription); return }
        remoteController.addReceiver(core)
        hostController.addReceiver(core)
        hostInput.onButtons = { [weak self] buttons in
            guard let self else { return }
            if self.usesLocalROM { self.frameCapture?.setButtons(buttons, player: 0) }
            else { self.hostController.setButtons(buttons) }
        }
        heartbeat = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastInputAt > 0.5 {
                self.remoteController.setButtons(0)
                self.frameCapture?.setButtons(0, player: 1)
            }
            if self.awaitingMediaReady, now > self.mediaReadyDeadline { self.end(message: "The guest did not initialize playback. Please reconnect.") }
        }
        if let heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
        coreObservation = core.observe(\.state, options: [.new]) { [weak self] core, _ in
            let newState = core.state
            DispatchQueue.main.async { self?.hostStateChanged(newState) }
        }
    }

    func browse()
    {
        guard claim() else { return }
        transport?.stop()
        state.transition(to: .browsing)
        makeTransport().browse()
    }

    func join(_ game: NearbyGame, code: String)
    {
        guard code.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            errorMessage = "Enter the six digits shown on the host device."
            return
        }
        errorMessage = nil
        joinedWithRememberedKey = false
        lastRejoinFailed = false
        guard state.transition(to: .connecting) else { return }
        transport?.join(game, code: code)
    }

    // Reconnect to a host this device paired with before, without re-entering the code.
    func rejoin(_ game: NearbyGame)
    {
        errorMessage = nil
        joinedWithRememberedKey = true
        lastRejoinFailed = false
        guard state.transition(to: .connecting) else { return }
        transport?.rejoin(game)
    }

    func startGame()
    {
        guard isHost, core != nil, state.transition(to: .playing) else { return }
        hasStarted = true
        awaitingMediaReady = true
        mediaReadyDeadline = ProcessInfo.processInfo.systemUptime + 10
        let epoch = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        if usesLocalROM { prepareLocalCapture(); sendLocalState(epoch: epoch) }
        transport?.send(.start, timestamp: epoch)
        // Start capture only after the guest has initialized playback and acknowledged it.
    }

    // Called after the ordinary controller registration pass, including hot-plug changes.
    func routeHostControllers(_ controllers: [GameController])
    {
        guard isHost, isActive, let core else { return }
        for previous in routedControllers where !controllers.contains(where: { $0 === previous })
        {
            previous.removeReceiver(hostInput)
            hostInput.remove(previous)
        }
        routedControllers = controllers
        for controller in controllers
        {
            let id = ObjectIdentifier(controller)
            if savedControllers[id] == nil { savedControllers[id] = (controller, controller.playerIndex) }
            let mapping = controller.inputMapping(for: core) ?? controller.defaultInputMapping
            controller.removeReceiver(core)
            controller.playerIndex = 0
            controller.addReceiver(hostInput, inputMapping: mapping)
        }
    }

    func end(message: String? = nil)
    {
        guard !finished else { return }
        // A remembered key that no longer authenticates (host reinstalled, rotated its
        // secret, or a different host advertises the same title) falls back to the code;
        // keep the stored pairing in case the real host returns.
        if joinedWithRememberedKey, message != nil, state.phase == .connecting { lastRejoinFailed = true }
        finished = true
        transport?.send(.leave)
        transport?.stop()
        transport = nil
        heartbeat?.invalidate()
        heartbeat = nil
        coreObservation?.invalidate()
        coreObservation = nil
        if let core, isHost
        {
            // Pause before detaching callbacks; no emulation callback can race teardown.
            core.pause()
            if let bridge = core.deltaCore.emulatorBridge as? NESEmulatorBridge {
                bridge.shouldRunFrameHandler = nil
                bridge.willRunFrameHandler = nil
                bridge.didRunFrameHandler = nil
            }
            core.videoManager.frameHandler = nil
            (core.deltaCore.emulatorBridge as? NESEmulatorBridge)?.audioFrameHandler = nil
            remoteController.setButtons(0)
            hostController.setButtons(0)
            remoteController.removeReceiver(core)
            hostController.removeReceiver(core)
            for controller in routedControllers { controller.removeReceiver(hostInput) }
            routedControllers.removeAll()
            for (_, entry) in savedControllers { entry.0.playerIndex = entry.1 }
            savedControllers.removeAll()
            core.rate = savedRate
        }
        frameCapture?.stop()
        frameCapture = nil
        replica?.stop()
        replica = nil
        pendingLocalState = nil
        mediaWatchdog?.invalidate()
        mediaWatchdog = nil
        hostInput.reset()
        input.isEnabled = false
        encoder?.stop()
        encoder = nil
        audioCapture?.stop()
        audioCapture = nil
        if !isHost { player.stop() }
        state.transition(to: .disconnected)
        errorMessage = message
        if Self.current === self { Self.current = nil }
        if isHost { Settings.localControllerPlayerIndex = savedLocalIndex }
        onEnd?()
    }

    private func makeTransport() -> MultiplayerTransport
    {
        let transport = MultiplayerTransport()
        self.transport = transport
        transport.onDiscoveryNotice = { [weak self] in self?.errorMessage = $0 }
        transport.onGames = { [weak self] in self?.games = $0 }
        transport.onReady = { [weak self, weak transport] title in
            guard let self, let transport else { return }
            self.title = title
            if !self.isHost, let digest = transport.romDigest, NESEmulatorBridge.shared.gameURL == nil
            {
                let request: NSFetchRequest<Game> = Game.fetchRequest()
                let candidates = (try? DatabaseManager.shared.viewContext.fetch(request)) ?? []
                self.localROM = candidates.first(where: { $0.type == .nes && (try? MultiplayerLocalGame.digest($0.fileURL)) == digest })?.fileURL
                if self.localROM != nil {
                    self.usesLocalROM = true
                    transport.send(.localROM, payload: digest)
                }
            }
            guard self.state.transition(to: .ready) else { self.end(message: "Unexpected session state."); return }
            if self.isHost
            {
                // Issue the return key so this guest can rejoin without the pairing code.
                transport.send(.pairKey, payload: MultiplayerPairing.returnKey)
            }
            if !self.isHost
            {
                self.heartbeat = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self, self.state.phase == .playing else { return }
                    self.transport?.send(.input, payload: Data([self.currentButtons]))
                }
                if let heartbeat = self.heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
            }
        }
        transport.onPacket = { [weak self] in self?.receive($0) }
        transport.onDisconnect = { [weak self] in self?.end(message: $0) }
        return transport
    }

    private func prepareCapture(_ core: EmulatorCore)
    {
        let encoder = MultiplayerVideoEncoder()
        self.encoder = encoder
        encoder.onFrame = { [weak self] data, timestamp, done in
            guard let self, self.state.phase == .playing, !self.awaitingMediaReady else { done(); return }
            self.transport?.sendMedia(.video, payload: data, timestamp: timestamp) { _ in done() }
        }
        encoder.onError = { [weak self] in self?.end(message: $0) }
        core.videoManager.frameHandler = { [weak encoder] in encoder?.capture($0) }
        let capture = MultiplayerAudioCapture()
        audioCapture = capture
        capture.onSamples = { [weak self] data, timestamp, done in
            guard let self, self.state.phase == .playing, !self.awaitingMediaReady else { done(); return }
            self.transport?.sendMedia(.audio, payload: data, timestamp: timestamp) { _ in done() }
        }
        (core.deltaCore.emulatorBridge as? NESEmulatorBridge)?.audioFrameHandler = { [weak capture] in capture?.capture($0) }
    }

    private func hostStateChanged(_ newState: EmulatorCore.State)
    {
        guard isActive, isHost, hasStarted else { return }
        if newState == .stopped { end(message: "The host stopped the game.") }
        else if newState == .paused, state.transition(to: .paused)
        {
            hostInput.reset()
            remoteController.setButtons(0)
            audioCapture?.resetClock()
            frameCapture?.setEnabled(false)
            transport?.send(.pause)
        }
        else if newState == .running, state.transition(to: .playing)
        {
            awaitingMediaReady = true
            mediaReadyDeadline = ProcessInfo.processInfo.systemUptime + 10
            let epoch = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
            if usesLocalROM { sendLocalState(epoch: epoch) }
            transport?.send(.resume, timestamp: epoch)
        }
    }

    private func receive(_ packet: MultiplayerPacket)
    {
        switch packet.kind
        {
        case .input:
            if isHost, state.phase == .playing, let buttons = packet.payload.first
            {
                lastInputAt = ProcessInfo.processInfo.systemUptime
                if usesLocalROM { frameCapture?.setButtons(buttons, player: 1) }
                else { remoteController.setButtons(buttons) }
            }
        case .start:
            guard !isHost, state.transition(to: .playing) else { end(message: "Unexpected start message."); return }
            mediaMinimumTimestamp = packet.timestamp
            do
            {
                // Local-ROM audio must clear Wi-Fi transit, replica execution, and jitter;
                // streamed audio only needs to cover decoder scheduling.
                try player.start(playbackDelay: usesLocalROM ? 0.05 : 0.035)
                if usesLocalROM { guestAwaitingState = true; tryStartReplica() }
                else { transport?.send(.started) }
                startMediaWatchdog()
                onStart?()
            }
            catch { end(message: error.localizedDescription) }
        case .pause:
            guard !isHost, state.transition(to: .paused) else { return }
            input.isEnabled = false
            mediaWatchdog?.invalidate()
            mediaWatchdog = nil
            replica?.pause()
            player.pause()
        case .resume:
            guard !isHost, state.transition(to: .playing) else { return }
            mediaMinimumTimestamp = packet.timestamp
            startMediaWatchdog()
            // The guest screen reenables inputs only when its local menu is closed.
            if usesLocalROM { guestAwaitingState = true; tryStartReplica() }
            else { transport?.send(.started) }
        case .started:
            guard isHost, state.phase == .playing, awaitingMediaReady, let core else { return }
            awaitingMediaReady = false
            if usesLocalROM {
                frameCapture?.setEnabled(true)
                if core.state == .paused { onStart?(); core.resume() }
                return
            }
            audioCapture?.resetClock()
            encoder?.requestKeyFrame()
            if encoder == nil
            {
                prepareCapture(core)
                onStart?()
                core.resume()
            }
        case .localROM:
            guard isHost, state.phase == .hosting, packet.payload == transport?.romDigest else { end(message: "The games do not match."); return }
            usesLocalROM = true
        case .localState:
            guard !isHost, usesLocalROM else { end(message: "Unexpected local game state."); return }
            pendingLocalState = packet
            tryStartReplica()
        case .localFrame:
            guard !isHost, usesLocalROM, state.phase == .playing, !guestAwaitingState, packet.timestamp >= mediaMinimumTimestamp else { return }
            noteMediaReceived()
            receivedFrames += 1
            do { replica?.receive(try MultiplayerFrame(data: packet.payload), timestamp: packet.timestamp) }
            catch { end(message: error.localizedDescription) }
        case .pairKey:
            guard !isHost, state.phase == .ready, packet.payload.count == 32 else { return }
            if let hostID = transport?.hostDeviceID.uuidString
            {
                MultiplayerPairing.remember(hostID: hostID, name: title, key: packet.payload)
            }
        case .video, .audio:
            if !isHost, !usesLocalROM, state.phase == .playing, packet.timestamp >= mediaMinimumTimestamp
            {
                noteMediaReceived()
                if packet.kind == .video { receivedFrames += 1 }
                player.receive(packet)
            }
        default: break
        }
    }


    private func prepareLocalCapture()
    {
        guard let core, let bridge = core.deltaCore.emulatorBridge as? NESEmulatorBridge else { return }
        hostController.removeReceiver(core)
        remoteController.removeReceiver(core)
        let capture = MultiplayerFrameCapture()
        frameCapture = capture
        capture.onFrame = { [weak self] frame, timestamp, done in
            guard let self, self.state.phase == .playing, !self.awaitingMediaReady else { done(); return }
            self.transport?.sendMedia(.localFrame, payload: frame.data, timestamp: timestamp) { _ in done() }
        }
        capture.onError = { [weak self] in self?.end(message: "The connection cannot keep up with the game. Please reconnect.") }
        bridge.shouldRunFrameHandler = { [weak capture] in capture?.shouldRun == true }
        bridge.willRunFrameHandler = { [weak capture, weak bridge] in
            if let bridge { capture?.beforeFrame(bridge) }
        }
        bridge.didRunFrameHandler = { [weak capture, weak core] in
            if let core { capture?.afterFrame(core.videoManager) }
        }
    }

    private func sendLocalState(epoch: UInt64)
    {
        guard let bridge = core?.deltaCore.emulatorBridge as? NESEmulatorBridge else { return }
        // The frame gate is closed since pause, even if the outer game loop has resumed.
        frameCapture?.reset(epoch: epoch)
        do {
            let data = try MultiplayerLocalGame.snapshot(bridge)
            transport?.sendMedia(.localState, payload: data, timestamp: epoch) { [weak self] sent in
                if !sent { self?.end(message: "Could not synchronize the local game.") }
            }
        } catch { end(message: error.localizedDescription) }
    }

    private func tryStartReplica()
    {
        guard guestAwaitingState, let packet = pendingLocalState, packet.timestamp == mediaMinimumTimestamp,
              let localROM else { return }
        pendingLocalState = nil
        do {
            if replica == nil {
                replica = try MultiplayerLocalReplica(romURL: localROM)
                replica?.onError = { [weak self] in self?.end(message: $0) }
                replica?.onFrame = { [weak self] image, audio, timestamp in
                    guard let self, self.state.phase == .playing else { return }
                    if let image { self.player.receiveImage(image, timestamp: timestamp) }
                    if !audio.isEmpty {
                        self.player.receive(MultiplayerPacket(kind: .audio, session: .init(), sequence: 1, timestamp: timestamp, payload: audio))
                    }
                }
            }
            try replica?.load(packet.payload) { [weak self] in
                guard let self, self.state.phase == .playing, self.mediaMinimumTimestamp == packet.timestamp else { return }
                self.guestAwaitingState = false
                self.transport?.send(.started)
            }
        } catch { end(message: "Could not start the local game: \(error.localizedDescription)") }
    }

    deinit
    {
        transport?.stop()
        heartbeat?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

private final class MultiplayerAudioCapture
{
    var onSamples: ((Data, UInt64, @escaping () -> Void) -> Void)?
    private let lock = NSLock()
    private var pending = 0
    private var stopped = false
    private var origin: UInt64?
    private var frames: UInt64 = 0

    func capture(_ data: Data)
    {
        guard !data.isEmpty, data.count <= 8820, data.count % 2 == 0 else { return }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        if origin == nil { origin = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000); frames = 0 }
        let timestamp = origin! + frames * 1_000_000 / 44100
        frames += UInt64(data.count / 2)
        guard pending < 6 else { lock.unlock(); return }
        pending += 1
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
            let done = { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.pending -= 1; self.lock.unlock()
            }
            guard !stopped, let onSamples = self.onSamples else { done(); return }
            onSamples(data, timestamp, done)
        }
    }

    func resetClock() { lock.lock(); origin = nil; frames = 0; lock.unlock() }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
}
