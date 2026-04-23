import XCTest
@testable import CrunchCore

final class DiskSpaceGuardTests: XCTestCase {
    func testDiskSpaceGuardAllowsSmallWriteIntoNestedDestination() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let destination = base
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("out.bin")

        XCTAssertNoThrow(try DiskSpaceGuard.assertSufficientSpace(
            at: destination,
            requiredBytes: 1
        ))
    }

    func testDiskSpaceGuardThrowsWhenRequirementExceedsAvailableCapacity() throws {
        let destination = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("out.bin")

        XCTAssertThrowsError(try DiskSpaceGuard.assertSufficientSpace(
            at: destination,
            requiredBytes: Int64.max
        )) { error in
            guard case CrunchError.insufficientDiskSpace(let needed, let available) = error else {
                return XCTFail("expected insufficientDiskSpace, got \(error)")
            }
            XCTAssertEqual(needed, Int64.max)
            XCTAssertGreaterThanOrEqual(available, 0)
        }
    }
}
