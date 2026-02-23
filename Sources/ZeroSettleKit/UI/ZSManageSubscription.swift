//
//  ZSManageSubscription.swift
//  ZeroSettleKit
//
//  SwiftUI modifier for presenting subscription management UI.
//

import SwiftUI

// MARK: - Manage Subscription Modifier

/// Presents subscription management UI when `isPresented` becomes true.
/// Routes to either Stripe customer portal or Apple's native management
/// based on the user's entitlement sources.
private struct ManageSubscriptionModifier: ViewModifier {
    @Binding var isPresented: Bool
    let userId: String

    func body(content: Content) -> some View {
        content
            .task(id: isPresented) {
                guard isPresented else { return }
                defer { isPresented = false }
                try? await ZeroSettle.shared.showManageSubscription(userId: userId)
            }
    }
}

// MARK: - View Extension

extension View {
    /// Presents subscription management UI when `isPresented` is true.
    ///
    /// Routes automatically based on entitlement sources:
    /// - Web checkout entitlements → Stripe customer portal (SFSafariViewController)
    /// - StoreKit-only entitlements → Apple's native subscription management
    /// - Both sources → Stripe customer portal
    ///
    /// Entitlements are automatically refreshed when the management UI is dismissed.
    ///
    ///     @State private var showManage = false
    ///
    ///     Button("Manage Subscription") { showManage = true }
    ///         .manageSubscription(isPresented: $showManage, userId: "user_123")
    ///
    /// - Parameters:
    ///   - isPresented: Binding that triggers presentation when set to `true`.
    ///     Automatically reset to `false` when done.
    ///   - userId: Your app's user identifier
    public func manageSubscription(
        isPresented: Binding<Bool>,
        userId: String
    ) -> some View {
        modifier(ManageSubscriptionModifier(
            isPresented: isPresented,
            userId: userId
        ))
    }
}
