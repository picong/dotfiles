/**
 * Auto Memory Extension for Pi (Pi 自动记忆扩展)
 * ------------------------------------------------------------------
 * Claude Code-style persistent memory, faithful to Pi's real mechanism:
 *   - NO daemon / NO background thread (无后台进程/无常驻线程)
 *   - The MEMORY.md index is injected before every LLM call via `context`
 *     (每次 LLM 调用前通过 context 事件注入 MEMORY.md 索引)
 *   - The model writes/reads memory itself by calling registered tools,
 *     exactly like Claude Code's inline "Writing memory" / "Recalled memory"
 *     (模型通过注册的工具自己读写记忆，等同 Claude Code 的内联读写)
 *
 * Storage layout (存储结构), per git-repo / cwd:
 *   <root>/MEMORY.md          -> concise index, injected every session (索引，每次注入)
 *   <root>/<topic>.md         -> detail files, read on demand (主题文件，按需读取)
 *
 * This is the "Plan B" skeleton: injection + tools, no session-end LLM extraction.
 * Extension points for "Plan C" (session_shutdown background extraction) are marked TODO.
 * (这是"方案 B"骨架：注入 + 工具，不做会话结束的 LLM 提取；方案 C 的扩展点已用 TODO 标注)
 */

import { execSync } from "node:child_process";
import {
	existsSync,
	mkdirSync,
	readdirSync,
	readFileSync,
	writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { Type } from "typebox";
import type {
	AgentToolResult,
	ExtensionAPI,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";

// ── Config (配置) ────────────────────────────────────────────────

// Root for all memory stores; one subdir per project (所有记忆库根目录，每项目一个子目录)
const MEMORY_HOME = join(homedir(), ".pi", "memory");

// Index file name (索引文件名)
const INDEX_FILE = "MEMORY.md";

// Max chars of the index injected at session start. Mirrors Claude Code's
// "first 200 lines / 25KB" cap on MEMORY.md. (索引注入上限，对标 Claude Code 的 200 行/25KB)
const INDEX_INJECT_MAX_CHARS = 12_000;

// ── Helpers (辅助函数) ───────────────────────────────────────────

/**
 * Resolve the memory directory for the current project.
 * Keyed by git repo root if available, else cwd. All worktrees of one repo
 * share a directory, matching Claude Code semantics.
 * (按 git 仓库根定位记忆目录，无 git 时用 cwd；同仓库所有 worktree 共享)
 */
function resolveMemoryDir(cwd: string): string {
	let key = cwd;
	try {
		// git rev-parse to find repo root (用 git rev-parse 找仓库根)
		const root = execSync("git rev-parse --show-toplevel", {
			cwd,
			stdio: ["ignore", "pipe", "ignore"],
		})
			.toString()
			.trim();
		if (root) key = root;
	} catch {
		// Not a git repo, fall back to cwd (非 git 仓库，回退到 cwd)
	}
	// Encode the path into a single safe dir name (把路径编码成安全的单层目录名)
	const safe = key.replace(/[/\\]/g, "-").replace(/^-+/, "");
	const dir = join(MEMORY_HOME, safe);
	if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
	return dir;
}

/** Sanitize a topic into a safe markdown filename (把主题名清理成安全的 md 文件名) */
function topicToFile(topic: string): string {
	const base = topic
		.toLowerCase()
		.replace(/[^a-z0-9_-]+/g, "-")
		.replace(/^-+|-+$/g, "")
		.slice(0, 64);
	return `${base || "note"}.md`;
}

/** Read the index, or empty string if none yet (读取索引，无则返回空串) */
function readIndex(dir: string): string {
	const p = join(dir, INDEX_FILE);
	return existsSync(p) ? readFileSync(p, "utf8") : "";
}

/** List topic files (excluding the index) (列出主题文件，排除索引) */
function listTopics(dir: string): string[] {
	if (!existsSync(dir)) return [];
	return readdirSync(dir)
		.filter((f) => f.endsWith(".md") && f !== INDEX_FILE)
		.sort();
}

/** Build a text tool result (构造文本类工具返回) */
function textResult(text: string): AgentToolResult<unknown> {
	return { content: [{ type: "text", text }], details: undefined };
}

// ── Extension entry (扩展入口) ───────────────────────────────────

export default function (pi: ExtensionAPI) {
	// 1) INJECTION: prepend the index before every LLM call.
	//    (注入：每次 LLM 调用前，把索引拼到对话最前面)
	//    This is the equivalent of Claude Code loading MEMORY.md at session start,
	//    but done per-request so it survives compaction. (等价于 Claude Code 启动注入，按请求注入以抗压缩)
	pi.on("context", async (event, ctx) => {
		const dir = resolveMemoryDir(ctx.cwd);
		let index = readIndex(dir);
		if (!index.trim()) return; // nothing to inject yet (暂无记忆可注入)

		// Cap the injected size (限制注入体积)
		if (index.length > INDEX_INJECT_MAX_CHARS) {
			index = `${index.slice(0, INDEX_INJECT_MAX_CHARS)}\n...[truncated]`;
		}

		const topics = listTopics(dir);
		const topicList = topics.length
			? `\n\nAvailable detail files (call memory_read to load): ${topics.join(", ")}`
			: "";

		const block =
			`<project-memory>\n` +
			`The following is your persistent memory for this project (index only). ` +
			`Use memory_read to load a detail file, memory_write to save a new learning, ` +
			`memory_search to grep across files.\n\n` +
			`${index}${topicList}\n` +
			`</project-memory>`;

		// Prepend as a system-ish user message at the very front (作为最前置消息注入)
		const messages = [
			{
				role: "user" as const,
				content: [{ type: "text" as const, text: block }],
				timestamp: Date.now(),
			},
			...event.messages,
		];
		return { messages };
	});

	// 2) WRITE TOOL: model saves a learning. Appends to a topic file and
	//    upserts a one-line entry in MEMORY.md index. (写工具：保存学习并更新索引)
	pi.registerTool({
		name: "memory_write",
		label: "Write Memory",
		description:
			"Save a durable learning for this project (build commands, conventions, debugging insights, user corrections/preferences). " +
			"Only save things that will be useful in a FUTURE session. Do not save transient task state. " +
			"(保存对未来会话有用的持久记忆：构建命令、约定、调试经验、用户纠正/偏好；不要存临时任务状态)",
		promptSnippet:
			"memory_write: persist a durable project learning to long-term memory",
		parameters: Type.Object({
			topic: Type.String({
				description:
					"Short topic/filename for this memory, e.g. 'build-commands', 'debugging', 'api-conventions'. Reuse existing topics when relevant.",
			}),
			summary: Type.String({
				description:
					"One concise line for the MEMORY.md index (shown every session). Make it searchable and specific.",
			}),
			content: Type.String({
				description:
					"The full memory content in markdown. Include WHY it matters and HOW to apply it.",
			}),
		}),
		async execute(
			_id,
			params: { topic: string; summary: string; content: string },
			_signal,
			_onUpdate,
			ctx: ExtensionContext,
		): Promise<AgentToolResult<unknown>> {
			const dir = resolveMemoryDir(ctx.cwd);
			const file = topicToFile(params.topic);
			const filePath = join(dir, file);

			// Append (or create) the topic detail file (追加或创建主题文件)
			const stamp = new Date().toISOString().slice(0, 10);
			const entry = `\n## ${stamp} ${params.summary}\n\n${params.content}\n`;
			const prior = existsSync(filePath) ? readFileSync(filePath, "utf8") : `# ${params.topic}\n`;
			writeFileSync(filePath, prior + entry, "utf8");

			// Upsert index line pointing at the file (更新索引行)
			const indexPath = join(dir, INDEX_FILE);
			const indexLine = `- [${params.summary}](${file})`;
			let index = readIndex(dir);
			if (!index.includes(`(${file})`)) {
				// New topic: add a fresh index line (新主题：新增索引行)
				index = index.trim()
					? `${index.trimEnd()}\n${indexLine}\n`
					: `# Project Memory Index\n\n${indexLine}\n`;
			} else if (!index.includes(params.summary)) {
				// Existing topic, new summary: append under it as a sub-bullet
				// (已有主题、新摘要：作为子条目补充)
				index = index.replace(
					new RegExp(`(\\(${file.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\\\$&")}\\)[^\\n]*)`),
					`$1\n  - ${params.summary}`,
				);
			}
			writeFileSync(indexPath, index, "utf8");

			if (ctx.hasUI) ctx.ui.notify(`Writing memory → ${file}`, "info");
			return textResult(`Saved to ${file} and updated ${INDEX_FILE}.`);
		},
	});

	// 3) READ TOOL: model loads a detail file on demand. (读工具：按需加载主题文件)
	pi.registerTool({
		name: "memory_read",
		label: "Read Memory",
		description:
			"Load the full content of a project memory detail file by name (from the index). " +
			"(按文件名加载某个记忆主题文件的完整内容)",
		promptSnippet: "memory_read: load a memory detail file by name",
		parameters: Type.Object({
			file: Type.String({
				description:
					"The memory file to read, e.g. 'debugging.md'. See the index in <project-memory>.",
			}),
		}),
		async execute(
			_id,
			params: { file: string },
			_signal,
			_onUpdate,
			ctx: ExtensionContext,
		): Promise<AgentToolResult<unknown>> {
			const dir = resolveMemoryDir(ctx.cwd);
			// Prevent path traversal; only allow files inside the memory dir (防目录穿越)
			const target = resolve(dir, params.file);
			if (!target.startsWith(resolve(dir))) {
				return textResult("Refused: path outside memory directory.");
			}
			if (!existsSync(target)) {
				return textResult(`No such memory file: ${params.file}`);
			}
			if (ctx.hasUI) ctx.ui.notify(`Recalled memory ← ${params.file}`, "info");
			return textResult(readFileSync(target, "utf8"));
		},
	});

	// 4) SEARCH TOOL: grep across all memory files. (搜索工具：跨文件 grep)
	pi.registerTool({
		name: "memory_search",
		label: "Search Memory",
		description:
			"Full-text search across all project memory files. Returns matching lines with file names. " +
			"(全文检索所有记忆文件，返回匹配行及文件名)",
		promptSnippet: "memory_search: grep across memory files",
		parameters: Type.Object({
			query: Type.String({ description: "Case-insensitive substring to search for." }),
		}),
		async execute(
			_id,
			params: { query: string },
			_signal,
			_onUpdate,
			ctx: ExtensionContext,
		): Promise<AgentToolResult<unknown>> {
			const dir = resolveMemoryDir(ctx.cwd);
			const q = params.query.toLowerCase();
			const files = [INDEX_FILE, ...listTopics(dir)];
			const hits: string[] = [];
			for (const f of files) {
				const p = join(dir, f);
				if (!existsSync(p)) continue;
				const lines = readFileSync(p, "utf8").split("\n");
				lines.forEach((line, i) => {
					if (line.toLowerCase().includes(q)) {
						hits.push(`${f}:${i + 1}: ${line.trim()}`);
					}
				});
			}
			return textResult(
				hits.length ? hits.slice(0, 50).join("\n") : `No matches for "${params.query}".`,
			);
		},
	});

	// 5) /memory COMMAND: show where memory lives + the index. (命令：显示记忆位置和索引)
	pi.registerCommand("memory", {
		description: "Show the auto-memory directory and current index (显示自动记忆目录与索引)",
		handler: async (_args, ctx) => {
			const dir = resolveMemoryDir(ctx.cwd);
			const index = readIndex(dir) || "(empty)";
			const topics = listTopics(dir);
			ctx.ui.notify(
				`Memory dir: ${dir}\nTopics: ${topics.join(", ") || "(none)"}\n\n${index}`,
				"info",
			);
		},
	});

	// ── TODO (Plan C extension point / 方案 C 扩展点) ──────────────
	// To add Claude Code-style passive background learning, hook session_shutdown
	// and use `complete()` from "@earendil-works/pi-ai" with a CHEAP/FAST model to
	// extract corrections/preferences/build-commands from the finished session,
	// then call the same write logic. Keep it fire-and-forget so it never blocks exit.
	// (要加被动后台学习：挂 session_shutdown，用便宜快模型 complete() 提取要点后写入，
	//  fire-and-forget 不阻塞退出。注意你本地推理慢，务必用独立快模型，别用主 opus。)
	//
	// pi.on("session_shutdown", async (event, ctx) => { /* extract + memory_write */ });
}
