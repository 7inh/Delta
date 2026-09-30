import Foundation

// Foundation-only protocol and state models are also compiled by the standalone tests.
enum MultiplayerProtocolError: Error, LocalizedError
{
    case invalidPacket, incompatibleVersion, wrongSession, unexpectedMessage, connectionLost

    var errorDescription: String? {
        switch self
        {
        case .invalidPacket: return "The other device sent invalid multiplayer data."
        case .incompatibleVersion: return "Both devices must use a compatible version of DeltaSwipe."
        case .wrongSession, .unexpectedMessage: return "The multiplayer session is no longer available."
        case .connectionLost: return "The connection was lost. Keep both devices open on the same Wi-Fi network."
        }
    }
}

struct MultiplayerPacket
{
    enum Kind: UInt8
    {
        case hello = 1, welcome, ready, start, pause, resume, input, heartbeat, leave, video, audio, started, localROM, localState, localFrame, pairKey
    }

    static let version: UInt8 = 3
    static let headerSize = 44
    static let emptySession = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    static let maximumPayloadSize = 512 * 1024

    let kind: Kind
    let session: UUID
    let sequence: UInt64
    let timestamp: UInt64 // Host monotonic microseconds, shared by audio and video.
    let payload: Data

    func encoded() throws -> Data
    {
        guard payload.count <= Self.limit(for: kind) else { throw MultiplayerProtocolError.invalidPacket }
        var data = Data([0x44, 0x53, 0x4D, 0x50, Self.version, kind.rawValue, 0, 0])
        var uuid = session.uuid
        withUnsafeBytes(of: &uuid) { data.append(contentsOf: $0) }
        data.appendInteger(sequence)
        data.appendInteger(timestamp)
        data.appendInteger(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func limit(for kind: Kind) -> Int
    {
        switch kind
        {
        case .video, .localState: return maximumPayloadSize
        case .localROM, .pairKey: return 32
        case .localFrame: return 18
        case .audio: return 8820 // At most 100 ms of 44.1 kHz mono Int16 PCM.
        case .input: return 1
        case .hello, .welcome: return 4096
        default: return 0
        }
    }

    static func decodeHeader(_ data: Data) throws -> (Kind, UUID, UInt64, UInt64, Int)
    {
        guard data.count == headerSize, Array(data.prefix(4)) == [0x44, 0x53, 0x4D, 0x50],
              data[6] == 0, data[7] == 0 else { throw MultiplayerProtocolError.invalidPacket }
        guard data[4] == version else { throw MultiplayerProtocolError.incompatibleVersion }
        guard let kind = Kind(rawValue: data[5]) else { throw MultiplayerProtocolError.invalidPacket }
        let bytes = Array(data[8..<24])
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        let timestamp: UInt64 = data.integer(at: 32)
        guard timestamp <= UInt64(Int64.max) else { throw MultiplayerProtocolError.invalidPacket }
        let count = Int(data.integer(at: 40, as: UInt32.self))
        guard count <= limit(for: kind) else { throw MultiplayerProtocolError.invalidPacket }
        return (kind, uuid, data.integer(at: 24), timestamp, count)
    }
}

struct MultiplayerPacketDecoder
{
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [MultiplayerPacket]
    {
        // NWConnection delivers chunks <= 64 KB. Bound the partial-frame buffer before allocation.
        guard buffer.count + data.count <= MultiplayerPacket.maximumPayloadSize + 65536 + MultiplayerPacket.headerSize else {
            throw MultiplayerProtocolError.invalidPacket
        }
        buffer.append(data)
        var packets = [MultiplayerPacket]()
        while buffer.count >= MultiplayerPacket.headerSize
        {
            let header = Data(buffer.prefix(MultiplayerPacket.headerSize))
            let (kind, session, sequence, timestamp, length) = try MultiplayerPacket.decodeHeader(header)
            let total = MultiplayerPacket.headerSize + length
            guard buffer.count >= total else { break }
            let payload = Data(buffer[MultiplayerPacket.headerSize..<total])
            if kind == .localROM && payload.count != 32 { throw MultiplayerProtocolError.invalidPacket }
            if kind == .pairKey && payload.count != 32 { throw MultiplayerProtocolError.invalidPacket }
            if kind == .localFrame && payload.count != 18 { throw MultiplayerProtocolError.invalidPacket }
            if kind == .localState && payload.isEmpty { throw MultiplayerProtocolError.invalidPacket }
            if kind == .input && payload.count != 1 { throw MultiplayerProtocolError.invalidPacket }
            if kind == .audio && (payload.isEmpty || payload.count % 2 != 0) { throw MultiplayerProtocolError.invalidPacket }
            packets.append(MultiplayerPacket(kind: kind, session: session, sequence: sequence, timestamp: timestamp, payload: payload))
            buffer = Data(buffer.dropFirst(total))
        }
        return packets
    }
}

struct MultiplayerSequence
{
    private var last: UInt64 = 0

    mutating func accept(_ sequence: UInt64) -> Bool
    {
        guard sequence > last else { return false }
        last = sequence
        return true
    }
}

struct MultiplayerInputState
{
    private var sources = [String: UInt8]()
    var buttons: UInt8 { sources.values.reduce(0, |) }

    mutating func set(_ buttons: UInt8, for source: String)
    {
        sources[source] = buttons == 0 ? nil : buttons
    }

    mutating func reset() { sources.removeAll() }
}

struct MultiplayerSessionState
{
    enum Phase: String
    {
        case idle, hosting, browsing, connecting, ready, playing, paused, disconnected
    }

    private(set) var phase: Phase = .idle

    @discardableResult mutating func transition(to next: Phase) -> Bool
    {
        let allowed: Bool
        switch (phase, next)
        {
        case (_, .disconnected), (_, .idle): allowed = true
        case (.idle, .hosting), (.idle, .browsing), (.disconnected, .hosting), (.disconnected, .browsing),
             (.browsing, .connecting), (.hosting, .ready), (.connecting, .ready),
             (.ready, .playing), (.playing, .paused), (.paused, .playing): allowed = true
        default: allowed = false
        }
        guard allowed else { return false }
        phase = next
        return true
    }
}

extension Data
{
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T)
    {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    func integer<T: FixedWidthInteger>(at offset: Int, as type: T.Type = T.self) -> T
    {
        // No alignment assumptions about network buffers.
        self[offset..<(offset + MemoryLayout<T>.size)].reduce(T.zero) { ($0 << 8) | T($1) }
    }
}

// Host-authoritative frame order; a gap must never silently advance a guest differently.
struct MultiplayerFrame: Equatable
{
    let number: UInt64
    let player1: UInt8
    let player2: UInt8
    let checksum: UInt64

    var data: Data {
        var data = Data()
        data.appendInteger(number)
        data.append(player1)
        data.append(player2)
        data.appendInteger(checksum)
        return data
    }

    init(number: UInt64, player1: UInt8, player2: UInt8, checksum: UInt64) {
        self.number = number; self.player1 = player1; self.player2 = player2; self.checksum = checksum
    }

    init(data: Data) throws {
        guard data.count == 18 else { throw MultiplayerProtocolError.invalidPacket }
        self.init(number: data.integer(at: 0), player1: data[8], player2: data[9], checksum: data.integer(at: 10))
    }
}
