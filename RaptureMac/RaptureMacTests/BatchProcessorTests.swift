import XCTest
@testable import RaptureMac

final class BatchProcessorTests: XCTestCase {

    func testFirstBatchOfOneIsNotCatchup() {
        XCTAssertFalse(BatchProcessor.isCatchup(batchSize: 1, isFirstNonemptyBatchSeen: false))
    }

    func testFirstBatchOfThreeIsNotCatchup() {
        XCTAssertFalse(BatchProcessor.isCatchup(batchSize: 3, isFirstNonemptyBatchSeen: false))
    }

    func testFirstBatchOfFourIsCatchup() {
        XCTAssertTrue(BatchProcessor.isCatchup(batchSize: 4, isFirstNonemptyBatchSeen: false))
    }

    func testFirstBatchOfFiveIsCatchup() {
        XCTAssertTrue(BatchProcessor.isCatchup(batchSize: 5, isFirstNonemptyBatchSeen: false))
    }

    func testNonFirstBatchOfTenIsNotCatchup() {
        // Once the first non-empty batch is processed, subsequent batches of any size
        // are live mode — rapid-fire dictation is not catch-up.
        XCTAssertFalse(BatchProcessor.isCatchup(batchSize: 10, isFirstNonemptyBatchSeen: true))
    }

    func testThresholdValueIsThree() {
        // Sentinel to catch accidental threshold changes — PRD specifies > 3.
        XCTAssertEqual(BatchProcessor.catchupThreshold, 3)
    }
}
