import XCTest
@testable import StoreCheckCore

final class DistanceCalculatorTests: XCTestCase {
    func testSameCoordinateDistanceIsZero() {
        let calc = DistanceCalculator()
        let d = calc.haversineMeters(lat1: 37.3349, lng1: -122.0090, lat2: 37.3349, lng2: -122.0090)
        XCTAssertLessThan(d, 0.1)
    }

    func testNearbyDistanceWithinExpectedRange() {
        let calc = DistanceCalculator()
        let d = calc.haversineMeters(lat1: 37.3349, lng1: -122.0090, lat2: 37.3355, lng2: -122.0100)
        XCTAssertGreaterThan(d, 90)
        XCTAssertLessThan(d, 130)
    }
}
