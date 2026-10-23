// Section B — resident context cost and never-used resources.
// (B 组 — 常驻上下文成本与从未使用的资源。)
//
// Every "unused" verdict here is an inference from session transcripts, because pi
// keeps no usage counters at all. Each such finding carries a caveat spelling out
// what the data source cannot prove, so nothing gets deleted on a false positive.
// (本组所有「未使用」判定都是从会话记录反推的，因为 pi 完全没有用量计数器。
//  每条这类结论都带口径说明，避免因误报误删。)

import { existsSync, readFileSync, statSync } from "node:fs"
import { homedir } from "node:os"
import { join, relative } from "node:path"
import { estTokens, fmtBytes, type Finding, type Section } from "./types.ts"
import type { SessionScan } from "./scan-sessions.ts"

export interface SkillEntry {
	name: string
	description: string
	filePath: string
	/** Whether the skill is resident in the system prompt, i.e. actually costs tokens
	 *  per request. Invoke-only skills are discoverable but cost nothing.
	 *  (8be5 skill 662f54265e389a7b4e8e7cfb7edf63d0793aFf0c5373662f5426771f6b636bcf6b218bf76c4290fd82b1 token3002
	 *   4ec553ef663e5f0f8c0375287684 skill 53ef88ab53d173b04f464e0d82b194b13002) */
	resident: boolean
}

export interface ToolEntry {
	name: string
	/** Whether the tool is advertised in the system prompt(是否在系统提示里宣传) */
	visible: boolean
	source: string
}

export interface ContextInputs {
	agentDir: string
	skills: SkillEntry[]
	tools: ToolEntry[]
	/** Prompt template names discovered under prompts dirs(prompts 目录下发现的模板名) */
	promptTemplates: { name: string; path: string }[]
	/** Subagent definition names under agents/(agents/ 下的子代理定义名) */
	subagents: { name: string; path: string }[]
	/** Resident system prompt, used for the true resident cost(常驻系统提示，用于计算真实常驻成本) */
	systemPrompt: string
	scan: SessionScan
}

/** Context files pi injects into the system prompt on every request.
 *  (pi 每次请求都注入系统提示的上下文文件。) */
function contextFileCandidates(agentDir: string, cwd: string): string[] {
	const home = homedir()
	const names = ["AGENTS.md", "CLAUDE.md"]
	const dirs = [join(agentDir), join(home, ".agents"), cwd]
	const out: string[] = []
	for (const dir of dirs) {
		for (const name of names) {
			const path = join(dir, name)
			if (existsSync(path)) out.push(path)
		}
	}
	return [...new Set(out)]
}

export function checkContext(inputs: ContextInputs, cwd: string): Section {
	const { agentDir, skills, tools, promptTemplates, subagents, systemPrompt, scan } = inputs
	const findings: Finding[] = []
	const detail: string[] = []
	const home = homedir()
	const short = (path: string): string => path.replace(home, "~")

	// ---- resident system prompt cost(常驻系统提示成本) ----
	const promptTokens = estTokens(systemPrompt.length)
	const skillListChars = skills
		.filter((skill) => skill.resident)
		.reduce((sum, skill) => sum + skill.name.length + skill.description.length + 40, 0)
	const visibleTools = tools.filter((tool) => tool.visible)
	const contextFiles = contextFileCandidates(agentDir, cwd).map((path) => {
		let bytes = 0
		try {
			bytes = statSync(path).size
		} catch {
			/* ignore(忽略) */
		}
		return { path, bytes }
	})
	const contextFileChars = contextFiles.reduce((sum, file) => sum + file.bytes, 0)

	detail.push(
		[
			"| Resident item | Size | est. tokens |",
			"|---|---:|---:|",
			`| System prompt (total) | ${fmtBytes(systemPrompt.length)} | ${estTokens(systemPrompt.length)} |`,
			`| ├ context files (${contextFiles.length}) | ${fmtBytes(contextFileChars)} | ${estTokens(contextFileChars)} |`,
			`| ├ skill catalogue (${skills.filter((s) => s.resident).length}) | ${fmtBytes(skillListChars)} | ${estTokens(skillListChars)} |`,
			`| └ tool list (${visibleTools.length} advertised) | — | — |`,
		].join("\n"),
	)
	if (contextFiles.length > 0) {
		detail.push(
			[
				"| Context file | Size | est. tokens |",
				"|---|---:|---:|",
				...contextFiles
					.sort((a, b) => b.bytes - a.bytes)
					.map((file) => `| ${short(file.path)} | ${fmtBytes(file.bytes)} | ${estTokens(file.bytes)} |`),
			].join("\n"),
		)
	}
	findings.push({
		severity: "ok",
		title: `resident system prompt ≈ ${promptTokens.toLocaleString("en-US")} est. tokens`,
		detail: `${skills.length} skills, ${visibleTools.length}/${tools.length} tools advertised, ${contextFiles.length} context files`,
		caveat: "Token figures are chars/4 estimates (est.), the same heuristic pi uses internally.",
	})

	// A context file large enough to dominate the prompt is worth flagging on size
	// alone; whether its content is derivable is a judgement call left to --fix.
	// (体积足以主导系统提示的上下文文件值得单独提示；内容是否可推导交给 --fix 判断。)
	const bigContextFiles = contextFiles.filter((file) => file.bytes >= 8192)
	if (bigContextFiles.length > 0) {
		findings.push({
			severity: "notice",
			title: `${bigContextFiles.length} large context file${bigContextFiles.length > 1 ? "s" : ""}`,
			detail: bigContextFiles
				.map((file) => `${short(file.path)} ${fmtBytes(file.bytes)} ≈ ${estTokens(file.bytes)} est. tokens`)
				.join(", "),
			fix: `Review these always-resident context files for content the session could derive on its own:\n${bigContextFiles
				.map((file) => `  - ${file.path} (${fmtBytes(file.bytes)}, ≈${estTokens(file.bytes)} est. tokens)`)
				.join(
					"\n",
				)}\nSafe to cut: directory listings, tech-stack inventories already in the manifest, standard build commands, type signatures copied from source, generic best practices, and rules already enforced by lint/CI. Keep: gotchas and failure contracts, design rationale, conventions that differ from the tool's default, security prohibitions, repo etiquette, domain vocabulary, unguessable commands, and @path references. When unsure, keep it — and never delete a "never do X" rule just because it reads as generic. Show the diff and let the user approve; do not commit.`,
			caveat:
				"Size alone does not mean waste — a long file of genuinely non-obvious rules is worth its tokens. Only content judged derivable should go.",
		})
	}

	// ---- skills never explicitly invoked(从未被显式调用的 skill) ----
	const unusedSkills = skills.filter((skill) => !scan.skillInvocations.has(skill.name))
	const usedSkills = skills.length - unusedSkills.length
	if (skills.length > 0) {
		const rows = skills
			.map((skill) => ({
				name: skill.name,
				count: scan.skillInvocations.get(skill.name) ?? 0,
				chars: skill.name.length + skill.description.length + 40,
				path: skill.filePath,
				hidden: !skill.resident,
			}))
			.sort((a, b) => b.count - a.count || a.name.localeCompare(b.name))
		detail.push(
			[
				"| Skill | Explicit invocations | Catalogue cost (est.) | In prompt |",
				"|---|---:|---:|:--:|",
				...rows.map(
					(row) =>
						`| ${row.name} | ${row.count} | ${estTokens(row.chars)} | ${row.hidden ? "no" : "yes"} |`,
				),
			].join("\n"),
		)
	}
	if (unusedSkills.length > 0) {
		const residentUnused = unusedSkills.filter((skill) => skill.resident)
		const wastedChars = residentUnused.reduce(
			(sum, skill) => sum + skill.name.length + skill.description.length + 40,
			0,
		)
		findings.push({
			severity: "notice",
			title: `${unusedSkills.length}/${skills.length} skills never explicitly invoked`,
			detail:
				residentUnused.length > 0
					? `${residentUnused.length} of them sit in the system prompt, ≈${estTokens(wastedChars)} est. tokens per request`
					: "none of them are in the system prompt, so they cost nothing per request",
			lines: unusedSkills.map(
				(skill) => `${skill.name}${skill.resident ? "" : " (not in prompt)"} — ${short(skill.filePath)}`,
			),
			fix:
				residentUnused.length > 0
					? `Consider disabling the skills below so their catalogue lines stop being sent on every request. Disable by adding "-<relative path>/SKILL.md" to the "skills" array in ${join(agentDir, "settings.json")} (paths resolve against the skill's baseDir, e.g. "skills/foo/SKILL.md" for ~/.agents/skills/foo). Before disabling any of them, confirm with the user — a skill may be intentionally kept for future use:\n${residentUnused
							.map((skill) => `  - ${skill.name} (${skill.filePath})`)
							.join("\n")}`
					: undefined,
			caveat:
				'Inferred from <skill name="..."> blocks injected into user messages — the only skill-usage signal pi persists. A skill the model read on its own (plain read of SKILL.md, without /skill:name) leaves no such marker, so zero invocations means "never explicitly invoked", not "never useful".',
		})
	} else if (skills.length > 0) {
		findings.push({
			severity: "ok",
			title: `all ${skills.length} skills have been invoked`,
			detail: `${usedSkills} distinct skills seen in transcripts`,
		})
	}

	// ---- extension tools never called(从未被调用的扩展工具) ----
	const unusedTools = tools.filter((tool) => !scan.toolCalls.has(tool.name))
	if (tools.length > 0) {
		const rows = tools
			.map((tool) => ({
				name: tool.name,
				count: scan.toolCalls.get(tool.name) ?? 0,
				errors: scan.toolErrors.get(tool.name) ?? 0,
				visible: tool.visible,
				source: tool.source,
			}))
			.sort((a, b) => b.count - a.count || a.name.localeCompare(b.name))
		detail.push(
			[
				"| Tool | Calls | Errors | Advertised | Source |",
				"|---|---:|---:|:--:|---|",
				...rows.map(
					(row) =>
						`| ${row.name} | ${row.count} | ${row.errors} | ${row.visible ? "yes" : "no"} | ${row.source} |`,
				),
			].join("\n"),
		)
	}
	if (unusedTools.length > 0) {
		const advertised = unusedTools.filter((tool) => tool.visible)
		findings.push({
			severity: "notice",
			title: `${unusedTools.length}/${tools.length} tools never called`,
			detail: unusedTools
				.slice(0, 6)
				.map((tool) => tool.name)
				.join(", ") + (unusedTools.length > 6 ? ` … +${unusedTools.length - 6}` : ""),
			lines: unusedTools.map(
				(tool) => `${tool.name}${tool.visible ? "" : " (not advertised)"} — ${tool.source}`,
			),
			fix:
				advertised.length > 0
					? `These tools are advertised in the system prompt but were never called in any recorded session: ${advertised
							.map((tool) => `${tool.name} (${tool.source})`)
							.join(
								", ",
							)}. Check whether the providing extension is still wanted; if not, disable it via the "extensions"/"packages" arrays in ${join(agentDir, "settings.json")}. Confirm with the user first — a tool can be rarely-but-critically used.`
					: undefined,
			caveat:
				"Counted from toolCall blocks in assistant messages across all scanned sessions. A tool added recently, or one only reachable in a project you have not opened since, will look unused here.",
		})
	}

	// ---- prompt templates: existence only(模板：仅统计存在，无法统计用量) ----
	// Templates expand into ordinary user text before the session records anything,
	// so no usage signal survives. Reporting a "never used" verdict here would be a
	// guess, so the finding deliberately reports existence only.
	// (模板在会话记录任何内容之前就展开成普通用户文本，没有用量信号残留。
	//  这里若给出「从未使用」结论纯属猜测，故只报告存在性。)
	if (promptTemplates.length > 0) {
		detail.push(
			`Prompt templates (${promptTemplates.length}): ${promptTemplates.map((t) => `/${t.name}`).join(", ")}`,
		)
		findings.push({
			severity: "ok",
			title: `${promptTemplates.length} prompt templates registered`,
			detail: promptTemplates.map((t) => `/${t.name}`).join(", "),
			caveat:
				"Prompt templates expand into ordinary user text and leave no marker in the transcript, so pi records no usage signal for them at all — usage cannot be measured here, only existence.",
		})
	}

	const unusedSubagents = subagents.filter((agent) => !scan.subagentTypes.has(agent.name))
	if (subagents.length > 0) {
		const rows = subagents
			.map((agent) => ({ name: agent.name, count: scan.subagentTypes.get(agent.name) ?? 0 }))
			.sort((a, b) => b.count - a.count || a.name.localeCompare(b.name))
		detail.push(
			[
				"| Subagent | Dispatches |",
				"|---|---:|",
				...rows.map((row) => `| ${row.name} | ${row.count} |`),
			].join("\n"),
		)
	}
	if (unusedSubagents.length > 0) {
		findings.push({
			severity: "notice",
			title: `${unusedSubagents.length}/${subagents.length} subagent definitions never dispatched`,
			detail: unusedSubagents.map((agent) => agent.name).join(", "),
			lines: unusedSubagents.map((agent) => `${agent.name} — ${short(agent.path)}`),
			fix: `These subagent definitions under ${join(agentDir, "agents")} were never dispatched in any recorded session: ${unusedSubagents
				.map((agent) => agent.name)
				.join(
					", ",
				)}. Subagent definitions are loaded on demand and cost no resident context, so this is housekeeping only — ask the user before removing any.`,
			caveat:
				"Counted from the subagentType field in Agent tool results. Definitions cost no resident tokens, so an unused one is harmless clutter rather than waste.",
		})
	}

	return {
		key: "context",
		title: "Context cost & unused resources",
		findings,
		detailMarkdown: detail.length > 0 ? detail.join("\n\n") : undefined,
	}
}
