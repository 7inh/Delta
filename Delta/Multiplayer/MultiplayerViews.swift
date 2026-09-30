import SwiftUI
import UIKit
import Combine
import DeltaCore
import NESDeltaCore

struct NearbyMultiplayerLobby: View
{
    @ObservedObject var session: MultiplayerSession
    var resume: () -> Void
    var close: () -> Void

    var body: some View {
        Form {
            Section {
                Text(session.title).font(.headline)
                Text(session.playbackDescription).font(.caption).foregroundStyle(.secondary)
                Label("Player 1 · This Device", systemImage: "iphone")
                Label(session.state.phase == .disconnected ? "Player 2 · Disconnected" :
                      session.state.phase == .hosting ? "Player 2 · Waiting to join" : "Player 2 · Connected", systemImage: "person.fill")
            }
            if session.state.phase == .hosting
            {
                Section {
                    Text(session.pairingCode).font(.largeTitle.monospacedDigit()).textSelection(.enabled)
                } header: {
                    Text("Pairing Code")
                } footer: {
                    Text("On the other device, open Settings → Nearby Multiplayer → Join Game. Select this game and enter the code. Both devices must use the same Wi-Fi network.")
                }
            }
            if session.state.phase == .ready
            {
                Button("Start Game") { session.startGame() }
            }
            if session.state.phase == .paused
            {
                Button("Resume Game", action: resume)
            }
            if let message = session.errorMessage
            {
                Section { Text(message).foregroundStyle(.secondary) }
            }
            Button(session.isActive ? "End Multiplayer" : "Continue Solo") {
                session.end()
                close()
            }
            .foregroundStyle(.red)
        }
        .navigationTitle("Nearby Multiplayer")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(session.isActive)
    }
}

struct NearbyMultiplayerJoinView: View
{
    @StateObject private var session = MultiplayerSession()
    @SwiftUI.State private var selected: NearbyGame?
    @SwiftUI.State private var code = ""
    @SwiftUI.State private var showsGuest = false
    @SwiftUI.State private var rejoinedHostID: String?
    @SwiftUI.State private var forgottenHostIDs = Set<String>()
    @SwiftUI.State private var rememberedHosts = [RememberedHost]()

    var body: some View {
        Form {
            Section {
                Text("Join Game").font(.headline)
                Text("Play as Player 2. A matching imported ROM generates video and audio on this device for smoother play. Otherwise, the host streams the game.")
                    .foregroundStyle(.secondary)
            }
            if session.state.phase == .browsing
            {
                Section {
                    if session.games.isEmpty
                    {
                        HStack { ProgressView(); Text("Looking for a host…") }
                    }
                    ForEach(session.games) { game in
                        let remembered = game.rejoinID != nil
                            && game.rememberedKey != nil
                            && !forgottenHostIDs.contains(game.hostID?.uuidString ?? "")
                            && !(session.lastRejoinFailed && rejoinedHostID == game.hostID?.uuidString)
                        Button {
                            if remembered {
                                rejoinedHostID = game.hostID?.uuidString
                                session.rejoin(game)
                            } else {
                                selected = game
                                code = ""
                            }
                        } label: {
                            HStack {
                                Text(game.title)
                                if remembered {
                                    Spacer()
                                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if remembered {
                                Button(role: .destructive) {
                                    if let hostID = game.hostID { MultiplayerPairing.forget(hostID: hostID.uuidString) }
                                    if let hostID = game.hostID { forgottenHostIDs.insert(hostID.uuidString) }
                                    if rejoinedHostID == game.hostID?.uuidString { rejoinedHostID = nil }
                                } label: {
                                    Label("Forget", systemImage: "clock.arrow.circlepath")
                                }
                            }
                        }
                        .contextMenu {
                            if remembered {
                                Button(role: .destructive) {
                                    if let hostID = game.hostID { MultiplayerPairing.forget(hostID: hostID.uuidString) }
                                    if let hostID = game.hostID { forgottenHostIDs.insert(hostID.uuidString) }
                                    if rejoinedHostID == game.hostID?.uuidString { rejoinedHostID = nil }
                                } label: {
                                    Label("Forget This Host", systemImage: "clock.arrow.circlepath")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Nearby Games")
                } footer: {
                    Text("On the host, open an NES game and choose Pause → Nearby Multiplayer → Host Game. Keep both devices on the same Wi-Fi network. Games marked with a clock rejoin without the pairing code; swipe one left to remove it.")
                }
                if let selected, session.state.phase == .browsing || session.state.phase == .connecting
                {
                    // Inline code entry: an alert can get stuck invisible when the view below
                    // changes state (connecting → error) and then swallows every touch.
                    Section {
                        Text(selected.title)
                        TextField("6-digit code", text: $code).keyboardType(.numberPad)
                        Button("Join") { session.join(selected, code: code) }
                            .disabled(code.count != 6)
                        Button("Cancel", role: .destructive) {
                            self.selected = nil
                            code = ""
                        }
                    } header: {
                        Text("Enter Pairing Code")
                    } footer: {
                        Text("Enter the code shown on the host device.")
                    }
                }
            }
            if session.state.phase == .disconnected, session.errorMessage == nil
            {
                Button("Join Another Game") { session.browse() }
            }
            if session.state.phase == .connecting { ProgressView("Connecting…") }
            if !rememberedHosts.isEmpty, session.state.phase != .ready, session.state.phase != .playing
            {
                Section {
                    ForEach(rememberedHosts) { host in
                        HStack {
                            Label(host.name, systemImage: "clock.arrow.circlepath")
                            Spacer()
                            Button("Forget") {
                                MultiplayerPairing.forget(hostID: host.hostID)
                                forgottenHostIDs.insert(host.hostID)
                                refreshRememberedHosts()
                            }
                            .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Remembered Hosts")
                } footer: {
                    Text("These hosts can be rejoined without a pairing code. Forgetting one asks for its code again.")
                }
            }
            if session.state.phase == .ready
            {
                Section {
                    Text(session.title)
                    Text(session.playbackDescription).font(.caption)
                    Text("Player 2 · Waiting for the host to start")
                }
            }
            if let message = session.errorMessage
            {
                Section {
                    Text(message)
                    Button("Try Again") { session.browse() }
                    Button("Open System Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
        }
        .navigationTitle("Nearby Multiplayer")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showsGuest, onDismiss: { session.end() }) {
            NearbyGuestScreen(session: session)
                .ignoresSafeArea()
        }
        .onAppear {
            if session.state.phase == .idle { session.browse() }

        }
        .onChange(of: session.state.phase) { _, phase in
            if phase == .playing { showsGuest = true; rejoinedHostID = nil }
            refreshRememberedHosts()
        }
        .onAppear {
            refreshRememberedHosts()
        }
        .onDisappear {
            if !showsGuest { session.end() }
        }
    }

    private func refreshRememberedHosts()
    {
        rememberedHosts = MultiplayerPairing.rememberedHosts()
    }
}

private struct NearbyGuestScreen: UIViewControllerRepresentable
{
    let session: MultiplayerSession
    func makeUIViewController(context: Context) -> NearbyGuestViewController { NearbyGuestViewController(session: session) }
    func updateUIViewController(_ uiViewController: NearbyGuestViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: NearbyGuestViewController, coordinator: ()) { uiViewController.disconnect() }
}

// Deliberately leaves GameViewController.game nil: there is no guest emulator or save lifecycle.
private final class NearbyGuestViewController: DeltaCore.GameViewController
{
    let session: MultiplayerSession
    private let swipeController = SwipeGameController()
    private var overlay: SwipeControlsOverlayView!
    private var connected = [GameController]()
    private var observers = [NSObjectProtocol]()
    private var stateSubscription: AnyCancellable?
    private let statusLabel = UILabel()
    private let menuButton = UIButton(type: .system)
    private var showingMenu = false
    private var framesSubscription: AnyCancellable?

    init(session: MultiplayerSession)
    {
        self.session = session
        super.init()
        automaticallyPausesWhileInactive = false
    }

    required init() { fatalError("Use init(session:)") }
    required init?(coder: NSCoder) { fatalError("Use init(session:)") }

    override func viewDidLoad()
    {
        super.viewDidLoad()
        controllerView.controllerSkin = DeltaCore.ControllerSkin.standardControllerSkin(for: .nes)
        controllerView.playerIndex = 1
        swipeController.playerIndex = 1
        (swipeController.defaultInputMapping as? SwipeInputMapping)?.gameType = .nes
        overlay = SwipeControlsOverlayView(controllerView: controllerView, swipeController: swipeController)
        overlay.onMenuToggle = { [weak self] in self?.showMenu() }
        // ControllerView routes hit testing directly to its skin buttons, so the
        // gesture overlay must be its sibling (as on the local game screen).
        view.addSubview(overlay)
        session.input.onMenu = { [weak self] in self?.showMenu() }
        session.player.onImage = { [weak self] image in
            guard let self else { return }
            (self.gameViews + self.controllerView.gameViews).forEach { $0.inputImage = image }
        }
        menuButton.setTitle("Menu", for: .normal)
        menuButton.tintColor = .white
        menuButton.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        menuButton.layer.cornerRadius = 12
        menuButton.addTarget(self, action: #selector(showMenu), for: .touchUpInside)
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menuButton)
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            menuButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            menuButton.widthAnchor.constraint(equalToConstant: 68), menuButton.heightAnchor.constraint(equalToConstant: 36),
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusLabel.topAnchor.constraint(equalTo: menuButton.topAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -8)
        ])
        for name in [Notification.Name.externalGameControllerDidConnect, .externalGameControllerDidDisconnect, .settingsDidChange]
        {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.configureInputs() })
        }
        stateSubscription = session.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self else { return }
            self.updateStatusLabel()
            if state.phase == .paused { self.overlay.pauseSession() }
            if state.phase == .playing, !self.showingMenu { self.session.input.isEnabled = true; self.overlay.resumeSession() }
            if state.phase == .disconnected { self.showDisconnected() }
        }
        framesSubscription = session.$receivedFrames.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateStatusLabel()
        }
        configureInputs()
    }

    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)
        // Skin assignment in viewDidLoad can race early view loading before cores register.
        if controllerView.controllerSkin == nil {
            controllerView.controllerSkin = DeltaCore.ControllerSkin.standardControllerSkin(for: .nes)
        }
    }

    private func updateStatusLabel()
    {
        if session.state.phase == .paused
        {
            statusLabel.text = "Host paused the game"
        }
        else if session.state.phase == .playing, session.receivedFrames == 0
        {
            statusLabel.text = "Player 2 · \(session.title) · waiting for game…"
        }
        else
        {
            statusLabel.text = "Player 2 · \(session.title) · \(session.receivedFrames) frames"
        }
    }

    override func viewDidLayoutSubviews()
    {
        super.viewDidLayoutSubviews()
        overlay.frame = view.bounds
        view.bringSubviewToFront(menuButton)
        view.bringSubviewToFront(statusLabel)
    }

    private func configureInputs()
    {
        let external = ExternalGameControllerManager.shared.connectedControllers
        let controllers: [GameController] = [controllerView, swipeController] + external
        for previous in connected where !controllers.contains(where: { $0 === previous })
        {
            previous.removeReceiver(session.input)
            session.input.remove(previous)
        }
        connected = controllers
        for controller in controllers
        {
            let mapping = GameControllerInputMapping.inputMapping(forPlayer: 1, gameType: .nes, controllerType: controller.inputType, in: DatabaseManager.shared.viewContext)
            controller.addReceiver(session.input, inputMapping: mapping ?? controller.defaultInputMapping)
        }
        overlay.isHidden = !Settings.features.swipeControls.isEnabled
        if overlay.isHidden { overlay.pauseSession() }
        controllerView.isButtonHapticFeedbackEnabled = Settings.isButtonHapticFeedbackEnabled
        controllerView.isThumbstickHapticFeedbackEnabled = Settings.isThumbstickHapticFeedbackEnabled
    }

    @objc private func showMenu()
    {
        guard !showingMenu, session.isActive else { return }
        showingMenu = true
        overlay.pauseSession()
        session.input.isEnabled = false
        let alert = UIAlertController(title: session.title, message: "Player 2", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: session.player.isMuted ? "Unmute Audio" : "Mute Audio", style: .default) { [weak self] _ in
            self?.session.player.isMuted.toggle()
            self?.closeMenu()
        })
        alert.addAction(UIAlertAction(title: "Leave Game", style: .destructive) { [weak self] _ in
            self?.session.end()
            self?.dismiss(animated: true)
        })
        alert.addAction(UIAlertAction(title: "Resume", style: .cancel) { [weak self] _ in self?.closeMenu() })
        alert.popoverPresentationController?.sourceView = menuButton
        alert.popoverPresentationController?.sourceRect = menuButton.bounds
        present(alert, animated: true)
    }

    private func closeMenu()
    {
        showingMenu = false
        session.input.isEnabled = session.state.phase == .playing
        if session.input.isEnabled { overlay.resumeSession() }
    }

    private func showDisconnected()
    {
        overlay.pauseSession()
        let show = { [weak self] in
            guard let self, self.view.window != nil else { return }
            let alert = UIAlertController(title: "Multiplayer Ended", message: self.session.errorMessage ?? "The session has ended.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Back to Settings", style: .default) { [weak self] _ in self?.dismiss(animated: true) })
            self.present(alert, animated: true)
        }
        if presentedViewController != nil { dismiss(animated: false, completion: show) }
        else { show() }
    }

    func disconnect()
    {
        session.player.onImage = nil
        session.input.onMenu = nil
        overlay?.pauseSession()
        connected.forEach { $0.removeReceiver(session.input) }
        session.end()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
