#if DEBUG && canImport(XCTest)
import XCTest
@testable import DebtScope

final class PurchaseConversionDiagnosticsTests: XCTestCase {
    func testPaywallImpressionsIncrementTotalAndSourceCounts() {
        var diagnostics = PurchaseConversionDiagnostics()

        diagnostics.recordPaywallImpression(source: .settings)
        diagnostics.recordPaywallImpression(source: .settings)
        diagnostics.recordPaywallImpression(source: .assistant)

        XCTAssertEqual(diagnostics.paywallImpressionsTotal, 3)
        XCTAssertEqual(diagnostics.paywallImpressionsBySource[.settings], 2)
        XCTAssertEqual(diagnostics.paywallImpressionsBySource[.assistant], 1)
        XCTAssertNil(diagnostics.paywallImpressionsBySource[.backupRestore])
    }

    func testPurchaseCountersIncrementIndependently() {
        var diagnostics = PurchaseConversionDiagnostics()

        diagnostics.recordPurchaseButtonTap()
        diagnostics.recordPurchaseButtonTap()
        diagnostics.recordPurchaseSuccess()
        diagnostics.recordPurchaseCancellation()

        XCTAssertEqual(diagnostics.purchaseButtonTaps, 2)
        XCTAssertEqual(diagnostics.successfulPurchases, 1)
        XCTAssertEqual(diagnostics.cancelledPurchases, 1)
        XCTAssertEqual(diagnostics.productLoadFailures, 0)
    }

    func testProductLoadFailureCounterIncrements() {
        var diagnostics = PurchaseConversionDiagnostics()

        diagnostics.recordProductLoadFailure()
        diagnostics.recordProductLoadFailure()

        XCTAssertEqual(diagnostics.productLoadFailures, 2)
    }

    func testDefaultValueMatchesResetState() {
        let diagnostics = PurchaseConversionDiagnostics()

        XCTAssertEqual(diagnostics.paywallImpressionsTotal, 0)
        XCTAssertTrue(diagnostics.paywallImpressionsBySource.isEmpty)
        XCTAssertEqual(diagnostics.purchaseButtonTaps, 0)
        XCTAssertEqual(diagnostics.successfulPurchases, 0)
        XCTAssertEqual(diagnostics.cancelledPurchases, 0)
        XCTAssertEqual(diagnostics.productLoadFailures, 0)
    }
}
#endif
