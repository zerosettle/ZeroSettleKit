# react-native-zerosettle-kit

React Native bridge for the [ZeroSettleKit](https://github.com/ZeroSettle/ZeroSettleKit) iOS SDK. This package exposes the `ZSMigrateTipView` SwiftUI component as a React Native view.

## Features

- **iOS-only**: This package wraps iOS-native SwiftUI views
- **ZSMigrateTipView**: A beautiful UI component for migrating users from Apple billing to direct billing with a 15% discount
- **Automatic state management**: Handles checkout flow, success states, and persistent dismissal

## Installation

```bash
npm install react-native-zerosettle-kit
# or
yarn add react-native-zerosettle-kit
```

### iOS Setup

1. Ensure iOS 17.0+ in your Podfile:

```ruby
platform :ios, '17.0'
```

2. Install pods:

```bash
cd ios && pod install
```

That's it! The package automatically pulls in `ZeroSettleKit` from CocoaPods.

## Usage

```tsx
import { ZSMigrateTipView } from 'react-native-zerosettle-kit';

function MyScreen() {
  return (
    <View style={{ flex: 1 }}>
      <ZSMigrateTipView
        backgroundColorHex="#1E1E1E"
        style={{ marginHorizontal: 16, marginTop: 20 }}
      />
    </View>
  );
}
```

## Props

| Prop | Type | Default | Description |
|------|------|---------|-------------|
| `backgroundColorHex` | `string` | `"#000000"` | Background color in hex format (e.g., `"#FF5733"`) |
| `style` | `ViewStyle` | - | Standard React Native view style |

## How It Works

The `ZSMigrateTipView` component:

1. Shows a promotional banner encouraging users to switch from Apple billing to direct billing
2. Expands to show a Stripe checkout form when tapped
3. Handles the checkout flow inline with Apple Pay and card options
4. After successful checkout, prompts users to cancel their Apple subscription
5. Shows a congratulations message with confetti on completion
6. Persists the dismissed state so users don't see it again

## Platform Support

| Platform | Supported |
|----------|-----------|
| iOS | ✅ (17.0+) |
| Android | ❌ (renders empty view) |

## Example

Check out the [example app](./example) to see the component in action:

```bash
# Install dependencies
yarn

# Run the example on iOS
yarn example ios
```

## License

MIT
