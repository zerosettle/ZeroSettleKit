//
//  NativePayFlowTests.swift
//  ZeroSettleKitTests
//
//  Tests for NativePay.Flow's deferred-mode handling of the
//  STPApplePayContext finalize-on-tap pattern.
//
//  These tests are gated on the `NativePay` package trait. The default
//  ZeroSettleKit test scheme runs without the trait (the Stripe Apple Pay
//  dependency is opt-in), so the tests below silently disappear when the
//  trait is off. They become exercisable as soon as a NativePay-enabled
//  scheme is wired up — until then, the resolver helper they test is
//  exercised only via the production code path.
//
//  Spec: docs/superpowers/specs/2026-04-29-deferred-mode-architecture-design.md §3.5
//

import XCTest
@testable import ZeroSettleKit

#if NativePay

final class NativePayFlowTests: XCTestCase {

    // MARK: - PaymentError descriptions

    func testTrialViaApplePayErrorDescription() {
        let err = NativePay.PaymentError.trialViaApplePayNotSupported
        XCTAssertNotNil(err.errorDescription)
        XCTAssertFalse(err.errorDescription!.isEmpty)
    }

    func testCheckoutConfigExpiredErrorDescription() {
        let err = NativePay.PaymentError.checkoutConfigExpired
        XCTAssertNotNil(err.errorDescription)
        XCTAssertFalse(err.errorDescription!.isEmpty)
    }

    // MARK: - resolveClientSecret: legacy (cached) branch

    /// Legacy fall-through: `CheckoutResponse.clientSecret` is non-nil.
    /// The resolver must short-circuit and return the cached value without
    /// invoking `finalize`. Verifies the SDK does NOT regress to an extra
    /// round-trip when the backend returned a client_secret eagerly.
    func testResolveClientSecret_LegacyCached_ReturnsCachedAndSkipsFinalize() async throws {
        // `finalize` is `@Sendable` (it crosses into the @MainActor finalize-on-tap
        // Task in production), so the test spy uses a reference-type recorder
        // rather than a captured `var`. `resolveClientSecret` awaits `finalize`
        // serially, so there is no real concurrency here — the recorder just
        // satisfies the Sendable requirement.
        let recorder = FinalizeRecorder()
        let result = try await NativePay.resolveClientSecret(
            cached: "pi_legacy_secret_xyz",
            transactionId: "txn_abc",
            finalize: { _ in
                recorder.calls += 1
                return "pi_should_not_be_used_secret_xxx"
            }
        )
        XCTAssertEqual(result, "pi_legacy_secret_xyz")
        XCTAssertEqual(recorder.calls, 0, "Cached client_secret must not invoke finalize")
    }

    /// Empty-string cached value is treated the same as nil — the legacy
    /// pre-Task-14 backend used to return `client_secret: ""` as a placeholder
    /// for deferred mode. The resolver normalizes empty to "no cached" and
    /// falls through to finalize.
    func testResolveClientSecret_EmptyCached_TreatedAsDeferred() async throws {
        let recorder = FinalizeRecorder()
        let result = try await NativePay.resolveClientSecret(
            cached: "",
            transactionId: "txn_abc",
            finalize: { id in
                recorder.calls += 1
                XCTAssertEqual(id, "txn_abc")
                return "pi_finalized_secret_yyy"
            }
        )
        XCTAssertEqual(result, "pi_finalized_secret_yyy")
        XCTAssertEqual(recorder.calls, 1)
    }

    // MARK: - resolveClientSecret: deferred PI branch

    /// Deferred mode + PaymentIntent (`pi_*_secret_*`): the resolver calls
    /// finalize with the txn id and returns its result.
    func testResolveClientSecret_DeferredPI_CallsFinalizeAndReturns() async throws {
        let recorder = FinalizeRecorder()
        let result = try await NativePay.resolveClientSecret(
            cached: nil,
            transactionId: "txn_deferred_42",
            finalize: { id in
                recorder.observedTxnId = id
                return "pi_3PaymentIntent_secret_abc123"
            }
        )
        XCTAssertEqual(result, "pi_3PaymentIntent_secret_abc123")
        XCTAssertEqual(recorder.observedTxnId, "txn_deferred_42")
    }

    // MARK: - resolveClientSecret: deferred SI (trial) branch

    /// Deferred mode + SetupIntent (`seti_*_secret_*`): finalize succeeds but
    /// returns a SetupIntent secret. STPApplePayContext only supports
    /// PaymentIntent confirmation — surface a clear error rather than
    /// letting Stripe fail downstream. Trial-via-Apple-Pay is tracked as a
    /// follow-up.
    func testResolveClientSecret_DeferredSI_ThrowsTrialNotSupported() async {
        do {
            _ = try await NativePay.resolveClientSecret(
                cached: nil,
                transactionId: "txn_trial_007",
                finalize: { _ in "seti_1Setup_secret_zzz" }
            )
            XCTFail("Expected trialViaApplePayNotSupported to throw")
        } catch let err as NativePay.PaymentError {
            switch err {
            case .trialViaApplePayNotSupported:
                break // expected
            default:
                XCTFail("Expected .trialViaApplePayNotSupported, got \(err)")
            }
        } catch {
            XCTFail("Expected NativePay.PaymentError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - resolveClientSecret: 410 → checkoutConfigExpired mapping

    /// When `Backend.finalizePaymentIntent` throws
    /// `ZeroSettleError.checkoutConfigExpired` (HTTP 410), the resolver must
    /// re-throw it as `NativePay.PaymentError.checkoutConfigExpired` so the
    /// NativePay caller surface stays uniform.
    func testResolveClientSecret_FinalizeExpired_MapsToCheckoutConfigExpired() async {
        do {
            _ = try await NativePay.resolveClientSecret(
                cached: nil,
                transactionId: "txn_stale",
                finalize: { _ in
                    throw ZeroSettleError.checkoutConfigExpired
                }
            )
            XCTFail("Expected checkoutConfigExpired to throw")
        } catch let err as NativePay.PaymentError {
            switch err {
            case .checkoutConfigExpired:
                break // expected
            default:
                XCTFail("Expected .checkoutConfigExpired, got \(err)")
            }
        } catch {
            XCTFail("Expected NativePay.PaymentError, got \(type(of: error)): \(error)")
        }
    }

    /// Other errors thrown by finalize propagate unchanged — only the 410
    /// expiry branch is remapped. Network errors etc. should reach the
    /// caller as-is so they're not flattened into a generic NativePay error.
    func testResolveClientSecret_FinalizeOtherError_PropagatesUnchanged() async {
        struct FakeNetworkError: Error, Equatable {}
        do {
            _ = try await NativePay.resolveClientSecret(
                cached: nil,
                transactionId: "txn_x",
                finalize: { _ in
                    throw FakeNetworkError()
                }
            )
            XCTFail("Expected error to throw")
        } catch is FakeNetworkError {
            // expected — propagated unchanged
        } catch {
            XCTFail("Expected FakeNetworkError, got \(type(of: error)): \(error)")
        }
    }
}

/// Reference-type spy for `resolveClientSecret`'s now-`@Sendable` `finalize`
/// closure. `@Sendable` forbids mutating a captured `var`; a class lets the test
/// record invocation count / the observed txn id without that capture. Safe:
/// `resolveClientSecret` awaits `finalize` serially (no concurrent access), so
/// `@unchecked Sendable` is sound here.
private final class FinalizeRecorder: @unchecked Sendable {
    var calls = 0
    var observedTxnId: String?
}

#endif // NativePay
