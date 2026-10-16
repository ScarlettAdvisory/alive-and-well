import { Tabs } from 'expo-router/tabs';

import { FontSize } from '@/constants/theme';
import { useTheme } from '@/hooks/use-theme';
import { useCircle } from '@/lib/circle';

// Labels only, in large type: clearer for older eyes than small icons.
export default function TabsLayout() {
  const c = useTheme();
  const { role } = useCircle();
  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarActiveTintColor: c.accent,
        tabBarInactiveTintColor: c.muted,
        tabBarStyle: { backgroundColor: c.surface, borderTopColor: c.line, minHeight: 64 },
        tabBarLabelStyle: { fontSize: FontSize.small, fontWeight: '700' },
        tabBarIconStyle: { display: 'none' },
        tabBarLabelPosition: 'below-icon',
      }}>
      <Tabs.Screen name="index" options={{ title: role === 'senior' ? 'Check in' : 'Today' }} />
      <Tabs.Screen name="people" options={{ title: 'People' }} />
      <Tabs.Screen name="schedule" options={{ title: 'Schedule' }} />
      <Tabs.Screen name="history" options={{ title: 'History' }} />
    </Tabs>
  );
}
