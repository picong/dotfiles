import {
  getBarStyle,
  type BarStyle,
  type RgbColor,
  type TerminalScheme,
} from "../shell-prompt-editor/style.ts"

const RESET = "\x1b[0m"
const BOLD = "\x1b[1m"
const WHITE = "\x1b[38;2;255;255;255m"

type Tone = "primary" | "secondary" | "accent" | "muted" | "chrome"
type Part = { text: string; tone: Tone; bold?: boolean }

export type HeaderRenderOptions = {
  width: number
  version: string
  cwd: string
  home?: string
  scheme: TerminalScheme
}

function fgRgb(color: RgbColor): string {
  return `\x1b[38;2;${color.r};${color.g};${color.b}m`
}

function toneColor(style: BarStyle, tone: Tone): RgbColor {
  return tone === "chrome" ? style.chrome : style.foreground[tone]
}

function plainWidth(parts: Part[]): number {
  return parts.reduce((total, part) => total + part.text.length, 0)
}

function styledLine(parts: Part[], style: BarStyle, width: number): string {
  const padding = " ".repeat(Math.max(0, Math.floor((width - plainWidth(parts)) / 2)))
  return padding + parts.map((part) => {
    const weight = part.bold ? BOLD : ""
    return `${fgRgb(toneColor(style, part.tone))}${weight}${part.text}${RESET}`
  }).join("")
}

function cowArt(width: number): string[] {
  if (width >= 27) {
    return [
      "\\   ^__^",
      " \\  (oo)\\_______",
      "    (__)\\       )\\/\\",
      "        ||----w |",
      "        ||     ||",
    ]
  }

  if (width >= 17) {
    return [
      "  ^__^",
      "  (oo)\\_____",
      "  (__)\\     )",
      "      ||--w |",
      "      ||   ||",
    ]
  }

  if (width >= 6) return ["^__^", "(oo)", "(/\\)"]
  return ["^v^".slice(0, width)]
}

function renderCowArt(lines: string[], width: number): string[] {
  const blockWidth = Math.max(...lines.map((line) => line.length))
  const blockPadding = " ".repeat(Math.max(0, Math.floor((width - blockWidth) / 2)))

  // Center the block as one unit so the cow's relative indentation stays intact.(整体居中以保持小牛各行相对缩进。)
  return lines.map((line) => `${blockPadding}${WHITE}${BOLD}${line}${RESET}`)
}

export function abbreviateHome(cwd: string, home?: string): string {
  if (!home || home === "/") return cwd
  const normalizedHome = home.replace(/\/+$/, "")
  if (cwd === normalizedHome) return "~"
  if (cwd.startsWith(`${normalizedHome}/`)) return `~${cwd.slice(normalizedHome.length)}`
  return cwd
}

export function shortenPathLeft(value: string, maxWidth: number): string {
  if (maxWidth <= 0) return ""
  if (value.length <= maxWidth) return value
  if (maxWidth === 1) return "…"
  return `…${value.slice(-(maxWidth - 1))}`
}

function infoParts(version: string, path: string, separator: string): Part[] {
  return [
    { text: `PI v${version}`, tone: "primary", bold: true },
    { text: separator, tone: "chrome" },
    { text: path, tone: "accent" },
  ]
}

function infoLines(version: string, path: string, width: number): Part[][] {
  const spacious = infoParts(version, path, " · ")
  if (plainWidth(spacious) <= width) return [spacious]

  const compact = infoParts(version, path, "│")
  if (plainWidth(compact) <= width) return [compact]

  const pathWidth = width - plainWidth(infoParts(version, "", "│"))
  if (pathWidth > 0) {
    return [infoParts(version, shortenPathLeft(path, pathWidth), "│")]
  }

  return [[{
    text: shortenPathLeft(`PI v${version}`, width),
    tone: "primary",
    bold: true,
  }]]
}

export function renderNeonCowHeader(options: HeaderRenderOptions): string[] {
  const width = Math.max(0, Math.floor(options.width))
  if (width === 0) return []

  const style = getBarStyle(options.scheme)
  const art = renderCowArt(cowArt(width), width)
  const path = abbreviateHome(options.cwd, options.home)
  const footer = infoLines(options.version, path, width)
    .map((parts) => styledLine(parts, style, width))

  return [...art, "", ...footer, ""]
}
