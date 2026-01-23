# Getting Started

Install and configure ZeroSettleKit in your iOS app.

## Prerequisites

- iOS 16.0 or later
- Xcode 15.0 or later
- Swift 5.9 or later
- A Privy account (for authentication) - [Sign up at privy.io](https://privy.io)
- A Coinbase Commerce account (for payments) - [Sign up at commerce.coinbase.com](https://commerce.coinbase.com)

## Installation

### Swift Package Manager

Add ZeroSettleKit to your project using Swift Package Manager:

1. In Xcode, select **File → Add Package Dependencies**
2. Enter the package URL: `https://github.com/yourusername/ZeroSettleKit.git`
3. Select the version you want to use
4. Click **Add Package**

Alternatively, add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/ZeroSettleKit.git", from: "1.0.0")
]
```

## Configuration

### 1. Get Your API Keys

#### Privy App ID

1. Go to [dashboard.privy.io](https://dashboard.privy.io)
2. Create a new app or select an existing one
3. Copy your App ID from the dashboard

#### Coinbase Commerce API Key

1. Go to [commerce.coinbase.com/dashboard](https://commerce.coinbase.com/dashboard)
2. Navigate to **Settings → API Keys**
3. Create a new API key and save it securely

### 2. Configure Info.plist

Add the Privy URL scheme to your app's `Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>privy-YOUR_APP_ID</string>
        </array>
    </dict>
</array>
```

Replace `YOUR_APP_ID` with your actual Privy App ID.

### 3. Initialize ZeroSettleKit

In your app's main entry point (typically `App.swift`), initialize ZeroSettleKit:

```swift
import SwiftUI
import ZeroSettleKit

@main
struct YourApp: App {
    @StateObject private var settleManager: ZeroSettleManager

    init() {
        // Configure ZeroSettleKit
        let config = ZeroSettleConfig(
            privyAppId: "YOUR_PRIVY_APP_ID",
            coinbaseApiKey: "YOUR_COINBASE_API_KEY",
            environment: .sandbox // Use .production for live transactions
        )

        _settleManager = StateObject(wrappedValue: ZeroSettleManager(config: config))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settleManager)
                .task {
                    await settleManager.initialize()
                }
        }
    }
}
```

### 4. Handle URL Callbacks

ZeroSettleKit uses URL callbacks for authentication. Add this to your `App` struct:

```swift
var body: some Scene {
    WindowGroup {
        ContentView()
            .environmentObject(settleManager)
            .onOpenURL { url in
                Task {
                    await settleManager.handleAuthCallback(url: url)
                }
            }
    }
}
```

## Verify Installation

Create a simple test to verify everything is working:

```swift
import SwiftUI
import ZeroSettleKit

struct ContentView: View {
    @EnvironmentObject var settleManager: ZeroSettleManager

    var body: some View {
        VStack(spacing: 20) {
            Text("ZeroSettleKit Status")
                .font(.headline)

            if settleManager.isInitialized {
                Text("✅ Initialized")
                    .foregroundColor(.green)
            } else {
                Text("⏳ Initializing...")
                    .foregroundColor(.orange)
            }

            if settleManager.isAuthenticated {
                Text("✅ Authenticated")
                    .foregroundColor(.green)
                Text("User: \(settleManager.currentUser?.phoneNumber ?? "Unknown")")
                    .font(.caption)
            } else {
                Text("❌ Not Authenticated")
                    .foregroundColor(.red)

                Button("Sign In") {
                    Task {
                        try? await settleManager.authenticate()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
```

Run your app. You should see "✅ Initialized" once ZeroSettleKit has loaded successfully.

## Environment Setup

ZeroSettleKit supports two environments:

### Sandbox (Development)

Use sandbox mode during development to test without real money:

```swift
let config = ZeroSettleConfig(
    privyAppId: "your-app-id",
    coinbaseApiKey: "your-api-key",
    environment: .sandbox
)
```

Sandbox mode uses:
- Privy test environment
- Coinbase Commerce test mode
- Solana Devnet

### Production

Switch to production when you're ready to go live:

```swift
let config = ZeroSettleConfig(
    privyAppId: "your-app-id",
    coinbaseApiKey: "your-api-key",
    environment: .production
)
```

Production mode uses:
- Privy production environment
- Coinbase Commerce live mode
- Solana Mainnet

## Security Best Practices

### Never Commit API Keys

Store your API keys securely and never commit them to version control:

1. Create a `Config.xcconfig` file (add to `.gitignore`)
2. Store keys in the xcconfig file
3. Reference them in your build settings

Or use environment variables:

```swift
let config = ZeroSettleConfig(
    privyAppId: ProcessInfo.processInfo.environment["PRIVY_APP_ID"] ?? "",
    coinbaseApiKey: ProcessInfo.processInfo.environment["COINBASE_API_KEY"] ?? "",
    environment: .sandbox
)
```

### Use Keychain for Sensitive Data

ZeroSettleKit automatically stores authentication tokens in the Keychain, but you should also use Keychain for any additional sensitive data.

## Troubleshooting

### "Privy initialization failed"

- Verify your App ID is correct
- Check that your URL scheme is properly configured in Info.plist
- Make sure you're using a valid Privy account

### "Coinbase API authentication failed"

- Verify your API key is correct
- Make sure your API key has the correct permissions in Coinbase Commerce
- Check that you're using the correct environment (sandbox vs production)

### "Module not found: ZeroSettleKit"

- Verify the package was added correctly in Xcode
- Clean build folder (Cmd+Shift+K) and rebuild
- Check that your deployment target is iOS 16.0 or later

## Next Steps

Now that ZeroSettleKit is installed and configured, you're ready to build your first payment flow!

- <doc:Quickstart> - Build a complete payment flow in 10 minutes
- <doc:Architecture> - Understand how ZeroSettleKit is structured
- <doc:Authentication> - Deep dive into user authentication

## See Also

- ``ZeroSettleConfig``
- ``ZeroSettleManager``
- <doc:Security>
