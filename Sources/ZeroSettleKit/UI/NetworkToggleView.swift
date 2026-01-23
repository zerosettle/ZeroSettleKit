//
//  NetworkToggleView.swift
//  ZeroSettleKit
//
//  A simple view for toggling between mainnet and devnet
//  Can be embedded in your app's settings or shown as a debug option
//

import SwiftUI

/// A simple toggle view for switching between mainnet and devnet
public struct NetworkToggleView: View {
    @ObservedObject private var networkManager = NetworkEnvironmentManager.shared
    @State private var showConfirmation = false

    public init() {}

    public var body: some View {
        VStack(spacing: 20) {
            // Network Status
            HStack {
                Circle()
                    .fill(networkManager.currentEnvironment == .mainnet ? Color.green : Color.orange)
                    .frame(width: 12, height: 12)

                Text("Current Network: \(networkManager.currentEnvironment.displayName)")
                    .font(.headline)

                Spacer()
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)

            // Network Info
            VStack(alignment: .leading, spacing: 12) {
                if networkManager.currentEnvironment == .mainnet {
                    infoRow(icon: "checkmark.circle.fill",
                            text: "Using real USDC and real money",
                            color: .green)
                    infoRow(icon: "creditcard.fill",
                            text: "Transactions are permanent",
                            color: .green)
                } else {
                    infoRow(icon: "wrench.and.screwdriver.fill",
                            text: "Using test USDC (no real value)",
                            color: .orange)
                    infoRow(icon: "testtube.2",
                            text: "Safe for testing and development",
                            color: .orange)
                    infoRow(icon: "link",
                            text: "Get test USDC from faucet",
                            color: .orange)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(12)

            // Toggle Button
            Button(action: {
                showConfirmation = true
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Switch to \(networkManager.currentEnvironment == .mainnet ? "Devnet" : "Mainnet")")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: [.blue, .blue.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(12)
            }
            .confirmationDialog(
                "Switch Network?",
                isPresented: $showConfirmation,
                titleVisibility: .visible
            ) {
                Button("Switch to \(networkManager.currentEnvironment == .mainnet ? "Devnet" : "Mainnet")") {
                    withAnimation {
                        networkManager.toggleEnvironment()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(networkManager.currentEnvironment == .mainnet
                     ? "Switching to Devnet will use test tokens. You may need to reconnect your wallet."
                     : "Switching to Mainnet will use real USDC. Be careful with your transactions!")
            }

            // RPC Endpoint Info (for developers)
            DisclosureGroup("Developer Info") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RPC Endpoint")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(networkManager.getSolanaRpcEndpoint())
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)

                    Text("USDC Mint")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    Text(BlockchainConfig.getUSDCMint(for: networkManager.currentEnvironment))
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                }
                .padding(.top, 8)
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(12)

            Spacer()
        }
        .padding()
        .navigationTitle("Network Settings")
    }

    private func infoRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
            Spacer()
        }
    }
}

// MARK: - Compact Toggle for Settings

/// A compact network toggle suitable for embedding in settings lists
public struct CompactNetworkToggle: View {
    @ObservedObject private var networkManager = NetworkEnvironmentManager.shared

    public init() {}

    public var body: some View {
        HStack {
            Label("Network", systemImage: "network")

            Spacer()

            Picker("Network", selection: Binding(
                get: { networkManager.currentEnvironment },
                set: { networkManager.setEnvironment($0) }
            )) {
                ForEach(NetworkEnvironment.allCases, id: \.self) { env in
                    Text(env.displayName).tag(env)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
    }
}

// MARK: - Badge View

/// A small badge showing the current network (useful for debug builds)
public struct NetworkBadge: View {
    @ObservedObject private var networkManager = NetworkEnvironmentManager.shared

    public init() {}

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(networkManager.currentEnvironment == .mainnet ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            Text(networkManager.currentEnvironment.displayName)
                .font(.caption)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.2))
        .cornerRadius(12)
    }
}

// MARK: - Preview

#Preview("Full View") {
    NavigationView {
        NetworkToggleView()
    }
}

#Preview("Compact Toggle") {
    List {
        CompactNetworkToggle()
    }
}

#Preview("Badge") {
    VStack {
        NetworkBadge()
    }
    .padding()
}

