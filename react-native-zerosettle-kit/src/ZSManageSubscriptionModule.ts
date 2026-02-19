import { NativeModules, Platform } from 'react-native';

const { ZSManageSubscriptionModule } = NativeModules;

export type ZSManageSubscriptionResult = 'pauseAccount' | 'stayWithDiscount' | 'cancelSubscription' | 'dismissed';

/**
 * Present the manage subscription retention sheet.
 *
 * Shows three options: Stay & Save 40%, Pause Account, and Cancel Subscription.
 * Returns a promise that resolves with the user's choice.
 *
 * @returns The user's selection: `'stayWithDiscount'`, `'pauseAccount'`, `'cancelSubscription'`, or `'dismissed'`
 *
 * @example
 * ```tsx
 * import { presentManageSubscriptionSheet } from 'react-native-zerosettle-kit';
 *
 * const result = await presentManageSubscriptionSheet();
 * if (result === 'stayWithDiscount') {
 *   // Apply 40% discount
 * }
 * ```
 */
export function presentManageSubscriptionSheet(): Promise<ZSManageSubscriptionResult> {
  if (Platform.OS !== 'ios') {
    console.warn('[ZeroSettleKit] presentManageSubscriptionSheet is only available on iOS');
    return Promise.resolve('dismissed');
  }

  if (!ZSManageSubscriptionModule?.presentManageSubscriptionSheet) {
    console.error('[ZeroSettleKit] ZSManageSubscriptionModule not found');
    return Promise.resolve('dismissed');
  }

  return ZSManageSubscriptionModule.presentManageSubscriptionSheet();
}

/**
 * Dismiss the manage subscription sheet if it's currently presented.
 *
 * @example
 * ```tsx
 * import { dismissManageSubscriptionSheet } from 'react-native-zerosettle-kit';
 *
 * dismissManageSubscriptionSheet();
 * ```
 */
export function dismissManageSubscriptionSheet(): void {
  if (Platform.OS !== 'ios') {
    return;
  }

  ZSManageSubscriptionModule?.dismissManageSubscriptionSheet?.();
}
