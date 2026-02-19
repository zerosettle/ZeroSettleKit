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

    /// Save offer configuration shown to retain the user.
    public struct Offer: Codable, Sendable {
        public let enabled: Bool
        public let title: String
        public let body: String
        public let ctaText: String
        public let type: String
        public let value: String
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

    // MARK: - Internal Types

    /// Payload submitted to the backend after a cancel flow completes.
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
