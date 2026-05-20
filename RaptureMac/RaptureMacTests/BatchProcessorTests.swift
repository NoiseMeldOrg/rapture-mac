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

    func testNonFirstBatchOfNineIsNotCatchup() {
        // Once the first non-empty batch is processed, subsequent batches under the
        // backlog threshold are live mode — rapid-fire dictation of a few messages
        // should still produce per-message replies.
        XCTAssertFalse(BatchProcessor.isCatchup(batchSize: 9, isFirstNonemptyBatchSeen: true))
    }

    func testNonFirstBatchOfTenTriggersBacklogCatchup() {
        // Regression test for the v1.0.18 echo-cascade incident: backlog of >=10
        // events (e.g., from Mac sleep/wake or iCloud re-sync) MUST trigger catchup
        // mode regardless of first-batch-seen state, so replies are suppressed.
        XCTAssertTrue(BatchProcessor.isCatchup(batchSize: 10, isFirstNonemptyBatchSeen: true))
    }

    func testNonFirstBatchOfFiftyTriggersBacklogCatchup() {
        XCTAssertTrue(BatchProcessor.isCatchup(batchSize: 50, isFirstNonemptyBatchSeen: true))
    }

    func testCatchupThresholdValueIsThree() {
        // Sentinel to catch accidental threshold changes — PRD specifies > 3 for
        // first-batch catchup. Bumping this without updating the rationale could
        // silently change behavior.
        XCTAssertEqual(BatchProcessor.catchupThreshold, 3)
    }

    func testBacklogThresholdValueIsTen() {
        // Sentinel to catch accidental threshold changes for the v1.0.19 backlog
        // protection. Lowering this might cause normal rapid dictation to suppress
        // replies; raising this re-opens the cascade risk.
        XCTAssertEqual(BatchProcessor.backlogThreshold, 10)
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

    func testNormalLiveBatchUnderBacklogThresholdIsNotCatchup() {
        // Never paused; not the first batch; batch size under backlog threshold.
        // This is rapid-fire dictation in normal use, not a backlog.
        let p = BatchProcessor.policy(
            paused: false,
            wasPausedLastBatch: false,
            isFirstNonemptyBatchSeen: true,
            batchSize: 9
        )
        XCTAssertFalse(p.deferred)
        XCTAssertFalse(p.isCatchup)
    }

    func testLiveBatchAtBacklogThresholdTriggersCatchup() {
        // The v1.0.19 fix: any batch >=10 triggers catchup, even on non-first
        // batches. This prevents the v1.0.18 echo-cascade scenario where a
        // backlog of 600+ rows from chat.db was processed as if live.
        let p = BatchProcessor.policy(
            paused: false,
            wasPausedLastBatch: false,
            isFirstNonemptyBatchSeen: true,
            batchSize: 10
        )
        XCTAssertFalse(p.deferred)
        XCTAssertTrue(p.isCatchup)
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

    // MARK: - GUID dedup (iCloud multi-device delivery duplicate suppression)

    func testDedupFirstSightOfGuidIsNotDuplicate() {
        let r = BatchProcessor.dedupCheck(guid: "guid-1", recent: [], capacity: 100)
        XCTAssertFalse(r.isDuplicate)
        XCTAssertEqual(r.updatedRecent, ["guid-1"])
    }

    func testDedupSecondSightOfGuidIsDuplicate() {
        let r = BatchProcessor.dedupCheck(guid: "guid-1", recent: ["guid-1"], capacity: 100)
        XCTAssertTrue(r.isDuplicate)
        // When duplicate, buffer is unchanged (no re-append).
        XCTAssertEqual(r.updatedRecent, ["guid-1"])
    }

    func testDedupEvictsOldestWhenCapacityExceeded() {
        let recent = ["g1", "g2", "g3"]
        let r = BatchProcessor.dedupCheck(guid: "g4", recent: recent, capacity: 3)
        XCTAssertFalse(r.isDuplicate)
        XCTAssertEqual(r.updatedRecent, ["g2", "g3", "g4"])
    }

    func testDedupKeepsCapacityWhenAtLimit() {
        // Boundary: 100 entries, adding one new one keeps 100, oldest evicted.
        let recent = (1...100).map { "g\($0)" }
        let r = BatchProcessor.dedupCheck(guid: "g101", recent: recent, capacity: 100)
        XCTAssertFalse(r.isDuplicate)
        XCTAssertEqual(r.updatedRecent.count, 100)
        XCTAssertEqual(r.updatedRecent.first, "g2")  // g1 evicted
        XCTAssertEqual(r.updatedRecent.last, "g101")
    }

    func testDedupEmptyGuidIsNeverDuplicate() {
        // Defensive: missing guid from chat.db is normalized to empty string; we don't
        // want empty-vs-empty to collapse unrelated messages into one another.
        let r1 = BatchProcessor.dedupCheck(guid: "", recent: [], capacity: 100)
        XCTAssertFalse(r1.isDuplicate)
        XCTAssertEqual(r1.updatedRecent, [], "Empty guid should not be tracked")

        let r2 = BatchProcessor.dedupCheck(guid: "", recent: [""], capacity: 100)
        XCTAssertFalse(r2.isDuplicate, "Empty-vs-empty must NOT dedup")
    }

    func testDedupCapacityValueIsOneHundred() {
        XCTAssertEqual(BatchProcessor.recentGuidCapacity, 100)
    }

    // MARK: - pause persists across batches

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
