// Colours and sizes carried over from the original Alive & Well page: calm
// green for "I'm OK", a strong red for help, and large type throughout because
// the main user is a senior.

export const Colors = {
  light: {
    background: '#EEF3F1',
    surface: '#FFFFFF',
    sunk: '#E3EBE8',
    text: '#13231F',
    muted: '#4A5C57',
    line: '#C6D4CE',
    ok: '#1E6A4E',
    okText: '#FFFFFF',
    okSoft: '#DCEDE5',
    help: '#B2361D',
    helpText: '#FFFFFF',
    helpSoft: '#F6E1DA',
    accent: '#2B5C88',
    accentText: '#FFFFFF',
  },
  dark: {
    background: '#0E1916',
    surface: '#162420',
    sunk: '#1C2D28',
    text: '#E5EEEA',
    muted: '#A2B4AD',
    line: '#2D403A',
    ok: '#3E9F78',
    okText: '#04130D',
    okSoft: '#173329',
    help: '#E0694E',
    helpText: '#1A0703',
    helpSoft: '#3A1E17',
    accent: '#8CB7DF',
    accentText: '#0E1916',
  },
} as const;

export type ThemeColors = { [K in keyof typeof Colors.light]: string };

export const Spacing = { xs: 4, sm: 8, md: 16, lg: 24, xl: 32 } as const;

export const FontSize = { small: 16, body: 20, large: 24, title: 32 } as const;

// Smallest comfortable tap target for older hands.
export const MinTouch = 56;

export const MaxContentWidth = 560;
