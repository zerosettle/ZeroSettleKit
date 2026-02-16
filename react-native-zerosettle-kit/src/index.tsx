// ZSMigrateTipView - iOS-only component for migrate tip UI (inline view)
export { ZSMigrateTipView, default } from './ZSMigrateTipView';
export type { ZSMigrateTipViewProps } from './ZSMigrateTipView';

// Modal presentation API (recommended for Apple Pay support)
export { presentMigrateTip, dismissMigrateTip } from './ZSMigrateTipModule';

// Save-the-sale retention sheet
export { presentSaveTheSaleSheet, dismissSaveTheSaleSheet } from './ZSSaveTheSaleModule';
export type { ZSSaveTheSaleResult } from './ZSSaveTheSaleModule';

// Re-export the Fabric component for new architecture users
export { default as ZerosettleKitView } from './ZerosettleKitViewNativeComponent';
export * from './ZerosettleKitViewNativeComponent';
