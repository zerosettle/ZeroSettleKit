import { NativeModules, Platform } from 'react-native';

const { ZSMigrateTipModule } = NativeModules;

/**
 * Present the ZSMigrateTipView as a modal overlay.
 * This is the recommended approach as it ensures Apple Pay works correctly.
 *
 * Free trial days are automatically calculated based on when the user's current
 * StoreKit subscription expires, so they won't be charged until their Apple
 * subscription ends.
 *
 * @param backgroundColorHex - Background color in hex format (e.g., "#1E1E1E")
 * @param userId - The user identifier passed to the checkout backend.
 *
 * @example
 * ```tsx
 * import { presentMigrateTip } from 'react-native-zerosettle-kit';
 *
 * // Show the migrate tip modal
 * presentMigrateTip('#1E1E1E', 'my_user_id');
 * ```
 */
export function presentMigrateTip(backgroundColorHex: string = '#000000', userId: string): void {
  if (Platform.OS !== 'ios') {
    console.warn('[ZeroSettleKit] presentMigrateTip is only available on iOS');
    return;
  }

  if (!ZSMigrateTipModule?.presentMigrateTip) {
    console.error('[ZeroSettleKit] ZSMigrateTipModule not found');
    return;
  }

  ZSMigrateTipModule.presentMigrateTip(backgroundColorHex, userId);
}

/**
 * Dismiss the ZSMigrateTipView modal if it's currently presented.
 *
 * @example
 * ```tsx
 * import { dismissMigrateTip } from 'react-native-zerosettle-kit';
 *
 * dismissMigrateTip();
 * ```
 */
export function dismissMigrateTip(): void {
  if (Platform.OS !== 'ios') {
    return;
  }

  ZSMigrateTipModule?.dismissMigrateTip?.();
}
