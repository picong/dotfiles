/**
 * jump-to-bottom.ts — Claude Code 风格 "Jump to bottom" 按钮扩展。
 *
 * 依赖 pi 0.84+ 原生 fullscreen TUI（固定 editor/footer、独立滚动 transcript）。
 * 按钮渲染为 editor（shell-prompt-editor）上方、水平居中的 chip，背景色与
 * shell-prompt-editor 状态栏一致（共用 style.ts 的 scheme 检测与调色板），
 * 仅当 transcript 滚动离开底部时显示；点击 chip → tui.scrollToBottom()。
 *
 * 点击处理要点：
 * - TuiAltScreen 构造函数注册的 viewport 处理器会把所有 SGR 鼠标事件 consume
 *   掉，扩展监听器排在它后面永远收不到鼠标。因此 patch
 *   TuiAltScreen/TuiMainScreen.prototype.addInputListener：新监听器插到 Set 最前。
 *   全 pi-tui 只有 alt-screen 构造器与 interactive-mode 的扩展监听器调用该方法。
 * - widgetAbove 是共享容器：todo overlay（rpiv-todos）也注册在 aboveEditor，
 *   widget 顺序随扩展注册顺序变化，布局树又只到 Container 一层（普通子组件
 *   无 box）。因此命中测试不看 dock 索引，直接搜 tui.previousScreen（上一帧
 *   实际渲染画面）里含 "Jump to bottom" 的行——与 widget 顺序无关，绝对准确。
 *
 * 环境开关 / env kill switch: PI_JUMP_BOTTOM=0（默认开启）
 * 调试 / debug log: PI_JUMP_BOTTOM_DEBUG=1 → /tmp/pi-jump-bottom.log
 * 命令 / commands: /jump-bottom toggle|on|off|jump
 */
import type { ExtensionAPI, Theme } from "@earendil-works/pi-coding-agent";
import {
    TuiAltScreen,
    TuiMainScreen,
    stripTerminalSequences,
    visibleWidth,
} from "@earendil-works/pi-tui";
import { appendFileSync, statSync } from "node:fs";

const KEY = "jump-to-bottom";
const PATCHED = Symbol.for("jump-to-bottom.patched");
const DEBUG = process.env.PI_JUMP_BOTTOM_DEBUG === "1";
const DEBUG_LOG = "/tmp/pi-jump-bottom.log";
const DEBUG_MAX_BYTES = 64 * 1024;
const CHIP_TEXT = "Jump to bottom";
const FALLBACK_BG = { r: 45, g: 44, b: 54 }; // shell-prompt-editor dark #2D2C36

type Rgb = { r: number; g: number; b: number };
type MouseEvent = { button: number; x: number; y: number; release: boolean };

interface JumpWidget {
    render(width: number): string[];
    dispose(): void;
}

const state: {
    enabled: boolean;
    /** ctx.ui 传入的 proxy，跨 fullscreen/regular 运行时切换自动指向当前 TUI 实例 */
    tui?: unknown;
    theme?: Theme;
    widget?: JumpWidget;
    chipWidth: number;
    chipBg: Rgb;
    unsub?: () => void;
} = {
    enabled: process.env.PI_JUMP_BOTTOM !== "0",
    chipWidth: 0,
    chipBg: FALLBACK_BG,
};

function dbg(msg: string): void {
    if (!DEBUG) return;
    try {
        const f = DEBUG_LOG;
        try {
            if (statSync(f).size > DEBUG_MAX_BYTES) appendFileSync(f, "\n");
        } catch {
            /* first write */
        }
        appendFileSync(f, `${new Date().toISOString()} ${msg}\n`);
    } catch {
        /* best effort */
    }
}

/**
 * 与 shell-prompt-editor 共用 style.ts 的终端 scheme 检测 + 调色板，
 * 让 chip 背景和其状态栏完全一致。模块缺失时回退深色背景。
 *
 * Share shell-prompt-editor's terminal scheme detection and palette so the
 * chip background exactly matches its status bar. Fall back to the dark
 * background if the module is unavailable.
 */
export async function resolveChipBg(tui: unknown): Promise<Rgb> {
    try {
        const mod = (await import("./shell-prompt-editor/style.ts")) as any;
        const override = mod.normalizeSchemeOverride(process.env.PI_SHELL_PROMPT_SCHEME);
        const scheme = await mod.detectTerminalScheme(tui, override);
        const bg = mod.getBarStyle(scheme).background as Rgb;
        if (bg && typeof bg.r === "number") return bg;
    } catch {
        /* fall through */
    }
    return FALLBACK_BG;
}

/**
 * 解析 SGR (\x1b[<b;x;yM/m) 与 X10 (\x1b[M Cb Cx Cy) 鼠标序列。
 * x/y 转为 0-based。
 */
export function parseMouse(data: string): MouseEvent | null {
    const sgr = /^\x1b\[<(\d+);(\d+);(\d+)([Mm])$/.exec(data);
    if (sgr) {
        return {
            button: Number.parseInt(sgr[1]!, 10),
            x: Number.parseInt(sgr[2]!, 10) - 1,
            y: Number.parseInt(sgr[3]!, 10) - 1,
            release: sgr[4] === "m",
        };
    }
    // X10 legacy: ESC [ M + 3 bytes offset by 32
    if (data.length === 6 && data.startsWith("\x1b[M")) {
        const b = data.charCodeAt(3) - 32;
        return {
            button: b,
            x: data.charCodeAt(4) - 33,
            y: data.charCodeAt(5) - 33,
            release: (b & 3) === 3,
        };
    }
    return null;
}

/**
 * 在上一帧实际渲染画面上定位 chip 行与 x 区间（与 widget 顺序无关）。
 * Locate the chip row and x span in the last rendered screen frame.
 */
export function findChipOnScreen(
    screen: readonly string[] | undefined,
    chipWidth: number,
): { y: number; x0: number; x1: number } | undefined {
    if (!screen || chipWidth <= 0) return undefined;
    for (let y = screen.length - 1; y >= 0; y--) {
        const line = screen[y];
        if (!line || !line.includes(CHIP_TEXT)) continue;
        const stripped = stripTerminalSequences(line);
        const x0 = stripped.indexOf("↓");
        if (x0 < 0) continue;
        const w = Math.max(1, Math.min(chipWidth, stripped.length - x0));
        return { y, x0, x1: x0 + w };
    }
    return undefined;
}

/**
 * 让 addInputListener 新加入的监听器排在 Set 最前（仅这两个 TUI 类）。
 * 原因：TuiAltScreen 在构造函数里注册 viewport 处理器，普通注册会排在它后面，
 * 鼠标事件被其 consume 掉，扩展收不到。此补丁在 /reload、运行时模式切换的
 * rebind 中自动生效（rebind 也走 addInputListener）。
 */
export function patchAddInputListener(): void {
    for (const cls of [TuiAltScreen, TuiMainScreen]) {
        const proto = cls.prototype as any;
        if (proto[PATCHED]) continue;
        Object.defineProperty(proto, PATCHED, { value: true });
        proto.addInputListener = function (this: any, listener: unknown) {
            const set: Set<unknown> = this.inputListeners;
            set.delete(listener);
            set.add(listener);
            if (set.size > 1) {
                const rest = [...set].filter((l) => l !== listener);
                set.clear();
                set.add(listener);
                for (const l of rest) set.add(l);
            }
            return () => {
                set.delete(listener);
            };
        };
    }
}

/** 点击命中测试 + 跳底。Press on the chip jumps to bottom. */
export function handleInput(
    data: string,
    s: typeof state = state,
): { consume: boolean } | undefined {
    if (!s.enabled || !s.widget) return undefined;
    const tui = s.tui as any;
    if (!tui || tui.mode !== "fullscreen") return undefined;
    const ev = parseMouse(data);
    if (!ev || ev.button !== 0 || ev.release) return undefined;
    if (typeof tui.hasOverlay === "function" && tui.hasOverlay()) return undefined;
    const rect = findChipOnScreen(tui.previousScreen, s.chipWidth);
    if (!rect) return undefined;
    const hit = ev.y === rect.y && ev.x >= rect.x0 && ev.x < rect.x1;
    if (!hit) {
        dbg(
            `miss x=${ev.x} y=${ev.y} rect=${JSON.stringify(rect)} chip=${s.chipWidth} overlay=${false}`,
        );
        return undefined;
    }
    dbg(`HIT x=${ev.x} y=${ev.y} rect=${JSON.stringify(rect)} -> scrollToBottom`);
    tui.scrollToBottom();
    return { consume: true };
}

function makeWidget(tui: unknown, theme: Theme): JumpWidget {
    state.tui = tui;
    state.theme = theme;
    // Async resolve chip bg to match shell-prompt-editor (fire and forget).
    void resolveChipBg(tui).then((bg) => {
        if (bg) {
            state.chipBg = bg;
            (state.tui as any)?.requestRender?.();
        }
    });
    const widget: JumpWidget = {
        render(width: number): string[] {
            const t = state.tui as any;
            // 仅 fullscreen 且滚动离开底部时显示。layout renderCache 每帧新建，
            // render() 每帧调用，显隐与滚动状态自动同步。
            if (!state.enabled || !t || t.mode !== "fullscreen" || t.isFollowingOutput) {
                state.chipWidth = 0;
                return [];
            }
            // 背景 = shell-prompt-editor 状态栏同款 RGB；上下各留一行空白：
            // 上方制造悬浮感，下方避免与 todo overlay（或 editor）紧贴。
            const { r, g, b } = state.chipBg;
            const chip =
                `\x1b[48;2;${r};${g};${b}m` +
                theme.fg("accent", "↓") +
                theme.fg("muted", ` ${CHIP_TEXT}`) +
                theme.fg("dim", " (End)") +
                "\x1b[49m";
            const chipW = visibleWidth(chip);
            if (width <= chipW + 1) {
                state.chipWidth = 0;
                return [];
            }
            state.chipWidth = chipW;
            const padL = " ".repeat(Math.floor((width - chipW) / 2));
            return ["", padL + chip, ""];
        },
        dispose() {
            if (state.widget === widget) state.widget = undefined;
        },
    };
    state.widget = widget;
    return widget;
}

export default function (pi: ExtensionAPI) {
    pi.on("session_start", (_event, ctx) => {
        if (!ctx.hasUI || !state.enabled) return;
        patchAddInputListener();
        state.unsub?.();
        state.unsub = ctx.ui.onTerminalInput(handleInput);
        ctx.ui.setWidget(KEY, (tui, theme) => makeWidget(tui, theme), {
            placement: "aboveEditor",
        });
    });

    pi.registerCommand("jump-bottom", {
        description: "Toggle the Jump to bottom button, or jump now (/jump-bottom jump)",
        handler: async (args, ctx) => {
            const a = (args ?? "").trim();
            if (a === "bottom" || a === "jump") {
                (state.tui as any)?.scrollToBottom?.();
                return;
            }
            state.enabled = a === "on" || (a !== "off" && !state.enabled);
            if (state.enabled && ctx.hasUI) {
                patchAddInputListener();
                if (!state.unsub) state.unsub = ctx.ui.onTerminalInput(handleInput);
                ctx.ui.setWidget(KEY, (tui, theme) => makeWidget(tui, theme), {
                    placement: "aboveEditor",
                });
                ctx.ui.notify("jump-to-bottom enabled", "info");
            } else {
                state.unsub?.();
                state.unsub = undefined;
                if (ctx.hasUI) ctx.ui.setWidget(KEY, undefined);
                ctx.ui.notify("jump-to-bottom disabled", "info");
            }
            if (ctx.hasUI) (state.tui as any)?.requestRender?.();
        },
    });
}
