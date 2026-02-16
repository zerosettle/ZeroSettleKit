//
//  ZSSaveTheSaleSheet.swift
//  ZeroSettleKit
//
//  A retention sheet that presents users with two options when they're
//  about to cancel: Pause Account or Stay for 40% Off.
//

import SwiftUI

// MARK: - Result

/// The user's choice from the save-the-sale sheet.
public enum ZSSaveTheSaleResult {
    case pauseAccount
    case stayWithDiscount
    case dismissed
}

// MARK: - Sheet View

/// A retention sheet with two option cards: Pause Account and Stay & Save 40%.
///
/// Present via the `.zsSaveTheSaleSheet(isPresented:onResult:)` modifier
/// or `ZSSaveTheSaleSheet.present(from:onResult:)` for UIKit.
public struct ZSSaveTheSaleSheet: View {

    private let onResult: (ZSSaveTheSaleResult) -> Void

    @Environment(\.dismiss) private var dismiss

    public init(onResult: @escaping (ZSSaveTheSaleResult) -> Void) {
        self.onResult = onResult
    }

    public var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 6) {
                Text("We'd hate to see you go!")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Choose an option below")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            // Option cards
            VStack(spacing: 12) {
                // Pause Account
                optionCard(
                    icon: "pause.circle.fill",
                    title: "Pause Account",
                    description: "Take a break. We'll keep your data safe and you can come back anytime.",
                    highlighted: false
                ) {
                    dismiss()
                    onResult(.pauseAccount)
                }

                // Stay & Save 40%
                optionCard(
                    icon: "tag.fill",
                    title: "Stay & Save 40%",
                    description: "Get 40% off your next billing cycle. Same features, better price.",
                    highlighted: true
                ) {
                    dismiss()
                    onResult(.stayWithDiscount)
                }
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .topTrailing) {
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
        .presentationDetents([.height(420)])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(false)
    }

    // MARK: - Option Card

    private func optionCard(
        icon: String,
        title: String,
        description: String,
        highlighted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(highlighted ? .white : .accentColor)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(highlighted ? .white : .primary)

                    Text(description)
                        .font(.caption)
                        .foregroundStyle(highlighted ? .white.opacity(0.85) : .secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(highlighted ? Color.accentColor : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(highlighted ? Color.clear : Color(.separator), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SwiftUI View Modifier

private struct ZSSaveTheSaleSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onResult: (ZSSaveTheSaleResult) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            ZSSaveTheSaleSheet { result in
                isPresented = false
                onResult(result)
            }
        }
    }
}

extension View {
    /// Presents the save-the-sale retention sheet when `isPresented` is true.
    public func zsSaveTheSaleSheet(
        isPresented: Binding<Bool>,
        onResult: @escaping (ZSSaveTheSaleResult) -> Void
    ) -> some View {
        modifier(ZSSaveTheSaleSheetModifier(
            isPresented: isPresented,
            onResult: onResult
        ))
    }
}

// MARK: - UIKit Presentation

extension ZSSaveTheSaleSheet {
    /// Present the save-the-sale sheet from a UIKit view controller.
    @MainActor
    public static func present(
        from viewController: UIViewController,
        onResult: @escaping (ZSSaveTheSaleResult) -> Void
    ) {
        let bridge = UIKitSaveTheSaleBridge(
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

/// Transparent bridge that presents `ZSSaveTheSaleSheet` via SwiftUI's `.sheet()`
/// so `.presentationDetents` works correctly when called from UIKit.
private struct UIKitSaveTheSaleBridge: View {
    let onResult: (ZSSaveTheSaleResult) -> Void
    let onDismissed: () -> Void

    @State private var showSheet = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $showSheet, onDismiss: onDismissed) {
                ZSSaveTheSaleSheet(onResult: onResult)
            }
    }
}

// MARK: - Preview

#if DEBUG
struct ZSSaveTheSaleSheet_Previews: PreviewProvider {
    static var previews: some View {
        ZSSaveTheSaleSheet { result in
            print("Result: \(result)")
        }
    }
}
#endif
