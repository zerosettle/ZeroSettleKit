# @zerosettle/react-native

React Native bindings for ZeroSettle iOS SDK components. Exposes SwiftUI views as native React Native components.

## Installation

```bash
yarn add @zerosettle/react-native
# or
npm install @zerosettle/react-native
```

Then install pods:

```bash
cd ios && pod install
```

## Requirements

- iOS 17.0+
- React Native 0.70+
- Xcode 15+

## Usage

### ZSMigrateTipView

A SwiftUI-based tip view that encourages users to migrate from Apple billing to direct web checkout for a 15% discount.

```tsx
import { ZSMigrateTipView } from '@zerosettle/react-native';

function MyScreen() {
  return (
    <ZSMigrateTipView
      backgroundColorHex="#121212"
      style={{ width: '100%' }}
    />
  );
}
```

### Props

| Prop | Type | Default | Description |
|------|------|---------|-------------|
| `backgroundColorHex` | `string` | `"#000000"` | Background color as hex string (e.g., "#111111") |
| `style` | `ViewStyle` | - | Standard React Native view styles |

### Important Notes

The view internally manages all state:
- **Expand/collapse animation** - Tapping "Save 15% Forever" expands the checkout
- **Web checkout flow** - Embedded Stripe checkout with Apple Pay and card support
- **Persistent dismissal** - Dismissing saves to UserDefaults across app launches
- **Confetti/success animations** - Celebratory animations on successful checkout
- **Content height changes** - Automatically adjusts height (220pt collapsed, up to 690pt for card entry)

**No state is controlled from React Native** - this is an uncontrolled component.

### Layout Considerations

The view can expand to approximately 690pt when showing the card checkout form. Ensure your layout can accommodate this:

```tsx
// Option 1: Inside a ScrollView
<ScrollView>
  <ZSMigrateTipView backgroundColorHex="#1A1A1A" />
  {/* Other content */}
</ScrollView>

// Option 2: In a container with enough height
<View style={{ flex: 1 }}>
  <ZSMigrateTipView backgroundColorHex="#1A1A1A" />
</View>
```

## Example App

See the `example/` directory for a complete working example:

```bash
cd ReactNative/example
yarn install
cd ios && pod install && cd ..
yarn ios
```

## Platform Support

This package is **iOS-only**. On Android and other platforms, `ZSMigrateTipView` renders `null`.

## License

MIT
