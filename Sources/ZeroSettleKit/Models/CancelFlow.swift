//
//  CancelFlow.swift
//  ZeroSettleKit
//
//  Cancel flow questionnaire types.
//  Uses uninhabited enum as namespace: CancelFlow.Config, CancelFlow.Question, etc.
//

import Foundation

/// Namespace for cancellation questionnaire types.
///
/// The cancel flow presents a native questionnaire when a user tries to cancel
/// a subscription. Developers customize questions, answer options, and a
/// conditional save offer via the ZeroSettle dashboard.
///
/// Access types via the namespace: `CancelFlow.Config`, `CancelFlow.Result`, etc.
public enum CancelFlow {

    // MARK: - Public Types

    /// Configuration returned by the backend for presenting the cancel flow.
    public struct Config: Codable, Sendable {
        /// Whether the cancel flow is enabled for this app.
        public let enabled: Bool
        /// Ordered list of questions to present.
        public let questions: [Question]
        /// Optional save offer to show (if `offer.enabled` is true).
        public let offer: Offer?
        /// Optional pause configuration for the retention page.
        public let pause: PauseConfig?
    }

    /// A single question in the cancel flow questionnaire.
    public struct Question: Codable, Sendable, Identifiable {
        public let id: Int
        public let order: Int
        public let questionText: String
        public let questionType: QuestionType
        public let isRequired: Bool
        public let options: [Option]
    }

    /// The type of a cancel flow question.
    public enum QuestionType: String, Codable, Sendable {
        case singleSelect = "single_select"
        case freeText = "free_text"
    }

    /// An answer option for a single-select question.
    public struct Option: Codable, Sendable, Identifiable {
        public let id: Int
        public let order: Int
        public let label: String
        public let triggersOffer: Bool
        public let triggersPause: Bool
    }

    /// The type of retention offer shown to the user.
    ///
    /// Unknown server values are preserved via `.other(String)` for forward compatibility.
    public enum OfferType: Sendable, Equatable, Hashable {
        case discount
        case freeTrial
        case freeExtension
        case other(String)

        /// The raw string value for serialization.
        public var rawString: String {
            switch self {
            case .discount: return "discount"
            case .freeTrial: return "free_trial"
            case .freeExtension: return "free_extension"
            case .other(let value): return value
            }
        }

        init(rawString: String) {
            switch rawString {
            case "discount": self = .discount
            case "free_trial": self = .freeTrial
            case "free_extension": self = .freeExtension
            default: self = .other(rawString)
            }
        }
    }

    /// Save offer configuration shown to retain the user.
    public struct Offer: Codable, Sendable {
        public let enabled: Bool
        public let title: String
        public let body: String
        public let ctaText: String
        public let type: OfferType
        public let value: String

        private enum CodingKeys: String, CodingKey {
            case enabled, title, body, ctaText, type, value
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            title = try container.decode(String.self, forKey: .title)
            body = try container.decode(String.self, forKey: .body)
            ctaText = try container.decode(String.self, forKey: .ctaText)
            let rawType = try container.decode(String.self, forKey: .type)
            type = OfferType(rawString: rawType)
            value = try container.decode(String.self, forKey: .value)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(enabled, forKey: .enabled)
            try container.encode(title, forKey: .title)
            try container.encode(body, forKey: .body)
            try container.encode(ctaText, forKey: .ctaText)
            try container.encode(type.rawString, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    /// Pause configuration for the retention page.
    public struct PauseConfig: Codable, Sendable {
        /// Whether pause is enabled for this app.
        public let enabled: Bool
        /// Title text for the pause section.
        public let title: String
        /// Body text for the pause section.
        public let body: String
        /// CTA button text (e.g., "Pause Subscription").
        public let ctaText: String
        /// Available pause duration options.
        public let options: [PauseOption]
    }

    /// A selectable pause duration option.
    public struct PauseOption: Codable, Sendable, Identifiable {
        public let id: Int
        public let order: Int
        public let label: String
        public let durationType: DurationType
        public let durationDays: Int?
        public let resumeDate: Date?

        /// How the pause duration is specified.
        public enum DurationType: String, Codable, Sendable {
            case days
            case fixedDate = "fixed_date"
        }
    }

    /// The outcome of a cancel flow presentation.
    public enum Result: Sendable, Equatable {
        /// The user completed the flow and chose to cancel.
        case cancelled
        /// The user accepted the save offer and was retained.
        case retained
        /// The user chose to pause their subscription.
        case paused(resumesAt: Date?)
        /// The user dismissed the sheet without completing the flow.
        case dismissed
    }

    // MARK: - Headless Cancel Flow Types

    /// The outcome of a cancel flow for analytics tracking.
    public enum Outcome: String, Sendable, Codable {
        case cancelled
        case retained
        case paused
        case dismissed
    }

    /// A single answer to a cancel flow question.
    ///
    /// For `.singleSelect` questions, set `selectedOptionId`.
    /// For `.freeText` questions, set `freeText`.
    public struct Answer: Sendable {
        /// The question ID this answer corresponds to.
        public let questionId: Int
        /// The selected option ID (for single-select questions).
        public let selectedOptionId: Int?
        /// The free text response (for free-text questions).
        public let freeText: String?

        public init(questionId: Int, selectedOptionId: Int? = nil, freeText: String? = nil) {
            self.questionId = questionId
            self.selectedOptionId = selectedOptionId
            self.freeText = freeText
        }
    }

    /// Analytics payload submitted after a cancel flow completes.
    ///
    /// Use with ``ZeroSettle/submitCancelFlowResponse(_:)`` when building custom cancel flow UI.
    public struct Response: Sendable {
        /// The product the user was cancelling.
        public let productId: String
        /// Your app's user identifier.
        public let userId: String
        /// The final outcome of the cancel flow.
        public let outcome: Outcome
        /// The user's answers to questionnaire questions.
        public let answers: [Answer]
        /// Whether the save offer was shown to the user.
        public let offerShown: Bool
        /// Whether the user accepted the save offer.
        public let offerAccepted: Bool
        /// Whether the pause option was shown to the user.
        public let pauseShown: Bool
        /// Whether the user accepted the pause option.
        public let pauseAccepted: Bool
        /// The selected pause duration in days (if pause was accepted).
        public let pauseDurationDays: Int?

        public init(
            productId: String,
            userId: String,
            outcome: Outcome,
            answers: [Answer] = [],
            offerShown: Bool = false,
            offerAccepted: Bool = false,
            pauseShown: Bool = false,
            pauseAccepted: Bool = false,
            pauseDurationDays: Int? = nil
        ) {
            self.productId = productId
            self.userId = userId
            self.outcome = outcome
            self.answers = answers
            self.offerShown = offerShown
            self.offerAccepted = offerAccepted
            self.pauseShown = pauseShown
            self.pauseAccepted = pauseAccepted
            self.pauseDurationDays = pauseDurationDays
        }
    }

    /// Result returned after a save offer is successfully applied.
    ///
    /// Returned by ``ZeroSettle/acceptSaveOffer(productId:userId:)``.
    public struct SaveOfferResult: Sendable {
        /// Human-readable description of the applied offer (e.g., "40% off for 3 months").
        public let message: String
        /// Discount percentage, if the offer type is a percentage discount.
        public let discountPercent: Int?
        /// Duration of the discount in months, if applicable.
        public let durationMonths: Int?
    }

    // MARK: - Internal Types

    /// Payload submitted to the backend after a cancel flow completes.
    /// Used by the built-in cancel flow UI. The public ``Response`` type is converted
    /// to this before submission.
    internal struct ResponsePayload: Encodable {
        let userId: String
        let productId: String
        let outcome: String
        let offerShown: Bool
        let offerAccepted: Bool
        let pauseShown: Bool
        let pauseAccepted: Bool
        let pauseDurationDays: Int?
        let lastStepSeen: Int
        let answers: [AnswerPayload]
    }

    /// A single answer within a cancel flow response.
    internal struct AnswerPayload: Encodable {
        let questionId: Int
        let selectedOptionId: Int?
        let freeText: String?
    }
}
