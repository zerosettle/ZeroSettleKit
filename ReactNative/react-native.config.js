module.exports = {
  dependency: {
    platforms: {
      ios: {
        // Podspec is at the package root (not in ios/)
        podspecPath: './zerosettle-react-native.podspec',
      },
      android: null, // iOS-only package
    },
  },
};
