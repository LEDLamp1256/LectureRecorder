import Foundation
import XCTest

final class MachOHeaderValidatorTests: XCTestCase {
    func testValidCompleteThinArm64ExecutableIsAccepted() throws {
        XCTAssertNoThrow(try MachOHeaderValidator.validateThinArm64Executable(makeHeader()))
    }

    func testZeroCommandsWithZeroCommandBytesIsStructurallyConsistent() throws {
        XCTAssertNoThrow(try MachOHeaderValidator.validateThinArm64Executable(
            makeMachO(commandCount: 0, commandBytes: 0, commandRegion: Data())
        ))
    }

    func testTruncatedHeadersAreRejected() {
        for length in [0, 8, 31] {
            XCTAssertThrowsError(try MachOHeaderValidator.validateThinArm64Executable(Data(repeating: 0, count: length))) {
                XCTAssertEqual($0 as? MachOHeaderValidationError, .incompleteHeader)
            }
        }
    }

    func testSwappedEndianAndFatInputsAreRejected() {
        for magic: UInt32 in [0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca] {
            XCTAssertThrowsError(try MachOHeaderValidator.validateThinArm64Executable(makeHeader(magic: magic))) {
                XCTAssertEqual($0 as? MachOHeaderValidationError, .notThinLittleEndian64)
            }
        }
    }

    func testWrongCPUAndSubtypeAreRejected() {
        XCTAssertThrowsError(try MachOHeaderValidator.validateThinArm64Executable(makeHeader(cpuType: 7))) {
            XCTAssertEqual($0 as? MachOHeaderValidationError, .wrongCPU)
        }
        XCTAssertThrowsError(try MachOHeaderValidator.validateThinArm64Executable(makeHeader(cpuSubtype: 2))) {
            XCTAssertEqual($0 as? MachOHeaderValidationError, .wrongCPUSubtype)
        }
    }

    func testWrongFileTypeIsRejected() {
        XCTAssertThrowsError(try MachOHeaderValidator.validateThinArm64Executable(makeHeader(fileType: 1))) {
            XCTAssertEqual($0 as? MachOHeaderValidationError, .wrongFileType)
        }
    }

    func testLoadCommandsMustFitAndEachHaveRoomForAHeader() {
        assertInvalid(makeMachO(commandCount: 1, commandBytes: 64, commandRegion: Self.makeLoadCommand()))
        assertInvalid(makeMachO(commandCount: 2, commandRegion: Self.makeLoadCommand()))
    }

    func testZeroAndUndersizedCommandSizesAreRejected() {
        assertInvalid(makeMachO(commandRegion: Self.makeLoadCommand(commandSize: 0)))
        assertInvalid(makeMachO(commandRegion: Self.makeLoadCommand(commandSize: 4)))
    }

    func testMisalignedCommandSizeIsRejected() {
        assertInvalid(makeMachO(commandBytes: 12, commandRegion: Self.makeLoadCommand(commandSize: 12, actualSize: 12)))
    }

    func testCommandOverrunIsRejected() {
        assertInvalid(makeMachO(commandBytes: 8, commandRegion: Self.makeLoadCommand(commandSize: 16)))
    }

    func testTruncatedCommandHeaderIsRejected() {
        assertInvalid(makeMachO(commandBytes: 4, commandRegion: Data(repeating: 0, count: 4)))
    }

    func testTooManyAndTooFewCommandsAreRejected() {
        assertInvalid(makeMachO(commandCount: 2, commandRegion: Self.makeLoadCommand()))
        assertInvalid(makeMachO(commandCount: 1, commandRegion: Self.makeLoadCommand() + Self.makeLoadCommand()))
    }

    func testOverlappingOrInconsistentCommandBoundariesAreRejected() {
        var overlapping = Self.makeLoadCommand(commandSize: 16, actualSize: 16)
        overlapping.replaceSubrange(8..<16, with: Self.makeLoadCommand())
        assertInvalid(makeMachO(commandCount: 2, commandBytes: UInt32(overlapping.count), commandRegion: overlapping))
    }

    func testTrailingUnclaimedCommandBytesAreRejected() {
        assertInvalid(makeMachO(commandCount: 1, commandRegion: Self.makeLoadCommand() + Data(repeating: 0, count: 8)))
    }

    func testCommandCountAndByteCountMustBothBeZeroOrBothNonzero() {
        assertInvalid(makeMachO(commandCount: 0, commandRegion: Data(repeating: 0, count: 8)))
        assertInvalid(makeMachO(commandCount: 1, commandBytes: 0, commandRegion: Data()))
    }

    func testMaximumDeclaredRegionThatCannotFitInFileIsRejected() {
        assertInvalid(makeMachO(commandCount: UInt32.max, commandBytes: UInt32.max, commandRegion: Data()))
    }

    private func makeHeader(
        magic: UInt32 = 0xfeedfacf,
        cpuType: UInt32 = 0x0100000c,
        cpuSubtype: UInt32 = 0,
        fileType: UInt32 = 2
    ) -> Data {
        makeMachO(
            magic: magic,
            cpuType: cpuType,
            cpuSubtype: cpuSubtype,
            fileType: fileType
        )
    }

    private func assertInvalid(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try MachOHeaderValidator.validateThinArm64Executable(data), file: file, line: line) {
            XCTAssertEqual($0 as? MachOHeaderValidationError, .impossibleLoadCommandBounds, file: file, line: line)
        }
    }

    private func makeMachO(
        magic: UInt32 = 0xfeedfacf,
        cpuType: UInt32 = 0x0100000c,
        cpuSubtype: UInt32 = 0,
        fileType: UInt32 = 2,
        commandCount: UInt32 = 1,
        commandBytes: UInt32? = nil,
        commandRegion: Data = makeLoadCommand()
    ) -> Data {
        var data = Data()
        Self.appendUInt32LE(magic, to: &data)
        Self.appendUInt32LE(cpuType, to: &data)
        Self.appendUInt32LE(cpuSubtype, to: &data)
        Self.appendUInt32LE(fileType, to: &data)
        Self.appendUInt32LE(commandCount, to: &data)
        Self.appendUInt32LE(commandBytes ?? UInt32(commandRegion.count), to: &data)
        Self.appendUInt32LE(0, to: &data)
        Self.appendUInt32LE(0, to: &data)
        data.append(commandRegion)
        return data
    }

    /// A structurally valid LC_UUID: eight-byte load-command header plus its
    /// sixteen-byte UUID payload, for a total cmdsize of 24 (8-byte aligned).
    private static func makeLoadCommand(
        command: UInt32 = 0x1b,
        commandSize: UInt32 = 24,
        actualSize: Int = 24
    ) -> Data {
        var data = Data()
        appendUInt32LE(command, to: &data)
        appendUInt32LE(commandSize, to: &data)
        if actualSize > data.count {
            data.append(Data(repeating: 0, count: actualSize - data.count))
        } else if actualSize < data.count {
            data = data.prefix(actualSize)
        }
        return data
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}
