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
@MainActor
internal final class CancelFlowPresenter: NSObject {

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
            ZSLogger.error("Unable to find root view controller for cancel flow", category: .cancelFlow)
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
                        ZSLogger.debug("Cancel flow response submitted", category: .cancelFlow)
                    } catch {
                        ZSLogger.error("Failed to submit cancel flow response: \(error)", category: .cancelFlow)
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
        // Swipe-to-dismiss = user chose not to cancel (retained),
        // not "cancel flow unconfigured" (.dismissed).
        continuation?.resume(returning: .retained)
        continuation = nil
        hostingController = nil
    }
}

// MARK: - CancelFlowSheetView

/// Navigation path element for the cancel flow.
private enum CancelFlowStep: Hashable {
    case question(index: Int)
    case retention
}

/// Internal SwiftUI view for the cancel flow questionnaire.
private struct CancelFlowSheetView: View {
    let config: CancelFlow.Config
    let productId: String
    let userId: String
    let backend: Backend
    let onComplete: (CancelFlow.Result, CancelFlow.ResponsePayload) -> Void

    @State private var path: [CancelFlowStep] = []
    @State private var answers: [CancelFlow.AnswerPayload] = []
    @State private var pendingSelections: [Int: Int] = [:]
    @State private var pendingFreeText: [Int: String] = [:]
    @State private var offerShown = false
    @State private var pauseShown = false
    @State private var lastStepSeen = 0
    @State private var earlyOfferTriggered = false
    @State private var showOfferSection = false
    @State private var showPauseSection = false
    @State private var selectedPauseOptionId: Int? = nil
    @State private var isPauseLoading = false
    @State private var pauseExpanded = false
    @State private var confettiTrigger = 0
    @State private var heroAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Derived from path
    private var currentQuestionIndex: Int {
        switch path.last {
        case .question(let idx): return idx
        case .retention:
            // Last question answered before retention
            for step in path.reversed() {
                if case .question(let idx) = step { return idx }
            }
            return 0
        case nil: return 0 // root = question 0
        }
    }

    private var showingRetention: Bool {
        path.last == .retention
    }

    private var hasRetentionPage: Bool {
        (config.offer?.enabled == true) || (config.pause?.enabled == true)
    }

    private var totalSteps: Int {
        if earlyOfferTriggered {
            return (currentQuestionIndex + 1) + 1
        }
        let questionSteps = config.questions.count
        let retentionStep = hasRetentionPage ? 1 : 0
        return questionSteps + retentionStep
    }

    private var currentStep: Int {
        if showingRetention {
            if earlyOfferTriggered {
                return currentQuestionIndex + 1
            }
            return config.questions.count
        }
        return currentQuestionIndex
    }

    private func canContinue(questionIndex: Int) -> Bool {
        guard questionIndex < config.questions.count else { return false }
        let question = config.questions[questionIndex]
        switch question.questionType {
        case .singleSelect:
            return pendingSelections[questionIndex] != nil || !question.isRequired
        case .freeText:
            let text = pendingFreeText[questionIndex] ?? ""
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !question.isRequired
        }
    }

    var body: some View {
        ZStack {
            NavigationStack(path: $path) {
                stepContent(for: .question(index: 0))
                    .navigationDestination(for: CancelFlowStep.self) { step in
                        stepContent(for: step)
                    }
            }
            .onChange(of: path) { oldPath, newPath in
                guard newPath.count < oldPath.count else { return }
                // A pop occurred — run cleanup
                guard let popped = oldPath.last else { return }
                switch popped {
                case .retention:
                    offerShown = false
                    pauseShown = false
                    showOfferSection = false
                    showPauseSection = false
                    earlyOfferTriggered = false
                    selectedPauseOptionId = nil
                    pauseExpanded = false
                    heroAppeared = false
                    if !answers.isEmpty { answers.removeLast() }
                case .question(let idx):
                    // Restore the previous question's pending answer
                    if !answers.isEmpty {
                        let removed = answers.removeLast()
                        let prevIdx = idx - 1
                        if prevIdx >= 0 {
                            if let optionId = removed.selectedOptionId {
                                pendingSelections[prevIdx] = optionId
                            }
                            if let text = removed.freeText {
                                pendingFreeText[prevIdx] = text
                            }
                        }
                    }
                }
            }

            ConfettiCannon(
                trigger: $confettiTrigger,
                num: 50,
                openingAngle: .degrees(40),
                closingAngle: .degrees(140),
                radius: 300
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Per-Step Content

    @ViewBuilder
    private func stepContent(for step: CancelFlowStep) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    switch step {
                    case .question(let index):
                        if index < config.questions.count {
                            questionView(question: config.questions[index], index: index)
                        }
                    case .retention:
                        retentionView
                    }
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                switch step {
                case .question(let index):
                    questionButtons(index: index)
                case .retention:
                    retentionButtons
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(step == .question(index: 0))
        .toolbar {
            ToolbarItem(placement: .principal) {
                progressDots
            }
        }
    }

    // MARK: - Question Buttons

    @ViewBuilder
    private func questionButtons(index: Int) -> some View {
        Button {
            advanceToNext(fromIndex: index)
        } label: {
            Text("Continue")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    canContinue(questionIndex: index) ? Color.green : Color.green.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
        }
        .disabled(!canContinue(questionIndex: index))
        .accessibilityHint("Proceeds to the next step")

        Button {
            finish(result: .cancelled)
        } label: {
            Text("Skip and cancel subscription")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityHint("Skips remaining questions and cancels your subscription")
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { step in
                Capsule()
                    .fill(
                        step == currentStep
                            ? AnyShapeStyle(LinearGradient(colors: [.green, .teal], startPoint: .leading, endPoint: .trailing))
                            : step < currentStep
                                ? AnyShapeStyle(Color.green.opacity(0.5))
                                : AnyShapeStyle(Color(.systemGray4).opacity(0.6))
                    )
                    .frame(width: step == currentStep ? 28 : 8, height: 8)
                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: currentStep)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(currentStep + 1) of \(totalSteps)")
    }

    // MARK: - Question View

    @ViewBuilder
    private func questionView(question: CancelFlow.Question, index: Int) -> some View {
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
                singleSelectView(question: question, index: index)
            case .freeText:
                freeTextView(index: index)
            }
        }
    }

    private func singleSelectView(question: CancelFlow.Question, index: Int) -> some View {
        VStack(spacing: 12) {
            ForEach(question.options) { option in
                let isSelected = pendingSelections[index] == option.id
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        pendingSelections[index] = option.id
                    }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    optionRowLabel(option: option, isSelected: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel([option.label, option.subtitle].compactMap { $0 }.joined(separator: ", "))
                .accessibilityValue(isSelected ? "Selected" : "")
                .accessibilityAddTraits(.isButton)
            }
        }
    }

    private func optionRowLabel(option: CancelFlow.Option, isSelected: Bool) -> some View {
        let fillColor: Color = isSelected ? Color.green.opacity(0.08) : Color(.secondarySystemGroupedBackground)
        let strokeColor: Color = isSelected ? Color.green.opacity(0.5) : Color(.systemGray3).opacity(0.6)
        let strokeWidth: CGFloat = isSelected ? 2 : 1

        return HStack(spacing: 14) {
            if let iconName = option.iconName {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.green : .secondary)
                    .frame(width: 44, height: 44)
                    .background(
                        (isSelected ? Color.green.opacity(0.12) : Color(.systemGray4).opacity(0.25)),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                if let subtitle = option.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.green)
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(strokeColor, lineWidth: strokeWidth)
        )
    }

    private func freeTextView(index: Int) -> some View {
        TextEditor(text: Binding(
            get: { pendingFreeText[index] ?? "" },
            set: { pendingFreeText[index] = $0 }
        ))
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(12)
        .frame(minHeight: 120)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Your feedback")
        .accessibilityHint("Enter your reason for cancelling")
    }

    // MARK: - Retention View (Offer + Pause)

    @ViewBuilder
    private var retentionView: some View {
        let _ = ZSLogger.info("[CancelFlow] retentionView — showOffer=\(showOfferSection), showPause=\(showPauseSection), earlyTrigger=\(earlyOfferTriggered), pauseOptions=\(config.pause?.options.count ?? 0)", category: .cancelFlow)
        VStack(spacing: 20) {
            // Hero gradient banner
            if showOfferSection, let offer = config.offer {
                heroBanner(title: offer.title)
            } else if showPauseSection, let pauseConfig = config.pause {
                heroBanner(title: pauseConfig.title)
            }

            // Offer section (only if this path's trigger includes offer)
            if showOfferSection, let offer = config.offer {
                offerSection(offer: offer)
                    .offset(y: heroAppeared ? 0 : 30)
                    .opacity(heroAppeared ? 1 : 0)
                    .animation(reduceMotion ? .none : .spring(response: 0.6).delay(0.15), value: heroAppeared)
            }

            // Pause body text (only when pause is the sole section)
            if showPauseSection, !showOfferSection, let pauseConfig = config.pause {
                Text(pauseConfig.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .offset(y: heroAppeared ? 0 : 20)
                    .opacity(heroAppeared ? 1 : 0)
                    .animation(reduceMotion ? .none : .spring(response: 0.6).delay(0.12), value: heroAppeared)
            }

            // Pause section (only if this path's trigger includes pause)
            if showPauseSection, let pauseConfig = config.pause, !pauseConfig.options.isEmpty {
                pauseSection(pauseConfig: pauseConfig)
                    .offset(y: heroAppeared ? 0 : 40)
                    .opacity(heroAppeared ? 1 : 0)
                    .animation(reduceMotion ? .none : .spring(response: 0.6).delay(showOfferSection ? 0.25 : 0.15), value: heroAppeared)
            }
        }
        .onAppear {
            // Auto-expand pause when it's the only section
            if showPauseSection, !showOfferSection {
                pauseExpanded = true
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                heroAppeared = true
            }
        }
    }

    private func heroBanner(title: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 140)

            VStack(spacing: 10) {
                Image(systemName: "heart.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .scaleEffect(heroAppeared ? 1.0 : 0.8)
                    .opacity(heroAppeared ? 1 : 0)
                    .animation(reduceMotion ? .none : .spring(response: 0.6, dampingFraction: 0.7), value: heroAppeared)

                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .offset(y: heroAppeared ? 0 : 10)
                    .opacity(heroAppeared ? 1 : 0)
                    .animation(reduceMotion ? .none : .spring(response: 0.6).delay(0.08), value: heroAppeared)
            }
            .padding(.horizontal, 20)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private func offerSection(offer: CancelFlow.Offer) -> some View {
        let product = ZeroSettle.shared.product(for: productId)
        let currentPrice = product?.webPrice ?? product?.storeKitPrice
        let discountPercent = Int(offer.value) ?? 0

        return VStack(spacing: 0) {
            // TODO: Re-enable exclusive offer badge
//            HStack {
//                HStack(spacing: 6) {
//                    Image(systemName: "tag.fill")
//                        .font(.caption2)
//                    Text("EXCLUSIVE OFFER")
//                        .font(.system(size: 10, weight: .heavy))
//                        .tracking(0.5)
//                }
//                .foregroundStyle(.white)
//                .padding(.horizontal, 14)
//                .padding(.vertical, 6)
//                .background(
//                    LinearGradient(colors: [.green, .teal], startPoint: .leading, endPoint: .trailing),
//                    in: Capsule()
//                )
//                Spacer()
//            }
//            .padding(.bottom, 14)

            // Body text
            Text(offer.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 20)

            // Side-by-side price comparison
            if let price = currentPrice, discountPercent > 0 {
                let discountedCents = Int((Double(price.amountCents) * Double(100 - discountPercent) / 100.0).rounded())
                let discountedPrice = Price(amountCents: discountedCents, currencyCode: price.currencyCode)
                let period: String = {
                    guard product?.type == .autoRenewableSubscription else { return "" }
                    switch product?.billingInterval {
                    case "week": return "/ week"
                    case "year": return "/ year"
                    default: return "/ month"
                    }
                }()

                HStack(spacing: 0) {
                    // Original price
                    VStack(spacing: 4) {
                        Text("Current")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(price.formatted)
                            .font(.title3)
                            .strikethrough(color: .secondary.opacity(0.6))
                            .foregroundStyle(.secondary)
                        Text(period)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)

                    // Discounted price
                    VStack(spacing: 4) {
                        Text("Your price")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                        Text(discountedPrice.formatted)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.green)
                        Text(period)
                            .font(.caption2)
                            .foregroundStyle(.green.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.green.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.green.opacity(0.2), lineWidth: 1)
                )

                // Duration callout
                if let months = offer.durationMonths {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .font(.caption2)
                        Text("\(discountPercent)% off for \(months) month\(months == 1 ? "" : "s"), then regular price")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .accessibilityElement(children: .combine)
        .onAppear {
            ZSLogger.debug("offerSection appeared: type=\(offer.type.rawString), value=\(offer.value), productId=\(productId), productFound=\(product != nil), price=\(currentPrice?.formatted ?? "nil"), discountPercent=\(discountPercent)", category: .cancelFlow)
        }
    }

    private func pauseSection(pauseConfig: CancelFlow.PauseConfig) -> some View {
        VStack(spacing: 16) {
            // Tappable header
            Button {
                pauseExpanded.toggle()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.title2)
                        .foregroundStyle(pauseExpanded ? Color.blue : .secondary)
                        .frame(width: 52, height: 52)
                        .background(
                            Color.blue.opacity(pauseExpanded ? 0.12 : 0.06),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .animation(.snappy(duration: 0.35), value: pauseExpanded)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(pauseConfig.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(pauseConfig.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(pauseExpanded ? 180 : 0))
                        .animation(.snappy(duration: 0.35), value: pauseExpanded)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(pauseConfig.title), \(pauseConfig.body)")
            .accessibilityHint(pauseExpanded ? "Collapses pause duration options" : "Expands pause duration options")
            .accessibilityAddTraits(.isButton)

            // Expandable pause duration options with radio buttons
            if pauseExpanded {
                VStack(spacing: 10) {
                    let sortedOptions = pauseConfig.options.sorted { $0.order < $1.order }
                    ForEach(sortedOptions) { option in
                        pauseOptionRow(option: option)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.35), value: pauseExpanded)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func pauseOptionRow(option: CancelFlow.PauseOption) -> some View {
        let isSelected = selectedPauseOptionId == option.id
        let fillColor: Color = isSelected ? Color.blue.opacity(0.08) : .clear
        let strokeColor: Color = isSelected ? Color.blue.opacity(0.3) : Color(.systemGray4).opacity(0.5)

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedPauseOptionId = option.id
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 14) {
                // Radio-style indicator
                Circle()
                    .fill(isSelected ? Color.blue : Color.clear)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle().stroke(isSelected ? Color.blue : Color(.systemGray3), lineWidth: 2)
                    )
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }

                Text(option.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fillColor))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(strokeColor, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pause for \(option.label)")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Retention Buttons

    @ViewBuilder
    private var retentionButtons: some View {
        // Primary CTA: Accept Offer (full width)
        if showOfferSection, let offer = config.offer {
            Button {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                confettiTrigger += 1
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    finish(result: .retained, offerAccepted: true)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                    Text(offer.ctaText)
                        .font(.body.weight(.bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    LinearGradient(colors: [.green, .teal], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .shadow(color: .green.opacity(0.3), radius: 12, y: 6)
            }
            .disabled(isPauseLoading)
            .accessibilityHint("Accepts the offer and keeps your subscription")
        }

        // Secondary CTA: Pause (only when expanded and a duration is selected)
        if showPauseSection, let pauseConfig = config.pause, !pauseConfig.options.isEmpty, pauseExpanded {
            Button {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                submitPause()
            } label: {
                HStack(spacing: 8) {
                    if isPauseLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "moon.zzz.fill")
                            .font(.subheadline)
                        Text(pauseConfig.ctaText)
                            .font(.body.weight(.semibold))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    selectedPauseOptionId != nil ? Color.blue : Color.blue.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .disabled(selectedPauseOptionId == nil || isPauseLoading)
            .accessibilityLabel(isPauseLoading ? "Processing" : pauseConfig.ctaText)
            .accessibilityHint("Pauses your subscription for the selected duration")
        }

        // Cancel link (centered)
        Button {
            finish(result: .cancelled)
        } label: {
            Text("No thanks, cancel")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .disabled(isPauseLoading)
        .accessibilityHint("Cancels your subscription without accepting any offers")
    }

    // MARK: - Flow Logic

    private func advanceToNext(fromIndex index: Int) {
        guard index < config.questions.count else { return }
        let question = config.questions[index]

        // Record answer
        let answer: CancelFlow.AnswerPayload
        switch question.questionType {
        case .singleSelect:
            answer = CancelFlow.AnswerPayload(
                questionId: question.id,
                selectedOptionId: pendingSelections[index],
                freeText: nil
            )
        case .freeText:
            let text = (pendingFreeText[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            answer = CancelFlow.AnswerPayload(
                questionId: question.id,
                selectedOptionId: nil,
                freeText: text.isEmpty ? nil : text
            )
        }
        answers.append(answer)

        // Check if selected option triggers offer/pause and there's a retention page.
        // Per-option flags determine which sections to show on the retention page.
        if question.questionType == .singleSelect,
           let optionId = pendingSelections[index],
           let option = question.options.first(where: { $0.id == optionId }),
           (option.triggersOffer || option.triggersPause),
           hasRetentionPage {
            earlyOfferTriggered = true
            showOfferSection = option.triggersOffer && config.offer?.enabled == true
            showPauseSection = option.triggersPause && config.pause?.enabled == true
            offerShown = showOfferSection
            pauseShown = showPauseSection
            lastStepSeen = config.questions.count
            path.append(.retention)
            return
        }

        // Move to next question
        let nextIndex = index + 1
        if nextIndex < config.questions.count {
            lastStepSeen = max(lastStepSeen, nextIndex)
            path.append(.question(index: nextIndex))
        } else {
            // Last question answered, no trigger — show all enabled sections
            if hasRetentionPage {
                showOfferSection = config.offer?.enabled == true
                showPauseSection = config.pause?.enabled == true
                offerShown = showOfferSection
                pauseShown = showPauseSection
                lastStepSeen = config.questions.count
                path.append(.retention)
            } else {
                finish(result: .cancelled)
            }
        }
    }

    private func submitPause() {
        guard let pauseOptionId = selectedPauseOptionId else { return }
        let selectedOption = config.pause?.options.first { $0.id == pauseOptionId }
        let durationDays = selectedOption?.durationDays
        isPauseLoading = true

        Task {
            do {
                let response = try await backend.pauseSubscription(
                    productId: productId,
                    userId: userId,
                    pauseDurationDays: durationDays
                )

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
                    ZSLogger.error("Failed to pause subscription from cancel flow: \(error)", category: .cancelFlow)
                    // Still dismiss — the cancel flow response payload records the intent
                    finish(
                        result: .paused(resumesAt: nil),
                        pauseAccepted: true,
                        pauseDurationDays: durationDays
                    )
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
        case .cancelled: return CancelFlow.Outcome.cancelled.rawValue
        case .retained: return CancelFlow.Outcome.retained.rawValue
        case .paused: return CancelFlow.Outcome.paused.rawValue
        case .dismissed: return CancelFlow.Outcome.dismissed.rawValue
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

