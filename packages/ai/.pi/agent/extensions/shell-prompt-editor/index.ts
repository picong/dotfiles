/**
 * Fish Tide style prompt editor - replaces powerline-footer entirely.
 * Powerline-style status bar with colored background blocks.
 * (Fish Tide 风格提示编辑器 - 使用彩色背景色块的 powerline 风格状态栏)
 *
 * Layout:
 *   ╭─ [model][think][ctx%][tps][git][timer] ─── [🐎][time] ─
 *   ╰ ❯ input text here
 *
 * The top bar hides lower-priority segments on narrow terminals.
 * (顶部状态栏会在窄终端自动隐藏低优先级段落)
 */

import {
  CustomEditor,
  type ExtensionAPI,
  type KeybindingsManager,
  type ReadonlyFooterDataProvider,
} from "@earendil-works/pi-coding-agent";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { Component, EditorTheme, TUI } from "@earendil-works/pi-tui";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import {
  detectTerminalScheme,
  getBarStyle,
  normalizeSchemeOverride,
  type BarStyle,
  type RgbColor,
  type SegmentTone,
  type TerminalScheme,
} from "./style.ts";
import { restyleStatusText, sanitizeStatusText } from "./text.ts";

// ANSI escape helpers for 24-bit RGB background + foreground
// (ANSI 转义辅助函数，用于 24 位 RGB 背景与前景)
const RST = "\x1b[0m";
function bgRgb(color: RgbColor): string { return `\x1b[48;2;${color.r};${color.g};${color.b}m`; }
function fgRgb(color: RgbColor): string { return `\x1b[38;2;${color.r};${color.g};${color.b}m`; }
function bold(): string { return "\x1b[1m"; }

// Powerline rounded cap characters (Powerline 圆角字符)
const LEFT_CAP = "\uE0B6";  // Left half-circle - opening rounded edge (左半圆 - 开口圆角)
const RIGHT_CAP = "\uE0B4"; // Right half-circle - closing rounded edge (右半圆 - 闭合圆角)

const SEP_CHAR = ")"; // Simple parenthesis as curved separator (圆括号作为弧形分隔符)
const SEP_CHAR_RIGHT = "("; // Right group separator (右侧组分隔符)

/**
 * Create a bold semantic-color segment on the shared bar background.
 * Each segment has 1-space padding on each side.
 * (在当前状态背景上创建高对比文本段，每段左右各 1 空格 padding)
 */
function segmentStyle(style: BarStyle, tone: SegmentTone): string {
  return `${bgRgb(style.background)}${fgRgb(style.foreground[tone])}${bold()}`;
}

function barSegment(text: string, style: BarStyle, tone: SegmentTone): string {
  return `${segmentStyle(style, tone)} ${text} ${RST}`;
}

/**
 * Segment that preserves the source text's own SGR colors (extension statuses
 * such as the caveman campfire animation) without letting its resets clear the
 * bar background.
 * (保留来源文本自带 SGR 配色的段落，如 caveman 篝火动画，且不让其 reset 清掉状态栏背景)
 */
function barRichSegment(text: string, style: BarStyle, tone: SegmentTone): string {
  const restore = segmentStyle(style, tone);
  return `${restore} ${restyleStatusText(text, restore)} ${RST}`;
}

function barSep(style: BarStyle, char: string): string {
  return `${bgRgb(style.background)}${fgRgb(style.separator)}${char}${RST}`;
}

/**
 * Wrap a group of semantic-color segments with rounded caps and separators.
 * (用圆角端帽和柔和分隔符包裹语义配色段落组)
 */
function wrapBar(segments: string[], style: BarStyle, separator: string): string {
  if (segments.length === 0) return "";
  const leftRound = `${fgRgb(style.background)}${LEFT_CAP}${RST}`;
  const rightRound = `${fgRgb(style.background)}${RIGHT_CAP}${RST}`;
  const sep = barSep(style, separator);
  return `${leftRound}${segments.join(sep)}${rightRound}`;
}

const CORE_SEGMENT_PRIORITY = 100;

type BarItem = {
  rendered: string;
  text: string;
  keepPriority: number;
};

function makeBarItem(
  text: string,
  style: BarStyle,
  tone: SegmentTone,
  keepPriority: number,
): BarItem {
  return {
    rendered: barSegment(text, style, tone),
    text: ` ${text} `,
    keepPriority,
  };
}

/**
 * Bar item whose rendered form keeps the source's own colors; width math still
 * uses the plain text.
 * (保留原始配色的段落项，宽度计算仍使用纯文本)
 */
function makeRichBarItem(
  text: string,
  plain: string,
  style: BarStyle,
  tone: SegmentTone,
  keepPriority: number,
): BarItem {
  return {
    rendered: barRichSegment(text, style, tone),
    text: ` ${plain} `,
    keepPriority,
  };
}

function groupVisibleWidth(items: readonly BarItem[]): number {
  if (items.length === 0) return 0;
  const sepCount = Math.max(0, items.length - 1);
  return items.reduce((sum, item) => sum + visibleWidth(item.text), 0) + sepCount + 2;
}

function fitBarItems(items: readonly BarItem[], maxWidth: number): BarItem[] {
  const selected = [...items];
  while (selected.length > 0 && groupVisibleWidth(selected) > maxWidth) {
    let removeIdx = -1;
    let lowestPriority = CORE_SEGMENT_PRIORITY;
    for (let i = 0; i < selected.length; i++) {
      if (selected[i]!.keepPriority < lowestPriority) {
        lowestPriority = selected[i]!.keepPriority;
        removeIdx = i;
      }
    }
    if (removeIdx === -1) break;
    selected.splice(removeIdx, 1);
  }
  return selected;
}

function fmtTokens(n: number): string {
  if (n < 1000) return n.toString();
  if (n < 10000) return `${(n / 1000).toFixed(1)}k`;
  if (n < 1000000) return `${Math.round(n / 1000)}k`;
  return `${(n / 1000000).toFixed(1)}M`;
}

function fmtTime(): string {
  const now = new Date();
  return `${now.getHours().toString().padStart(2, "0")}:${now.getMinutes().toString().padStart(2, "0")}`;
}

/**
 * Empty footer - hides default footer (pwd/token stats/extension statuses).
 * Extension statuses (MCP, PLAN) are shown in the top bar instead.
 * 空 footer - 隐藏默认底部栏，扩展状态已移至顶部状态栏显示
 */
class EmptyFooter implements Component {
  render(_width: number): string[] {
    return [""]; // Return empty line to prevent default footer fallback (防止回退到默认 footer)
  }
  invalidate(): void {}
  dispose(): void {}
}

export default function shellPromptEditor(pi: ExtensionAPI) {
  let isWorking = false;
  let spinnerIdx = 0;
  let spinnerTimer: ReturnType<typeof setInterval> | undefined;
  let timeTimer: ReturnType<typeof setInterval> | undefined;
  let tui: TUI | undefined;
  let sessionStart = Date.now();
  const SPINNER = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

  // Response timer state (响应计时状态)
  let agentStartTime: number | null = null;
  let lastElapsed: string | null = null;
  let elapsedHideTimer: ReturnType<typeof setTimeout> | undefined;

  const stopSpinner = () => {
    if (spinnerTimer) { clearInterval(spinnerTimer); spinnerTimer = undefined; }
  };

  pi.on("agent_start", () => {
    isWorking = true;
    agentStartTime = Date.now();
    lastElapsed = null;
    if (elapsedHideTimer) { clearTimeout(elapsedHideTimer); elapsedHideTimer = undefined; }
    stopSpinner();
    spinnerTimer = setInterval(() => {
      spinnerIdx = (spinnerIdx + 1) % SPINNER.length;
      tui?.requestRender();
    }, 80);
    tui?.requestRender();
  });

  pi.on("agent_end", () => {
    isWorking = false;
    // Record final elapsed time (记录最终耗时)
    if (agentStartTime !== null) {
      const secs = (Date.now() - agentStartTime) / 1000;
      lastElapsed = secs >= 60
        ? `${Math.floor(secs / 60)}m${(secs % 60).toFixed(1)}s`
        : `${secs.toFixed(1)}s`;
      agentStartTime = null;
    }
    stopSpinner();
    // Auto-hide elapsed after 5s (5 秒后自动隐藏耗时)
    elapsedHideTimer = setTimeout(() => {
      lastElapsed = null;
      tui?.requestRender();
    }, 5000);
    tui?.requestRender();
  });

  pi.on("session_shutdown", () => {
    stopSpinner();
    if (timeTimer) { clearInterval(timeTimer); timeTimer = undefined; }
    if (elapsedHideTimer) { clearTimeout(elapsedHideTimer); elapsedHideTimer = undefined; }
    tui = undefined;
  });

  pi.on("session_start", (_event, ctx) => {
    sessionStart = Date.now();

    let footerData: ReadonlyFooterDataProvider | undefined;
    let terminalScheme: TerminalScheme = "dark";
    let schemeDetectionStarted = false;
    const schemeOverride = normalizeSchemeOverride(process.env.PI_SHELL_PROMPT_SCHEME);

    ctx.ui.setWorkingVisible(false);
    ctx.ui.setFooter((_t: TUI, _th: unknown, fd: ReadonlyFooterDataProvider) => {
      footerData = fd;
      return new EmptyFooter();
    });

    let branch: string | undefined;
    const refreshBranch = async () => {
      const r = await pi.exec("git", ["branch", "--show-current"], { cwd: ctx.cwd }).catch(() => undefined);
      branch = r?.stdout.trim() || undefined;
      tui?.requestRender();
    };
    void refreshBranch();

    if (timeTimer) clearInterval(timeTimer);
    timeTimer = setInterval(() => tui?.requestRender(), 30_000);

    class TideEditor extends CustomEditor {
      constructor(t: TUI, theme: EditorTheme, kb: KeybindingsManager) {
        super(t, theme, kb, { paddingX: 0 });
        tui = t;
        if (!schemeDetectionStarted) {
          schemeDetectionStarted = true;
          void detectTerminalScheme(t, schemeOverride).then((detected) => {
            // Ignore a late probe result after reload/session replacement.
            // (重载或会话替换后忽略旧 TUI 的延迟探测结果。)
            if (tui !== t) return;
            terminalScheme = detected;
            t.requestRender();
          });
        }
      }

      render(width: number): string[] {
        const barStyle = getBarStyle(terminalScheme);
        const promptStr = `${fgRgb(barStyle.chrome)}╰${RST} ${fgRgb(barStyle.prompt)}${bold()}❯${RST} `;
        const promptW = visibleWidth(promptStr);
        // Tell super to render in narrower width so we can prepend prompt
        // (让 super 在更窄的宽度中渲染，以便我们前置 prompt)
        const innerWidth = Math.max(10, width - promptW);
        const lines = super.render(innerWidth);
        if (lines.length < 2 || width < 20) return lines;

        // --- Compute stats (计算统计数据) ---
        let totalTokens = 0;
        let cacheReadTokens = 0;
        let cacheWriteTokens = 0;
        for (const e of ctx.sessionManager.getBranch()) {
          if (e.type === "message" && e.message.role === "assistant") {
            const m = e.message as AssistantMessage;
            totalTokens += m.usage.totalTokens || (m.usage.input + m.usage.output);
            cacheReadTokens += m.usage.cacheRead || 0;
            cacheWriteTokens += m.usage.cacheWrite || 0;
          }
        }
        const elapsed = (Date.now() - sessionStart) / 1000;
        const tps = elapsed > 1 && totalTokens > 0 ? Math.round(totalTokens / elapsed) : 0;

        let modelName = ctx.model?.name || ctx.model?.id || "no-model";
        if (modelName.startsWith("Claude ")) modelName = modelName.slice(7);

        const usage = ctx.getContextUsage();
        const contextPercent = usage?.percent != null ? usage.percent : undefined;
        const pct = contextPercent != null ? contextPercent.toFixed(1) : "?";

        const gitStr = branch ? `⇡ ${branch}` : "⇡ No Git";
        const thinkingLevel = pi.getThinkingLevel();
        const thinkStr = `think:${thinkingLevel}`;

        // --- Build segments for left section (构建左侧栏位段落) ---
        const leftItems: BarItem[] = [];

        // Model name (模型名)
        leftItems.push(makeBarItem(modelName, barStyle, "primary", CORE_SEGMENT_PRIORITY));

        // Thinking level (思考级别)
        leftItems.push(makeBarItem(thinkStr, barStyle, "secondary", 40));

        // Context usage (上下文使用率)
        leftItems.push(makeBarItem(`${pct}%`, barStyle, "primary", CORE_SEGMENT_PRIORITY));

        // Tokens per second (每秒 token)
        const tpsStr = `${fmtTokens(tps)} t/s`;
        leftItems.push(makeBarItem(tpsStr, barStyle, "accent", 20));

        // Git branch (Git 分支)
        leftItems.push(makeBarItem(gitStr, barStyle, "accent", 30));

        // Response timer (响应计时)
        if (isWorking && agentStartTime !== null) {
          const secs = (Date.now() - agentStartTime) / 1000;
          const timerStr = secs >= 60
            ? `⏱ ${Math.floor(secs / 60)}m${(secs % 60).toFixed(1)}s`
            : `⏱ ${secs.toFixed(1)}s`;
          leftItems.push(makeBarItem(timerStr, barStyle, "secondary", 70));
        } else if (lastElapsed) {
          const timerStr = `⏱ ${lastElapsed}`;
          leftItems.push(makeBarItem(timerStr, barStyle, "secondary", 70));
        }

        // Extension statuses (扩展状态)
        if (footerData) {
          const extensionStatuses = footerData.getExtensionStatuses();
          for (const [, text] of extensionStatuses) {
            const plain = sanitizeStatusText(text);
            if (plain) {
              leftItems.push(makeRichBarItem(text, plain, barStyle, "muted", 10));
            }
          }
        }

        // --- Build segments for right section (构建右侧栏位段落) ---
        const horseIcon = "🐎";
        const timeStr = fmtTime();
        const cacheReadPct = totalTokens > 0 ? Math.round((cacheReadTokens / totalTokens) * 100) : 0;
        const cacheWritePct = totalTokens > 0 ? Math.round((cacheWriteTokens / totalTokens) * 100) : 0;
        const cacheStr = `R${cacheReadPct}% W${cacheWritePct}%`;
        const rightItems = [
          makeBarItem(horseIcon, barStyle, "primary", CORE_SEGMENT_PRIORITY),
          makeBarItem(cacheStr, barStyle, "accent", CORE_SEGMENT_PRIORITY),
          makeBarItem(timeStr, barStyle, "secondary", CORE_SEGMENT_PRIORITY),
        ];

        // --- Assemble top line with rounded bar groups (组装带圆角的顶部状态行) ---
        const spinner = isWorking ? `${fgRgb(barStyle.spinner)}${bold()}${SPINNER[spinnerIdx]}${RST}` : "";
        const borderLeft = `${fgRgb(barStyle.chrome)}╭─${RST}`;
        const borderRight = `${fgRgb(barStyle.chrome)}─${RST}`;

        // Calculate visible widths (计算可见宽度)
        // No spacing between borders and groups (边框与色块之间无间距)
        const spinnerW = isWorking ? 1 : 0; // spinner char only
        const borderLeftW = 2; // ╭─
        const borderRightW = 1; // ─
        const rightW = groupVisibleWidth(rightItems);
        const maxLeftW = Math.max(0, width - borderLeftW - spinnerW - rightW - borderRightW - 1);
        const fittedLeftItems = fitBarItems(leftItems, maxLeftW);
        const leftSegments = fittedLeftItems.map((item) => item.rendered);
        const rightSegments = rightItems.map((item) => item.rendered);
        const leftGroup = wrapBar(leftSegments, barStyle, SEP_CHAR);
        const rightGroup = wrapBar(rightSegments, barStyle, SEP_CHAR_RIGHT);
        const leftW = groupVisibleWidth(fittedLeftItems);
        const fixedW = borderLeftW + spinnerW + leftW + rightW + borderRightW;

        const fillW = Math.max(1, width - fixedW);
        const fill = `${fgRgb(barStyle.chrome)}${"─".repeat(fillW)}${RST}`;

        // No spaces between border and groups (边框与色块之间无空格)
        const topLine = `${borderLeft}${spinner}${leftGroup}${fill}${rightGroup}${borderRight}`;
        lines[0] = truncateToWidth(topLine, width, "", false);

        // --- Remove bottom border, replace with blank ---
        // (移除底部边框)
        for (let i = lines.length - 1; i > 0; i--) {
          const plain = lines[i]!.replace(/\x1b\[[0-9;]*m/g, "");
          if (/^─/.test(plain)) {
            lines.splice(i, 1);
            break;
          }
        }

        // --- Prepend prompt/indent to content lines ---
        // (为内容行添加 prompt/缩进前缀)
        const indent = " ".repeat(promptW);
        for (let i = 1; i < lines.length; i++) {
          const pre = i === 1 ? promptStr : indent;
          const combined = pre + lines[i]!;
          const w = visibleWidth(combined);
          if (w > width) {
            lines[i] = combined.replace(/ +$/, (m) => m.slice(0, Math.max(0, m.length - (w - width))));
          } else if (w < width) {
            lines[i] = combined + " ".repeat(width - w);
          } else {
            lines[i] = combined;
          }
        }

        return lines;
      }
    }

    ctx.ui.setEditorComponent((t, theme, kb) => new TideEditor(t, theme, kb));
  });
}
