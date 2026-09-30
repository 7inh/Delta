import Foundation

// Generates an NROM-128 NES ROM whose backdrop color depends on a frame loop
// counter and on Player 1's A button, so replays are visibly input-sensitive.
enum TestROM
{
    static func make() -> Data {
        var program = Data(count: 16384)
        let code: [UInt8] = [
            0x78,                   // SEI
            0xD8,                   // CLD
            0xA2, 0xFF,             // LDX #$FF
            0x9A,                   // TXS
            0xA9, 0x00,             // LDA #$00
            0x8D, 0x00, 0x20,       // STA $2000 (NMI off)
            0xA9, 0x1E,             // LDA #$1E
            0x8D, 0x01, 0x20,       // STA $2001 (rendering on)
            // loop:
            0xE6, 0x20,             // INC $20
            0xA9, 0x01,             // LDA #$01
            0x8D, 0x16, 0x40,       // STA $4016 (strobe)
            0xA9, 0x00,             // LDA #$00
            0x8D, 0x16, 0x40,       // STA $4016
            0xAD, 0x16, 0x40,       // LDA $4016 (Player 1 A)
            0x4A,                   // LSR A
            0xB0, 0x02,             // BCS +2 (A held skips the extra increment)
            0xE6, 0x20,             // INC $20
            0xA9, 0x3F,             // LDA #$3F
            0x8D, 0x06, 0x20,       // STA $2006
            0xA9, 0x00,             // LDA #$00
            0x8D, 0x06, 0x20,       // STA $2006 (PPUADDR $3F00)
            0xA5, 0x20,             // LDA $20
            0x8D, 0x07, 0x20,       // STA $2007 (backdrop = counter)
            0x4C, 0x0D, 0xC0        // JMP loop
        ]
        var rom = Data([0x4E, 0x45, 0x53, 0x1A, 0x01, 0x01, 0x00, 0x00])
        rom.append(Data(count: 8))
        program.replaceSubrange(0..<code.count, with: Data(code))
        for vector in [0x3FFA, 0x3FFC, 0x3FFE] { // NMI, RESET, IRQ -> $C000
            program[vector] = 0x00
            program[vector + 1] = 0xC0
        }
        rom.append(program)
        rom.append(Data(count: 8192)) // CHR
        return rom
    }
}
