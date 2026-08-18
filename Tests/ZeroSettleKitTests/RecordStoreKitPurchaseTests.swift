//
//  RecordStoreKitPurchaseTests.swift
//  ZeroSettleKitTests
//
//  Covers the guard paths of `recordStoreKitPurchase(_:)`, the entry point for
//  apps that run their own `Product.purchase()` and report the result to
//  ZeroSettle afterwards.
//
//  The happy path is not unit-testable: `Product.PurchaseResult` and
//  `VerificationResult` cannot be constructed without a live StoreKit session,
//  and the sync itself needs the network. What *is* testable, and what actually
//  protects an adopter, is that every refusal is silent and returns `false`
//  rather than throwing into a purchase flow.
//

import StoreKit
import XCTest
@testable import ZeroSettleKit

@MainActor
final class RecordStoreKitPurchaseTests: XCTestCase {

    /// A cancelled purchase carries no transaction, so there is nothing to
    /// report. It must not be treated as a failure worth surfacing.
    func testCancelledPurchaseResultIsNotReported() async {
        let reported = await ZeroSettle.shared.recordStoreKitPurchase(
            Product.PurchaseResult.userCancelled
        )
        XCTAssertFalse(reported)
    }

    /// Ask to Buy — the transaction arrives later through `Transaction.updates`,
    /// which the SDK's own listener handles. Nothing to report now.
    func testPendingPurchaseResultIsNotReported() async {
        let reported = await ZeroSettle.shared.recordStoreKitPurchase(
            Product.PurchaseResult.pending
        )
        XCTAssertFalse(reported)
    }

    /// A product the user never bought resolves no transaction. The call must
    /// return `false` rather than trap on the `nil`.
    func testUnknownProductIdIsNotReported() async {
        let reported = await ZeroSettle.shared.recordStoreKitPurchase(
            productId: "com.zerosettle.tests.product.that.was.never.bought"
        )
        XCTAssertFalse(reported)
    }

    /// The whole contract in one line: this API never throws. An adopter calls
    /// it from a `Task { }` after a successful purchase, and a ZeroSettle
    /// outage must not be able to reach the customer.
    func testReportingIsNonThrowingAcrossEveryRefusalPath() async {
        // Each of these hits a different guard — no transaction, no
        // transaction, and no StoreKit entitlement respectively.
        _ = await ZeroSettle.shared.recordStoreKitPurchase(Product.PurchaseResult.userCancelled)
        _ = await ZeroSettle.shared.recordStoreKitPurchase(Product.PurchaseResult.pending)
        _ = await ZeroSettle.shared.recordStoreKitPurchase(productId: "")
        // Reaching here without a thrown error or a trap is the assertion.
    }
}

@MainActor
final class ZeroSettleErrorEquatableTests: XCTestCase {

    /// The comparison adopters keep reaching for — and that two of our own doc
    /// samples used before this conformance existed.
    func testSimpleCasesCompareByIdentity() {
        XCTAssertEqual(ZeroSettleError.cancelled, .cancelled)
        XCTAssertEqual(ZeroSettleError.notConfigured, .notConfigured)
        XCTAssertNotEqual(ZeroSettleError.cancelled, .purchasePending)
        XCTAssertNotEqual(ZeroSettleError.userNotIdentified, .invalidUserId)
    }

    func testPayloadCasesCompareTheirPayloads() {
        XCTAssertEqual(
            ZeroSettleError.productNotFound("premium_monthly"),
            .productNotFound("premium_monthly")
        )
        XCTAssertNotEqual(
            ZeroSettleError.productNotFound("premium_monthly"),
            .productNotFound("premium_yearly")
        )
        XCTAssertEqual(
            ZeroSettleError.applePaySetupRequired(autoPresentedSetup: true),
            .applePaySetupRequired(autoPresentedSetup: true)
        )
        XCTAssertNotEqual(
            ZeroSettleError.applePaySetupRequired(autoPresentedSetup: true),
            .applePaySetupRequired(autoPresentedSetup: false)
        )
    }

    func testCheckoutFailureReasonsCompare() {
        XCTAssertEqual(
            ZeroSettleError.checkoutFailed(reason: .networkUnavailable),
            .checkoutFailed(reason: .networkUnavailable)
        )
        XCTAssertNotEqual(
            ZeroSettleError.checkoutFailed(reason: .networkUnavailable),
            .checkoutFailed(reason: .merchantNotOnboarded)
        )
        XCTAssertEqual(
            ZeroSettleError.checkoutFailed(reason: .serverError(statusCode: 502, message: "bad gateway")),
            .checkoutFailed(reason: .serverError(statusCode: 502, message: "bad gateway"))
        )
        XCTAssertNotEqual(
            ZeroSettleError.checkoutFailed(reason: .serverError(statusCode: 502, message: "bad gateway")),
            .checkoutFailed(reason: .serverError(statusCode: 500, message: "bad gateway"))
        )
    }

    /// Cases carrying `any Error` compare by case identity only — documented
    /// behaviour, because `Error` is not `Equatable` and never will be.
    func testErrorPayloadCasesCompareByCaseIdentityOnly() {
        struct A: Error {}
        struct B: Error {}
        XCTAssertEqual(
            ZeroSettleError.storeKitVerificationFailed(underlyingError: A()),
            .storeKitVerificationFailed(underlyingError: B())
        )
        XCTAssertNotEqual(
            ZeroSettleError.storeKitVerificationFailed(underlyingError: A()),
            .cancelled
        )
    }

    /// `isCancellation(_:)` stays the right tool: it catches cancellations that
    /// `== .cancelled` cannot see, because they are not `ZeroSettleError` at all.
    func testIsCancellationStillCatchesMoreThanEquality() {
        XCTAssertTrue(ZeroSettleError.isCancellation(CancellationError()))
        XCTAssertFalse(ZeroSettleError.cancelled == (CancellationError() as? ZeroSettleError))
    }
}
