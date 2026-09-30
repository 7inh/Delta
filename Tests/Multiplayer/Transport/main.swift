import Foundation
import Network

// Exercises the real Bonjour + TLS transport on macOS without loading emulator frameworks.
// Phase 1: code pairing, media relay, extra-guest and wrong-code rejection, pairing-key issue.
// Phase 2: the guest leaves, the host re-hosts (same persisted secret), and a returning
// guest reconnects with the remembered key instead of the pairing code.
let host = MultiplayerTransport()
let guest = MultiplayerTransport()
let extra = MultiplayerTransport()
let incorrectCode = MultiplayerTransport()
let returner = MultiplayerTransport()
var rehoster: MultiplayerTransport?
var discovered: NearbyGame?
var joined = false
var guestLeaving = false
var checks = Set<String>()
var unexpectedFailure: String?
let expectedChecks: Set<String> = ["host ready", "guest ready", "start", "input", "video", "audio", "pause", "resume",
                                   "extra guest rejected", "wrong code rejected", "pairing key issued", "rejoin without code", "pairing identity", "large state burst"]

func fail(_ message: String)
{
    unexpectedFailure = message
    host.stop(); guest.stop(); extra.stop(); incorrectCode.stop(); returner.stop(); rehoster?.stop()
    print("FAIL: \(message)")
    exit(1)
}
func record(_ name: String)
{
    checks.insert(name)
    if checks == expectedChecks
    {
        host.stop(); guest.stop(); extra.stop(); incorrectCode.stop(); returner.stop(); rehoster?.stop()
        print("\(checks.count)/\(expectedChecks.count) real transport checks passed")
        exit(0)
    }
}
host.onDisconnect = { if !guestLeaving { fail("host: \($0)") } }
guest.onDisconnect = { fail("guest: \($0)") }
returner.onDisconnect = { fail("returner: \($0)") }
returner.onReady = { title in
    guard title == "A different game" else { fail("wrong returner title"); return }
    record("rejoin without code")
}
returner.onGames = { games in
    guard let game = games.first(where: { $0.title == "A different game" }), game.rejoinID != nil,
          game.rememberedKey != nil, rehoster != nil else { return }
    returner.rejoin(game)
}
host.onReady = { title in
    guard title == "DeltaSwipe Transport Test" else { fail("wrong host title"); return }
    record("host ready")
    // Issue the return key exactly like a real host does when a guest becomes ready.
    host.send(.pairKey, payload: MultiplayerPairing.returnKey)
    host.send(.start)
}
guest.onReady = { title in
    guard title == "DeltaSwipe Transport Test" else { fail("wrong guest title"); return }
    record("guest ready")
    if let discovered
    {
        extra.onDisconnect = { _ in record("extra guest rejected") }
        extra.onReady = { _ in fail("third player was admitted") }
        extra.join(discovered, code: "123456")
        incorrectCode.onDisconnect = { _ in record("wrong code rejected") }
        incorrectCode.onReady = { _ in fail("incorrect code was accepted") }
        incorrectCode.join(discovered, code: "654321")
    }
}
guest.onPacket = { packet in
    switch packet.kind
    {
    case .start: record("start"); guest.send(.input, payload: Data([0x81]))
    case .pause: record("pause")
    case .resume: record("resume")
    case .pairKey:
        guard packet.payload.count == 32, let discovered else { fail("bad pairing key"); return }
        MultiplayerPairing.remember(hostID: guest.hostDeviceID.uuidString, name: discovered.title, key: packet.payload)
        record("pairing key issued")
    case .video:
        guard packet.payload == Data(repeating: 0x42, count: 400_000), packet.timestamp == 123 else { fail("corrupt video"); return }
        record("video")
    case .localState:
        guard packet.payload == Data(repeating: 0x73, count: 500_000) else { fail("corrupt state"); return }
        record("large state burst")
    case .audio:
        guard packet.payload == Data(repeating: 0x21, count: 1470), packet.timestamp == 124 else { fail("corrupt audio"); return }
        record("audio")
    default: break
    }
}
host.onPacket = { packet in
    if packet.kind == .input
    {
        guard packet.payload == Data([0x81]) else { fail("corrupt input"); return }
        record("input")
        host.sendMedia(.video, payload: Data(repeating: 0x42, count: 400_000), timestamp: 123) { sent in
            if !sent { fail("video send failed") }
        }
        host.sendMedia(.audio, payload: Data(repeating: 0x21, count: 1470), timestamp: 124) { sent in
            if !sent { fail("audio send failed") }
        }
        host.sendMedia(.localState, payload: Data(repeating: 0x73, count: 500_000), timestamp: 125) { sent in
            if !sent { fail("state burst failed") }
        }
        host.send(.pause)
        host.send(.resume)
    }
}
guest.onGames = { games in
    guard !joined, let game = games.first(where: { $0.title == "DeltaSwipe Transport Test" }) else { return }
    joined = true
    discovered = game
    guest.join(game, code: "123456")
}
// Same title must never select another device's remembered secret.
let firstID = UUID(), secondID = UUID()
let testEndpoint = NWEndpoint.hostPort(host: "localhost", port: 1234)
MultiplayerPairing.remember(hostID: firstID.uuidString, name: "Same game", key: Data(repeating: 1, count: 32))
MultiplayerPairing.remember(hostID: secondID.uuidString, name: "Same game", key: Data(repeating: 2, count: 32))
let firstGame = NearbyGame(id: testEndpoint, title: "Same game", hostID: firstID)
let secondGame = NearbyGame(id: testEndpoint, title: "Same game", hostID: secondID)
guard firstGame.rememberedKey == Data(repeating: 1, count: 32),
      secondGame.rememberedKey == Data(repeating: 2, count: 32),
      NearbyGame(id: testEndpoint, title: "Same game").rememberedKey == nil else { fatalError("pairing identity collision") }
MultiplayerPairing.forget(hostID: firstID.uuidString)
MultiplayerPairing.forget(hostID: secondID.uuidString)
record("pairing identity")
try host.hostGame(title: "DeltaSwipe Transport Test", code: "123456")
guest.browse()

// Phase 2: tear the first session down, re-host from the same persisted secret, rejoin key-only.
DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
    guard checks.contains("pairing key issued") else { fail("no pairing key before teardown"); return }
    guestLeaving = true
    guest.stop()
    extra.stop()
}
DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
    let rehost = MultiplayerTransport()
    rehoster = rehost
    rehost.onDisconnect = { if !guestLeaving { fail("rehoster: \($0)") } }
    do { try rehost.hostGame(title: "A different game", code: "222333") }
    catch { fail("rehost failed: \(error)") }
    returner.browse()
}
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { fail("timeout; missing \(expectedChecks.subtracting(checks).sorted())") }
RunLoop.main.run()
