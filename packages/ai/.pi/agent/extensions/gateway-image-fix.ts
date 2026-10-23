/**
 * Gateway Image Fix Extension
 * (网关图片修复扩展)
 *
 * Problem (问题):
 *   The self-hosted new-api gateway (http://192.168.1.99:3200) strips `image`
 *   blocks out of Anthropic `tool_result` content. Images survive only inside
 *   `user` message content. Pi's interactive paste inserts the pasted image as a
 *   *file path* into the editor; on submit the model calls the `read` tool, the
 *   image lands in a `tool_result` block, the gateway drops it, and the model
 *   hallucinates.
 *   (公司自建 new-api 网关会剥掉 Anthropic tool_result 里的 image block，
 *    只有 user 消息里的图片能透传。pi 交互粘贴把图片存成临时文件、把路径当文本
 *    插入编辑器，提交后模型用 read 工具读图 → 图进 tool_result → 被网关吞 → 幻觉。)
 *
 * Fix (修复):
 *   A. `input` event: detect local image file paths in the user's text, load and
 *      attach them as user-message images (same path `@file` uses, which works),
 *      and replace the raw path with a short "[image: name]" note.
 *      (在 input 事件里识别文本中的本地图片路径，加载并作为 user 消息附件，
 *       同时把裸路径替换成简短标注。)
 *   B. `tool_call` on `read` of an image: block the read and re-deliver the image
 *      as a follow-up user message instead, so it never enters a tool_result.
 *      (拦截对图片的 read 工具调用，改用 follow-up user 消息投递图片，避免进入
 *       tool_result。)
 *
 * Terminal rendering (终端渲染):
 *   pi only draws images inline from `read` tool_result blocks (tool-execution.js,
 *   via the kitty protocol); the user-message component renders text only. Since
 *   this extension routes images into user messages, the picture would vanish from
 *   the terminal. To restore it, each rerouted image is also appended as a TUI-only
 *   custom entry (pi.appendEntry + registerEntryRenderer) rendered with pi-tui's
 *   Image. Custom entries do NOT enter LLM context, so the model is not sent the
 *   image twice.
 *   (pi 只从 read 的 tool_result 内联画图；user 消息组件只渲染文本。因本扩展
 *    把图改道进 user 消息，终端会看不到图，故额外用仅 TUI 自定义条目重新画出；
 *    自定义条目不进 LLM 上下文，不会重发图。)
 *
 * Disable at startup: PI_GATEWAY_IMAGE_FIX=0
 * Runtime toggle / status: /gateway-image-fix [on|off|status]
 */
import { readFile } from "node:fs/promises";
import { basename, isAbsolute, resolve } from "node:path";
import { homedir } from "node:os";
import { resizeImage, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ImageContent } from "@earendil-works/pi-ai";
import { Box, Image, Text } from "@earendil-works/pi-tui";

// Anchored: validates that a single cleaned token IS an image path.
// (锚定版：校验单个 token 是否为图片路径)
const IMAGE_EXT = /\.(png|jpe?g|gif|webp|bmp)$/i;
// Unanchored: cheap gate for "does this text mention any image file at all".
// (非锚定版：廉价判断文本是否提到图片文件)
const IMAGE_EXT_ANY = /\.(png|jpe?g|gif|webp|bmp)\b/i;

// Reserved reference marker so we can recognize our own notes and avoid re-processing.
// (标注前缀，用于识别扩展自己插入的引用，避免重复处理)
const NOTE = (name: string) => `[image: ${name}]`;

// customType for the TUI-only inline image preview entries we append.
// (插入 transcript 的仅 TUI 图片预览条目的 customType)
const IMAGE_ENTRY = "gateway-image-fix:image";

interface ImageEntryData {
	data: string; // base64
	mimeType: string;
	name: string;
}

function envDisabled(): boolean {
	const v = process.env.PI_GATEWAY_IMAGE_FIX;
	return v === "0" || v === "false" || v === "off";
}

/** Sniff a supported image mime type from magic bytes. (通过魔数嗅探图片类型) */
function detectImageMime(buf: Uint8Array): string | null {
	if (buf.length >= 4 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) {
		return "image/png";
	}
	if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) {
		return "image/jpeg";
	}
	if (buf.length >= 4 && buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x38) {
		return "image/gif";
	}
	if (
		buf.length >= 12 &&
		buf[0] === 0x52 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x46 &&
		buf[8] === 0x57 && buf[9] === 0x45 && buf[10] === 0x42 && buf[11] === 0x50
	) {
		return "image/webp";
	}
	if (buf.length >= 2 && buf[0] === 0x42 && buf[1] === 0x4d) {
		return "image/bmp";
	}
	return null;
}

/** Expand ~ and resolve relative to cwd. (展开 ~ 并相对 cwd 解析) */
function resolvePath(raw: string, cwd: string): string {
	let p = raw;
	if (p === "~") p = homedir();
	else if (p.startsWith("~/")) p = homedir() + p.slice(1);
	return isAbsolute(p) ? p : resolve(cwd, p);
}

/** Load a file path into an ImageContent, or null if not a readable image. (加载图片附件) */
async function loadImage(
	absPath: string,
): Promise<{ image: ImageContent; note: string } | null> {
	let buf: Buffer;
	try {
		buf = await readFile(absPath);
	} catch {
		return null;
	}
	if (buf.length === 0) return null;
	const mimeType = detectImageMime(buf);
	if (!mimeType) return null;

	// Resize to inline provider limits when possible; fall back to raw bytes.
	// (尽量按内联限制压缩；失败则回退原始字节)
	let data: string;
	let outMime = mimeType;
	try {
		const resized = await resizeImage(new Uint8Array(buf), mimeType);
		if (resized) {
			data = resized.data;
			outMime = resized.mimeType;
		} else {
			data = buf.toString("base64");
		}
	} catch {
		data = buf.toString("base64");
	}

	return {
		image: { type: "image", data, mimeType: outMime },
		note: NOTE(basename(absPath)),
	};
}

/**
 * Find candidate image-path tokens in text. Returns unique {token} in order.
 * Skips URLs and tokens already inside our own note markers.
 * (在文本中查找候选图片路径 token；跳过 URL 和已标注内容)
 */
function findImagePathTokens(text: string): string[] {
	const tokens: string[] = [];
	const seen = new Set<string>();
	// Quoted paths first (support spaces): "…img.png" or '…img.png'
	const quoted = /(['"])((?:\\.|(?!\1).)*?\.(?:png|jpe?g|gif|webp|bmp))\1/gi;
	// Bare non-whitespace runs ending in an image extension.
	const bare = /\S+\.(?:png|jpe?g|gif|webp|bmp)\b/gi;

	const push = (t: string) => {
		const cleaned = t.replace(/^['"(<]+/, "").replace(/[)'">,.]+$/, "");
		if (!cleaned || seen.has(cleaned)) return;
		if (/^https?:\/\//i.test(cleaned)) return; // remote URL, not a local file
		if (!IMAGE_EXT.test(cleaned)) return;
		seen.add(cleaned);
		tokens.push(cleaned);
	};

	for (const m of text.matchAll(quoted)) push(m[2]!.replace(/\\(.)/g, "$1"));
	for (const m of text.matchAll(bare)) push(m[0]!);
	return tokens;
}

export default function (pi: ExtensionAPI) {
	let enabled = !envDisabled();
	// Paths already rerouted from a read tool call, to avoid infinite reroute loops.
	// (已从 read 重路由过的路径，防止无限循环)
	const rerouted = new Set<string>();

	// Because images are routed into user messages (which the TUI renders as
	// text-only) instead of tool_result blocks (which the TUI renders inline via
	// kitty), pi no longer draws the picture in the terminal. Re-add an inline
	// preview by appending a TUI-only custom entry rendered with pi-tui's Image.
	// Custom entries do NOT enter LLM context, so the model is not sent the image
	// twice.
	// (图片改道进 user 消息后 TUI 不再内联渲染，用仅 TUI 的自定义条目
	//  配 pi-tui 的 Image 重新画出来；自定义条目不进 LLM 上下文，不会重发图)
	pi.registerEntryRenderer<ImageEntryData>(IMAGE_ENTRY, (entry, _opts, theme) => {
		const d = entry.data;
		if (!d) return undefined;
		const box = new Box(1, 0, (t) => theme.bg("userMessageBg", t));
		box.addChild(new Text(theme.fg("dim", `▣ ${d.name}`), 0, 0));
		box.addChild(
			new Image(
				d.data,
				d.mimeType,
				{ fallbackColor: (s) => theme.fg("dim", s) },
				{ maxWidthCells: 60, filename: d.name },
			),
		);
		return box;
	});

	// Append an inline TUI preview for a rerouted image. Guarded by hasUI so it is
	// a no-op in headless modes. (为重路由的图片追加内联预览，hasUI 保护)
	const previewImage = (ctx: { hasUI: boolean }, image: ImageContent, name: string) => {
		if (!ctx.hasUI) return;
		try {
			pi.appendEntry<ImageEntryData>(IMAGE_ENTRY, {
				data: image.data,
				mimeType: image.mimeType,
				name,
			});
		} catch {
			// best-effort TUI rendering; never break the image reroute over it.
			// (尽力而为的渲染，绝不因此中断改道)
		}
	};

	// ---- Handler A: intercept image paths in user input -------------------
	pi.on("input", async (event, ctx) => {
		if (!enabled) return { action: "continue" };
		if (event.source === "extension") return { action: "continue" };
		if (!event.text || !IMAGE_EXT_ANY.test(event.text)) return { action: "continue" };

		const tokens = findImagePathTokens(event.text);
		if (tokens.length === 0) return { action: "continue" };

		let text = event.text;
		const images: ImageContent[] = [...(event.images ?? [])];
		let changed = false;

		for (const token of tokens) {
			const abs = resolvePath(token, ctx.cwd);
			const loaded = await loadImage(abs);
			if (!loaded) continue;
			const alreadyAttached = images.some(
				(existing) =>
					existing.type === "image" &&
					existing.mimeType === loaded.image.mimeType &&
					existing.data === loaded.image.data,
			);
			if (!alreadyAttached) {
				images.push(loaded.image);
				previewImage(ctx, loaded.image, basename(abs)); // inline TUI preview
			}
			// Keep read fallback available for prompts that explicitly require read.
			// (保留显式要求 read 的提示的改道兜底)
			// Replace the raw path token with a short note so the model has context
			// and is not tempted to re-read a dangling path.
			text = text.split(token).join(loaded.note);
			changed = true;
		}

		if (!changed) return { action: "continue" };
		if (!text.trim()) text = images.length > 1 ? "Describe these images." : "Describe this image.";
		return { action: "transform", text, images };
	});

	// ---- Handler B: reroute read-of-image away from tool_result -----------
	pi.on("tool_call", async (event, ctx) => {
		if (!enabled) return;
		if (event.toolName !== "read") return;
		const input = event.input as { path?: unknown; file_path?: unknown };
		const raw = typeof input.path === "string" ? input.path : typeof input.file_path === "string" ? input.file_path : undefined;
		if (!raw || !IMAGE_EXT.test(raw)) return;

		const abs = resolvePath(raw, ctx.cwd);
		const name = basename(abs);

		if (rerouted.has(abs)) {
			return {
				block: true,
				reason: `The image "${name}" was already delivered directly as a user message (the API gateway strips images from tool results, so it cannot be read here). Refer to that image above instead of reading the file again.`,
			};
		}

		const loaded = await loadImage(abs);
		if (!loaded) return; // not actually a readable image; let read proceed

		rerouted.add(abs);
		previewImage(ctx, loaded.image, name); // inline TUI preview
		// Deliver the image as a real user message (survives the gateway).
		pi.sendUserMessage(
			[
				{ type: "text", text: `Attached image "${name}" (delivered as a user message because the gateway drops images from tool results):` },
				loaded.image,
			],
			{ deliverAs: "followUp" },
		);
		return {
			block: true,
			terminate: true,
			reason: `Reading images through the read tool does not work with this API gateway (it strips images from tool results). The image "${name}" is being delivered directly as a follow-up user message — analyze it there.`,
		};
	});

	// ---- Status / toggle command ------------------------------------------
	pi.registerCommand("gateway-image-fix", {
		description: "Toggle/inspect the gateway image fix (on|off|status)",
		handler: async (args, ctx) => {
			const arg = (args ?? "").trim().toLowerCase();
			if (arg === "on") enabled = true;
			else if (arg === "off") enabled = false;
			const state = enabled ? "on" : "off";
			ctx.ui.notify(`gateway-image-fix is ${state}`, "info");
		},
	});

	pi.on("session_start", (_event, ctx) => {
		if (!enabled || !ctx.hasUI) return;
		// Show a transient badge to confirm the extension loaded, then clear it so the
		// footer status line (shared, alphabetically sorted, single-line + truncated)
		// stays free for other extensions like rtk.
		// (短暂显示确认加载，随后清除；footer 状态行是共享单行、按 key
		//  字母序拼接并截断的，不长期占用就不会挤掉 rtk 等其他标识)
		try {
			ctx.ui.setStatus("gateway-image-fix", "img-fix on");
			setTimeout(() => {
				try {
					ctx.ui.setStatus("gateway-image-fix", undefined);
				} catch {
					// UI may be gone; best-effort. (UI 可能已销毁，尽力而为)
				}
			}, 4000).unref?.();
		} catch {
			// best-effort UI call
		}
	});
}
