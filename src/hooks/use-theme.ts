import { useColorScheme } from 'react-native';

import { Colors, type ThemeColors } from '@/constants/theme';

export function useTheme(): ThemeColors {
  return Colors[useColorScheme() === 'dark' ? 'dark' : 'light'];
}
