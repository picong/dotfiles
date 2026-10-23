/**
 * /doctor — deterministic health check for pi.(pi 的确定性健康体检)
 * ------------------------------------------------------------------
 * Modelled on `claude doctor`, adapted to what pi actually exposes:
 *   - Pure JS, no model turn, 0 tokens. Commands are intercepted before the agent
 *     loop, and slash commands are never listed in the system prompt, so the model
 *     can neither see nor trigger this.
 *     (纯 JS、不触发模型轮次、0 token。命令在 agent loop 之前被拦截，
 *      且系统提示从不列出 slash command，模型既看不到也无法触发。)
 *   - The report is written with pi.appendEntry, which persists into the session
 *     but never enters LLM context.
 *     (报告通过 pi.appendEntry 输出，持久化进会话但不进入 LLM 上下文。)
 *   - `--fix` is the only path that spends tokens: it hands the critical findings
 *     to the model as a user message, and the model edits files through the normal
 *     tools where the user approves each change. This extension never writes files.
 *     (--fix 是唯一花 token 的路径：把严重项作为 user message 交给模型，
 *      模型走常规工具改文件、由用户逐次确认。本扩展自身从不写文件。)
 *
 * Deliberately absent, because pi has no equivalent of them:
 * hooks (no hook system), default permission mode and pre-approved command rules
 * (no permission/allow-rule system at all).
 * (以下项因 pi 无对应机制而刻意缺失：慢 hook（无 hook 系统）、
 *  默认权限模式与预批准命令规则（完全没有权限/allow 规则系统）。)
 */

import { existsSync, readdirSync, readFileSync } from "node:fs"
import { homedir } from "node:os"
import { basename, join } from "node:path"
import {
	getAgentDir,
	getMarkdownTheme,
	loadSkillsFromDir,
	parseFrontmatter,
	VERSION,
	type ExtensionAPI,
	type ExtensionCommandContext,
} from "@earendil-works/pi-coding-agent"
import { Box, Markdown, Text } from "@earendil-works/pi-tui"
import { checkInstall } from "./check-install.ts"
import { checkContext, type SkillEntry, type ToolEntry } from "./check-context.ts"
import { checkUsage } from "./check-usage.ts"
import { coverageLine, scanSessions } from "./scan-sessions.ts"
import { countBySeverity, estTokens, fmtBytes, type DoctorReport, type Section } from "./types.ts"

const ENTRY_TYPE = "doctor:report"
const SECTION_KEYS = ["install", "context", "usage"] as const
type SectionKey = (typeof SECTION_KEYS)[number]

interface EntryData {
	report: DoctorReport
}

// ---------------------------------------------------------------------------
// Input collection(输入采集)
// ---------------------------------------------------------------------------

/** Sessions dir, honouring the same override precedence pi uses.
 *  (会话目录，遵循与 pi 相同的覆盖优先级。) */
function resolveSessionsDir(agentDir: string): string {
	const env = process.env.PI_SESSION_DIR
	if (env && env.length > 0) return env
	return join(agentDir, "sessions")
}

/** Skills that are actually resident in the system prompt, parsed from the
 *  <available_skills> block pi builds via formatSkillsForPrompt.
 *
 *  This is deliberately not loadSkills(): that helper only covers ~/.pi/agent/skills
 *  and <cwd>/.pi/skills, while the real resident catalogue also includes
 *  ~/.agents/skills and ancestor .agents/skills dirs assembled by the package
 *  manager. Parsing the prompt measures exactly what costs tokens per request.
 *  (从 pi 通过 formatSkillsForPrompt 生成的 <available_skills> 块解析真正常驻于
 *   系统提示的 skill。刻意不用 loadSkills：它只覆盖 ~/.pi/agent/skills 与
 *   <cwd>/.pi/skills，而真实常驻目录还包括由包管理器组装的 ~/.agents/skills
 *   及祖先 .agents/skills。解析提示词能精确度量每次请求的实际开销。) */
function parseResidentSkills(systemPrompt: string): SkillEntry[] {
	const block = systemPrompt.match(/<available_skills>\n([\s\S]*?)\n<\/available_skills>/)
	if (!block) return []
	const out: SkillEntry[] = []
	const entryRe = /<skill>\s*<name>([\s\S]*?)<\/name>\s*<description>([\s\S]*?)<\/description>\s*<location>([\s\S]*?)<\/location>\s*<\/skill>/g
	let match: RegExpExecArray | null
	while ((match = entryRe.exec(block[1])) !== null) {
		out.push({
			name: unescapeXml(match[1].trim()),
			description: unescapeXml(match[2].trim()),
			filePath: unescapeXml(match[3].trim()),
			resident: true,
		})
	}
	return out
}

function unescapeXml(text: string): string {
	return text
		.replace(/&lt;/g, "<")
		.replace(/&gt;/g, ">")
		.replace(/&quot;/g, '"')
		.replace(/&apos;/g, "'")
		.replace(/&amp;/g, "&")
}

/** Skills discovered on disk but absent from the prompt, i.e. invoke-only ones.
 *  Merged with the resident set so the report covers every skill that exists,
 *  while still distinguishing which of them cost resident tokens.
 *  (磁盘上存在但未进入提示的 skill，即仅可显式调用的。与常驻集合并，
 *   使报告覆盖所有存在的 skill，同时仍区分哪些真正占用常驻 token。) */
function collectSkills(agentDir: string, cwd: string, systemPrompt: string): SkillEntry[] {
	const resident = parseResidentSkills(systemPrompt)
	const byName = new Map<string, SkillEntry>()
	for (const skill of resident) byName.set(skill.name, skill)

	const extraDirs = [
		join(agentDir, "skills"),
		join(homedir(), ".agents", "skills"),
		join(cwd, ".pi", "skills"),
		join(cwd, ".agents", "skills"),
	]
	for (const dir of extraDirs) {
		if (!existsSync(dir)) continue
		try {
			for (const skill of loadSkillsFromDir({ dir, source: "doctor" }).skills) {
				if (byName.has(skill.name)) continue
				byName.set(skill.name, {
					name: skill.name,
					description: skill.description,
					filePath: skill.filePath,
					// Absent from the prompt, so it costs no resident tokens
					// (未进入提示，因此不占用常驻 token)
					resident: false,
				})
			}
		} catch {
			/* unreadable skill dir(不可读的 skill 目录) */
		}
	}
	return [...byName.values()]
}

/** A tool is advertised in the system prompt only when it contributes a prompt
 *  snippet; the resident cost of a non-advertised tool is zero.
 *  Note: getAllTools lives on the `pi` API object, not on the command context.
 *  (只有提供 prompt snippet 的工具才会出现在系统提示里；
 *   未宣传的工具常驻成本为零。
 *   注意：getAllTools 在 pi API 对象上，不在命令上下文上。) */
function collectTools(pi: ExtensionAPI, systemPrompt: string): ToolEntry[] {
	let all: ReturnType<ExtensionAPI["getAllTools"]> = []
	try {
		all = pi.getAllTools()
	} catch {
		return []
	}
	const advertised = new Set<string>()
	const toolsBlock = systemPrompt.match(/Available tools:\n([\s\S]*?)\n\n/)
	if (toolsBlock) {
		for (const line of toolsBlock[1].split("\n")) {
			const match = line.match(/^- ([^:]+):/)
			if (match) advertised.add(match[1].trim())
		}
	}
	return all.map((tool) => ({
		name: tool.name,
		visible: advertised.has(tool.name),
		source: tool.sourceInfo?.source ?? "builtin",
	}))
}

function collectPromptTemplates(agentDir: string, cwd: string): { name: string; path: string }[] {
	const dirs = [join(agentDir, "prompts"), join(cwd, ".pi", "prompts")]
	const out: { name: string; path: string }[] = []
	for (const dir of dirs) {
		if (!existsSync(dir)) continue
		let names: string[] = []
		try {
			names = readdirSync(dir).filter((name) => name.endsWith(".md"))
		} catch {
			continue
		}
		for (const name of names) {
			out.push({ name: basename(name, ".md"), path: join(dir, name) })
		}
	}
	return out
}

function collectSubagents(agentDir: string): { name: string; path: string }[] {
	const dir = join(agentDir, "agents")
	if (!existsSync(dir)) return []
	const out: { name: string; path: string }[] = []
	let names: string[] = []
	try {
		names = readdirSync(dir).filter((name) => name.endsWith(".md"))
	} catch {
		return []
	}
	for (const name of names) {
		const path = join(dir, name)
		let declared = basename(name, ".md")
		try {
			const parsed = parseFrontmatter<Record<string, unknown>>(readFileSync(path, "utf8"))
			if (typeof parsed.frontmatter.name === "string" && parsed.frontmatter.name.length > 0) {
				declared = parsed.frontmatter.name
			}
		} catch {
			/* fall back to the filename(回退到文件名) */
		}
		out.push({ name: declared, path })
	}
	return out
}

/** Current-session snapshot: answers "what am I burning right now".
 *  (当前会话快照：回答「我现在烧了多少」。) */
function buildSnapshot(ctx: ExtensionCommandContext, systemPrompt: string, toolCount: number): string[] {
	const lines: string[] = []
	const model = ctx.model
	lines.push(
		`model: ${model ? `${model.provider ?? "?"}/${model.id}` : "none"} · thinking: ${ctx.thinkingLevel ?? "?"}`,
	)
	const usage = ctx.getContextUsage()
	if (usage) {
		const pct = usage.percent === null ? "?" : `${usage.percent.toFixed(1)}%`
		const tokens = usage.tokens === null ? "unknown" : usage.tokens.toLocaleString("en-US")
		lines.push(
			`context: ${tokens} / ${usage.contextWindow.toLocaleString("en-US")} tokens (${pct})`,
		)
	} else {
		lines.push("context: not yet measured in this session")
	}
	lines.push(
		`system prompt: ${fmtBytes(systemPrompt.length)} ≈ ${estTokens(systemPrompt.length).toLocaleString("en-US")} est. tokens · ${toolCount} tools active`,
	)
	return lines
}

// ---------------------------------------------------------------------------
// Report assembly(报告组装)
// ---------------------------------------------------------------------------

function buildReport(pi: ExtensionAPI, ctx: ExtensionCommandContext, only: SectionKey[]): DoctorReport {
	const started = Date.now()
	const agentDir = getAgentDir()
	const cwd = ctx.cwd
	let systemPrompt = ""
	try {
		systemPrompt = ctx.getSystemPrompt()
	} catch {
		/* system prompt unavailable in some modes(部分模式下取不到系统提示) */
	}
	const tools = collectTools(pi, systemPrompt)
	const sections: Section[] = []
	let coverage: string | undefined

	if (only.includes("install")) {
		sections.push(checkInstall(agentDir, VERSION, cwd))
	}

	// Both context and usage read the same scan, so do it at most once.
	// (context 与 usage 共用同一次扫描，最多执行一次。)
	const needsScan = only.includes("context") || only.includes("usage")
	if (needsScan) {
		const scan = scanSessions(resolveSessionsDir(agentDir))
		coverage = coverageLine(scan)
		if (only.includes("context")) {
			sections.push(
				checkContext(
					{
						agentDir,
						skills: collectSkills(agentDir, cwd, systemPrompt),
						tools,
						promptTemplates: collectPromptTemplates(agentDir, cwd),
						subagents: collectSubagents(agentDir),
						systemPrompt,
						scan,
					},
					cwd,
				),
			)
		}
		if (only.includes("usage")) {
			sections.push(checkUsage(scan))
		}
	}

	return {
		version: VERSION,
		snapshot: buildSnapshot(ctx, systemPrompt, tools.length),
		coverage,
		sections,
		elapsedMs: Date.now() - started,
	}
}

// ---------------------------------------------------------------------------
// Rendering(渲染)
// ---------------------------------------------------------------------------

function summaryLines(report: DoctorReport): string[] {
	const counts = countBySeverity(report)
	const lines: string[] = []
	lines.push(
		`pi doctor · ${report.version} · ${report.elapsedMs}ms` +
			(report.coverage ? ` · ${report.coverage}` : ""),
	)
	lines.push(`▲ ${counts.critical} critical   △ ${counts.notice} notice   ✓ ${counts.ok} ok`)
	for (const section of report.sections) {
		for (const finding of section.findings) {
			if (finding.severity === "ok") continue
			const mark = finding.severity === "critical" ? "▲" : "△"
			lines.push(`${mark} ${finding.title}${finding.detail ? `  ${finding.detail}` : ""}`)
		}
	}
	return lines
}

function detailMarkdown(report: DoctorReport): string {
	const parts: string[] = []
	parts.push(`## pi doctor · ${report.version}`)
	parts.push(report.snapshot.map((line) => `- ${line}`).join("\n"))
	if (report.coverage) parts.push(`_${report.coverage}_`)

	for (const section of report.sections) {
		parts.push(`### ${section.title}`)
		if (section.findings.length === 0) {
			parts.push("_no findings_")
		}
		for (const finding of section.findings) {
			const mark = finding.severity === "critical" ? "▲" : finding.severity === "notice" ? "△" : "✓"
			parts.push(`**${mark} ${finding.title}**${finding.detail ? `\n\n${finding.detail}` : ""}`)
			if (finding.lines && finding.lines.length > 0) {
				parts.push(finding.lines.map((line) => `- ${line}`).join("\n"))
			}
			if (finding.caveat) {
				parts.push(`> ${finding.caveat}`)
			}
		}
		if (section.detailMarkdown) parts.push(section.detailMarkdown)
		if (section.scanErrors && section.scanErrors.length > 0) {
			parts.push(`_scan warnings:_\n${section.scanErrors.map((line) => `- ${line}`).join("\n")}`)
		}
	}
	return parts.join("\n\n")
}

/** Plain text for non-TUI modes (-p / json), where no renderer runs.
 *  (无 TUI 模式（-p / json）的纯文本输出，此时不会执行 renderer。) */
function plainText(report: DoctorReport): string {
	const lines = summaryLines(report)
	lines.push("")
	lines.push(detailMarkdown(report))
	return lines.join("\n")
}

// ---------------------------------------------------------------------------
// --fix prompt(--fix 提示词)
// ---------------------------------------------------------------------------

function buildFixPrompt(report: DoctorReport): string | undefined {
	const tasks: string[] = []
	for (const section of report.sections) {
		for (const finding of section.findings) {
			if (!finding.fix) continue
			const mark = finding.severity === "critical" ? "CRITICAL" : "NOTICE"
			tasks.push(
				`### [${mark}] ${finding.title}\n${finding.detail ? `Observed: ${finding.detail}\n` : ""}${
					finding.caveat ? `Caveat: ${finding.caveat}\n` : ""
				}Task: ${finding.fix}`,
			)
		}
	}
	if (tasks.length === 0) return undefined

	return [
		"A deterministic pi health check just ran and produced the findings below. Work through them and fix what should be fixed.",
		"",
		"Ground rules for this task:",
		"- Verify each finding against the filesystem before acting on it. The scan is heuristic; if a finding does not reproduce, say so and skip it.",
		"- Treat CRITICAL items as the required work and NOTICE items as suggestions that need a judgement call.",
		"- Respect each Caveat: it states what the underlying data cannot prove. Never delete something whose caveat says the evidence is inconclusive without asking first.",
		"- Ask for confirmation before any deletion, before touching anything outside the home directory, and before removing session files (they are the only record of past work).",
		"- Only edit user-scoped configuration: ~/.pi/agent/settings.json, ~/.pi/settings.json, and files under ~/.pi/agent or ~/.agents. Leave project-checked-in files alone unless a task explicitly names one.",
		"- When editing JSON settings, change only the specific keys or array entries named; preserve formatting and every unrelated key.",
		"- Do not commit anything. Leave changes in the working tree for review.",
		"",
		"Findings:",
		"",
		tasks.join("\n\n"),
	].join("\n")
}

// ---------------------------------------------------------------------------
// Extension entry(扩展入口)
// ---------------------------------------------------------------------------

export default function (pi: ExtensionAPI) {
	pi.registerEntryRenderer<EntryData>(ENTRY_TYPE, (entry, { expanded }, theme) => {
		const report = entry.data?.report
		if (!report) return undefined
		const box = new Box(1, 0, (text) => theme.bg("customMessageBg", text))
		const counts = countBySeverity(report)

		if (expanded) {
			box.addChild(new Markdown(detailMarkdown(report), 0, 0, getMarkdownTheme()))
			return box
		}

		const [header, tally, ...issues] = summaryLines(report)
		box.addChild(new Text(theme.fg("toolTitle", theme.bold(header)), 0, 0))
		const tallyColor = counts.critical > 0 ? "error" : counts.notice > 0 ? "warning" : "success"
		box.addChild(new Text(theme.fg(tallyColor, tally), 0, 0))
		for (const line of issues) {
			box.addChild(new Text(line.startsWith("▲") ? theme.fg("error", line) : theme.fg("warning", line), 0, 0))
		}
		box.addChild(
			new Text(theme.fg("dim", "ctrl+o to expand the full report · /doctor --fix to hand fixes to the model"), 0, 0),
		)
		return box
	})

	pi.registerCommand("doctor", {
		description: "Health check for this pi installation (install | context | usage, --fix)",
		getArgumentCompletions: (prefix) => {
			const items = [
				{ value: "install", label: "install", description: "Installation & configuration only" },
				{ value: "context", label: "context", description: "Context cost & unused resources only" },
				{ value: "usage", label: "usage", description: "Usage & efficiency only" },
				{ value: "--fix", label: "--fix", description: "Hand findings to the model to fix" },
			].filter((item) => item.value.startsWith(prefix))
			return items.length > 0 ? items : null
		},
		handler: async (args, ctx) => {
			const words = args.trim().split(/\s+/).filter((word) => word.length > 0)
			const wantFix = words.includes("--fix")
			const requested = words.filter((word) => !word.startsWith("-"))
			const unknown = requested.filter((word) => !SECTION_KEYS.includes(word as SectionKey))
			if (unknown.length > 0) {
				ctx.ui.notify(
					`unknown argument: ${unknown.join(", ")} — expected any of ${SECTION_KEYS.join(", ")} and/or --fix`,
					"warning",
				)
				return
			}
			const only = (requested.length > 0 ? requested : [...SECTION_KEYS]) as SectionKey[]

			let report: DoctorReport
			try {
				report = buildReport(pi, ctx, only)
			} catch (err) {
				ctx.ui.notify(
					`doctor failed: ${err instanceof Error ? err.message : String(err)}`,
					"error",
				)
				return
			}

			if (ctx.hasUI) {
				pi.appendEntry<EntryData>(ENTRY_TYPE, { report })
			} else {
				console.log(plainText(report))
			}

			if (!wantFix) return

			const prompt = buildFixPrompt(report)
			if (!prompt) {
				ctx.ui.notify("nothing actionable to fix", "info")
				return
			}
			if (!ctx.isIdle()) {
				ctx.ui.notify("agent is busy — run /doctor --fix again once it settles", "warning")
				return
			}
			pi.sendUserMessage(prompt)
		},
	})
}
