// Session transcript scanner: the single data source shared by the context-cost
// and usage sections. Streams every *.jsonl under the sessions dir and keeps only
// aggregates, never the raw lines.
// (会话记录扫描器：上下文成本与用量两组检查的唯一数据源。流式读取
//  sessions 目录下所有 *.jsonl，只保留聚合结果，不保留原始行。)
//
// Entry shapes verified against real files on this machine:
//   {"type":"session","version":3,"id":...,"timestamp":...,"cwd":...}
//   {"type":"model_change","provider":...,"modelId":...}
//   {"type":"message","message":{role:"user"|"assistant"|"toolResult",...}}
//   {"type":"custom","customType":...} / {"type":"compaction"} / {"type":"session_info"}
// assistant messages carry usage{input,output,cacheRead,cacheWrite,totalTokens,cost{}}
// toolResult messages carry toolName + isError.
// (以上 entry 形状均在本机真实 session 文件中核对过。)

import { readFileSync, readdirSync, statSync } from "node:fs"
import { join } from "node:path"

export interface UsageAgg {
	input: number
	output: number
	cacheRead: number
	cacheWrite: number
	cost: number
	/** Number of assistant responses(assistant 响应条数) */
	responses: number
	/** Responses that reported a non-zero cost. Gateways commonly report zero, so a
	 *  cost total is only meaningful relative to this count.
	 *  (上报非零成本的响应数。网关普遍上报 0，
	 *   因此成本总额只有对比该计数才有意义。) */
	costedResponses: number
	/** Responses that reported a non-zero cacheWrite. Some providers auto-cache and
	 *  never report writes, which would otherwise show as a fake 100% hit rate.
	 *  (上报非零 cacheWrite 的响应数。部分 provider 自动缓存且从不上报写入，
	 *   否则会表现为虚假的 100% 命中率。) */
	cacheWriteReports: number
}

export interface SessionScan {
	/** Top-level session files, i.e. one per user session(顶层会话文件数) */
	sessionFiles: number
	/** Nested subagent run transcripts(嵌套的子代理运行记录数) */
	subagentFiles: number
	totalBytes: number
	totalLines: number
	/** Files that could not be read or parsed at all(完全无法读取的文件) */
	unreadable: string[]
	/** Lines that failed JSON.parse(解析失败的行数) */
	badLines: number
	earliest?: number
	latest?: number
	/** Largest session files, biggest first(最大的会话文件，降序) */
	largest: { path: string; bytes: number }[]
	/** Session files carrying no message entry at all(没有任何消息的空会话) */
	emptySessions: number

	/** Tool name -> total calls(工具名 -> 调用总数) */
	toolCalls: Map<string, number>
	/** Tool name -> error results(工具名 -> 失败结果数) */
	toolErrors: Map<string, number>
	/** Skill name -> explicit invocations, from <skill name="..."> injections
	 *  (skill 名 -> 显式调用次数，来自 <skill name="..."> 注入文本) */
	skillInvocations: Map<string, number>
	/** Prompt-template / custom entry types seen(出现过的自定义 entry 类型) */
	customEntryTypes: Map<string, number>
	/** Subagent types seen in Agent tool details(Agent 工具里出现过的子代理类型) */
	subagentTypes: Map<string, number>

	compactions: number

	/** Usage aggregated over everything(全量用量聚合) */
	usageAll: UsageAgg
	/** Usage aggregated over the recent window(近窗口用量聚合) */
	usageWindow: UsageAgg
	/** provider/model -> usage over the recent window(近窗口按模型聚合) */
	usageByModel: Map<string, UsageAgg>
	windowDays: number
}

const SKILL_RE = /<skill name="([^"]+)"/g

function emptyUsage(): UsageAgg {
	return {
		input: 0,
		output: 0,
		cacheRead: 0,
		cacheWrite: 0,
		cost: 0,
		responses: 0,
		costedResponses: 0,
		cacheWriteReports: 0,
	}
}

function addUsage(target: UsageAgg, u: Record<string, unknown>): void {
	target.input += num(u.input)
	target.output += num(u.output)
	target.cacheRead += num(u.cacheRead)
	const cacheWrite = num(u.cacheWrite)
	target.cacheWrite += cacheWrite
	if (cacheWrite > 0) target.cacheWriteReports += 1
	target.responses += 1
	const cost = u.cost
	if (cost && typeof cost === "object") {
		const total = num((cost as Record<string, unknown>).total)
		target.cost += total
		if (total > 0) target.costedResponses += 1
	}
}

function num(v: unknown): number {
	return typeof v === "number" && Number.isFinite(v) ? v : 0
}

function bump(map: Map<string, number>, key: string, by = 1): void {
	map.set(key, (map.get(key) ?? 0) + by)
}

/** Collect *.jsonl under the sessions dir. Depth 1 = one session per user session,
 *  deeper = subagent run transcripts written by the subagents extension.
 *  (收集 sessions 目录下的 *.jsonl。深度 1 为用户会话，更深为子代理运行记录。) */
function collectFiles(
	root: string,
	unreadable: string[],
): { path: string; depth: number; bytes: number; mtime: number }[] {
	const out: { path: string; depth: number; bytes: number; mtime: number }[] = []
	const walk = (dir: string, depth: number): void => {
		let entries: ReturnType<typeof readdirSync>
		try {
			entries = readdirSync(dir, { withFileTypes: true })
		} catch {
			unreadable.push(dir)
			return
		}
		for (const entry of entries) {
			const path = join(dir, entry.name)
			if (entry.isDirectory()) {
				// Skip artifact dirs created by other extensions(跳过其他扩展产生的产物目录)
				if (entry.name === "subagent-artifacts") continue
				walk(path, depth + 1)
			} else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
				try {
					const st = statSync(path)
					out.push({ path, depth, bytes: st.size, mtime: st.mtimeMs })
				} catch {
					unreadable.push(path)
				}
			}
		}
	}
	walk(root, 0)
	return out
}

export function scanSessions(sessionsDir: string, windowDays = 30): SessionScan {
	const unreadable: string[] = []
	const files = collectFiles(sessionsDir, unreadable)
	const windowStart = Date.now() - windowDays * 24 * 60 * 60 * 1000

	const scan: SessionScan = {
		sessionFiles: 0,
		subagentFiles: 0,
		totalBytes: 0,
		totalLines: 0,
		unreadable,
		badLines: 0,
		largest: [],
		emptySessions: 0,
		toolCalls: new Map(),
		toolErrors: new Map(),
		skillInvocations: new Map(),
		customEntryTypes: new Map(),
		subagentTypes: new Map(),
		compactions: 0,
		usageAll: emptyUsage(),
		usageWindow: emptyUsage(),
		usageByModel: new Map(),
		windowDays,
	}

	for (const file of files) {
		// Depth 1 means <sessions>/<project>/<file>.jsonl(深度 1 即项目目录下的会话文件)
		if (file.depth === 1) scan.sessionFiles++
		else scan.subagentFiles++
		scan.totalBytes += file.bytes

		let text: string
		try {
			text = readFileSync(file.path, "utf8")
		} catch {
			unreadable.push(file.path)
			continue
		}

		let sessionMessages = 0
		let sessionModel: string | undefined

		for (const line of text.split("\n")) {
			if (line.length === 0) continue
			scan.totalLines++
			let entry: Record<string, unknown>
			try {
				entry = JSON.parse(line) as Record<string, unknown>
			} catch {
				scan.badLines++
				continue
			}

			switch (entry.type) {
				case "session": {
					const ts = Date.parse(String(entry.timestamp ?? ""))
					if (Number.isFinite(ts)) {
						if (scan.earliest === undefined || ts < scan.earliest) scan.earliest = ts
						if (scan.latest === undefined || ts > scan.latest) scan.latest = ts
					}
					continue
				}
				case "model_change": {
					sessionModel = `${entry.provider}/${entry.modelId}`
					continue
				}
				case "compaction": {
					scan.compactions++
					continue
				}
				case "custom": {
					bump(scan.customEntryTypes, String(entry.customType ?? "?"))
					continue
				}
				case "message":
					break
				default:
					continue
			}

			const message = entry.message
			if (!message || typeof message !== "object") continue
			const msg = message as Record<string, unknown>
			sessionMessages++

			const tsRaw = msg.timestamp ?? entry.timestamp
			const ts = typeof tsRaw === "number" ? tsRaw : Date.parse(String(tsRaw ?? ""))
			if (Number.isFinite(ts)) {
				if (scan.latest === undefined || ts > scan.latest) scan.latest = ts
			}
			const inWindow = Number.isFinite(ts) && ts >= windowStart

			switch (msg.role) {
				case "user": {
					// Skill invocations only appear as an injected <skill name="..."> block
					// in the user message. This is the only skill-usage signal pi persists.
					// (skill 调用只以注入的 <skill name="..."> 文本出现在 user 消息里，
					//  这是 pi 唯一持久化的 skill 使用信号。)
					const content = msg.content
					if (Array.isArray(content)) {
						for (const block of content) {
							if (
								block &&
								typeof block === "object" &&
								(block as Record<string, unknown>).type === "text"
							) {
								const text = String((block as Record<string, unknown>).text ?? "")
								if (!text.includes("<skill name=")) continue
								SKILL_RE.lastIndex = 0
								let m: RegExpExecArray | null
								while ((m = SKILL_RE.exec(text)) !== null) {
									bump(scan.skillInvocations, m[1])
								}
							}
						}
					}
					continue
				}
				case "assistant": {
					const usage = msg.usage
					if (usage && typeof usage === "object") {
						const u = usage as Record<string, unknown>
						addUsage(scan.usageAll, u)
						if (inWindow) {
							addUsage(scan.usageWindow, u)
							const key =
								msg.provider && msg.model
									? `${msg.provider}/${msg.model}`
									: (sessionModel ?? "unknown")
							let agg = scan.usageByModel.get(key)
							if (!agg) {
								agg = emptyUsage()
								scan.usageByModel.set(key, agg)
							}
							addUsage(agg, u)
						}
					}
					const content = msg.content
					if (Array.isArray(content)) {
						for (const block of content) {
							if (!block || typeof block !== "object") continue
							const b = block as Record<string, unknown>
							if (b.type !== "toolCall") continue
							bump(scan.toolCalls, String(b.name ?? "?"))
						}
					}
					continue
				}
				case "toolResult": {
					if (msg.isError === true) bump(scan.toolErrors, String(msg.toolName ?? "?"))
					const details = msg.details
					if (details && typeof details === "object") {
						const type = (details as Record<string, unknown>).subagentType
						if (typeof type === "string") bump(scan.subagentTypes, type)
					}
					continue
				}
				default:
					continue
			}
		}

		if (file.depth === 1 && sessionMessages === 0) scan.emptySessions++
		scan.largest.push({ path: file.path, bytes: file.bytes })
	}

	scan.largest.sort((a, b) => b.bytes - a.bytes)
	scan.largest = scan.largest.slice(0, 5)
	return scan
}

export function coverageLine(scan: SessionScan): string {
	const days =
		scan.earliest !== undefined && scan.latest !== undefined
			? Math.max(1, Math.round((scan.latest - scan.earliest) / 86_400_000))
			: 0
	const from = scan.earliest ? new Date(scan.earliest).toISOString().slice(0, 10) : "?"
	const to = scan.latest ? new Date(scan.latest).toISOString().slice(0, 10) : "?"
	const sub = scan.subagentFiles > 0 ? ` + ${scan.subagentFiles} subagent runs` : ""
	return `Scanned ${scan.sessionFiles} sessions${sub} across ${days} days (${from} → ${to})`
}
