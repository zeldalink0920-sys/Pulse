import XCTest
@testable import Pulse

final class RestaurantAddressTests: XCTestCase {
    func testRootAndFullEndpoint() throws {
        XCTAssertEqual(try RestaurantAddress.normalized(" https://order.lydialink.es/api/v1/status ").absoluteString, "https://order.lydialink.es")
        XCTAssertEqual(try RestaurantAddress.normalized("https://order.lydialink.es/").absoluteString, "https://order.lydialink.es")
    }
    func testRestaurantPathIsPreserved() throws {
        for endpoint in RestaurantEndpoint.allCases {
            XCTAssertEqual(try RestaurantAddress.normalized("https://order.lydialink.es/r/restaurant-2/api/v1/" + endpoint.rawValue).absoluteString, "https://order.lydialink.es/r/restaurant-2")
        }
        XCTAssertEqual(try RestaurantAddress.normalized("https://order.lydialink.es/r/restaurant-2/api/v1/").absoluteString, "https://order.lydialink.es/r/restaurant-2")
    }
    func testRejectsInvalidOrCredentialBearingAddresses() {
        for address in ["http://order.lydialink.es", "", "not a URL", "https://user:pass@order.lydialink.es", "https://order.lydialink.es?token=secret", "https://order.lydialink.es/#fragment"] {
            XCTAssertThrowsError(try RestaurantAddress.normalized(address))
        }
    }
}
