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

    // MARK: - resolveClientSecretWithRecovery: happy path (no 410)

    /// First finalize succeeds with a PaymentIntent secret → no re-initiate.
    /// This is the common path (TTL not expired, config not superseded). Verifies
    /// recovery is NOT triggered and the effective txn id is the original one.
    func testRecovery_FinalizeSucceeds_NoReinitiate() async throws {
        let recorder = RecoveryRecorder()
        let result = try await NativePay.resolveClientSecretWithRecovery(
            authorized: .init(transactionId: "txn_1", amount: 499, isTrial: false),
            finalize: { id in
                recorder.finalizeCalls += 1
                recorder.lastFinalizeTxn = id
                return "pi_secret_ok"
            },
            reinitiate: {
                recorder.reinitiateCalls += 1
                return .init(transactionId: "txn_should_not_happen", amount: 499, isTrial: false)
            }
        )
        XCTAssertEqual(result.clientSecret, "pi_secret_ok")
        XCTAssertEqual(result.effectiveTransactionId, "txn_1")
        XCTAssertEqual(recorder.finalizeCalls, 1)
        XCTAssertEqual(recorder.reinitiateCalls, 0, "No 410 → must not re-initiate")
    }

    /// A SetupIntent secret on the first finalize → trialViaApplePayNotSupported,
    /// same as the legacy resolver. No re-initiate.
    func testRecovery_FinalizeReturnsSetupIntent_ThrowsTrialNotSupported() async {
        let recorder = RecoveryRecorder()
        do {
            _ = try await NativePay.resolveClientSecretWithRecovery(
                authorized: .init(transactionId: "txn_1", amount: 0, isTrial: true),
                finalize: { _ in
                    recorder.finalizeCalls += 1
                    return "seti_secret_trial"
                },
                reinitiate: { recorder.reinitiateCalls += 1; return .init(transactionId: "x", amount: 0, isTrial: true) }
            )
            XCTFail("Expected trialViaApplePayNotSupported")
        } catch NativePay.PaymentError.trialViaApplePayNotSupported {
            // expected
        } catch {
            XCTFail("Expected .trialViaApplePayNotSupported, got \(error)")
        }
        XCTAssertEqual(recorder.reinitiateCalls, 0)
    }

    // MARK: - resolveClientSecretWithRecovery: 410 → single retry

    /// 410 on first finalize → re-initiate ONCE → finalize the fresh txn →
    /// success. Verifies: re-initiate fires exactly once, the retried finalize
    /// targets the FRESH txn id, and the result reports the fresh txn id (so the
    /// caller verifies the right transaction post-pay).
    func testRecovery_FirstFinalize410_ReinitiatesOnceAndRetries() async throws {
        let recorder = RecoveryRecorder()
        let result = try await NativePay.resolveClientSecretWithRecovery(
            authorized: .init(transactionId: "txn_old", amount: 499, isTrial: false),
            finalize: { id in
                recorder.finalizeCalls += 1
                recorder.lastFinalizeTxn = id
                if id == "txn_old" { throw ZeroSettleError.checkoutConfigExpired }
                return "pi_secret_fresh"
            },
            reinitiate: {
                recorder.reinitiateCalls += 1
                return .init(transactionId: "txn_new", amount: 499, isTrial: false)
            }
        )
        XCTAssertEqual(result.clientSecret, "pi_secret_fresh")
        XCTAssertEqual(result.effectiveTransactionId, "txn_new")
        XCTAssertEqual(recorder.reinitiateCalls, 1, "Must re-initiate exactly once")
        XCTAssertEqual(recorder.finalizeCalls, 2, "finalize: once on old (410), once on fresh")
        XCTAssertEqual(recorder.lastFinalizeTxn, "txn_new")
    }

    /// A second 410 on the RE-INITIATED config must NOT loop — it maps to
    /// checkoutConfigExpired and propagates. Guards the single-retry contract.
    func testRecovery_SecondFinalize410_DoesNotLoopAndThrows() async {
        let recorder = RecoveryRecorder()
        do {
            _ = try await NativePay.resolveClientSecretWithRecovery(
                authorized: .init(transactionId: "txn_old", amount: 499, isTrial: false),
                finalize: { _ in
                    recorder.finalizeCalls += 1
                    throw ZeroSettleError.checkoutConfigExpired  // both old AND fresh 410
                },
                reinitiate: {
                    recorder.reinitiateCalls += 1
                    return .init(transactionId: "txn_new", amount: 499, isTrial: false)
                }
            )
            XCTFail("Expected checkoutConfigExpired")
        } catch NativePay.PaymentError.checkoutConfigExpired {
            // expected — no loop
        } catch {
            XCTFail("Expected .checkoutConfigExpired, got \(error)")
        }
        XCTAssertEqual(recorder.reinitiateCalls, 1, "Re-initiate exactly once, then give up")
        XCTAssertEqual(recorder.finalizeCalls, 2, "finalize twice total (old + fresh), never a third")
    }

    // MARK: - resolveClientSecretWithRecovery: amount guard

    /// 410 → re-initiate resolves a DIFFERENT price (a variant override that
    /// changed the amount). The user authorized the old amount on the Apple Pay
    /// sheet, so confirming the new amount would mischarge. Must abort with
    /// checkoutConfigExpired WITHOUT finalizing the fresh txn.
    func testRecovery_ReinitiateChangesAmount_AbortsBeforeFinalize() async {
        let recorder = RecoveryRecorder()
        do {
            _ = try await NativePay.resolveClientSecretWithRecovery(
                authorized: .init(transactionId: "txn_old", amount: 499, isTrial: false),
                finalize: { id in
                    recorder.finalizeCalls += 1
                    if id == "txn_old" { throw ZeroSettleError.checkoutConfigExpired }
                    return "pi_secret_DIFFERENT_PRICE"  // must never reach here
                },
                reinitiate: {
                    recorder.reinitiateCalls += 1
                    return .init(transactionId: "txn_new", amount: 399, isTrial: false)  // price changed!
                }
            )
            XCTFail("Expected checkoutConfigExpired on amount mismatch")
        } catch NativePay.PaymentError.checkoutConfigExpired {
            // expected
        } catch {
            XCTFail("Expected .checkoutConfigExpired, got \(error)")
        }
        XCTAssertEqual(recorder.reinitiateCalls, 1)
        XCTAssertEqual(recorder.finalizeCalls, 1, "Must NOT finalize the fresh (differently-priced) txn")
    }

    /// 410 → re-initiate keeps the same amount but flips trial→non-trial (or
    /// vice versa). The Apple Pay sheet was built for a trial; charging now would
    /// differ from what the user saw. Must abort even though `amount` matches.
    func testRecovery_ReinitiateFlipsTrialShape_Aborts() async {
        let recorder = RecoveryRecorder()
        do {
            _ = try await NativePay.resolveClientSecretWithRecovery(
                authorized: .init(transactionId: "txn_old", amount: 0, isTrial: true),
                finalize: { id in
                    recorder.finalizeCalls += 1
                    if id == "txn_old" { throw ZeroSettleError.checkoutConfigExpired }
                    return "pi_secret_x"
                },
                reinitiate: {
                    recorder.reinitiateCalls += 1
                    return .init(transactionId: "txn_new", amount: 0, isTrial: false)  // trial → charge-now
                }
            )
            XCTFail("Expected checkoutConfigExpired on trial-shape flip")
        } catch NativePay.PaymentError.checkoutConfigExpired {
            // expected
        } catch {
            XCTFail("Expected .checkoutConfigExpired, got \(error)")
        }
        XCTAssertEqual(recorder.finalizeCalls, 1, "Must NOT finalize the fresh txn when trial shape flips")
    }

    /// AuthorizedCharge derives its shape from a CheckoutResponse: `isTrial` is
    /// driven by `trialEnd != nil`, `amount` from `response.amount`.
    func testAuthorizedCharge_FromResponse_DerivesTrialFromTrialEnd() {
        let trial = makeResponse(amount: 0, trialEnd: 1_900_000_000)
        let charge = NativePay.AuthorizedCharge(response: trial)
        XCTAssertTrue(charge.isTrial)
        XCTAssertEqual(charge.amount, 0)
        XCTAssertEqual(charge.transactionId, trial.transactionId)

        let nonTrial = makeResponse(amount: 499, trialEnd: nil)
        XCTAssertFalse(NativePay.AuthorizedCharge(response: nonTrial).isTrial)
    }

    // MARK: - Helpers

    private func makeResponse(amount: Int, trialEnd: Int?) -> CheckoutResponse {
        CheckoutResponse(
            clientSecret: nil,
            transactionId: "txn_resp_\(amount)",
            amount: amount,
            currency: "USD",
            productName: "P",
            originalAmount: nil,
            callbackUrl: "https://e.com/cb",
            publishableKey: "pk",
            checkoutUrl: "https://e.com/co",
            stripeAccount: nil,
            merchantCountry: nil,
            isSubscription: trialEnd != nil,
            subscriptionInterval: trialEnd != nil ? "month" : nil,
            trialEnd: trialEnd,
            pendingAmount: trialEnd != nil ? amount : nil,
            deferredMode: true
        )
    }
}

/// Reference-type spy for the recovery resolver's `@Sendable` closures.
private final class RecoveryRecorder: @unchecked Sendable {
    var finalizeCalls = 0
    var reinitiateCalls = 0
    var lastFinalizeTxn: String?
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
