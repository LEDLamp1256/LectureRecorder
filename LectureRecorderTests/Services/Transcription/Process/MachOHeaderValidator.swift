import Foundation

enum MachOHeaderValidationError: Error, Equatable {
    case incompleteHeader
    case notThinLittleEndian64
    case wrongCPU
    case wrongCPUSubtype
    case wrongFileType
    case impossibleLoadCommandBounds
}

enum MachOHeaderValidator {
    private static let headerSize = 32
    private static let mhMagic64: UInt32 = 0xfeedfacf
    private static let cpuTypeArm64: UInt32 = 0x0100000c
    private static let cpuSubtypeArm64All: UInt32 = 0
    private static let mhExecute: UInt32 = 2
    private static let loadCommandHeaderSize: UInt64 = 8
    private static let loadCommandAlignment: UInt64 = 8

    static func validateThinArm64Executable(_ data: Data) throws {
        guard data.count >= headerSize else {
            throw MachOHeaderValidationError.incompleteHeader
        }

        let magic = readUInt32LE(data, offset: 0)
        guard magic == mhMagic64 else {
            // This rejects 32-bit, swapped-endian, and all fat magic values.
            throw MachOHeaderValidationError.notThinLittleEndian64
        }
        guard readUInt32LE(data, offset: 4) == cpuTypeArm64 else {
            throw MachOHeaderValidationError.wrongCPU
        }
        guard readUInt32LE(data, offset: 8) == cpuSubtypeArm64All else {
            throw MachOHeaderValidationError.wrongCPUSubtype
        }
        guard readUInt32LE(data, offset: 12) == mhExecute else {
            throw MachOHeaderValidationError.wrongFileType
        }

        let commandCount = UInt64(readUInt32LE(data, offset: 16))
        let commandBytes = UInt64(readUInt32LE(data, offset: 20))
        guard (commandCount == 0) == (commandBytes == 0) else {
            throw MachOHeaderValidationError.impossibleLoadCommandBounds
        }

        let fileSize = UInt64(data.count)
        let regionStart = UInt64(headerSize)
        let (regionEnd, regionOverflow) = regionStart.addingReportingOverflow(commandBytes)
        guard !regionOverflow,
              regionEnd <= fileSize,
              commandCount <= commandBytes / loadCommandHeaderSize else {
            throw MachOHeaderValidationError.impossibleLoadCommandBounds
        }

        var commandStart = regionStart
        for _ in 0..<commandCount {
            let (headerEnd, headerOverflow) = commandStart.addingReportingOverflow(loadCommandHeaderSize)
            guard !headerOverflow, headerEnd <= regionEnd, headerEnd <= fileSize else {
                throw MachOHeaderValidationError.impossibleLoadCommandBounds
            }

            let commandSize = UInt64(readUInt32LE(data, offset: Int(commandStart + 4)))
            guard commandSize >= loadCommandHeaderSize,
                  commandSize.isMultiple(of: loadCommandAlignment) else {
                throw MachOHeaderValidationError.impossibleLoadCommandBounds
            }

            let (nextCommandStart, commandOverflow) = commandStart.addingReportingOverflow(commandSize)
            guard !commandOverflow,
                  nextCommandStart <= regionEnd,
                  nextCommandStart <= fileSize else {
                throw MachOHeaderValidationError.impossibleLoadCommandBounds
            }
            commandStart = nextCommandStart
        }

        guard commandStart == regionEnd else {
            throw MachOHeaderValidationError.impossibleLoadCommandBounds
        }
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
