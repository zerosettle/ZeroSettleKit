//
//  CancelFlowSheet.swift
//  ZeroSettleKit
//
//  Native SwiftUI cancel flow sheet and presentation helpers.
//

import Foundation
import SwiftUI
import UIKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

// MARK: - Cancel Flow Presenter

/// Handles UIHostingController presentation for the cancel flow sheet.
internal final class CancelFlowPresenter: NSObject, @unchecked Sendable {

    private var hostingController: UIHostingController<AnyView>?
    private var continuation: CheckedContinuation<CancelFlow.Result, Never>?
    private var hasResumed = false

    /// Present the cancel flow sheet and await its result.
    @MainActor
    func present(
        config: CancelFlow.Config,
        productId: String,
        userId: String,
        backend: Backend
    ) async -> CancelFlow.Result {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            ZSLogger.error("Unable to find root view controller for cancel flow", category: .iap)
            return .cancelled
        }

        var topController = rootViewController
        while let presented = topController.presentedViewController {
            topController = presented
        }

        hasResumed = false

        return await withCheckedContinuation { (cont: CheckedContinuation<CancelFlow.Result, Never>) in
            self.continuation = cont

            let sheet = CancelFlowSheetView(
                config: config,
                productId: productId,
                userId: userId,
                backend: backend
            ) { [weak self] result, payload in
                guard let self, !self.hasResumed else { return }
                self.hasResumed = true

                // Fire-and-forget: submit response to backend
                Task {
                    do {
                        try await backend.submitCancelFlowResponse(payload)
                        ZSLogger.debug("Cancel flow response submitted", category: .iap)
                    } catch {
                        ZSLogger.error("Failed to submit cancel flow response: \(error)", category: .iap)
                    }
                }

                self.hostingController?.dismiss(animated: true) {
                    self.continuation?.resume(returning: result)
                    self.continuation = nil
                    self.hostingController = nil
                }
            }

            let hosting = UIHostingController(rootView: AnyView(sheet))
            hosting.modalPresentationStyle = .pageSheet

            if let presentationController = hosting.sheetPresentationController {
                presentationController.detents = [.large()]
                presentationController.prefersGrabberVisible = true
            }
            hosting.presentationController?.delegate = self

            self.hostingController = hosting
            topController.present(hosting, animated: true)
        }
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate

extension CancelFlowPresenter: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard !hasResumed else { return }
        hasResumed = true
        continuation?.resume(returning: .dismissed)
        continuation = nil
        hostingController = nil
    }
}

// MARK: - CancelFlowSheetView

/// Internal SwiftUI view for the cancel flow questionnaire.
private struct CancelFlowSheetView: View {
    let config: CancelFlow.Config
    let productId: String
    let userId: String
    let backend: Backend
    let onComplete: (CancelFlow.Result, CancelFlow.ResponsePayload) -> Void

    @State private var currentQuestionIndex = 0
    @State private var answers: [CancelFlow.AnswerPayload] = []
    @State private var selectedOptionId: Int? = nil
    @State private var freeTextInput = ""
    @State private var showingRetention = false
    @State private var offerShown = false
    @State private var pauseShown = false
    @State private var lastStepSeen = 0
    @State private var earlyOfferTriggered = false
    @State private var selectedPauseOptionId: Int? = nil
    @State private var isPauseLoading = false

    private var currentQuestion: CancelFlow.Question? {
        guard currentQuestionIndex < config.questions.count else { return nil }
        return config.questions[currentQuestionIndex]
    }

    private var hasRetentionPage: Bool {
        (config.offer?.enabled == true) || (config.pause?.enabled == true)
    }

    private var totalSteps: Int {
        let questionSteps = config.questions.count
        let retentionStep = hasRetentionPage ? 1 : 0
        return questionSteps + retentionStep
    }

    private var currentStep: Int {
        if showingRetention {
            return config.questions.count
        }
        return currentQuestionIndex
    }

    private var canContinue: Bool {
        guard let question = currentQuestion else { return false }
        switch question.questionType {
        case .singleSelect:
            return selectedOptionId != nil || !question.isRequired
        case .freeText:
            return !freeTextInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !question.isRequired
        }
    }

    private var canGoBack: Bool {
        if showingRetention { return true }
        return currentQuestionIndex > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: back arrow + progress dots
            HStack {
                // Back arrow (visible after first step)
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 30)
                }
                .opacity(canGoBack ? 1 : 0)
                .disabled(!canGoBack)

                Spacer()

                progressDots

                Spacer()

                // Invisible spacer for symmetry
                Color.clear.frame(width: 30, height: 30)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Content
            ScrollView {
                VStack(spacing: 0) {
                    if showingRetention {
                        retentionView
                    } else if let question = currentQuestion {
                        questionView(question: question)
                    }
                }
                .padding(.horizontal, 20)
            }

            Spacer(minLength: 16)

            // Bottom buttons
            VStack(spacing: 12) {
                if showingRetention {
                    retentionButtons
                } else {
                    // Continue button
                    Button {
                        advanceToNext()
                    } label: {
                        Text("Continue")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                canContinue ? Color.green : Color.green.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                    }
                    .disabled(!canContinue)

                    Button {
                        finish(result: .cancelled)
                    } label: {
                        Text("Skip and cancel subscription")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { step in
                Circle()
                    .fill(step <= currentStep ? Color.green : Color(.systemGray4))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Question View

    @ViewBuilder
    private func questionView(question: CancelFlow.Question) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(question.questionText)
                .font(.title3.weight(.semibold))
                .padding(.top, 16)

            if !question.isRequired {
                Text("Optional")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            switch question.questionType {
            case .singleSelect:
                singleSelectView(question: question)
            case .freeText:
                freeTextView
            }
        }
    }

    private func singleSelectView(question: CancelFlow.Question) -> some View {
        VStack(spacing: 10) {
            ForEach(question.options) { option in
                let isSelected = selectedOptionId == option.id
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedOptionId = option.id
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(isSelected ? Color.green : Color(.systemGray3))

                        Text(option.label)
                            .font(.body)
                            .fontWeight(isSelected ? .medium : .regular)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .background(
                        isSelected ? Color.green.opacity(0.06) : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.green.opacity(0.5) : Color(.separator).opacity(0.3),
                                lineWidth: isSelected ? 1.5 : 0.5
                            )
                    )
                }
            }
        }
    }

    private var freeTextView: some View {
        TextEditor(text: $freeTextInput)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(12)
            .frame(minHeight: 120)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Retention View (Offer + Pause)

    @ViewBuilder
    private var retentionView: some View {
        VStack(spacing: 24) {
            // Offer section
            if let offer = config.offer, offer.enabled {
                offerSection(offer: offer)
            }

            // Pause section
            if let pauseConfig = config.pause, pauseConfig.enabled, !pauseConfig.options.isEmpty {
                pauseSection(pauseConfig: pauseConfig)
            }
        }
    }

    private func offerSection(offer: CancelFlow.Offer) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "gift.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .padding(.top, 20)

            Text(offer.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text(offer.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pauseSection(pauseConfig: CancelFlow.PauseConfig) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Divider between offer and pause if both are shown
            if config.offer?.enabled == true {
                Divider()
                    .padding(.vertical, 4)
            }

            Image(systemName: "pause.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)

            Text(pauseConfig.title)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

            Text(pauseConfig.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

            // Pause duration options (card-based)
            VStack(spacing: 10) {
                let sortedOptions = pauseConfig.options.sorted { $0.order < $1.order }
                ForEach(sortedOptions) { option in
                    let isSelected = selectedPauseOptionId == option.id
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedPauseOptionId = option.id
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(isSelected ? Color.blue : Color(.systemGray3))

                            Text(option.label)
                                .font(.body)
                                .fontWeight(isSelected ? .medium : .regular)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .background(
                            isSelected ? Color.blue.opacity(0.06) : Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.blue.opacity(0.5) : Color(.separator).opacity(0.3),
                                    lineWidth: isSelected ? 1.5 : 0.5
                                )
                        )
                    }
                }
            }
        }
    }

    // MARK: - Retention Buttons

    @ViewBuilder
    private var retentionButtons: some View {
        // Accept offer button (if offer is enabled)
        if let offer = config.offer, offer.enabled {
            Button {
                finish(result: .retained, offerAccepted: true)
            } label: {
                Text(offer.ctaText)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.green, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }

        // Pause button (if pause is enabled)
        if let pauseConfig = config.pause, pauseConfig.enabled, !pauseConfig.options.isEmpty {
            Button {
                submitPause()
            } label: {
                if isPauseLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Text(pauseConfig.ctaText)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            selectedPauseOptionId != nil ? Color.blue : Color.blue.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
            }
            .disabled(selectedPauseOptionId == nil || isPauseLoading)
        }

        // Cancel anyway
        Button {
            finish(result: .cancelled)
        } label: {
            Text("No thanks, cancel")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .disabled(isPauseLoading)
    }

    // MARK: - Flow Logic

    private func goBack() {
        if showingRetention {
            // Return to last question
            showingRetention = false
            offerShown = false
            pauseShown = false
            earlyOfferTriggered = false
            selectedPauseOptionId = nil
            // Remove the last answer (it was the one that advanced us here)
            if !answers.isEmpty { answers.removeLast() }
            // Restore the selection for the current question
            selectedOptionId = answers.count <= currentQuestionIndex ? nil : nil
        } else if currentQuestionIndex > 0 {
            currentQuestionIndex -= 1
            // Remove the last answer and restore selection
            if !answers.isEmpty {
                let removed = answers.removeLast()
                selectedOptionId = removed.selectedOptionId
                freeTextInput = removed.freeText ?? ""
            }
        }
    }

    private func advanceToNext() {
        guard let question = currentQuestion else { return }

        // Record answer
        let answer: CancelFlow.AnswerPayload
        switch question.questionType {
        case .singleSelect:
            answer = CancelFlow.AnswerPayload(
                questionId: question.id,
                selectedOptionId: selectedOptionId,
                freeText: nil
            )
        case .freeText:
            let text = freeTextInput.trimmingCharacters(in: .whitespacesAndNewlines)
            answer = CancelFlow.AnswerPayload(
                questionId: question.id,
                selectedOptionId: nil,
                freeText: text.isEmpty ? nil : text
            )
        }
        answers.append(answer)

        // Check if selected option triggers offer/pause and there's a retention page
        if question.questionType == .singleSelect,
           let optionId = selectedOptionId,
           let option = question.options.first(where: { $0.id == optionId }),
           (option.triggersOffer || option.triggersPause),
           hasRetentionPage {
            earlyOfferTriggered = true
            offerShown = config.offer?.enabled == true
            pauseShown = config.pause?.enabled == true
            lastStepSeen = config.questions.count
            showingRetention = true
            return
        }

        // Move to next question
        let nextIndex = currentQuestionIndex + 1
        if nextIndex < config.questions.count {
            currentQuestionIndex = nextIndex
            lastStepSeen = max(lastStepSeen, nextIndex)
            selectedOptionId = nil
            freeTextInput = ""
        } else {
            // Last question answered, no trigger
            if hasRetentionPage {
                offerShown = config.offer?.enabled == true
                pauseShown = config.pause?.enabled == true
                lastStepSeen = config.questions.count
                showingRetention = true
            } else {
                finish(result: .cancelled)
            }
        }
    }

    private func submitPause() {
        guard let pauseOptionId = selectedPauseOptionId else { return }
        isPauseLoading = true

        Task {
            do {
                let response = try await backend.pauseSubscription(
                    productId: productId,
                    userId: userId,
                    pauseOptionId: pauseOptionId
                )

                let selectedOption = config.pause?.options.first { $0.id == pauseOptionId }
                let durationDays = selectedOption?.durationDays

                await MainActor.run {
                    isPauseLoading = false
                    finish(
                        result: .paused(resumesAt: response.resumesAt),
                        pauseAccepted: true,
                        pauseDurationDays: durationDays
                    )
                }
            } catch {
                await MainActor.run {
                    isPauseLoading = false
                    // On failure, stay on the retention page so the user can retry or cancel
                    ZSLogger.error("Failed to pause subscription from cancel flow: \(error)", category: .iap)
                }
            }
        }
    }

    private func finish(
        result: CancelFlow.Result,
        offerAccepted: Bool = false,
        pauseAccepted: Bool = false,
        pauseDurationDays: Int? = nil
    ) {
        let payload = CancelFlow.ResponsePayload(
            userId: userId,
            productId: productId,
            outcome: outcomeString(result),
            offerShown: offerShown,
            offerAccepted: offerAccepted,
            pauseShown: pauseShown,
            pauseAccepted: pauseAccepted,
            pauseDurationDays: pauseDurationDays,
            lastStepSeen: lastStepSeen,
            answers: answers,
            variantId: config.variantId
        )
        onComplete(result, payload)
    }

    private func outcomeString(_ result: CancelFlow.Result) -> String {
        switch result {
        case .cancelled: return "cancelled"
        case .retained: return "retained"
        case .paused: return "paused"
        case .dismissed: return "dismissed"
        }
    }
}

// MARK: - SwiftUI Modifier

/// Adds a cancel flow sheet to a SwiftUI view.
private struct CancelFlowModifier: ViewModifier {
    @Binding var isPresented: Bool
    let productId: String
    let userId: String
    let onResult: (CancelFlow.Result) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, newValue in
                if newValue {
                    Task { @MainActor in
                        let result = await ZeroSettle.shared.presentCancelFlow(
                            productId: productId,
                            userId: userId
                        )
                        isPresented = false
                        onResult(result)
                    }
                }
            }
    }
}

extension View {
    /// Present the ZeroSettle cancel flow questionnaire.
    ///
    /// When `isPresented` becomes `true`, the SDK fetches the cancel flow
    /// configuration from the backend and presents the native questionnaire sheet.
    ///
    /// - Parameters:
    ///   - isPresented: Binding that controls sheet presentation
    ///   - productId: The product the user wants to cancel
    ///   - userId: Your app's user identifier
    ///   - onResult: Called with the outcome when the flow completes
    public func cancelFlow(
        isPresented: Binding<Bool>,
        productId: String,
        userId: String,
        onResult: @escaping (CancelFlow.Result) -> Void = { _ in }
    ) -> some View {
        modifier(CancelFlowModifier(
            isPresented: isPresented,
            productId: productId,
            userId: userId,
            onResult: onResult
        ))
    }
}
