import { View, StyleSheet, SafeAreaView, ScrollView } from 'react-native';
import { ZSMigrateTipView } from 'react-native-zerosettle-kit';

export default function App() {
  return (
    <SafeAreaView style={styles.container}>
      <ScrollView contentContainerStyle={styles.scrollContent}>
        {/* The migrate tip view - always visible */}
        <ZSMigrateTipView
          backgroundColorHex="#1E1E1E"
          userId="example_user"
          style={styles.tipView}
        />
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#121212',
  },
  scrollContent: {
    padding: 16,
    paddingTop: 60,
  },
  tipView: {
    minHeight: 220,
  },
});
