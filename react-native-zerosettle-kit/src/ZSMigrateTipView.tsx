import {
  requireNativeComponent,
  type ViewStyle,
  type StyleProp,
  Platform,
  View,
} from 'react-native';

export interface ZSMigrateTipViewProps {
  /**
   * The user identifier passed to the checkout backend.
   */
  userId: string;

  /**
   * Optional existing Stripe Customer ID (`cus_xxx`) to attach the checkout to.
   * When provided, the backend uses this customer instead of creating a new one.
   */
  stripeCustomerId?: string;

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
  userId?: string;
  stripeCustomerId?: string;
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
 * Free trial days are automatically calculated based on when the user's current
 * StoreKit subscription expires, so they won't be charged until their Apple
 * subscription ends.
 *
 * @example
 * ```tsx
 * import { ZSMigrateTipView } from 'react-native-zerosettle-kit';
 *
 * function MyComponent() {
 *   return (
 *     <ZSMigrateTipView
 *       userId="my_user_id"
 *       backgroundColorHex="#1E1E1E"
 *       style={{ marginHorizontal: 16 }}
 *     />
 *   );
 * }
 * ```
 */
export function ZSMigrateTipView({
  userId,
  stripeCustomerId,
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
      userId={userId}
      stripeCustomerId={stripeCustomerId}
      style={style}
    />
  );
}

export default ZSMigrateTipView;
