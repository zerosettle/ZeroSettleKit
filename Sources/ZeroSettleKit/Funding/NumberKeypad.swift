//
//  NumberKeypad.swift
//  ZeroSettleKit
//

import SwiftUI

struct NumberKeypad: View {
    let onTap: (Int) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(1...9, id: \.self) { n in
                KeyButton(title: "\(n)") { onTap(n) }
            }

            // Optional spacer to keep "0" centered like a phone keypad
            Color.clear
                .frame(height: 56)

            KeyButton(title: "0") { onTap(0) }

            Color.clear
                .frame(height: 56)
        }
        .padding()
    }
}

private struct KeyButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary)
        )
    }
}

