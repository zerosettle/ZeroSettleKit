import { View, StyleSheet, SafeAreaView, Text } from 'react-native';
import { ZSMigrateTipView } from 'react-native-zerosettle-kit';

export default function App() {
  return (
    <SafeAreaView style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.title}>ZeroSettleKit Example</Text>
        <Text style={styles.subtitle}>
          The ZSMigrateTipView below demonstrates the billing migration UI
        </Text>
      </View>

      <View style={styles.tipContainer}>
        <ZSMigrateTipView
          backgroundColorHex="#1E1E1E"
          style={styles.tipView}
        />
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#121212',
  },
  header: {
    padding: 20,
    paddingTop: 40,
  },
  title: {
    fontSize: 28,
    fontWeight: 'bold',
    color: '#FFFFFF',
    marginBottom: 8,
  },
  subtitle: {
    fontSize: 16,
    color: '#AAAAAA',
  },
  tipContainer: {
    flex: 1,
    paddingHorizontal: 16,
    paddingTop: 20,
  },
  tipView: {
    // The view will size itself based on content
    minHeight: 220,
  },
});
