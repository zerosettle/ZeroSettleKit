import { NativeModules, Platform } from 'react-native';

const { ZSSaveTheSaleModule } = NativeModules;

export type ZSSaveTheSaleResult = 'pauseAccount' | 'stayWithDiscount' | 'dismissed';

/**
 * Present the save-the-sale retention sheet.
 *
 * Shows two options: Pause Account and Stay & Save 40%.
 * Returns a promise that resolves with the user's choice.
 *
 * @returns The user's selection: `'pauseAccount'`, `'stayWithDiscount'`, or `'dismissed'`
 *
 * @example
 * ```tsx
 * import { presentSaveTheSaleSheet } from 'react-native-zerosettle-kit';
 *
 * const result = await presentSaveTheSaleSheet();
 * if (result === 'stayWithDiscount') {
 *   // Apply 40% discount
 * }
 * ```
 */
export function presentSaveTheSaleSheet(): Promise<ZSSaveTheSaleResult> {
  if (Platform.OS !== 'ios') {
    console.warn('[ZeroSettleKit] presentSaveTheSaleSheet is only available on iOS');
    return Promise.resolve('dismissed');
  }

  if (!ZSSaveTheSaleModule?.presentSaveTheSaleSheet) {
    console.error('[ZeroSettleKit] ZSSaveTheSaleModule not found');
    return Promise.resolve('dismissed');
  }

  return ZSSaveTheSaleModule.presentSaveTheSaleSheet();
}

/**
 * Dismiss the save-the-sale sheet if it's currently presented.
 *
 * @example
 * ```tsx
 * import { dismissSaveTheSaleSheet } from 'react-native-zerosettle-kit';
 *
 * dismissSaveTheSaleSheet();
 * ```
 */
export function dismissSaveTheSaleSheet(): void {
  if (Platform.OS !== 'ios') {
    return;
  }

  ZSSaveTheSaleModule?.dismissSaveTheSaleSheet?.();
}
