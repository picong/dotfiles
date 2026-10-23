import {
  VERSION,
  type ExtensionAPI,
} from "@earendil-works/pi-coding-agent"
import type { Component, TUI } from "@earendil-works/pi-tui"
import {
  detectTerminalScheme,
  normalizeSchemeOverride,
  type SchemeOverride,
  type TerminalScheme,
} from "../shell-prompt-editor/style.ts"
import { renderNeonCowHeader } from "./render.ts"

class NeonCowHeader implements Component {
  private disposed = false
  private scheme: TerminalScheme
  private readonly tui: TUI
  private readonly version: string
  private readonly cwd: string
  private readonly home: string | undefined

  constructor(
    tui: TUI,
    version: string,
    cwd: string,
    home: string | undefined,
    schemeOverride: SchemeOverride,
  ) {
    this.tui = tui
    this.version = version
    this.cwd = cwd
    this.home = home
    this.scheme = schemeOverride === "auto" ? "dark" : schemeOverride

    void detectTerminalScheme(tui, schemeOverride).then((scheme) => {
      if (this.disposed || scheme === this.scheme) return
      this.scheme = scheme
      this.tui.requestRender()
    })
  }

  render(width: number): string[] {
    return renderNeonCowHeader({
      width,
      version: this.version,
      cwd: this.cwd,
      home: this.home,
      scheme: this.scheme,
    })
  }

  invalidate(): void {}

  dispose(): void {
    this.disposed = true
  }
}

export default function neonCowHeader(pi: ExtensionAPI): void {
  pi.on("session_start", (_event, ctx) => {
    if (ctx.mode !== "tui") return

    const schemeOverride = normalizeSchemeOverride(process.env.PI_SHELL_PROMPT_SCHEME)
    ctx.ui.setHeader((tui) => new NeonCowHeader(
      tui,
      VERSION,
      ctx.cwd,
      process.env.HOME,
      schemeOverride,
    ))
  })
}
