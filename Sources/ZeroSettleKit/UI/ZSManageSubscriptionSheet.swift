//
//  ZSManageSubscriptionSheet.swift
//  ZeroSettleKit
//
//  A multi-page cancellation retention funnel that walks users through
//  confirmation, a questionnaire, a discount offer, and a pause option
//  before allowing final cancellation.
//

import SwiftUI

// MARK: - Result

/// The user's choice from the manage subscription sheet.
public enum ZSManageSubscriptionResult {
    case pauseAccount
    case stayWithDiscount
    case cancelSubscription
    case dismissed
}

// MARK: - Sheet View

/// A multi-page retention sheet that walks users through confirmation,
/// a questionnaire, a discount offer, and a pause option before cancellation.
///
/// Present via the `.zsManageSubscriptionSheet(isPresented:onResult:)` modifier
/// or `ZSManageSubscriptionSheet.present(from:onResult:)` for UIKit.
public struct ZSManageSubscriptionSheet: View {

    // MARK: - Phase State Machine

    private enum SheetPhase: Hashable {
        case confirmation
        case questionnaire
        case offer
        case pause
        case discountSuccess
        case pauseSuccess
    }

    private static let reasons = [
        "Too expensive for how often I dive",
        "I'm not diving enough right now",
        "Reports aren't accurate for my area",
        "I switched to another dive app",
        "Other",
    ]

    // Ocean palette
    private static let teal = Color(red: 0.0, green: 0.72, blue: 0.76)
    private static let tealLight = Color(red: 0.0, green: 0.72, blue: 0.76).opacity(0.10)
    private static let deepBlue = Color(red: 0.05, green: 0.20, blue: 0.42)

    private let onResult: (ZSManageSubscriptionResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var phase: SheetPhase = .confirmation
    @State private var selectedReason: String? = nil
    @State private var confettiTrigger: Int = 0

    public init(onResult: @escaping (ZSManageSubscriptionResult) -> Void) {
        self.onResult = onResult
    }

    private var isSuccessScreen: Bool {
        phase == .discountSuccess || phase == .pauseSuccess
    }

    public var body: some View {
        Group {
            switch phase {
            case .confirmation:
                confirmationView.transition(.opacity)
            case .questionnaire:
                questionnaireView.transition(.opacity)
            case .offer:
                offerView.transition(.opacity)
            case .pause:
                pauseView.transition(.opacity)
            case .discountSuccess:
                discountSuccessView.transition(.opacity)
            case .pauseSuccess:
                pauseSuccessView.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .topTrailing) {
            if !isSuccessScreen {
                Button {
                    dismiss()
                    onResult(.dismissed)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.top, 14)
                .padding(.trailing, 18)
            }
        }
        .overlay(alignment: .bottom) {
            Text("Powered by ZeroSettle")
                .font(.caption2)
                .foregroundStyle(Color(.quaternaryLabel))
                .padding(.bottom, 2)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(true)
    }

    // MARK: - 1. Confirmation View

    private var confirmationView: some View {
        VStack(spacing: 0) {
            // Hero banner
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Self.teal.opacity(0.14), Self.teal.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Self.teal.opacity(0.15))
                            .frame(width: 64, height: 64)

                        Image(systemName: "water.waves")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(Self.teal)
                    }

                    Text("DiveGenius Pro")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Self.teal)
                        .textCase(.uppercase)
                        .tracking(1.2)
                }
                .padding(.vertical, 24)
            }
            .frame(height: 140)
            .padding(.horizontal, 20)
            .padding(.top, 48)

            // Title + subtitle
            VStack(spacing: 8) {
                Text("Cancel DiveGenius Pro?")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("You'll lose access to real-time dive visibility reports and condition alerts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 20)

            // Feature loss cards
            VStack(spacing: 10) {
                featureRow(icon: "eye.fill", title: "Visibility Forecasts", subtitle: "7-day clarity & depth reports")
                featureRow(icon: "location.fill", title: "Site Conditions", subtitle: "Current, surge & temp at 200+ sites")
                featureRow(icon: "bell.badge.fill", title: "Dive Alerts", subtitle: "Get notified when visibility is good")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            // Social proof stat
            HStack(spacing: 6) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Self.teal)

                Text("You checked visibility 47 times this month")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)

            Spacer()

            VStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        phase = .questionnaire
                    }
                } label: {
                    Text("I still want to cancel")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                    onResult(.dismissed)
                } label: {
                    Text("Keep My Reports")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Self.teal, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
    }

    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Self.teal)
                .frame(width: 36, height: 36)
                .background(Self.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: - 2. Questionnaire View

    private var questionnaireView: some View {
        VStack(spacing: 0) {
            // Header icon
            ZStack {
                Circle()
                    .fill(Self.teal.opacity(0.10))
                    .frame(width: 56, height: 56)

                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Self.teal)
            }
            .padding(.top, 48)

            VStack(spacing: 8) {
                Text("Before you go")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("What's your main reason for cancelling?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 14)
            .padding(.horizontal, 20)

            // Radio options card
            VStack(spacing: 0) {
                ForEach(Array(Self.reasons.enumerated()), id: \.offset) { index, reason in
                    if index > 0 {
                        Divider().padding(.leading, 52)
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedReason = reason
                        }
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .strokeBorder(
                                        selectedReason == reason ? Self.teal : Color(.separator),
                                        lineWidth: selectedReason == reason ? 6 : 1.5
                                    )
                                    .frame(width: 22, height: 22)
                            }

                            Text(reason)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = .offer
                }
            } label: {
                Text("Continue")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        Self.teal.opacity(selectedReason == nil ? 0.35 : 1.0),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .disabled(selectedReason == nil)
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
    }

    // MARK: - 3. Offer View

    private var offerView: some View {
        VStack(spacing: 0) {
            Spacer()

            // Badge
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 72, height: 72)

                Image(systemName: "tag.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 8) {
                Text("Save 40% on DiveGenius Pro")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("Keep your visibility reports for just **$2.99/mo** for the next 3 months — less than a tank fill.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 18)

            // Value reminder
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)

                Text("Pro members dive on 3x more good-visibility days")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)

            Spacer()

            VStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        phase = .discountSuccess
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        confettiTrigger += 1
                    }
                } label: {
                    Text("Save 40%")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.green, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        phase = .pause
                    }
                } label: {
                    Text("No thanks, I want to cancel")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
    }

    // MARK: - 4. Pause View

    private var pauseView: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(Self.teal.opacity(0.12))
                    .frame(width: 72, height: 72)

                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Self.teal)
            }

            VStack(spacing: 8) {
                Text("Not diving season?")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("Pause your account and we'll keep your saved sites, alerts, and history safe until you're ready to dive again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 18)

            Spacer()

            VStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        phase = .pauseSuccess
                    }
                } label: {
                    Text("Pause My Account")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Self.teal, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                    onResult(.cancelSubscription)
                } label: {
                    Text("No thanks, cancel my subscription")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
    }

    // MARK: - 5. Discount Success View

    private var discountSuccessView: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("\u{1F389}")
                .font(.system(size: 56))
                .confettiCannon(trigger: $confettiTrigger, num: 50, openingAngle: Angle(degrees: 0), closingAngle: Angle(degrees: 360), radius: 200)

            VStack(spacing: 8) {
                Text("You're saving 40%!")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("Your discount kicks in on the next billing cycle. Now get out there — visibility is looking great this week.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer()

            Button {
                dismiss()
                onResult(.stayWithDiscount)
            } label: {
                Text("Back to DiveGenius")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
    }

    // MARK: - 6. Pause Success View

    private var pauseSuccessView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Self.teal.opacity(0.12))
                    .frame(width: 80, height: 80)

                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Self.teal)
            }

            VStack(spacing: 8) {
                Text("Account Paused")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("Your saved dive sites and history are safe. We'll be here when you're ready to dive again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            Spacer()

            Button {
                dismiss()
                onResult(.pauseAccount)
            } label: {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Self.teal, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
    }
}

// MARK: - SwiftUI View Modifier

private struct ZSManageSubscriptionSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onResult: (ZSManageSubscriptionResult) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            ZSManageSubscriptionSheet { result in
                isPresented = false
                onResult(result)
            }
        }
    }
}

extension View {
    /// Presents the manage subscription retention sheet when `isPresented` is true.
    public func zsManageSubscriptionSheet(
        isPresented: Binding<Bool>,
        onResult: @escaping (ZSManageSubscriptionResult) -> Void
    ) -> some View {
        modifier(ZSManageSubscriptionSheetModifier(
            isPresented: isPresented,
            onResult: onResult
        ))
    }
}

// MARK: - UIKit Presentation

extension ZSManageSubscriptionSheet {
    /// Present the manage subscription sheet from a UIKit view controller.
    @MainActor
    public static func present(
        from viewController: UIViewController,
        onResult: @escaping (ZSManageSubscriptionResult) -> Void
    ) {
        let bridge = UIKitManageSubscriptionBridge(
            onResult: onResult,
            onDismissed: {
                viewController.dismiss(animated: false)
            }
        )

        let hosting = UIHostingController(rootView: bridge)
        hosting.view.backgroundColor = .clear
        hosting.modalPresentationStyle = .overFullScreen
        viewController.present(hosting, animated: false)
    }
}

/// Transparent bridge that presents `ZSManageSubscriptionSheet` via SwiftUI's `.sheet()`
/// so `.presentationDetents` works correctly when called from UIKit.
private struct UIKitManageSubscriptionBridge: View {
    let onResult: (ZSManageSubscriptionResult) -> Void
    let onDismissed: () -> Void

    @State private var showSheet = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $showSheet, onDismiss: onDismissed) {
                ZSManageSubscriptionSheet(onResult: onResult)
            }
    }
}

// MARK: - Preview

#if DEBUG
struct ZSManageSubscriptionSheet_Previews: PreviewProvider {
    static var previews: some View {
        ZSManageSubscriptionSheet { result in
            print("Result: \(result)")
        }
    }
}
#endif
