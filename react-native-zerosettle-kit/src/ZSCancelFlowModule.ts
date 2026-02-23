import { NativeModules, Platform } from 'react-native';

const { ZSCancelFlowModule } = NativeModules;

// -- Types --

export interface CancelFlowOption {
  id: number;
  order: number;
  label: string;
  triggersOffer: boolean;
  triggersPause: boolean;
}

export interface CancelFlowQuestion {
  id: number;
  order: number;
  questionText: string;
  questionType: 'single_select' | 'free_text';
  isRequired: boolean;
  options: CancelFlowOption[];
}

export interface CancelFlowOffer {
  enabled: boolean;
  title: string;
  body: string;
  ctaText: string;
  type: string;
  value: string;
}

export interface CancelFlowPauseOption {
  id: number;
  order: number;
  label: string;
  durationType: 'days' | 'fixed_date';
  durationDays?: number;
}

export interface CancelFlowPause {
  enabled: boolean;
  title: string;
  body: string;
  ctaText: string;
  options: CancelFlowPauseOption[];
}

export interface CancelFlowConfig {
  enabled: boolean;
  questions: CancelFlowQuestion[];
  offer?: CancelFlowOffer;
  pause?: CancelFlowPause;
}

export interface SaveOfferResult {
  message: string;
  discountPercent?: number;
  durationMonths?: number;
}

export type CancelFlowOutcome = 'cancelled' | 'retained' | 'paused' | 'dismissed';

export interface CancelFlowAnswer {
  questionId: number;
  selectedOptionId?: number;
  freeText?: string;
}

export interface CancelFlowResponse {
  productId: string;
  userId: string;
  outcome: CancelFlowOutcome;
  answers: CancelFlowAnswer[];
  offerShown: boolean;
  offerAccepted: boolean;
  pauseShown: boolean;
  pauseAccepted: boolean;
  pauseDurationDays?: number;
}

// -- API --

/**
 * Get the cached cancel flow configuration.
 *
 * This is fetched automatically during bootstrap, so no extra network call is needed.
 * Returns `null` if cancel flow is not configured for this app.
 */
export function getCancelFlowConfig(): Promise<CancelFlowConfig | null> {
  if (Platform.OS !== 'ios') {
    console.warn('[ZeroSettleKit] getCancelFlowConfig is only available on iOS');
    return Promise.resolve(null);
  }

  if (!ZSCancelFlowModule?.getCancelFlowConfig) {
    console.error('[ZeroSettleKit] ZSCancelFlowModule not found');
    return Promise.resolve(null);
  }

  return ZSCancelFlowModule.getCancelFlowConfig();
}

/**
 * Accept the save offer for a subscription.
 *
 * Applies the configured discount (e.g., 40% off for 3 months) to the user's
 * subscription via Stripe.
 *
 * @param productId - The product the user is cancelling
 * @param userId - Your app's user identifier
 * @returns The applied offer details
 * @throws If the offer cannot be applied
 */
export function acceptSaveOffer(productId: string, userId: string): Promise<SaveOfferResult> {
  if (Platform.OS !== 'ios') {
    return Promise.reject(new Error('[ZeroSettleKit] acceptSaveOffer is only available on iOS'));
  }

  if (!ZSCancelFlowModule?.acceptSaveOffer) {
    return Promise.reject(new Error('[ZeroSettleKit] ZSCancelFlowModule not found'));
  }

  return ZSCancelFlowModule.acceptSaveOffer(productId, userId);
}

/**
 * Submit the cancel flow analytics response.
 *
 * Call this after the user completes your custom cancel flow UI to record
 * the outcome and questionnaire answers for analytics.
 *
 * This is fire-and-forget — it resolves immediately and does not throw.
 *
 * @param response - The cancel flow response with outcome and answers
 */
export function submitCancelFlowResponse(response: CancelFlowResponse): Promise<void> {
  if (Platform.OS !== 'ios') {
    return Promise.resolve();
  }

  if (!ZSCancelFlowModule?.submitCancelFlowResponse) {
    return Promise.resolve();
  }

  return ZSCancelFlowModule.submitCancelFlowResponse(response);
}

/**
 * Pause a subscription for the given pause option.
 *
 * @param productId - The product to pause
 * @param userId - Your app's user identifier
 * @param pauseOptionId - The ID of the selected pause option from the config
 * @returns ISO 8601 date string when the subscription resumes, or `null`
 * @throws If the pause fails
 */
export function pauseSubscription(productId: string, userId: string, pauseOptionId: number): Promise<string | null> {
  if (Platform.OS !== 'ios') {
    return Promise.reject(new Error('[ZeroSettleKit] pauseSubscription is only available on iOS'));
  }

  if (!ZSCancelFlowModule?.pauseSubscription) {
    return Promise.reject(new Error('[ZeroSettleKit] ZSCancelFlowModule not found'));
  }

  return ZSCancelFlowModule.pauseSubscription(productId, userId, pauseOptionId);
}

/**
 * Resume a previously paused subscription.
 *
 * @param productId - The product to resume
 * @param userId - Your app's user identifier
 * @throws If the resume fails
 */
export function resumeSubscription(productId: string, userId: string): Promise<void> {
  if (Platform.OS !== 'ios') {
    return Promise.reject(new Error('[ZeroSettleKit] resumeSubscription is only available on iOS'));
  }

  if (!ZSCancelFlowModule?.resumeSubscription) {
    return Promise.reject(new Error('[ZeroSettleKit] ZSCancelFlowModule not found'));
  }

  return ZSCancelFlowModule.resumeSubscription(productId, userId);
}

/**
 * Cancel a subscription.
 *
 * @param productId - The product to cancel
 * @param userId - Your app's user identifier
 * @param immediate - If `true`, cancel immediately. If `false` (default), cancel at period end.
 * @throws If the cancellation fails
 */
export function cancelSubscription(productId: string, userId: string, immediate: boolean = false): Promise<void> {
  if (Platform.OS !== 'ios') {
    return Promise.reject(new Error('[ZeroSettleKit] cancelSubscription is only available on iOS'));
  }

  if (!ZSCancelFlowModule?.cancelSubscription) {
    return Promise.reject(new Error('[ZeroSettleKit] ZSCancelFlowModule not found'));
  }

  return ZSCancelFlowModule.cancelSubscription(productId, userId, immediate);
}

/**
 * Open the Stripe customer portal for the user.
 *
 * @param userId - Your app's user identifier
 * @throws If the portal cannot be opened
 */
export function openCustomerPortal(userId: string): Promise<void> {
  if (Platform.OS !== 'ios') {
    return Promise.reject(new Error('[ZeroSettleKit] openCustomerPortal is only available on iOS'));
  }

  if (!ZSCancelFlowModule?.openCustomerPortal) {
    return Promise.reject(new Error('[ZeroSettleKit] ZSCancelFlowModule not found'));
  }

  return ZSCancelFlowModule.openCustomerPortal(userId);
}
