import XCTest

@testable import Shared

final class FailureLogTests: XCTestCase {
    private enum SampleError: Error {
        case rejected(token: String)
    }

    func testSummaryOmitsAssociatedValuesAndDescription() {
        let error = SampleError.rejected(token: "secret-token")

        let summary = FailureLog.summary(of: error)

        XCTAssertFalse(summary.contains("secret-token"))
        XCTAssertTrue(String(describing: error).contains("secret-token"))
    }

    func testSummaryIdentifiesSystemErrors() {
        XCTAssertEqual(FailureLog.summary(of: URLError(.timedOut)), "NSURLErrorDomain#-1001")
    }

    func testSummaryOmitsURLFromSystemErrorDetails() {
        let url = URL(string: "https://project.example.test/rest/v1/polls?id=eq.secret-id")!
        let error = URLError(.badServerResponse, userInfo: [NSURLErrorFailingURLErrorKey: url])

        XCTAssertFalse(FailureLog.summary(of: error).contains("secret-id"))
    }
}
