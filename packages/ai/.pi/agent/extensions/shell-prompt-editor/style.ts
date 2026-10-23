export type RgbColor = {
  r: number
  g: number
  b: number
}

export type TerminalScheme = "dark" | "light"
export type SchemeOverride = TerminalScheme | "auto"
export type SegmentTone = "primary" | "secondary" | "accent" | "muted"

export type BarStyle = {
  background: RgbColor
  foreground: Record<SegmentTone, RgbColor>
  separator: RgbColor
  chrome: RgbColor
  prompt: RgbColor
  spinner: RgbColor
}

type TerminalColorProbe = {
  queryTerminalColorScheme(options: { timeoutMs: number }): Promise<TerminalScheme | undefined>
  queryTerminalBackgroundColor(options: { timeoutMs: number }): Promise<RgbColor | undefined>
}

// CharmTone-inspired palettes used by Crush. The light variant keeps the same
// color families with darker ramps for contrast.(采用 Crush 的 CharmTone 色系，浅色终端使用更深色阶以保证对比度。)
const BAR_STYLES: Record<TerminalScheme, BarStyle> = {
  dark: {
    background: { r: 45, g: 44, b: 54 }, // BBQ #2D2C36
    foreground: {
      primary: { r: 139, g: 117, b: 255 },   // Hazy #8B75FF
      secondary: { r: 255, g: 96, b: 255 }, // Dolly #FF60FF
      accent: { r: 104, g: 255, b: 214 },   // Bok #68FFD6
      muted: { r: 191, g: 188, b: 200 },    // Smoke #BFBCC8
    },
    separator: { r: 96, g: 95, b: 107 }, // Oyster #605F6B
    chrome: { r: 133, g: 131, b: 146 },  // Squid #858392
    prompt: { r: 139, g: 117, b: 255 },  // Hazy #8B75FF
    spinner: { r: 104, g: 255, b: 214 }, // Bok #68FFD6
  },
  light: {
    background: { r: 247, g: 246, b: 251 }, // Salt #F7F6FB
    foreground: {
      primary: { r: 91, g: 64, b: 236 },    // Darple #5B40EC
      secondary: { r: 171, g: 36, b: 84 },  // Pom #AB2454
      accent: { r: 0, g: 122, b: 104 },     // Deep Pickle, adapted for contrast
      muted: { r: 77, g: 76, b: 87 },       // Iron #4D4C57
    },
    separator: { r: 162, g: 160, b: 173 }, // Steam #A2A0AD
    chrome: { r: 96, g: 95, b: 107 },      // Oyster #605F6B
    prompt: { r: 91, g: 64, b: 236 },      // Darple #5B40EC
    spinner: { r: 0, g: 122, b: 104 },     // Deep Pickle, adapted for contrast
  },
}

export function normalizeSchemeOverride(value?: string): SchemeOverride {
  const normalized = value?.trim().toLowerCase()
  return normalized === "dark" || normalized === "light" ? normalized : "auto"
}

export function inferTerminalScheme(background: RgbColor): TerminalScheme {
  const linearize = (channel: number) => {
    const normalized = Math.max(0, Math.min(255, channel)) / 255
    return normalized <= 0.04045
      ? normalized / 12.92
      : ((normalized + 0.055) / 1.055) ** 2.4
  }
  const luminance =
    0.2126 * linearize(background.r) +
    0.7152 * linearize(background.g) +
    0.0722 * linearize(background.b)
  return luminance >= 0.5 ? "light" : "dark"
}

export function getBarStyle(scheme: TerminalScheme): BarStyle {
  return BAR_STYLES[scheme]
}

export async function detectTerminalScheme(
  tui: TerminalColorProbe,
  override: SchemeOverride,
): Promise<TerminalScheme> {
  if (override !== "auto") return override

  try {
    const reported = await tui.queryTerminalColorScheme({ timeoutMs: 150 })
    if (reported === "dark" || reported === "light") return reported
  } catch {
    // Fall through to OSC 11 background probing.(失败时回退到 OSC 11 背景探测。)
  }

  try {
    const background = await tui.queryTerminalBackgroundColor({ timeoutMs: 150 })
    if (background) return inferTerminalScheme(background)
  } catch {
    // Dark is the approved final fallback.(最终按已确认方案回退深色。)
  }

  return "dark"
}
