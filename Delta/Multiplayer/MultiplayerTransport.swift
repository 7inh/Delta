import Foundation
import Network
import Security
import CryptoKit

struct NearbyGame: Identifiable
{
    let id: NWEndpoint
    let title: String
    var hostID: UUID? = nil
    var rememberedKey: Data? { hostID.flatMap { MultiplayerPairing.rememberedKey(forHostID: $0.uuidString) } }
    // Endpoint of the host's rejoin service; nil when the host did not advertise one
    // or the guest has no remembered key for it.
    var rejoinID: NWEndpoint?
}

// Persistent, per-install identity and pairing memory so a guest can rejoin a known
// host without re-entering the pairing code. The return key is issued by the host over
// the already-authenticated session and presented as the TLS-PSK identity on rejoin.
// Bonjour TXT records correlate both services by host identity, even when hosts play
// the same game. The authenticated welcome must confirm that advertised identity.
struct RememberedHost: Identifiable
{
    let hostID: String
    let name: String
    var id: String { hostID }
}

enum MultiplayerPairing
{
    static let sessionIdentity = "DeltaSwipe-v1"
    static let returnIdentity = "DeltaSwipe-return-v1"
    private static let deviceKey = "multiplayer.deviceID"
    private static let secretKey = "multiplayer.hostSecret"
    private static let rememberedPrefix = "multiplayer.remembered."

    static var deviceID: UUID {
        if let id = UserDefaults.standard.string(forKey: deviceKey).flatMap(UUID.init(uuidString:)) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: deviceKey)
        return id
    }

    static var hostSecret: Data {
        if let secret = UserDefaults.standard.data(forKey: secretKey) { return secret }
        var secret = Data(count: 32)
        _ = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        UserDefaults.standard.set(secret, forKey: secretKey)
        return secret
    }

    static var returnKey: Data { Data(SHA256.hash(data: Data("DeltaSwipe Nearby return v1:".utf8) + hostSecret)) }

    static func sessionKey(code: String) -> Data { Data(SHA256.hash(data: Data(("DeltaSwipe Nearby v1:" + code).utf8))) }

    static func remember(hostID: String, name: String, key: Data)
    {
        UserDefaults.standard.set([name, key.base64EncodedString(), String(Date().timeIntervalSince1970)],
                                   forKey: rememberedPrefix + hostID)
    }

    static func rememberedKey(forHostID hostID: String) -> Data?
    {
        guard let entry = UserDefaults.standard.stringArray(forKey: rememberedPrefix + hostID),
              entry.count == 3, let key = Data(base64Encoded: entry[1]), key.count == 32 else { return nil }
        return key
    }

    static func rememberedHosts() -> [RememberedHost]
    {
        var hosts = [RememberedHost]()
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix(rememberedPrefix)
        {
            guard let entry = value as? [String], entry.count == 3, entry.first != nil else { continue }
            hosts.append(RememberedHost(hostID: String(key.dropFirst(rememberedPrefix.count)), name: entry[0]))
        }
        return hosts.sorted { $0.name < $1.name }
    }

    static func forget(hostID: String)
    {
        UserDefaults.standard.removeObject(forKey: rememberedPrefix + hostID)
    }


}

// All transport state and callbacks are confined to the main queue. Encoding happens elsewhere.
final class MultiplayerTransport
{
    static let serviceType = "_deltaswipe._tcp"
    // A second listener with its own single PSK so returning guests skip the pairing code.
    // One PSK per listener: registering several PSKs on a single listener makes wrong-key
    // handshakes stall for 15 s instead of failing fast.
    static let rejoinServiceType = "_deltaswipe-r._tcp"

    private(set) var romDigest: Data?
    var onGames: (([NearbyGame]) -> Void)?
    var onDiscoveryNotice: ((String?) -> Void)?
    var onReady: ((String) -> Void)?
    var onPacket: ((MultiplayerPacket) -> Void)?
    var onDisconnect: ((String) -> Void)?

    private struct Hello: Codable
    {
        let channel: String
        let client: UUID
        let token: UUID?
        let device: UUID
    }

    private struct Welcome: Codable
    {
        let title: String
        let token: UUID
        let romDigest: Data?
        let host: UUID
    }

    private final class Peer
    {
        let connection: NWConnection
        var decoder = MultiplayerPacketDecoder()
        var sequence = MultiplayerSequence()
        var outgoingSequence: UInt64 = 0
        var authenticated = false
        var pendingBytes = 0
        var lastReceived = ProcessInfo.processInfo.systemUptime
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private var listener: NWListener?
    private var rejoinListener: NWListener?
    private var browser: NWBrowser?
    private var rejoinBrowser: NWBrowser?
    private var control: Peer?
    private var media: Peer?
    private var pending = [ObjectIdentifier: Peer]()
    private var timer: Timer?
    private var host = false
    private var stopped = false
    private var session = MultiplayerPacket.emptySession
    private var client = UUID()
    private var token = UUID()
    private var code = ""
    private var title = ""
    private var endpoint: NWEndpoint?
    private var expectedHostID: UUID?
    // PSK used for this device's outgoing connections; the media connection must match.
    private var psk: (identity: String, key: Data) = (MultiplayerPairing.sessionIdentity, Data())
    private(set) var hostDeviceID = UUID()
    private(set) var rejoining = false

    func hostGame(title: String, code: String, romDigest: Data? = nil) throws
    {
        host = true
        self.romDigest = romDigest
        self.title = String(title.prefix(100))
        self.code = code
        session = UUID()
        let listener = try NWListener(using: Self.parameters(psks: [
            (MultiplayerPairing.sessionIdentity, MultiplayerPairing.sessionKey(code: code))
        ]))
        self.listener = listener
        let identity = MultiplayerPairing.deviceID.uuidString
        // A short ASCII instance name avoids Bonjour's 63-byte limit for Unicode titles.
        // Bound each TXT value to fit a DNS-SD string (255 bytes including its key).
        var displayTitle = self.title
        while displayTitle.utf8.count > 240 { displayTitle.removeLast() }
        let record = NWTXTRecord(["host": identity, "title": displayTitle])
        listener.service = NWListener.Service(name: identity, type: Self.serviceType, txtRecord: record)
        // Returning guests authenticate with the persistent return key instead of the code.
        let rejoinListener = try NWListener(using: Self.parameters(psks: [
            (MultiplayerPairing.returnIdentity, MultiplayerPairing.returnKey)
        ]))
        self.rejoinListener = rejoinListener
        rejoinListener.service = NWListener.Service(name: identity, type: Self.rejoinServiceType, txtRecord: record)
        configureListeners()
        listener.start(queue: .main)
        rejoinListener.start(queue: .main)
        startTimer()
    }

    private func configureListeners()
    {
        for current in [listener, rejoinListener].compactMap({ $0 })
        {
            current.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                switch state
                {
                case .failed(let error): self.fail(error.localizedDescription)
                case .waiting: self.onDiscoveryNotice?("Allow Local Network access in Settings and connect both devices to the same Wi-Fi network.")
                case .ready: self.onDiscoveryNotice?(nil)
                default: break
                }
            }
            current.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped, self.pending.count < 4 else { connection.cancel(); return }
                let peer = Peer(connection)
                self.pending[ObjectIdentifier(peer)] = peer
                self.configure(peer)
            }
        }
    }

    func browse()
    {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        self.browser = browser
        let rejoinBrowser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.rejoinServiceType, domain: nil), using: .tcp)
        self.rejoinBrowser = rejoinBrowser
        configureBrowsers()
        browser.start(queue: .main)
        rejoinBrowser.start(queue: .main)
    }

    private func configureBrowsers()
    {
        for current in [browser, rejoinBrowser].compactMap({ $0 })
        {
            current.browseResultsChangedHandler = { [weak self] _, _ in
                guard let self, !self.stopped, self.control == nil else { return }
                self.mergeGames()
            }
            current.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped, self.control == nil else { return }
                switch state
                {
                case .failed(let error):
                    self.fail("Nearby discovery is unavailable. \(error.localizedDescription)")
                case .waiting:
                    self.onDiscoveryNotice?("Allow Local Network access in Settings and connect both devices to the same Wi-Fi network.")
                case .ready:
                    self.onDiscoveryNotice?(nil)
                default: break
                }
            }
        }
        mergeGames()
    }

    // Merge the two service browsers into one row per host: the main endpoint joins with
    // the pairing code, the rejoin endpoint with the remembered key.
    private func mergeGames()
    {
        func identity(_ result: NWBrowser.Result) -> UUID? {
            guard case .bonjour(let record) = result.metadata, let value = record["host"] else { return nil }
            return UUID(uuidString: value)
        }
        let returning = rejoinBrowser?.browseResults ?? []
        var games = [NearbyGame]()
        for result in browser?.browseResults ?? []
        {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            let hostID = identity(result)
            var title = name
            if case .bonjour(let record) = result.metadata, let value = record["title"], !value.isEmpty {
                title = String(value.prefix(100))
            }
            let rejoin = hostID.flatMap { id in returning.first(where: { identity($0) == id })?.endpoint }
            games.append(NearbyGame(id: result.endpoint, title: title, hostID: hostID, rejoinID: rejoin))
        }
        games.sort { $0.title < $1.title }
        onGames?(games)
    }

    func join(_ game: NearbyGame, code: String)
    {
        rejoining = false
        connect(game, psk: (MultiplayerPairing.sessionIdentity, MultiplayerPairing.sessionKey(code: code)))
    }

    // Reconnect to a previously paired host without re-entering the pairing code.
    func rejoin(_ game: NearbyGame)
    {
        guard let key = game.rememberedKey, let endpoint = game.rejoinID else {
            fail("Unable to connect to this remembered host. Enter its pairing code again.")
            return
        }
        rejoining = true
        let target = NearbyGame(id: endpoint, title: game.title, hostID: game.hostID, rejoinID: endpoint)
        connect(target, psk: (MultiplayerPairing.returnIdentity, key))
    }

    private func connect(_ game: NearbyGame, psk: (identity: String, key: Data))
    {
        guard !stopped, control == nil else { return }
        browser?.cancel()
        rejoinBrowser?.cancel()
        browser = nil
        rejoinBrowser = nil
        expectedHostID = game.hostID
        self.psk = psk
        endpoint = game.id
        let peer = Peer(NWConnection(to: game.id, using: Self.parameters(psks: [psk])))
        control = peer
        configure(peer)
        startTimer()
    }

    func send(_ kind: MultiplayerPacket.Kind, payload: Data = Data(), timestamp: UInt64 = 0)
    {
        guard let control, control.authenticated else { return }
        send(kind, payload: payload, timestamp: timestamp, to: control)
    }

    func sendMedia(_ kind: MultiplayerPacket.Kind, payload: Data, timestamp: UInt64, completion: @escaping (Bool) -> Void)
    {
        guard let media, media.authenticated, !stopped else { completion(false); return }
        send(kind, payload: payload, timestamp: timestamp, to: media, completion: completion)
    }

    func stop()
    {
        stopped = true
        timer?.invalidate()
        timer = nil
        browser?.cancel()
        rejoinBrowser?.cancel()
        listener?.cancel()
        rejoinListener?.cancel()
        control?.connection.cancel()
        media?.connection.cancel()
        pending.values.forEach { $0.connection.cancel() }
        pending.removeAll()
        control = nil
        media = nil
    }

    private static func parameters(psks: [(identity: String, key: Data)]) -> NWParameters
    {
        let tls = NWProtocolTLS.Options()
        for psk in psks
        {
            let identity = Data(psk.identity.utf8)
            psk.key.withUnsafeBytes { keyBytes in
                identity.withUnsafeBytes { identityBytes in
                    sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                        DispatchData(bytes: keyBytes) as dispatch_data_t, DispatchData(bytes: identityBytes) as dispatch_data_t)
                }
            }
        }
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0x00A8)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    private func configure(_ peer: Peer)
    {
        peer.connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer, !self.stopped else { return }
            switch state
            {
            case .ready:
                if !self.host
                {
                    let hello = Hello(channel: peer === self.control ? "control" : "media", client: self.client,
                                      token: peer === self.media ? self.token : nil, device: MultiplayerPairing.deviceID)
                    self.send(.hello, payload: (try? JSONEncoder().encode(hello)) ?? Data(), to: peer)
                }
                self.receive(peer)
            case .failed, .cancelled:
                if peer === self.control || peer === self.media { self.fail("Unable to connect. Check the pairing code and Wi-Fi connection, and make sure both devices run the same app build.") }
                else { self.pending.removeValue(forKey: ObjectIdentifier(peer)); peer.connection.cancel() }
            default: break
            }
        }
        peer.connection.start(queue: .main)
    }

    private func receive(_ peer: Peer)
    {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak peer] data, _, complete, error in
            guard let self, let peer, !self.stopped else { return }
            do
            {
                if let data
                {
                    for packet in try peer.decoder.append(data)
                    {
                        guard peer.sequence.accept(packet.sequence) else { throw MultiplayerProtocolError.invalidPacket }
                        try self.handle(packet, from: peer)
                        guard !self.stopped else { return }
                        peer.lastReceived = ProcessInfo.processInfo.systemUptime
                    }
                }
                if complete || error != nil { throw MultiplayerProtocolError.connectionLost }
                self.receive(peer)
            }
            catch
            {
                if peer === self.control || peer === self.media { self.fail(error.localizedDescription) }
                else { self.pending.removeValue(forKey: ObjectIdentifier(peer)); peer.connection.cancel() }
            }
        }
    }

    private func handle(_ packet: MultiplayerPacket, from peer: Peer) throws
    {
        if !peer.authenticated
        {
            if host
            {
                guard packet.kind == .hello else { throw MultiplayerProtocolError.unexpectedMessage }
                let hello = try JSONDecoder().decode(Hello.self, from: packet.payload)
                if hello.channel == "control", control == nil, packet.session == MultiplayerPacket.emptySession, hello.token == nil
                {
                    control = peer
                    client = hello.client
                }
                else if hello.channel == "media", control != nil, media == nil,
                        hello.client == client, hello.token == token, packet.session == session
                {
                    media = peer
                }
                else { throw MultiplayerProtocolError.wrongSession }
                pending.removeValue(forKey: ObjectIdentifier(peer))
                peer.authenticated = true
                let welcome = Welcome(title: title, token: token, romDigest: romDigest, host: MultiplayerPairing.deviceID)
                send(.welcome, payload: try JSONEncoder().encode(welcome), to: peer)
            }
            else
            {
                guard packet.kind == .welcome, packet.session != MultiplayerPacket.emptySession else { throw MultiplayerProtocolError.unexpectedMessage }
                let welcome = try JSONDecoder().decode(Welcome.self, from: packet.payload)
                guard welcome.romDigest == nil || welcome.romDigest?.count == 32 else { throw MultiplayerProtocolError.invalidPacket }
                guard welcome.title.count <= 100 else { throw MultiplayerProtocolError.invalidPacket }
                if peer === control
                {
                    guard expectedHostID == nil || expectedHostID == welcome.host else { throw MultiplayerProtocolError.wrongSession }
                    session = packet.session
                    token = welcome.token
                    title = welcome.title
                    romDigest = welcome.romDigest
                    hostDeviceID = welcome.host
                    peer.authenticated = true
                    guard let endpoint else { throw MultiplayerProtocolError.wrongSession }
                    let media = Peer(NWConnection(to: endpoint, using: Self.parameters(psks: [psk])))
                    self.media = media
                    configure(media)
                }
                else
                {
                    guard packet.session == session, welcome.token == token, welcome.host == hostDeviceID,
                          welcome.romDigest == romDigest, welcome.title == title else { throw MultiplayerProtocolError.wrongSession }
                    peer.authenticated = true
                    onReady?(title)
                    send(.ready)
                }
            }
            return
        }

        guard packet.session == session else { throw MultiplayerProtocolError.wrongSession }
        if peer === media
        {
            guard !host, [.video, .audio, .localState, .localFrame].contains(packet.kind) else { throw MultiplayerProtocolError.unexpectedMessage }
        }
        else
        {
            let allowed: Set<MultiplayerPacket.Kind> = host ? [.ready, .started, .input, .heartbeat, .leave, .localROM] : [.start, .pause, .resume, .heartbeat, .leave, .pairKey]
            guard allowed.contains(packet.kind) else { throw MultiplayerProtocolError.unexpectedMessage }
            if packet.kind == .ready
            {
                guard media?.authenticated == true else { throw MultiplayerProtocolError.unexpectedMessage }
                onReady?(title)
                return
            }
        }
        if packet.kind == .leave { fail("The other player left the game."); return }
        onPacket?(packet)
    }

    private func send(_ kind: MultiplayerPacket.Kind, payload: Data = Data(), timestamp: UInt64 = 0, to peer: Peer, completion: ((Bool) -> Void)? = nil)
    {
        guard !stopped else { completion?(false); return }
        peer.outgoingSequence += 1
        do
        {
            let data = try MultiplayerPacket(kind: kind, session: session, sequence: peer.outgoingSequence, timestamp: timestamp, payload: payload).encoded()
            // Apply one consistent budget, including headers, to every channel. A valid
            // large video packet or a state followed by frame data must fit the media budget.
            let budget = peer === media ? 1024 * 1024 : 64 * 1024
            guard peer.pendingBytes + data.count <= budget else { throw MultiplayerProtocolError.connectionLost }
            peer.pendingBytes += data.count
            peer.connection.send(content: data, completion: .contentProcessed { [weak self, weak peer] error in
                peer?.pendingBytes -= data.count
                completion?(error == nil)
                guard let self, let peer, !self.stopped else { return }
                if let error, peer === self.control || peer === self.media { self.fail(error.localizedDescription) }
            })
        }
        catch { completion?(false); fail(error.localizedDescription) }
    }

    private func startTimer()
    {
        timer?.invalidate()
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, !self.stopped else { return }
            let now = ProcessInfo.processInfo.systemUptime
            for peer in Array(self.pending.values) where now - peer.lastReceived > 10
            {
                self.pending.removeValue(forKey: ObjectIdentifier(peer))
                peer.connection.cancel()
            }
            if let control = self.control
            {
                // TLS-PSK with a wrong key stalls silently instead of failing, so an
                // unauthenticated connection must time out quickly (a wrong pairing code
                // then surfaces within seconds rather than hanging).
                let timeout: TimeInterval = control.authenticated ? 10 : 6
                if now - control.lastReceived > timeout { self.fail(MultiplayerProtocolError.connectionLost.localizedDescription); return }
                if let media = self.media, !media.authenticated, now - media.lastReceived > 15
                {
                    self.fail("The media connection could not be established.")
                    return
                }
                self.send(.heartbeat)
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func fail(_ message: String)
    {
        guard !stopped else { return }
        stop()
        onDisconnect?(message)
    }

    deinit { timer?.invalidate() }
}
