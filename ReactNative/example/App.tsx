import React from 'react';
import {
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  View,
  StatusBar,
} from 'react-native';
import { ZSMigrateTipView } from '@zerosettle/react-native';

function App(): React.JSX.Element {
  return (
    <SafeAreaView style={styles.container}>
      <StatusBar barStyle="light-content" backgroundColor="#000000" />
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        style={styles.scrollView}
        contentContainerStyle={styles.scrollContent}>
        {/* Header */}
        <View style={styles.header}>
          <Text style={styles.title}>ZeroSettle Demo</Text>
          <Text style={styles.subtitle}>
            React Native + SwiftUI Integration
          </Text>
        </View>

        {/* ZSMigrateTipView - handles all state internally */}
        <ZSMigrateTipView
          backgroundColorHex="#1A1A1A"
          style={styles.tipView}
        />

        {/* Footer info */}
        <View style={styles.footer}>
          <Text style={styles.footerText}>
            The tip view above manages its own state:
          </Text>
          <Text style={styles.footerBullet}>• Expand/collapse animation</Text>
          <Text style={styles.footerBullet}>• Web checkout flow</Text>
          <Text style={styles.footerBullet}>• Persistent dismissal</Text>
          <Text style={styles.footerBullet}>• Confetti on success</Text>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000000',
  },
  scrollView: {
    flex: 1,
  },
  scrollContent: {
    padding: 16,
    paddingBottom: 100,
  },
  header: {
    marginBottom: 24,
    paddingTop: 20,
  },
  title: {
    fontSize: 32,
    fontWeight: 'bold',
    color: '#FFFFFF',
  },
  subtitle: {
    fontSize: 16,
    color: 'rgba(255, 255, 255, 0.7)',
    marginTop: 4,
  },
  tipView: {
    width: '100%',
    borderRadius: 16,
    overflow: 'hidden',
  },
  footer: {
    marginTop: 32,
    padding: 16,
    backgroundColor: 'rgba(255, 255, 255, 0.05)',
    borderRadius: 12,
  },
  footerText: {
    fontSize: 14,
    color: 'rgba(255, 255, 255, 0.8)',
    marginBottom: 12,
  },
  footerBullet: {
    fontSize: 13,
    color: 'rgba(255, 255, 255, 0.6)',
    marginLeft: 8,
    marginBottom: 4,
  },
});

export default App;
