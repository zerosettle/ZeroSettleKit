const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');
const path = require('path');

const root = path.resolve(__dirname, '..');

/**
 * Metro configuration for the example app.
 * Includes watchFolders to resolve the local package.
 */
const config = {
  watchFolders: [root],
  resolver: {
    extraNodeModules: {
      '@zerosettle/react-native': root,
    },
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
