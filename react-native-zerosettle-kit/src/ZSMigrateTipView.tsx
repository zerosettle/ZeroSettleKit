import {
  requireNativeComponent,
  type ViewStyle,
  type StyleProp,
  Platform,
  View,
} from 'react-native';

export interface ZSMigrateTipViewProps {
  /**
   * Background color for the tip view in hex format (e.g., "#FF5733")
   * @default "#000000"
   */
  backgroundColorHex?: string;

  /**
   * Style for the container view
   */
  style?: StyleProp<ViewStyle>;
}

interface NativeProps {
  backgroundColorHex?: string;
  style?: StyleProp<ViewStyle>;
}

const NativeZSMigrateTipView =
  Platform.OS === 'ios'
    ? requireNativeComponent<NativeProps>('ZSMigrateTipView')
    : null;

/**
 * ZSMigrateTipView - A React Native component that displays the ZeroSettleKit
 * migrate tip view for iOS. This view helps users migrate from Apple billing
 * to direct billing with a 15% discount.
 *
 * @example
 * ```tsx
 * import { ZSMigrateTipView } from 'react-native-zerosettle-kit';
 *
 * function MyComponent() {
 *   return (
 *     <ZSMigrateTipView
 *       backgroundColorHex="#1E1E1E"
 *       style={{ marginHorizontal: 16 }}
 *     />
 *   );
 * }
 * ```
 */
export function ZSMigrateTipView({
  backgroundColorHex = '#000000',
  style,
}: ZSMigrateTipViewProps) {
  if (Platform.OS !== 'ios' || !NativeZSMigrateTipView) {
    // Return empty view on non-iOS platforms
    return <View style={style} />;
  }

  return (
    <NativeZSMigrateTipView
      backgroundColorHex={backgroundColorHex}
      style={style}
    />
  );
}

export default ZSMigrateTipView;
