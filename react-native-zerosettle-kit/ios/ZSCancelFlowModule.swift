import Foundation
import ZeroSettleKit

@objc(ZSCancelFlowModule)
class ZSCancelFlowModule: NSObject {

    @objc
    static func requiresMainQueueSetup() -> Bool {
        return true
    }

    // MARK: - Get Cancel Flow Config

    @objc
    func getCancelFlowConfig(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            guard let config = ZeroSettle.shared.cancelFlowConfig else {
                resolve(nil)
                return
            }
            resolve(Self.configToMap(config))
        }
    }

    // MARK: - Accept Save Offer

    @objc
    func acceptSaveOffer(_ productId: String, userId: String, resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            do {
                let result = try await ZeroSettle.shared.acceptSaveOffer(productId: productId, userId: userId)
                resolve([
                    "message": result.message,
                    "discountPercent": result.discountPercent as Any,
                    "durationMonths": result.durationMonths as Any,
                ])
            } catch {
                reject("accept_offer_failed", error.localizedDescription, error)
            }
        }
    }

    // MARK: - Submit Cancel Flow Response

    @objc
    func submitCancelFlowResponse(_ responseMap: NSDictionary, resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            let answers = (responseMap["answers"] as? [[String: Any]])?.map { answerMap in
                CancelFlow.Answer(
                    questionId: answerMap["questionId"] as? Int ?? 0,
                    selectedOptionId: answerMap["selectedOptionId"] as? Int,
                    freeText: answerMap["freeText"] as? String
                )
            } ?? []

            let outcome: CancelFlow.Outcome
            switch responseMap["outcome"] as? String {
            case "cancelled": outcome = .cancelled
            case "retained": outcome = .retained
            case "paused": outcome = .paused
            case "dismissed": outcome = .dismissed
            default: outcome = .cancelled
            }

            let response = CancelFlow.Response(
                productId: responseMap["productId"] as? String ?? "",
                userId: responseMap["userId"] as? String ?? "",
                outcome: outcome,
                answers: answers,
                offerShown: responseMap["offerShown"] as? Bool ?? false,
                offerAccepted: responseMap["offerAccepted"] as? Bool ?? false,
                pauseShown: responseMap["pauseShown"] as? Bool ?? false,
                pauseAccepted: responseMap["pauseAccepted"] as? Bool ?? false,
                pauseDurationDays: responseMap["pauseDurationDays"] as? Int
            )

            await ZeroSettle.shared.submitCancelFlowResponse(response)
            resolve(nil)
        }
    }

    // MARK: - Pause Subscription

    @objc
    func pauseSubscription(_ productId: String, userId: String, pauseOptionId: Int, resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            do {
                let resumesAt = try await ZeroSettle.shared.pauseSubscription(productId: productId, userId: userId, pauseOptionId: pauseOptionId)
                if let resumesAt {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    resolve(formatter.string(from: resumesAt))
                } else {
                    resolve(nil)
                }
            } catch {
                reject("pause_failed", error.localizedDescription, error)
            }
        }
    }

    // MARK: - Resume Subscription

    @objc
    func resumeSubscription(_ productId: String, userId: String, resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            do {
                try await ZeroSettle.shared.resumeSubscription(productId: productId, userId: userId)
                resolve(nil)
            } catch {
                reject("resume_failed", error.localizedDescription, error)
            }
        }
    }

    // MARK: - Cancel Subscription

    @objc
    func cancelSubscription(_ productId: String, userId: String, immediate: Bool, resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            do {
                try await ZeroSettle.shared.cancelSubscription(productId: productId, userId: userId, immediate: immediate)
                resolve(nil)
            } catch {
                reject("cancel_failed", error.localizedDescription, error)
            }
        }
    }

    // MARK: - Open Customer Portal

    @objc
    func openCustomerPortal(_ userId: String, resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            do {
                try await ZeroSettle.shared.openCustomerPortal(userId: userId)
                resolve(nil)
            } catch {
                reject("portal_failed", error.localizedDescription, error)
            }
        }
    }

    // MARK: - Serialization

    private static func configToMap(_ config: CancelFlow.Config) -> [String: Any] {
        var map: [String: Any] = [
            "enabled": config.enabled,
            "questions": config.questions.map { question in
                [
                    "id": question.id,
                    "order": question.order,
                    "questionText": question.questionText,
                    "questionType": question.questionType.rawValue,
                    "isRequired": question.isRequired,
                    "options": question.options.map { option in
                        [
                            "id": option.id,
                            "order": option.order,
                            "label": option.label,
                            "triggersOffer": option.triggersOffer,
                            "triggersPause": option.triggersPause,
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
        ]
        if let offer = config.offer {
            map["offer"] = [
                "enabled": offer.enabled,
                "title": offer.title,
                "body": offer.body,
                "ctaText": offer.ctaText,
                "type": offer.type.rawString,
                "value": offer.value,
            ] as [String: Any]
        }
        if let pause = config.pause {
            map["pause"] = [
                "enabled": pause.enabled,
                "title": pause.title,
                "body": pause.body,
                "ctaText": pause.ctaText,
                "options": pause.options.map { option in
                    [
                        "id": option.id,
                        "order": option.order,
                        "label": option.label,
                        "durationType": option.durationType.rawValue,
                        "durationDays": option.durationDays as Any,
                    ] as [String: Any]
                },
            ] as [String: Any]
        }
        return map
    }
}
