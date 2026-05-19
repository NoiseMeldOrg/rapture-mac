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

    // MARK: - pause/resume policy

    func testPausedBatchIsDeferredAndHoldsState() {
        let p = BatchProcessor.policy(
            paused: true,
            wasPausedLastBatch: false,
            isFirstNonemptyBatchSeen: true,
            batchSize: 5
        )
        XCTAssertTrue(p.deferred)
        XCTAssertFalse(p.isCatchup)
        // wasPausedLastBatch must flip true so the next active batch knows to re-evaluate catchup.
        XCTAssertTrue(p.nextWasPausedLastBatch)
        // isFirstNonemptyBatchSeen is held (we didn't actually process anything).
        XCTAssertTrue(p.nextIsFirstNonemptyBatchSeen)
    }

    func testResumeBatchAfterPauseClearsFirstSeenAndCanCatchup() {
        // App ran for a while (isFirstNonemptyBatchSeen=true), user paused, now resuming.
        let p = BatchProcessor.policy(
            paused: false,
            wasPausedLastBatch: true,
            isFirstNonemptyBatchSeen: true,
            batchSize: 5
        )
        XCTAssertFalse(p.deferred)
        XCTAssertTrue(p.isCatchup, "5-message resume batch should be a catch-up trigger")
        XCTAssertTrue(p.nextIsFirstNonemptyBatchSeen)
        XCTAssertFalse(p.nextWasPausedLastBatch)
    }

    func testResumeBatchOfTwoIsNotCatchup() {
        // Resume with only 2 missed messages stays under the threshold.
        let p = BatchProcessor.policy(
            paused: false,
            wasPausedLastBatch: true,
            isFirstNonemptyBatchSeen: true,
            batchSize: 2
        )
        XCTAssertFalse(p.deferred)
        XCTAssertFalse(p.isCatchup)
        XCTAssertFalse(p.nextWasPausedLastBatch)
    }

    func testNormalLiveBatchHonorsFirstSeen() {
        // Never paused; not the first batch; should never be catchup regardless of size.
        let p = BatchProcessor.policy(
            paused: false,
            wasPausedLastBatch: false,
            isFirstNonemptyBatchSeen: true,
            batchSize: 10
        )
        XCTAssertFalse(p.deferred)
        XCTAssertFalse(p.isCatchup)
    }

    func testFirstEverBatchOfFiveIsCatchup() {
        // Startup case: no prior history, no prior pause.
        let p = BatchProcessor.policy(
            paused: false,
            wasPausedLastBatch: false,
            isFirstNonemptyBatchSeen: false,
            batchSize: 5
        )
        XCTAssertFalse(p.deferred)
        XCTAssertTrue(p.isCatchup)
        XCTAssertTrue(p.nextIsFirstNonemptyBatchSeen)
    }

    func testPausedPersistsAcrossMultipleBatchesWithoutTouchingFirstSeen() {
        // Two consecutive paused batches: state stays paused, firstSeen unchanged.
        let p1 = BatchProcessor.policy(
            paused: true,
            wasPausedLastBatch: false,
            isFirstNonemptyBatchSeen: false,
            batchSize: 3
        )
        let p2 = BatchProcessor.policy(
            paused: true,
            wasPausedLastBatch: p1.nextWasPausedLastBatch,
            isFirstNonemptyBatchSeen: p1.nextIsFirstNonemptyBatchSeen,
            batchSize: 7
        )
        XCTAssertTrue(p1.deferred)
        XCTAssertTrue(p2.deferred)
        XCTAssertFalse(p2.nextIsFirstNonemptyBatchSeen)
    }
}
