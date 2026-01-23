# Quickstart

Build your first payment flow with ZeroSettleKit in 10 minutes.

## Overview

In this quickstart, you'll build a simple payment flow that allows users to:
1. Sign in with their phone number
2. Add funds to their wallet using Apple Pay
3. View their balance

This tutorial assumes you've already completed the <doc:GettingStarted> guide and have ZeroSettleKit configured in your project.

## Step 1: Create the Payment View

Create a new SwiftUI view for handling payments:

```swift
import SwiftUI
import ZeroSettleKit

struct PaymentView: View {
    @EnvironmentObject var settleManager: ZeroSettleManager
    @State private var fundingAmount: Double = 10.0
    @State private var showingPayment = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            // User Info
            if let user = settleManager.currentUser {
                VStack(spacing: 8) {
                    Text("Welcome!")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(user.phoneNumber)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let balance = settleManager.walletBalance {
                        Text("Balance: $\(balance, specifier: "%.2f") USDC")
                            .font(.headline)
                            .foregroundColor(.green)
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }

            // Amount Selector
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Funds")
                    .font(.headline)

                HStack {
                    Text("$")
                    TextField("Amount", value: $fundingAmount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                }
            }

            // Pay Button
            Button(action: { showingPayment = true }) {
                Text("Add $\(fundingAmount, specifier: "%.2f") with Apple Pay")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.black)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(fundingAmount <= 0)

            // Error Message
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Spacer()
        }
        .padding()
        .sheet(isPresented: $showingPayment) {
            ApplePaySheet(
                amount: fundingAmount,
                onSuccess: handlePaymentSuccess,
                onError: handlePaymentError
            )
        }
    }

    private func handlePaymentSuccess() {
        showingPayment = false
        errorMessage = nil
        // Refresh balance
        Task {
            await settleManager.refreshBalance()
        }
    }

    private func handlePaymentError(_ error: Error) {
        showingPayment = false
        errorMessage = error.localizedDescription
    }
}
```

## Step 2: Create the Apple Pay Sheet

Create a view that handles the Apple Pay flow:

```swift
import SwiftUI
import ZeroSettleKit

struct ApplePaySheet: View {
    @EnvironmentObject var settleManager: ZeroSettleManager
    @Environment(\.dismiss) var dismiss

    let amount: Double
    let onSuccess: () -> Void
    let onError: (Error) -> Void

    @State private var isProcessing = false
    @State private var paymentStatus: String = "Initializing..."

    var body: some View {
        VStack(spacing: 24) {
            Text("Add Funds")
                .font(.title)
                .fontWeight(.bold)

            Text("$\(amount, specifier: "%.2f") USDC")
                .font(.title2)
                .foregroundColor(.green)

            if isProcessing {
                ProgressView()
                Text(paymentStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .disabled(isProcessing)
        }
        .padding()
        .task {
            await processPayment()
        }
    }

    private func processPayment() async {
        isProcessing = true

        do {
            // Start payment session
            paymentStatus = "Starting payment..."
            let session = try await settleManager.startPayment(amount: amount)

            // Show Apple Pay (Coinbase handles this)
            paymentStatus = "Waiting for payment..."
            try await session.waitForCompletion()

            // Payment successful
            paymentStatus = "Payment complete!"
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            onSuccess()
            dismiss()

        } catch {
            onError(error)
            dismiss()
        }
    }
}
```

## Step 3: Create the Authentication Flow

Create a view that handles user authentication:

```swift
import SwiftUI
import ZeroSettleKit

struct AuthenticationView: View {
    @EnvironmentObject var settleManager: ZeroSettleManager
    @State private var phoneNumber = ""
    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("Welcome to ZeroSettle")
                .font(.title)
                .fontWeight(.bold)

            Text("Sign in to get started")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(spacing: 16) {
                TextField("Phone Number", text: $phoneNumber)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.phonePad)
                    .disabled(isAuthenticating)

                Button(action: authenticate) {
                    if isAuthenticating {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Text("Continue")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(phoneNumber.isEmpty ? Color.gray : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
                .disabled(phoneNumber.isEmpty || isAuthenticating)
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Spacer()
        }
        .padding()
    }

    private func authenticate() {
        isAuthenticating = true
        errorMessage = nil

        Task {
            do {
                try await settleManager.authenticate(phoneNumber: phoneNumber)
                // Authentication successful - UI will update automatically
            } catch {
                errorMessage = error.localizedDescription
                isAuthenticating = false
            }
        }
    }
}
```

## Step 4: Wire It All Together

Update your `ContentView` to show the appropriate view based on authentication state:

```swift
import SwiftUI
import ZeroSettleKit

struct ContentView: View {
    @EnvironmentObject var settleManager: ZeroSettleManager

    var body: some View {
        Group {
            if settleManager.isAuthenticated {
                PaymentView()
            } else {
                AuthenticationView()
            }
        }
    }
}
```

## Step 5: Test Your Implementation

Build and run your app:

1. **Launch the app** - You should see the authentication screen
2. **Enter your phone number** - Use your real phone number in sandbox mode
3. **Complete authentication** - You'll receive an OTP code via SMS
4. **View your wallet** - After authentication, you'll see your wallet balance
5. **Add funds** - Tap the "Add with Apple Pay" button
6. **Complete payment** - Follow the Coinbase Commerce flow to add funds
7. **See updated balance** - Your balance should update after payment completes

## What's Happening Under the Hood

When you run this flow, ZeroSettleKit:

1. **Authenticates via Privy** - Creates or retrieves an embedded Solana wallet
2. **Generates a Coinbase Commerce session** - Creates a payment URL
3. **Opens Coinbase payment flow** - User completes payment via Apple Pay
4. **Monitors payment status** - Polls Coinbase API for payment completion
5. **Credits the wallet** - USDC appears in the user's Solana wallet
6. **Updates balance** - Refreshes the displayed balance

All of this happens automatically - you just call the APIs!

## Next Steps

Now that you have a basic payment flow working, you can:

- **Add payout tables** - <doc:PayoutTables> - Automatically split payments
- **Customize the UI** - Build your own payment components
- **Add withdrawal** - Let users withdraw USDC to external wallets
- **Multi-chain support** - <doc:MultiChainSupport> - Support other blockchains

## Common Issues

### "Phone number authentication failed"

Make sure your Privy account is configured for SMS authentication and you're using a valid phone number format.

### "Payment session timeout"

This can happen if the user doesn't complete the Coinbase Commerce flow. Implement timeout handling:

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
        try await session.waitForCompletion()
    }
    group.addTask {
        try await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
        throw PaymentError.timeout
    }
    try await group.next()
    group.cancelAll()
}
```

### "Balance not updating"

Make sure you're calling `await settleManager.refreshBalance()` after successful payments.

## See Also

- <doc:Authentication> - Deep dive into authentication
- <doc:PaymentProcessing> - Understanding payment flows
- <doc:Architecture> - How ZeroSettleKit is structured
- ``ZeroSettleManager``
- ``PaymentProcessor``
