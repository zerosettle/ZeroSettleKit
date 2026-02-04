import { NativeModules, Platform } from 'react-native';

const { ZSMigrateTipModule } = NativeModules;

/**
 * Present the ZSMigrateTipView as a modal overlay.
 * This is the recommended approach as it ensures Apple Pay works correctly.
 *
 * @param backgroundColorHex - Background color in hex format (e.g., "#1E1E1E")
 *
 * @example
 * ```tsx
 * import { presentMigrateTip } from 'react-native-zerosettle-kit';
 *
 * // Show the migrate tip modal
 * presentMigrateTip('#1E1E1E');
 * ```
 */
export function presentMigrateTip(backgroundColorHex: string = '#000000'): void {
  if (Platform.OS !== 'ios') {
    console.warn('[ZeroSettleKit] presentMigrateTip is only available on iOS');
    return;
  }

  if (!ZSMigrateTipModule?.presentMigrateTip) {
    console.error('[ZeroSettleKit] ZSMigrateTipModule not found');
    return;
  }

  ZSMigrateTipModule.presentMigrateTip(backgroundColorHex);
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
