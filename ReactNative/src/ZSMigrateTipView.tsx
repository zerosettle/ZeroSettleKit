import * as React from 'react';
import {
  requireNativeComponent,
  ViewProps,
  StyleSheet,
  Platform,
} from 'react-native';

/**
 * Props for ZSMigrateTipView component.
 *
 * The view internally manages:
 * - expand/collapse state
 * - web checkout flow
 * - persistent dismissal (via UserDefaults)
 * - confetti/success animations
 * - content height changes
 *
 * No state is controlled from React Native - this is an uncontrolled component.
 */
export interface ZSMigrateTipViewProps extends ViewProps {
  /**
   * Background color as hex string (e.g., "#111111", "#1A1A1A").
   * This color is applied to the view background and propagated to the web checkout.
   * @default "#000000"
   */
  backgroundColorHex?: string;
}

// Native component - only available on iOS
const NativeZSMigrateTipView =
  Platform.OS === 'ios'
    ? requireNativeComponent<ZSMigrateTipViewProps>('ZSMigrateTipViewManager')
    : null;

/**
 * A SwiftUI-based tip view that encourages users to migrate from Apple billing
 * to direct web checkout for a 15% discount.
 *
 * This component is iOS-only and renders nothing on other platforms.
 *
 * @example
 * ```tsx
 * import { ZSMigrateTipView } from '@zerosettle/react-native';
 *
 * function MyScreen() {
 *   return (
 *     <ZSMigrateTipView
 *       backgroundColorHex="#121212"
 *       style={{ width: '100%' }}
 *     />
 *   );
 * }
 * ```
 *
 * @remarks
 * The view can expand up to ~690pt when showing the card checkout form.
 * Ensure the parent container can accommodate this height, or place the
 * view inside a ScrollView.
 */
export function ZSMigrateTipView({
  backgroundColorHex = '#000000',
  style,
  ...restProps
}: ZSMigrateTipViewProps): React.ReactElement | null {
  // Only render on iOS
  if (Platform.OS !== 'ios' || !NativeZSMigrateTipView) {
    return null;
  }

  return (
    <NativeZSMigrateTipView
      backgroundColorHex={backgroundColorHex}
      style={[styles.container, style]}
      {...restProps}
    />
  );
}

const styles = StyleSheet.create({
  container: {
    // Default to full width, let height be determined by content
    width: '100%',
    // Minimum height for collapsed state
    minHeight: 220,
  },
});

export default ZSMigrateTipView;
