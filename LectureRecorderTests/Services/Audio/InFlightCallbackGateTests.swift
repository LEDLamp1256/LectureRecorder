//
//  InFlightCallbackGateTests.swift
//  LectureRecorder
//
//  Created by Dylan Lee on 9/7/26.
//


import XCTest
@testable import LectureRecorder

final class InFlightCallbackGateTests: XCTestCase {
    func testRegisteredCallbackBlocksDrainUntilLeave() async {
        let gate = InFlightCallbackGate()
        gate.open()
        XCTAssertTrue(gate.tryEnter())
        gate.close()

        let drainCompletedTooEarly = XCTestExpectation(
            description: "drain completed too early"
        )
        drainCompletedTooEarly.isInverted = true

        let drainTask = Task {
            await gate.drain()
            drainCompletedTooEarly.fulfill()
        }

        await fulfillment(
            of: [drainCompletedTooEarly],
            timeout: 0.2
        )

        gate.leave()
        await drainTask.value
    }

    func testLeavingFinalCallbackReleasesDrain() async {
        let gate = InFlightCallbackGate()
        gate.open()
        XCTAssertTrue(gate.tryEnter())
        XCTAssertTrue(gate.tryEnter())
        gate.close()

        let drainCompletedTooEarly = XCTestExpectation(
            description: "drain completed too early"
        )
        drainCompletedTooEarly.isInverted = true

        let drainTask = Task {
            await gate.drain()
            drainCompletedTooEarly.fulfill()
        }

        gate.leave()

        await fulfillment(
            of: [drainCompletedTooEarly],
            timeout: 0.2
        )

        gate.leave()
        await drainTask.value
    }

    func testTryEnterAfterCloseAlwaysFails() {
        let gate = InFlightCallbackGate()
        gate.open()
        gate.close()

        for _ in 0..<50 {
            XCTAssertFalse(gate.tryEnter())
        }
    }

    func testMultipleConcurrentCallbacksAllDrained() async {
        let gate = InFlightCallbackGate()
        gate.open()

        let admittedCount = 20

        for _ in 0..<admittedCount {
            XCTAssertTrue(gate.tryEnter())
        }

        gate.close()

        let drainCompletedTooEarly = XCTestExpectation(
            description: "drain completed too early"
        )
        drainCompletedTooEarly.isInverted = true

        let drainTask = Task {
            await gate.drain()
            drainCompletedTooEarly.fulfill()
        }

        await fulfillment(
            of: [drainCompletedTooEarly],
            timeout: 0.2
        )

        for _ in 0..<admittedCount {
            gate.leave()
        }

        await drainTask.value
    }

    func testConcurrentTryEnterCloseRaceNeverLeavesUncountedAdmission() async {
        for _ in 0..<200 {
            let gate = InFlightCallbackGate()
            gate.open()

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        if gate.tryEnter() {
                            await Task.yield()
                            gate.leave()
                        }
                    }
                }

                group.addTask {
                    gate.close()
                }

                await group.waitForAll()
            }

            await gate.drain()
        }
    }

    func testFreshGatePerCycleNeverTripsThePrecondition() async {
        for _ in 0..<10 {
            let gate = InFlightCallbackGate()
            gate.open()
            XCTAssertTrue(gate.tryEnter())
            gate.leave()
            gate.close()
            await gate.drain()
        }
    }
}
