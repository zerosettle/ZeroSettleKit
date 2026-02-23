//
//  UpgradeOfferSheet.swift
//  ZeroSettleKit
//
//  Native SwiftUI upgrade offer sheet and presentation helpers.
//

import Foundation
import SwiftUI
import UIKit

#if canImport(ZeroSettleCore)
internal import ZeroSettleCore
#endif

// MARK: - Upgrade Offer Presenter

/// Handles UIHostingController presentation for the upgrade offer sheet.
internal final class UpgradeOfferPresenter: NSObject, @unchecked Sendable {

    private var hostingController: UIHostingController<AnyView>?
    private var continuation: CheckedContinuation<UpgradeOffer.Result, Never>?
    private var hasResumed = false

    /// Present the upgrade offer sheet and await its result.
    @MainActor
    func present(
        config: UpgradeOffer.Config,
        userId: String,
        backend: Backend
    ) async -> UpgradeOffer.Result {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            ZSLogger.error("Unable to find root view controller for upgrade offer", category: .iap)
            return .dismissed
        }

        var topController = rootViewController
        while let presented = topController.presentedViewController {
            topController = presented
        }

        hasResumed = false

        return await withCheckedContinuation { (cont: CheckedContinuation<UpgradeOffer.Result, Never>) in
            self.continuation = cont

            let sheet = UpgradeOfferSheetView(
                config: config,
                userId: userId,
                backend: backend
            ) { [weak self] result in
                guard let self, !self.hasResumed else { return }
                self.hasResumed = true

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

extension UpgradeOfferPresenter: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard !hasResumed else { return }
        hasResumed = true
        continuation?.resume(returning: .dismissed)
        continuation = nil
        hostingController = nil
    }
}

// MARK: - UpgradeOfferSheetView

/// Internal SwiftUI view for the upgrade offer sheet.
private struct UpgradeOfferSheetView: View {
    let config: UpgradeOffer.Config
    let userId: String
    let backend: Backend
    let onComplete: (UpgradeOffer.Result) -> Void

    @State private var isLoading = false
    @State private var errorMessage: String?

    private var currentProduct: UpgradeOffer.ProductInfo? { config.currentProduct }
    private var targetProduct: UpgradeOffer.ProductInfo? { config.targetProduct }
    private var display: UpgradeOffer.Display? { config.display }
    private var isStorekitMigration: Bool { config.upgradeType == .storekitToWeb }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Button {
                    onComplete(.dismissed)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.quaternary, in: Circle())
                }

                Spacer()

                // Invisible spacer for symmetry
                Color.clear.frame(width: 30, height: 30)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Content
            ScrollView {
                VStack(spacing: 20) {
                    // Icon
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.green)
                        .padding(.top, 12)

                    // Title
                    Text(display?.title ?? "Upgrade & Save")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)

                    // Savings badge
                    if let savings = config.savingsPercent, savings > 0 {
                        Text("Save \(savings)%")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(.green, in: Capsule())
                    }

                    // Body text
                    if let bodyText = isStorekitMigration ? display?.storekitMigrationBody : display?.body {
                        Text(bodyText)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                    }

                    // Plan comparison
                    if let current = currentProduct, let target = targetProduct {
                        planComparison(current: current, target: target)
                    }

                    // Proration info
                    if let proration = config.proration, config.upgradeType == .webToWeb {
                        prorationInfo(proration)
                    }

                    // StoreKit cancel instructions
                    if isStorekitMigration, let instructions = display?.storekitCancelInstructions {
                        cancelInstructionsBanner(instructions)
                    }

                    // Error message
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 20)
            }

            Spacer(minLength: 16)

            // Bottom buttons
            VStack(spacing: 12) {
                // CTA button
                Button {
                    executeUpgrade()
                } label: {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.green.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        Text(display?.ctaText ?? "Upgrade Now")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.green, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .disabled(isLoading)

                // Dismiss button
                Button {
                    onComplete(.declined)
                } label: {
                    Text(display?.dismissText ?? "No Thanks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .disabled(isLoading)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Plan Comparison

    private func planComparison(current: UpgradeOffer.ProductInfo, target: UpgradeOffer.ProductInfo) -> some View {
        VStack(spacing: 0) {
            // Current plan
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current Plan")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(current.name)
                        .font(.body.weight(.medium))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(current.price.formatted)
                        .font(.body.weight(.semibold))
                    Text(current.billingLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)

            Divider()

            // Target plan
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Upgrade To")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(target.name)
                        .font(.body.weight(.medium))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(target.price.formatted)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.green)
                    if let monthly = target.monthlyEquivalent {
                        Text("\(monthly.formatted)/mo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(target.billingLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Proration Info

    private func prorationInfo(_ proration: UpgradeOffer.Proration) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                if proration.amountCents < 0 {
                    Text("You'll receive a \(Price(amountCents: abs(proration.amountCents), currencyCode: proration.currency).formatted) credit")
                        .font(.caption)
                } else if proration.amountCents > 0 {
                    Text("Prorated charge: \(Price(amountCents: proration.amountCents, currencyCode: proration.currency).formatted)")
                        .font(.caption)
                } else {
                    Text("No additional charge — your existing balance covers the upgrade")
                        .font(.caption)
                }

                if let nextDate = proration.nextBillingDate {
                    HStack(spacing: 0) {
                        Text("Next billing: ")
                        Text(nextDate, style: .date)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(12)
        .background(Color(.systemBlue).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - StoreKit Cancel Instructions

    private func cancelInstructionsBanner(_ instructions: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)

            Text(instructions)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(.systemOrange).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Execute Upgrade

    private func executeUpgrade() {
        guard let current = currentProduct, let target = targetProduct else { return }
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let request = UpgradeOffer.ExecuteRequest(
                    userId: userId,
                    currentProductId: current.referenceId,
                    targetProductId: target.referenceId
                )
                let response = try await backend.executeUpgradeOffer(request)

                await MainActor.run {
                    isLoading = false
                    if response.success {
                        onComplete(.upgraded)
                    } else {
                        errorMessage = "Upgrade could not be completed. Please try again."
                    }
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "Something went wrong. Please try again."
                    ZSLogger.error("Failed to execute upgrade: \(error)", category: .iap)
                }
            }
        }
    }

}

// MARK: - SwiftUI Modifier

/// Adds an upgrade offer sheet to a SwiftUI view.
private struct UpgradeOfferModifier: ViewModifier {
    @Binding var isPresented: Bool
    let productId: String?
    let userId: String
    let onResult: (UpgradeOffer.Result) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, newValue in
                if newValue {
                    Task { @MainActor in
                        let result = await ZeroSettle.shared.presentUpgradeOffer(
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
    /// Present the ZeroSettle upgrade offer sheet.
    ///
    /// When `isPresented` becomes `true`, the SDK fetches the upgrade offer
    /// configuration from the backend and presents the native offer sheet.
    ///
    /// - Parameters:
    ///   - isPresented: Binding that controls sheet presentation
    ///   - productId: Optional product to check upgrade for
    ///   - userId: Your app's user identifier
    ///   - onResult: Called with the outcome when the flow completes
    public func upgradeOffer(
        isPresented: Binding<Bool>,
        productId: String? = nil,
        userId: String,
        onResult: @escaping (UpgradeOffer.Result) -> Void = { _ in }
    ) -> some View {
        modifier(UpgradeOfferModifier(
            isPresented: isPresented,
            productId: productId,
            userId: userId,
            onResult: onResult
        ))
    }
}
