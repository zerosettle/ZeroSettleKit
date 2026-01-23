//
//  ZSDepositView.swift
//  ZeroSettleKit
//
//  Unified deposit view with Apple Pay and Phantom support
//

import SwiftUI
import WebKit
import UIKit
import Solana

// MARK: - Blockchain Types

public enum BlockchainType {
    case solana
    case ethereum
    case base
    case polygon
    case arbitrum
    case optimism
}

// MARK: - Deposit Method (UI selection for funding providers)

public enum DepositMethod: String, CaseIterable {
    case applePay = "Apple Pay"
    case stripe = "Credit/Debit Card"
    case phantom = "Phantom"
    case metamask = "MetaMask"
    case coinbase = "Coinbase (Base)"

    public var iconType: DepositIconType {
        switch self {
        case .applePay:
            return .system("applelogo")
        case .stripe:
            return .system("creditcard.fill")
        case .phantom:
            return .asset("PhantomIcon")
        case .metamask:
            return .system("hexagon.fill")
        case .coinbase:
            return .asset("CoinbaseIcon")
        }
    }

    public var preferredBlockchainType: BlockchainType {
        switch self {
        case .applePay:
            return .base
        case .stripe:
            return .base
        case .phantom:
            return .solana
        case .metamask:
            return .ethereum
        case .coinbase:
            return .base
        }
    }
}

public enum DepositIconType {
    case system(String)
    case asset(String)
}

// MARK: - Deposit Model

public final class ZSDepositModel: ObservableObject {
    @Published public var walletAddresses: [BlockchainType: String]
    public var onDeposit: ((Int) -> Void)?

    public init(
        walletAddresses: [BlockchainType: String] = [:],
        onDeposit: ((Int) -> Void)? = nil
    ) {
        self.walletAddresses = walletAddresses
        self.onDeposit = onDeposit
    }

    // Helper to get wallet address for a specific blockchain
    public func walletAddress(for blockchainType: BlockchainType) -> String? {
        return walletAddresses[blockchainType]
    }
}

// MARK: - Deposit View

public struct ZSDepositView: View {
    @ObservedObject private var model: ZSDepositModel
    @ObservedObject private var phantomManager = PhantomManager.shared
    @ObservedObject private var metamaskManager = MetaMaskManager.shared
    @ObservedObject private var coinbaseManager = CoinbaseManager.shared
    @ObservedObject private var stripeManager = StripeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAmount: Int = 300 // $3 in cents (for demo)
    @State private var isProcessing: Bool = false
    @State private var showSuccess: Bool = false
    @State private var errorMessage: String?
    @State private var showPaymentWebView: Bool = false
    @State private var paymentURL: URL?
    @State private var webViewLoading: Bool = true
    @State private var selectedDepositMethod: DepositMethod = .applePay
    @State private var showDepositMethodPicker: Bool = false
    @State private var showKeypad: Bool = false
    @State private var customAmount: String = ""

    // Predefined amounts in cents
    private let amounts: [(display: String, cents: Int)] = [
        ("$1", 100),
        ("$2", 200),
        ("$3", 300),
        ("$5", 500),
        ("$10", 1000)
    ]

    public init(
        model: ZSDepositModel
    ) {
        self.model = model
    }

    // Primary initializer with wallet addresses dictionary
    public init(
        walletAddresses: [BlockchainType: String],
        onDeposit: ((Int) -> Void)? = nil
    ) {
        let model = ZSDepositModel(
            walletAddresses: walletAddresses,
            onDeposit: onDeposit
        )
        self.init(model: model)
    }

    public var body: some View {
        NavigationView {
            VStack(spacing: showKeypad ? 16 : 32) {
                headerView

                if !showKeypad {
                    depositMethodSelectorButton
                }

                if showKeypad {
                    keypadView
                } else {
                    amountSelectionGrid
                }

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                Spacer()

                // Payment button area (switches based on selected deposit method)
                if selectedDepositMethod == .applePay {
                    applePayButtonArea
                } else if selectedDepositMethod == .stripe {
                    stripeButtonArea
                } else if selectedDepositMethod == .phantom {
                    phantomDepositButtonArea
                } else if selectedDepositMethod == .metamask {
                    metamaskDepositButtonArea
                } else if selectedDepositMethod == .coinbase {
                    coinbaseDepositButtonArea
                }

                // Powered by ZeroSettle
                Button(action: {
                    if let url = URL(string: "https://zerosettle.com") {
                        UIApplication.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Text("Powered by")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.6))
                        Text("ZeroSettle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.bottom, 20)
                }
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
        }
        .accentColor(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            // Set navigation bar to black
            let appearance = UINavigationBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = .black
            appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
            appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance

            if selectedDepositMethod == .applePay {
                loadPaymentLink()
            }

            // Setup Stripe callbacks
            stripeManager.onPaymentSuccess = { sessionId in
                print("[ZSDeposit] Stripe payment successful: \(sessionId)")
                self.showPaymentWebView = false
                self.showSuccess = true

                // Call onDeposit callback if provided
                if let onDeposit = self.model.onDeposit {
                    onDeposit(self.selectedAmount)
                }
            }

            stripeManager.onPaymentCancelled = {
                print("[ZSDeposit] Stripe payment cancelled")
                self.showPaymentWebView = false
                self.errorMessage = "Payment was cancelled"
            }
        }
        .onChange(of: selectedDepositMethod) { newMethod in
            print("[ZSDeposit] Deposit method changed to: \(newMethod.rawValue)")

            // Reset state when switching methods
            showPaymentWebView = false
            paymentURL = nil
            isProcessing = false
            showSuccess = false
            errorMessage = nil
            webViewLoading = true

            if newMethod == .applePay {
                print("   Loading Apple Pay payment link...")
                loadPaymentLink()
            } else {
                print("   No auto-load for \(newMethod.rawValue)")
            }
        }
    }

    // MARK: - View Components

    private var headerView: some View {
        VStack(spacing: showKeypad ? 8 : 12) {
            if !showKeypad {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.green, Color.green.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            Text("Deposit")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text("Add funds to ZeroSettle Playground.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.top, showKeypad ? 38 : 20)
    }

    private var depositMethodSelectorButton: some View {
        Button(action: {
            showDepositMethodPicker = true
        }) {
            HStack(spacing: 12) {
                switch selectedDepositMethod.iconType {
                case .system(let iconName):
                    Image(systemName: iconName)
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                case .asset(let assetName):
                    if let uiImage = UIImage(named: assetName, in: Bundle.module, with: nil) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                    } else {
                        // Fallback to SF Symbol if asset not found
                        Image(systemName: "wallet.pass.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                    }
                }

                Text(selectedDepositMethod.rawValue)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
        }
        .padding(.horizontal)
        .actionSheet(isPresented: $showDepositMethodPicker) {
            ActionSheet(
                title: Text("Select Deposit Method"),
                buttons: DepositMethod.allCases.map { method in
                        .default(Text(method.rawValue)) {
                            selectedDepositMethod = method
                        }
                } + [.cancel()]
            )
        }
    }

    private var applePayButtonArea: some View {
        ZStack {
            if !showSuccess && (isProcessing || webViewLoading) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.5)
            }

            if showPaymentWebView, let url = paymentURL {
                InlineWebView(url: url, onCompletion: { success in
                    print("[ZSDeposit] onCompletion: \(success)")
                    if success {
                        let depositAmount = 300 // Always $3 for demo
                        print("[ZSDeposit] Deposited \(depositAmount) cents ($3.00)")
                        showSuccess = true

                        // Call callback with deposited amount in cents
                        model.onDeposit?(depositAmount)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            dismiss()
                        }
                    } else {
                        print("[ZSDeposit] Payment failed")
                        showPaymentWebView = false
                        paymentURL = nil
                        errorMessage = "Payment was cancelled or failed"
                    }
                }, onLoadingChanged: { loading in
                    webViewLoading = loading
                })
                .opacity(webViewLoading ? 0 : 1)
                .animation(Animation.easeIn(duration: 0.2), value: webViewLoading)
            }

            if showSuccess {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                    Text("Success!")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }
        }
        .frame(height: 100)
        .padding(.horizontal)
        .padding(.bottom, 20)
    }

    private var stripeButtonArea: some View {
        VStack(spacing: 16) {
            // Show button to initiate Stripe checkout
            Button(action: {
                loadStripeCheckout()
            }) {
                HStack {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 20))
                    Text("Pay with Card")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color(red: 0.4, green: 0.5, blue: 1.0), Color(red: 0.3, green: 0.4, blue: 0.9)]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
            }
            .disabled(isProcessing)
            .opacity(isProcessing ? 0.6 : 1.0)
            .padding(.horizontal)

            if isProcessing {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("Opening Stripe Checkout...")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
            }

            if showSuccess {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                    Text("Success!")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.green)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
        }
        .padding(.bottom, 20)
    }

    private var phantomDepositButtonArea: some View {
        VStack(spacing: 16) {
            if PhantomManager.shared.isConnected {
                // Connected - show deposit button
                Button(action: initiatePhantomDeposit) {
                    HStack(spacing: 12) {
                        if isProcessing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else if showSuccess {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                        } else {
                            if let image = UIImage(named: "PhantomIcon", in: Bundle.module, with: nil) {
                                Image(uiImage: image)
                                    .resizable()
                                    .frame(width: 24, height: 24)
                            }
                        }

                        Text(showSuccess ? "Success!" : "Deposit with Phantom")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(showSuccess ? Color.green : Color.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isProcessing || showSuccess)

                if let phantomWallet = PhantomManager.shared.publicKey {
                    Text("Connected: \(formatWalletAddress(phantomWallet))")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            } else {
                // Not connected - show connect button
                Button(action: connectPhantom) {
                    HStack(spacing: 12) {
                        if let image = UIImage(named: "PhantomIcon", in: Bundle.module, with: nil) {
                            Image(uiImage: image)
                                .resizable()
                                .frame(width: 24, height: 24)
                        }

                        Text("Connect Phantom Wallet")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Text("Transfer USDC from your Phantom wallet")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 20)
    }

    private var metamaskDepositButtonArea: some View {
        VStack(spacing: 16) {
            if MetaMaskManager.shared.isConnected {
                // Connected - show deposit button
                Button(action: initiateMetaMaskDeposit) {
                    HStack(spacing: 12) {
                        if isProcessing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else if showSuccess {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                        } else {
                            Image(systemName: "hexagon.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.orange)
                        }

                        Text(showSuccess ? "Success!" : "Deposit with MetaMask")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        Group {
                            if showSuccess {
                                Color.green
                            } else {
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.orange, Color.orange.opacity(0.8)]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isProcessing || showSuccess)

                VStack(spacing: 4) {
                    if let metamaskAccount = MetaMaskManager.shared.account {
                        Text("Connected: \(formatWalletAddress(metamaskAccount))")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    if let chainId = MetaMaskManager.shared.chainId {
                        Text("Chain: \(chainName(for: chainId))")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            } else {
                // Not connected - show connect button
                Button {
                    print("👆 [ZSDeposit] MetaMask connect button tapped")
                    connectMetaMask()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "hexagon.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.orange)

                        Text("Connect MetaMask Wallet")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.orange, Color.orange.opacity(0.8)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(metamaskManager.isConnected || isProcessing)

                Text("Transfer USDC from your MetaMask wallet")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 20)
    }

    // MARK: - Phantom Methods

    private func connectPhantom() {
        print("[ZSDeposit] Connecting to Phantom...")

        // Use the appropriate Solana cluster based on current network environment
        let currentNetwork = NetworkEnvironmentManager.shared.currentEnvironment
        let cluster: Network = currentNetwork == .mainnet ? .mainnetBeta : .devnet

        print("[ZSDeposit] Connecting to \(currentNetwork.displayName) (\(cluster.cluster))")

        PhantomManager.shared.configure(
            appURL: "https://zerosettle.com",
            redirectScheme: "zerosettle",
            cluster: cluster
        )
        PhantomManager.shared.connect()
    }

    private func initiatePhantomDeposit() {
        guard let destinationWallet = model.walletAddress(for: .solana) else {
            errorMessage = "No Solana wallet address configured"
            return
        }

        isProcessing = true
        errorMessage = nil

        print("[ZSDeposit] Initiating Phantom deposit of $\(Double(selectedAmount) / 100.0)")

        // Get Phantom's USDC token account and destination token account
        // For now, we'll need to derive the ATAs from the wallet addresses
        // This requires the USDC mint address

        // Use the appropriate USDC mint based on current network environment
        let currentNetwork = NetworkEnvironmentManager.shared.currentEnvironment
        let usdcMint = BlockchainConfig.getUSDCMint(for: currentNetwork)

        print("[ZSDeposit] Using \(currentNetwork.displayName) USDC mint: \(usdcMint)")

        guard let phantomWallet = PhantomManager.shared.publicKey else {
            errorMessage = "Phantom wallet not connected"
            isProcessing = false
            return
        }

        // Derive ATAs (Associated Token Accounts)
        Task {
            do {
                let phantomATA = try deriveATA(walletAddress: phantomWallet, mintAddress: usdcMint)
                let destinationATA = try deriveATA(walletAddress: destinationWallet, mintAddress: usdcMint)

                print("[ZSDeposit] Token accounts derived:")
                print("   - Phantom USDC ATA: \(phantomATA)")
                print("   - Destination USDC ATA: \(destinationATA)")

                // Convert cents to USDC base units (1 USDC = 1,000,000 units)
                let amountUSDC = Double(selectedAmount) / 100.0

                PhantomManager.shared.depositUSDCToPrivyWallet(
                    fromTokenAccount: phantomATA,
                    toTokenAccount: destinationATA,
                    amountUSDC: amountUSDC
                )

                // Set up callbacks
                PhantomManager.shared.onTransactionSigned = { signature in
                    print("[ZSDeposit] Phantom deposit completed: \(signature)")

                    DispatchQueue.main.async {
                        showSuccess = true
                        isProcessing = false

                        // Call callback with deposited amount in cents
                        model.onDeposit?(selectedAmount)

                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            dismiss()
                        }
                    }
                }

                PhantomManager.shared.onTransactionError = { error in
                    print("[ZSDeposit] Phantom deposit failed: \(error)")

                    DispatchQueue.main.async {
                        errorMessage = error
                        isProcessing = false
                    }
                }

            } catch {
                DispatchQueue.main.async {
                    errorMessage = "Failed to derive token accounts: \(error.localizedDescription)"
                    isProcessing = false
                }
            }
        }
    }

    private func deriveATA(walletAddress: String, mintAddress: String) throws -> String {
        guard let walletPubkey = PublicKey(string: walletAddress),
              let mintPubkey = PublicKey(string: mintAddress) else {
            throw PhantomTransactionError.invalidAddress
        }

        let ataResult = PublicKey.associatedTokenAddress(
            walletAddress: walletPubkey,
            tokenMintAddress: mintPubkey
        )

        switch ataResult {
        case .success(let ataAddress):
            return ataAddress.base58EncodedString
        case .failure(let error):
            throw PhantomTransactionError.transactionBuildFailed("Failed to derive ATA: \(error.localizedDescription)")
        }
    }

    // MARK: - MetaMask Methods

    @State private var connectTaskCount: Int = 0

    private func connectMetaMask() {
        connectTaskCount += 1
        let taskNumber = connectTaskCount

        print("═══════════════════════════════════════════")
        print("[ZSDeposit] connectMetaMask() called (Task #\(taskNumber))")
        print("═══════════════════════════════════════════")
        print("   MetaMask current state:")
        print("      - Connected: \(MetaMaskManager.shared.isConnected)")
        print("      - Has account: \(MetaMaskManager.shared.account != nil)")
        print("   Call Stack:")
        Thread.callStackSymbols.prefix(15).forEach { print("      \($0)") }

        Task { @MainActor in
            print("   Starting async connect task #\(taskNumber)...")
            await MetaMaskManager.shared.connect()
            print("   Completed async connect task #\(taskNumber)")
        }
    }

    private func initiateMetaMaskDeposit() {
        guard let destinationWallet = model.walletAddress(for: .ethereum) else {
            errorMessage = "No Ethereum wallet address configured"
            return
        }

        // Validate Ethereum address format
        guard destinationWallet.hasPrefix("0x") && destinationWallet.count == 42 else {
            errorMessage = "Invalid Ethereum address format"
            return
        }

        isProcessing = true
        errorMessage = nil

        print("[ZSDeposit] Initiating MetaMask deeplink deposit")
        print("   - Destination: \(destinationWallet)")
        print("   - Amount: $\(Double(selectedAmount) / 100.0) USDC")
        print("   - Network: Ethereum mainnet (ERC-20)")
        print("   - Method: MetaMask Mobile deeplink (prefilled UI)")

        let amountUSDC = Double(selectedAmount) / 100.0

        // Set up callbacks
        MetaMaskManager.shared.onTransactionSent = { txHash in
            print("[ZSDeposit] MetaMask deposit completed: \(txHash)")

            DispatchQueue.main.async {
                showSuccess = true
                isProcessing = false

                // Call callback with deposited amount in cents
                model.onDeposit?(selectedAmount)

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    dismiss()
                }
            }
        }

        MetaMaskManager.shared.onTransactionError = { error in
            print("[ZSDeposit] MetaMask deposit failed: \(error)")

            DispatchQueue.main.async {
                errorMessage = error
                isProcessing = false
            }
        }

        // Send USDC via MetaMask Mobile deeplink (Ethereum mainnet ERC-20)
        // This opens MetaMask with a prefilled USDC transfer
        MetaMaskManager.shared.sendUSDCViaDeeplink(
            to: destinationWallet,
            amountUSDC: amountUSDC
        )

        // Note: With deeplink approach, we can't track transaction status directly
        // User completes the transaction in MetaMask and returns to app
        // For production, you'd want to:
        // 1. Monitor the destination wallet balance via backend
        // 2. Use transaction verification via blockchain explorer
        // 3. Implement a polling mechanism or webhook

        // For now, assume success after user returns (simplified flow)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let error = MetaMaskManager.shared.errorMessage {
                errorMessage = error
                isProcessing = false
            } else {
                // User returned from MetaMask
                // In production, verify the transaction here
                print("[ZSDeposit] User returned from MetaMask, assuming transaction submitted")
                showSuccess = true
                isProcessing = false
                model.onDeposit?(selectedAmount)

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    dismiss()
                }
            }
        }
    }

    private func chainName(for chainId: String) -> String {
        switch chainId {
        case "0x1": return "Ethereum"
        case "0x89": return "Polygon"
        case "0xa": return "Optimism"
        case "0xa4b1": return "Arbitrum"
        case "0x2105": return "Base"
        default: return "Chain \(chainId)"
        }
    }

    // MARK: - Coinbase Methods

    private var coinbaseDepositButtonArea: some View {
        VStack(spacing: 16) {
            if CoinbaseManager.shared.isConnected {
                // Connected - show deposit button
                Button(action: initiateCoinbaseDeposit) {
                    HStack(spacing: 12) {
                        if isProcessing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else if showSuccess {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                        } else {
                            Image(systemName: "bitcoinsign.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.blue)
                        }

                        Text(showSuccess ? "Success!" : "Deposit with Coinbase")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        Group {
                            if showSuccess {
                                Color.green
                            } else {
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.blue, Color.blue.opacity(0.8)]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isProcessing || showSuccess)

                if let coinbaseAddress = CoinbaseManager.shared.address {
                    Text("Connected: \(formatWalletAddress(coinbaseAddress))")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            } else {
                // Not connected - show connect button
                Button {
                    print("👆 [ZSDeposit] Coinbase connect button tapped")
                    connectCoinbase()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bitcoinsign.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.blue)

                        Text("Connect Coinbase Wallet")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.blue, Color.blue.opacity(0.8)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(coinbaseManager.isConnected || isProcessing)

                Text("Transfer USDC from Coinbase Wallet on Base")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 20)
    }

    private func connectCoinbase() {
        print("[ZSDeposit] Connecting to Coinbase...")
        guard let callbackURL = URL(string: "https://zerosettle.com/cbw-callback") else {
            errorMessage = "Invalid Coinbase callback URL"
            print("[ZSDeposit] Invalid Coinbase callback URL")
            return
        }

        CoinbaseManager.shared.configure(callbackURL: callbackURL)
        CoinbaseManager.shared.connect()
    }

    private func initiateCoinbaseDeposit() {
        guard let destinationWallet = model.walletAddress(for: .base) else {
            errorMessage = "No Base wallet address configured"
            return
        }

        // Validate Ethereum-compatible address format (Base is EVM-compatible)
        guard destinationWallet.hasPrefix("0x") && destinationWallet.count == 42 else {
            errorMessage = "Invalid Base address format"
            return
        }

        isProcessing = true
        errorMessage = nil

        print("[ZSDeposit] Initiating Coinbase deposit of $\(Double(selectedAmount) / 100.0)")
        print("   - Destination: \(destinationWallet)")
        print("   - Amount: $\(Double(selectedAmount) / 100.0)")

        let amountUSDC = Double(selectedAmount) / 100.0

        // Set up callbacks
        CoinbaseManager.shared.onTransactionSent = { txHash in
            print("[ZSDeposit] Coinbase deposit completed: \(txHash)")

            DispatchQueue.main.async {
                showSuccess = true
                isProcessing = false

                // Call callback with deposited amount in cents
                model.onDeposit?(selectedAmount)

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    dismiss()
                }
            }
        }

        CoinbaseManager.shared.onTransactionError = { error in
            print("[ZSDeposit] Coinbase deposit failed: \(error)")

            DispatchQueue.main.async {
                errorMessage = error
                isProcessing = false
            }
        }

        // Send USDC via Coinbase Wallet on Base
        Task {
            let _ = await CoinbaseManager.shared.sendUSDC(
                to: destinationWallet,
                amountUSDC: amountUSDC
            )
        }
    }

    private var amountSelectionGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 16) {
            ForEach(amounts, id: \.cents) { amount in
                amountButton(amount: amount)
            }

            // Keypad button in place of $20
            keypadButton
        }
        .padding(.horizontal)
    }

    private var keypadButton: some View {
        Button(action: {
            withAnimation {
                showKeypad = true
                customAmount = ""
            }
        }) {
            if let keypadImage = ZeroSettleResources.keypadIcon {
                Image(uiImage: keypadImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 40)
                    .foregroundColor(.white)
                    .frame(height: 70)
                    .frame(maxWidth: .infinity)
                    .background(Color(white: 0.15, opacity: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.2), lineWidth: 2)
                    )
            } else {
                // Fallback to SF Symbol
                Image(systemName: "number.square.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.white)
                    .frame(height: 70)
                    .frame(maxWidth: .infinity)
                    .background(Color(white: 0.15, opacity: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.2), lineWidth: 2)
                    )
            }
        }
    }

    private var keypadView: some View {
        VStack(spacing: 16) {
            // Payment method selector
            depositMethodSelectorButton

            // Display area
            HStack {
                Text("$")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))

                Text(customAmount.isEmpty ? "0" : customAmount)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Backspace button
                Button(action: {
                    if !customAmount.isEmpty {
                        customAmount.removeLast()
                        if let dollars = Int(customAmount), !customAmount.isEmpty {
                            selectedAmount = dollars * 100
                        } else {
                            selectedAmount = 0
                        }
                    }
                }) {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 24))
                        .foregroundColor(customAmount.isEmpty ? .white.opacity(0.3) : .white.opacity(0.6))
                }
                .disabled(customAmount.isEmpty)
            }
            .padding(.horizontal)

            // Keypad
            NumberKeypad { number in
                handleKeypadTap(number)
            }
        }
    }

    private func handleKeypadTap(_ number: Int) {
        // Limit to reasonable amounts (max $999.99)
        if customAmount.count < 5 {
            if customAmount.isEmpty && number == 0 {
                // Don't start with 0
                return
            }
            customAmount += "\(number)"

            // Update selected amount (convert dollars to cents)
            if let dollars = Int(customAmount) {
                selectedAmount = dollars * 100
            }
        }
    }

    private func amountButton(amount: (display: String, cents: Int)) -> some View {
        let isSelected = selectedAmount == amount.cents

        return Button(action: {
            selectedAmount = amount.cents
        }) {
            Text(amount.display)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(isSelected ? .green : .white)
                .frame(height: 70)
                .frame(maxWidth: .infinity)
                .background(isSelected ? Color.green.opacity(0.3) : Color(white: 0.15, opacity: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isSelected ? Color.green : Color.white.opacity(0.2), lineWidth: 2)
                )
        }
    }

    // MARK: - Methods

    private func formatWalletAddress(_ address: String) -> String {
        if address.count > 10 {
            let start = address.prefix(6)
            let end = address.suffix(4)
            return "\(start)...\(end)"
        }
        return address
    }

    private func loadPaymentLink() {
        errorMessage = nil
        isProcessing = true

        let startTime = Date()
        print("Starting API call at \(startTime)")

        let demoAmount = "3.00"

        let fallbackBaseDemoAddress = "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
        let destinationAddress: String
        if let walletAddress = model.walletAddress(for: .base),
           walletAddress.hasPrefix("0x"),
           walletAddress.count == 42 {
            destinationAddress = walletAddress
        } else {
            destinationAddress = fallbackBaseDemoAddress
        }

        let requestBody: [String: Any] = [
            "agreementAcceptedAt": ISO8601DateFormatter().string(from: Date()),
            "destinationAddress": destinationAddress,
            "destinationNetwork": "base",
            "email": "test@example.com",
            "isQuote": false,
            "partnerUserRef": "sandbox-\(UUID().uuidString)",
            "paymentAmount": demoAmount,
            "paymentCurrency": "USD",
            "paymentMethod": "GUEST_CHECKOUT_APPLE_PAY",
            "phoneNumber": "+12055555555",
            "phoneNumberVerifiedAt": ISO8601DateFormatter().string(from: Date()),
            "purchaseCurrency": "USDC"
        ]

        let requestMethod = "POST"
        let requestHost = "api.cdp.coinbase.com"
        let requestPath = "/platform/v2/onramp/orders"

        let jwtToken: String
        do {
            jwtToken = try CoinbaseJWTGenerator.generateJWT(
                requestMethod: requestMethod,
                requestHost: requestHost,
                requestPath: requestPath,
                apiKeyId: ZeroSettleKit.coinbaseApiKeyId,
                apiKeySecret: ZeroSettleKit.coinbaseApiKeySecret
            )
            print("Generated JWT token")
        } catch {
            errorMessage = "Failed to generate JWT: \(error.localizedDescription)"
            print("Failed to generate JWT: \(error)")
            isProcessing = false
            return
        }

        guard let url = URL(string: "https://\(requestHost)\(requestPath)") else {
            errorMessage = "Invalid URL"
            isProcessing = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = requestMethod
        request.setValue("Bearer \(jwtToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            print("Making request to Coinbase: \(url.absoluteString)")
        } catch {
            errorMessage = "Failed to encode request: \(error.localizedDescription)"
            print("Failed to encode request: \(error.localizedDescription)")
            isProcessing = false
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            let responseTime = Date()
            print("Response received, took \(responseTime.timeIntervalSince(startTime))s")

            DispatchQueue.main.async {
                isProcessing = false

                if let error = error {
                    errorMessage = "Network error: \(error.localizedDescription)"
                    print("Network error: \(error.localizedDescription)")
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    errorMessage = "Invalid response"
                    return
                }

                print("Response status: \(httpResponse.statusCode)")

                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    print("Response: \(responseString)")
                }

                if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                    guard let data = data else {
                        errorMessage = "No data received"
                        return
                    }

                    do {
                        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let paymentLink = json["paymentLink"] as? [String: Any],
                           let paymentLinkURL = paymentLink["url"] as? String,
                           let url = URL(string: paymentLinkURL) {
                            print("Payment URL received: \(paymentLinkURL)")
                            paymentURL = url
                            showPaymentWebView = true
                        } else {
                            errorMessage = "Invalid response format"
                            print("Could not parse payment link")
                        }
                    } catch {
                        errorMessage = "Failed to parse response"
                        print("JSON parsing error: \(error.localizedDescription)")
                    }
                } else {
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorMsg = json["errorMessage"] as? String {
                        errorMessage = "Coinbase error: \(errorMsg)"
                        print("Coinbase error: \(errorMsg)")
                    } else {
                        errorMessage = "Failed to create order (Status: \(httpResponse.statusCode))"
                        print("Failed with status: \(httpResponse.statusCode)")
                    }
                }
            }
        }.resume()
    }

    private func loadStripeCheckout() {
        errorMessage = nil
        isProcessing = true

        print("[Stripe] Creating checkout session...")

        let amountCents = selectedAmount  // Already in cents

        // Get destination address from model
        let fallbackBaseDemoAddress = "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
        let destinationAddress: String
        if let walletAddress = model.walletAddress(for: .base),
           walletAddress.hasPrefix("0x"),
           walletAddress.count == 42 {
            destinationAddress = walletAddress
        } else {
            destinationAddress = fallbackBaseDemoAddress
        }

        // Build request to Django backend
        let requestBody: [String: Any] = [
            "email": "user@wordplay.app",
            "destination_address": destinationAddress,
            "payment_amount_cents": amountCents,
        ]

        // Build URL based on environment (simulator uses localhost, device uses local IP)
        let baseURL: String
#if targetEnvironment(simulator)
        baseURL = "http://localhost:8000"
#else
        baseURL = "http://192.168.1.159:8000"
#endif

        guard let url = URL(string: "\(baseURL)/api/v1/onramp/stripe/") else {
            errorMessage = "Invalid URL"
            isProcessing = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            errorMessage = "Failed to encode request: \(error.localizedDescription)"
            isProcessing = false
            return
        }

        // Make API call
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {

                if let error = error {
                    self.errorMessage = "Network error: \(error.localizedDescription)"
                    self.isProcessing = false
                    return
                }

                guard let data = data else {
                    self.errorMessage = "No data received"
                    self.isProcessing = false
                    return
                }

                // Parse response
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let checkoutURL = json["checkout_url"] as? String,
                       let url = URL(string: checkoutURL) {
                        print("[Stripe] Checkout URL received: \(checkoutURL)")
                        print("[Stripe] Opening Safari for payment...")

                        // Open Stripe Checkout in Safari
                        UIApplication.shared.open(url, options: [:]) { success in
                            if success {
                                print("[Stripe] Safari opened successfully")
                            } else {
                                print("[Stripe] Failed to open Safari")
                                self.errorMessage = "Failed to open browser"
                            }
                        }
                    } else {
                        // Check for error response
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let error = json["error"] as? String {
                            self.errorMessage = "API error: \(error)"
                        } else {
                            self.errorMessage = "Invalid response format"
                        }
                    }
                } catch {
                    self.errorMessage = "Failed to parse response: \(error.localizedDescription)"
                }

                self.isProcessing = false
            }
        }.resume()
    }
}

// MARK: - Inline WebView

struct InlineWebView: UIViewRepresentable {
    typealias UIViewType = WKWebView

    let url: URL
    let onCompletion: (Bool) -> Void
    let onLoadingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion, onLoadingChanged: onLoadingChanged)
    }

    func makeUIView(context: UIViewRepresentableContext<InlineWebView>) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.processPool = WKProcessPool()
        configuration.suppressesIncrementalRendering = false

        configuration.userContentController.add(context.coordinator.onrampListener, name: "onramp")
        configuration.userContentController.addUserScript(OnrampListener.makeBridgeScript())

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear

#if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
#endif

        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: UIViewRepresentableContext<InlineWebView>) {
        if webView.url != url {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onCompletion: (Bool) -> Void
        let onLoadingChanged: (Bool) -> Void
        let onrampListener = OnrampListener()
        var hasCompleted = false

        init(onCompletion: @escaping (Bool) -> Void, onLoadingChanged: @escaping (Bool) -> Void) {
            self.onCompletion = onCompletion
            self.onLoadingChanged = onLoadingChanged
            super.init()

            onrampListener.onEvent = { [weak self] eventName, eventData in
                guard let self = self else { return }

                if self.hasCompleted { return }

                switch eventName {
                case .pollingSuccess:
                    if !self.hasCompleted {
                        self.hasCompleted = true
                        DispatchQueue.main.async {
                            self.onCompletion(true)
                        }
                    }
                case .commitError, .pollingError, .cancel:
                    self.hasCompleted = true
                    DispatchQueue.main.async {
                        self.onCompletion(false)
                    }
                default:
                    break
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                let urlString = url.absoluteString

                if !hasCompleted {
                    if urlString.contains("success") || urlString.contains("completed") || urlString.contains("status=success") || urlString.contains("/complete") {
                        hasCompleted = true
                        DispatchQueue.main.async {
                            self.onCompletion(true)
                        }
                        decisionHandler(.cancel)
                        return
                    } else if urlString.contains("cancel") || urlString.contains("error") || urlString.contains("status=cancelled") || urlString.contains("status=failed") {
                        hasCompleted = true
                        DispatchQueue.main.async {
                            self.onCompletion(false)
                        }
                        decisionHandler(.cancel)
                        return
                    }
                }
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.onLoadingChanged(false)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.onLoadingChanged(true)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.onLoadingChanged(false)
            }
            if !hasCompleted {
                hasCompleted = true
                onCompletion(false)
            }
        }
    }
}

#Preview {
    ZSDepositView(
        walletAddresses: [
            .solana: "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU",
            .ethereum: "0x71C7656EC7ab88b098defB751B7401B5f6d8976F",
            .base: "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
        ]
    )
}
