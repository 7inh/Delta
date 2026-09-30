import Foundation

var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String)
{
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(name)") }
}
func rejects(_ name: String, _ action: () throws -> Void)
{
    checks += 1
    do { try action(); failures += 1; print("FAIL: \(name)") }
    catch {}
}

let session = UUID()
let packet = MultiplayerPacket(kind: .input, session: session, sequence: 1, timestamp: 987654321, payload: Data([0x81]))
let bytes = try packet.encoded()
check(bytes.count == 45, "fixed-width frame")

// Every possible TCP split boundary, including splits inside the UUID and payload length.
for boundary in 0...bytes.count
{
    var decoder = MultiplayerPacketDecoder()
    let first = try decoder.append(Data(bytes.prefix(boundary)))
    let second = try decoder.append(Data(bytes.dropFirst(boundary)))
    let packets = first + second
    check(packets.count == 1, "split \(boundary) produces exactly one packet")
    check(packets.first?.session == session && packets.first?.timestamp == packet.timestamp && packets.first?.payload == packet.payload,
          "split \(boundary) preserves data")
}
var decoder = MultiplayerPacketDecoder()
let frames = try decoder.append(bytes + bytes + bytes)
check(frames.count == 3, "coalesced TCP packets")
var changed = bytes
changed[4] = 99
rejects("incompatible version") { var parser = MultiplayerPacketDecoder(); _ = try parser.append(changed) }
changed = bytes; changed[0] = 0
rejects("wrong magic") { var parser = MultiplayerPacketDecoder(); _ = try parser.append(changed) }
changed = bytes; changed[5] = 255
rejects("unknown message type") { var parser = MultiplayerPacketDecoder(); _ = try parser.append(changed) }
changed = bytes; changed[6] = 1
rejects("reserved header bits") { var parser = MultiplayerPacketDecoder(); _ = try parser.append(changed) }
changed = bytes; changed[40] = 127
rejects("oversized declared payload before buffering") { var parser = MultiplayerPacketDecoder(); _ = try parser.append(changed.prefix(44)) }
rejects("oversized video on send") {
    _ = try MultiplayerPacket(kind: .video, session: session, sequence: 1, timestamp: 0, payload: Data(count: 512 * 1024 + 1)).encoded()
}
rejects("invalid input length") {
    var parser = MultiplayerPacketDecoder()
    let empty = try MultiplayerPacket(kind: .input, session: session, sequence: 1, timestamp: 0, payload: Data()).encoded()
    _ = try parser.append(empty)
}
rejects("unaligned PCM samples") {
    var parser = MultiplayerPacketDecoder()
    _ = try parser.append(MultiplayerPacket(kind: .audio, session: session, sequence: 1, timestamp: 0, payload: Data([1])).encoded())
}
rejects("empty PCM samples") {
    var parser = MultiplayerPacketDecoder()
    _ = try parser.append(MultiplayerPacket(kind: .audio, session: session, sequence: 1, timestamp: 0, payload: Data()).encoded())
}
rejects("control message with unexpected payload") {
    _ = try MultiplayerPacket(kind: .pause, session: session, sequence: 1, timestamp: 0, payload: Data([1])).encoded()
}
rejects("bounded partial buffer") {
    var parser = MultiplayerPacketDecoder()
    _ = try parser.append(Data(count: 600 * 1024))
}
changed = bytes
for index in 32..<40 { changed[index] = 255 }
rejects("timestamp cannot overflow CoreMedia signed time") { var parser = MultiplayerPacketDecoder(); _ = try parser.append(changed) }
var sequence = MultiplayerSequence()
check(!sequence.accept(0), "zero sequence rejected")
check(sequence.accept(1), "first sequence")
check(!sequence.accept(1), "duplicate rejected")
check(sequence.accept(10), "new sequence accepted")
check(!sequence.accept(2), "stale sequence rejected")

var inputs = MultiplayerInputState()
inputs.set(1, for: "touch")
inputs.set(1, for: "controller")
inputs.set(0x80, for: "swipe")
check(inputs.buttons == 0x81, "independent sources aggregate")
inputs.set(0, for: "touch")
check(inputs.buttons == 0x81, "touch release preserves physical A")
inputs.set(0, for: "controller")
check(inputs.buttons == 0x80, "last source releases A")
inputs.reset()
check(inputs.buttons == 0, "disconnect releases every input")
inputs.set(0xFF, for: "all")
check(inputs.buttons == 0xFF, "all eight NES buttons supported")

var host = MultiplayerSessionState()
check(!host.transition(to: .playing), "cannot start before pairing")
check(host.transition(to: .hosting), "start host")
check(!host.transition(to: .browsing), "cannot browse while hosting")
check(host.transition(to: .ready), "host paired")
check(!host.transition(to: .ready), "duplicate ready rejected")
check(host.transition(to: .playing), "host starts game")
check(host.transition(to: .paused), "host pauses")
check(host.transition(to: .playing), "host resumes")
check(host.transition(to: .disconnected), "disconnect from play")
check(host.transition(to: .hosting), "manual rehost")
var guest = MultiplayerSessionState()
check(guest.transition(to: .browsing), "guest browses")
check(guest.transition(to: .connecting), "guest connects")
check(!guest.transition(to: .playing), "guest cannot play before ready")
check(guest.transition(to: .ready), "guest ready")
check(guest.transition(to: .playing), "guest starts")
check(guest.transition(to: .disconnected), "guest disconnects")
check(guest.transition(to: .browsing), "manual rejoin")

// Local-ROM matching mode framing.
let frame = MultiplayerFrame(number: 42, player1: 0x81, player2: 0x10, checksum: 0x1234_5678_9ABC_DEF0)
check(frame.data.count == 18, "frame payload is 18 bytes")
let roundtripFrame = try MultiplayerFrame(data: frame.data)
check(roundtripFrame == frame, "frame roundtrip preserves fields")
rejects("frame rejects a truncated payload") { _ = try MultiplayerFrame(data: frame.data.dropLast(1)) }
rejects("frame rejects an oversized payload") { _ = try MultiplayerFrame(data: frame.data + Data([0])) }
var frameParser = MultiplayerPacketDecoder()
let framePackets = try frameParser.append(
    try MultiplayerPacket(kind: .localFrame, session: session, sequence: 1, timestamp: 7, payload: frame.data).encoded())
let decodedFrame = try MultiplayerFrame(data: framePackets[0].payload)
check(framePackets.count == 1 && decodedFrame == frame, "localFrame decodes to its frame")
rejects("localFrame rejects the wrong length") {
    var parser = MultiplayerPacketDecoder()
    _ = try parser.append(try MultiplayerPacket(kind: .localFrame, session: session, sequence: 1, timestamp: 0, payload: Data(count: 17)).encoded())
}
rejects("localROM rejects a short digest") {
    var parser = MultiplayerPacketDecoder()
    _ = try parser.append(try MultiplayerPacket(kind: .localROM, session: session, sequence: 1, timestamp: 0, payload: Data(count: 31)).encoded())
}
rejects("localROM rejects a long digest") {
    var parser = MultiplayerPacketDecoder()
    _ = try parser.append(try MultiplayerPacket(kind: .localROM, session: session, sequence: 1, timestamp: 0, payload: Data(count: 33)).encoded())
}
var digestParser = MultiplayerPacketDecoder()
let digestPackets = try digestParser.append(
    try MultiplayerPacket(kind: .localROM, session: session, sequence: 1, timestamp: 0, payload: Data(count: 32)).encoded())
check(digestPackets.count == 1 && digestPackets[0].payload.count == 32, "localROM carries a 32-byte digest")
rejects("localState cannot be empty") {
    var parser = MultiplayerPacketDecoder()
    _ = try parser.append(try MultiplayerPacket(kind: .localState, session: session, sequence: 1, timestamp: 0, payload: Data()).encoded())
}
rejects("oversized localState on send") {
    _ = try MultiplayerPacket(kind: .localState, session: session, sequence: 1, timestamp: 0, payload: Data(count: 512 * 1024 + 1)).encoded()
}
var stateParser = MultiplayerPacketDecoder()
let statePackets = try stateParser.append(
    try MultiplayerPacket(kind: .localState, session: session, sequence: 1, timestamp: 9, payload: Data(count: 4096)).encoded())
check(statePackets.count == 1 && statePackets[0].payload.count == 4096, "localState carries a bounded state")
rejects("pairKey rejects the wrong length") {
    var parser = MultiplayerPacketDecoder()
    _ = try parser.append(try MultiplayerPacket(kind: .pairKey, session: session, sequence: 1, timestamp: 0, payload: Data(count: 31)).encoded())
}
var pairKeyParser = MultiplayerPacketDecoder()
let pairKeyPackets = try pairKeyParser.append(
    try MultiplayerPacket(kind: .pairKey, session: session, sequence: 1, timestamp: 0, payload: Data(count: 32)).encoded())
check(pairKeyPackets.count == 1 && pairKeyPackets[0].payload.count == 32, "pairKey carries a 32-byte return key")

print("\(checks - failures)/\(checks) multiplayer checks passed")
exit(failures == 0 ? 0 : 1)
