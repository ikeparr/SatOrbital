import Foundation
import XCTest
import simd
@testable import OrbitMath

final class TrackingCalculatorTests: XCTestCase {
    private func fixture() throws -> ([SatelliteTarget: CachedOrbit], Date) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "large-catalog", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let seeds = try decoder.decode([CachedOrbit].self, from: Data(contentsOf: url))
        return (Dictionary(uniqueKeysWithValues: seeds.map { (SatelliteTarget(rawValue: $0.elements.catalogID)!, $0) }), seeds.map(\.fetchedAt).max()!)
    }

    func testCachedOverviewPathsPausedReuseAndFocusedAlignment() async throws {
        let (cached, date) = try fixture()
        let calculator = TrackingCalculator()
        let targets = Set(cached.keys)
        let first = await calculator.snapshot(cached, targets: targets, selected: nil, at: date, freshnessDate: date, live: true)
        XCTAssertEqual(first.count, 396)
        let second = await calculator.snapshot(cached, targets: targets, selected: nil, at: date.addingTimeInterval(1), freshnessDate: date, live: true)
        let work = await calculator.lastWork
        XCTAssertEqual(work.engines, 0)
        XCTAssertEqual(work.paths, 0)
        XCTAssertEqual(second[.iss]?.path, first[.iss]?.path)
        XCTAssertNotEqual(second[.iss]?.state.scenePosition, first[.iss]?.state.scenePosition)
        let pausedDate = date.addingTimeInterval(2)
        _ = await calculator.snapshot(cached, targets: targets, selected: nil, at: pausedDate, freshnessDate: date, live: false)
        _ = await calculator.snapshot(cached, targets: targets, selected: nil, at: pausedDate, freshnessDate: date.addingTimeInterval(10), live: false)
        let pausedWork = await calculator.lastWork
        XCTAssertEqual(pausedWork.states, 0)
        XCTAssertEqual(pausedWork.paths, 0)
        let focused = await calculator.snapshot(cached, targets: [.iss], selected: .iss, at: pausedDate, freshnessDate: date, live: false)
        XCTAssertEqual(focused[.iss]?.path.count, 181)
        XCTAssertEqual(focused[.iss]?.path.first, focused[.iss]?.state.scenePosition)
        let focusWork = await calculator.lastWork
        XCTAssertEqual(focusWork.states, 1)
        XCTAssertEqual(focusWork.paths, 1)
        _ = await calculator.snapshot(cached, targets: [.iss], selected: .iss, at: pausedDate, freshnessDate: date, live: false)
        let heldFocus = await calculator.lastWork
        XCTAssertEqual(heldFocus.states, 0)
    }

    func testHiddenTargetsNotPropagatedAndChangedElementsInvalidateCache() async throws {
        let (cached, date) = try fixture()
        let calculator = TrackingCalculator()
        let targets = Set(cached.keys.filter { !$0.isStarlink })
        _ = await calculator.snapshot(cached, targets: targets, selected: nil, at: date, freshnessDate: date, live: true)
        let work = await calculator.lastWork
        XCTAssertEqual(work.engines, 187)
        XCTAssertEqual(work.states, 374)
        var changed = cached
        var record = try XCTUnwrap(changed[.iss])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record.elements)) as? [String: Any])
        object["MEAN_ANOMALY"] = 150.0
        let elements = try JSONDecoder().decode(OrbitalElements.self, from: JSONSerialization.data(withJSONObject: object))
        record = CachedOrbit(elements: elements, fetchedAt: date, isBundled: false)
        changed[.iss] = record
        let updated = await calculator.snapshot(changed, targets: [.iss], selected: .iss, at: date, freshnessDate: date, live: false)
        let changedWork = await calculator.lastWork
        XCTAssertEqual(changedWork.engines, 1)
        XCTAssertEqual(changedWork.paths, 1)
        XCTAssertEqual(updated[.iss]?.path.first, updated[.iss]?.state.scenePosition)
        let expired = await calculator.snapshot(changed, targets: targets, selected: nil, at: date, freshnessDate: date.addingTimeInterval(9 * 86400), live: false)
        XCTAssertTrue(expired.isEmpty)
    }

    func testCatalogCalculationBenchmark() async throws {
        let (cached, date) = try fixture()
        let ticks = 20
        let start = ContinuousClock.now
        for tick in 0..<ticks {
            _ = TrackingFrame.snapshot(cached, at: date.addingTimeInterval(Double(tick)), freshnessDate: date, live: true)
        }
        let original = start.duration(to: .now)
        let calculator = TrackingCalculator()
        let optimizedStart = ContinuousClock.now
        for tick in 0..<ticks {
            _ = await calculator.snapshot(cached, targets: Set(cached.keys), selected: nil,
                                          at: date.addingTimeInterval(Double(tick)), freshnessDate: date, live: true)
        }
        let optimized = optimizedStart.duration(to: .now)
        print("396-object model benchmark, 20 ticks: full snapshots \(original); cached snapshots \(optimized)")
        // Timing is reported, not asserted; correctness/work-count tests are deterministic.
    }
}


extension TrackingCalculatorTests {
    func testInertialPathCacheAndMarkerRemainAlignedAcrossAcceleratedTicks() async throws {
        let (cached, date) = try fixture()
        let calculator = TrackingCalculator()
        let start = await calculator.snapshot(cached, targets: [.iss], selected: .iss, at: date,
                                               freshnessDate: date, live: true, animationDate: date, playbackRate: 60)
        let original = try XCTUnwrap(start[.iss])
        let firstPoint = OrbitViewCoordinates.rotate(try XCTUnwrap(original.path.first), by: 0)
        XCTAssertLessThan(simd_distance(firstPoint, original.spacePosition(at: date, reference: date)), 0.000001)
        for tick in 1...4 {
            let frames = await calculator.snapshot(cached, targets: [.iss], selected: .iss,
                                                   at: date.addingTimeInterval(Double(tick) * 60), freshnessDate: date,
                                                   live: true, animationDate: date.addingTimeInterval(Double(tick)), playbackRate: 60)
            let frame = try XCTUnwrap(frames[.iss])
            XCTAssertEqual(frame.pathDate, original.pathDate)
            XCTAssertEqual(frame.path, original.path)
            let work = await calculator.lastWork
            XCTAssertEqual(work.paths, 0)
            let fixed = OrbitViewCoordinates.rotate(frame.spacePosition(at: frame.animationDate!, reference: date),
                                                   by: -OrbitViewCoordinates.angle(at: frame.state.date, reference: date))
            XCTAssertLessThan(simd_distance(fixed, frame.state.scenePosition), 0.000001)
            let normal = simd_normalize(simd_cross(original.state.temePosition, original.state.temeVelocity))
            let p = frame.state.temePosition
            // Natural orbital-plane drift over four minutes is tiny, rather than Earth's large rotation.
            XCTAssertLessThan(abs(simd_dot(p, normal)), 10)
        }
        _ = await calculator.snapshot(cached, targets: [.iss], selected: .iss, at: date.addingTimeInterval(300), freshnessDate: date, live: false)
        let renewed = await calculator.lastWork
        XCTAssertEqual(renewed.paths, 1)
    }
}
