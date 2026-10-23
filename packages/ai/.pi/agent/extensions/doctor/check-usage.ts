// Section D — usage and efficiency insight, aggregated from session transcripts.
// (D 组 — 用量与效率洞察，从会话记录聚合。)
//
// Data source: assistant messages carry usage{input,output,cacheRead,cacheWrite,
// totalTokens,cost{}} plus provider/model; toolResult messages carry toolName and
// isError. Both verified against real files under ~/.pi/agent/sessions.
// (数据源：assistant 消息带 usage{...} 与 provider/model；toolResult 带 toolName 与
//  isError。两者均在 ~/.pi/agent/sessions 的真实文件中核对过。)

import { homedir } from "node:os"
import { fmtBytes, fmtCount, type Finding, type Section } from "./types.ts"
import type { SessionScan, UsageAgg } from "./scan-sessions.ts"

/** Cache hit rate, or undefined when the provider never reports cache writes.
 *  A provider that auto-caches without reporting writes would otherwise show a
 *  fake 100%, so "no write data" is deliberately distinguished from "perfect".
 *  (缓存命中率；provider 从不上报写入时返回 undefined。
 *   自动缓存但不上报写入的 provider 否则会表现为虚假的 100%，
 *   故刻意区分「无写入数据」与「完美命中」。) */
function cacheHitRate(usage: UsageAgg): number | undefined {
	if (usage.cacheWriteReports === 0) return undefined
	const denom = usage.cacheRead + usage.cacheWrite
	if (denom === 0) return undefined
	return usage.cacheRead / denom
}

function fmtTokens(n: number): string {
	if (n >= 1_000_000_000) return `${(n / 1_000_000_000).toFixed(2)}B`
	if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
	if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`
	return String(n)
}

function fmtPct(v: number): string {
	return `${(v * 100).toFixed(1)}%`
}

export function checkUsage(scan: SessionScan): Section {
	const findings: Finding[] = []
	const detail: string[] = []
	const home = homedir()

	const { usageAll, usageWindow, usageByModel, windowDays } = scan

	// ---- token and cost totals(token 与成本总量) ----
	const totalAll =
		usageAll.input + usageAll.output + usageAll.cacheRead + usageAll.cacheWrite
	const totalWindow =
		usageWindow.input + usageWindow.output + usageWindow.cacheRead + usageWindow.cacheWrite

	detail.push(
		[
			`| Window | Responses | Input | Output | Cache read | Cache write | Total |`,
			"|---|---:|---:|---:|---:|---:|---:|",
			`| all time | ${fmtCount(usageAll.responses)} | ${fmtTokens(usageAll.input)} | ${fmtTokens(usageAll.output)} | ${fmtTokens(usageAll.cacheRead)} | ${fmtTokens(usageAll.cacheWrite)} | ${fmtTokens(totalAll)} |`,
			`| last ${windowDays}d | ${fmtCount(usageWindow.responses)} | ${fmtTokens(usageWindow.input)} | ${fmtTokens(usageWindow.output)} | ${fmtTokens(usageWindow.cacheRead)} | ${fmtTokens(usageWindow.cacheWrite)} | ${fmtTokens(totalWindow)} |`,
		].join("\n"),
	)

	const costAll = usageAll.cost
	const costNote =
		costAll > 0
			? `≈$${costAll.toFixed(2)} over the ${usageAll.costedResponses} of ${fmtCount(usageAll.responses)} responses that reported a cost`
			: "no cost reported by any provider"
	findings.push({
		severity: "ok",
		title: `${fmtTokens(totalAll)} tokens across ${fmtCount(usageAll.responses)} responses`,
		detail: `${costNote}; last ${windowDays}d: ${fmtTokens(totalWindow)} tokens`,
		caveat:
			`Token counts come from the provider's own usage field per response, so they are exact where recorded. Cost is only as complete as the provider makes it: ${
				usageAll.responses - usageAll.costedResponses
			} of ${fmtCount(usageAll.responses)} responses reported zero cost (typical for gateway providers), so the total is a floor, not a bill.`,
	})

	// ---- per-model breakdown over the recent window(近窗口按模型拆分) ----
	if (usageByModel.size > 0) {
		const rows = [...usageByModel.entries()]
			.map(([key, usage]) => ({
				key,
				usage,
				total: usage.input + usage.output + usage.cacheRead + usage.cacheWrite,
				hit: cacheHitRate(usage),
			}))
			.sort((a, b) => b.total - a.total)
		detail.push(
			[
				`| Model (last ${windowDays}d) | Responses | Total tokens | Cache hit | Cost |`,
				"|---|---:|---:|---:|---:|",
				...rows.map(
					(row) =>
						`| ${row.key} | ${fmtCount(row.usage.responses)} | ${fmtTokens(row.total)} | ${
							row.hit === undefined ? "n/a" : fmtPct(row.hit)
						} | ${row.usage.cost > 0 ? `$${row.usage.cost.toFixed(2)}` : "—"} |`,
				),
				"",
				"_Cache hit `n/a` means the provider never reported a cache write, so the rate is unmeasurable rather than perfect. Cost `—` means zero cost reported._",
			].join("\n"),
		)
	}

	// ---- cache hit rate(缓存命中率) ----
	// A cache write is charged at a premium and only pays off if later read back, so
	// a low read/write ratio means prompt prefixes are churning between requests.
	// (缓存写入按溢价计费，只有后续被读回才划算；读写比低说明请求间前缀在反复变动。)
	const hitWindow = cacheHitRate(usageWindow)
	const measurable = usageWindow.cacheWriteReports
	if (hitWindow !== undefined) {
		const low = hitWindow < 0.5
		findings.push({
			severity: low ? "notice" : "ok",
			title: `cache hit rate ${fmtPct(hitWindow)} over last ${windowDays}d`,
			detail: `${fmtTokens(usageWindow.cacheRead)} read vs ${fmtTokens(usageWindow.cacheWrite)} written`,
			fix: low
				? `Cache reads (${fmtTokens(usageWindow.cacheRead)}) are below cache writes (${fmtTokens(usageWindow.cacheWrite)}) over the last ${windowDays} days, meaning the prompt prefix keeps changing so cached blocks are paid for but rarely reused. Investigate what mutates early in the prompt between requests: extensions that inject changing text via the "context" event, a system prompt containing timestamps or per-turn state, or frequent model switching (each model has its own cache). Report findings before changing anything.`
				: undefined,
			caveat: `Ratio is cacheRead/(cacheRead+cacheWrite) across the ${fmtCount(measurable)} of ${fmtCount(usageWindow.responses)} responses whose provider reported a cache write; providers that auto-cache without reporting writes are excluded rather than counted as 100%. Short sessions legitimately write more than they read, so a low rate is a hint to investigate, not proof of waste.`,
		})
	} else if (usageWindow.responses > 0) {
		findings.push({
			severity: "ok",
			title: "cache hit rate not measurable",
			detail: `no cache writes reported across ${fmtCount(usageWindow.responses)} responses in the last ${windowDays}d`,
			caveat:
				"The providers used report cacheRead but never cacheWrite, so the hit rate cannot be computed. This is a reporting gap, not a cache problem.",
		})
	}

	// ---- tool error rates(工具错误率) ----
	const toolRows = [...scan.toolCalls.entries()]
		.map(([name, calls]) => ({
			name,
			calls,
			errors: scan.toolErrors.get(name) ?? 0,
			rate: calls > 0 ? (scan.toolErrors.get(name) ?? 0) / calls : 0,
		}))
		.sort((a, b) => b.errors - a.errors || b.calls - a.calls)
	if (toolRows.length > 0) {
		detail.push(
			[
				"| Tool | Calls | Errors | Error rate |",
				"|---|---:|---:|---:|",
				...toolRows.map(
					(row) => `| ${row.name} | ${fmtCount(row.calls)} | ${fmtCount(row.errors)} | ${fmtPct(row.rate)} |`,
				),
			].join("\n"),
		)
	}
	// Only flag tools with enough calls for a rate to mean anything. bash is excluded
	// because its isError maps to any non-zero exit code, which is routinely an
	// intentional probe (grep with no match, test-and-fallback), making the rate
	// uninterpretable rather than merely noisy.
	// (只对调用量足够的工具给出比率结论。bash 排除在外：它的 isError 对应任何非零
	//  退出码，而非零退出常常是有意探测（grep 无匹配、先试后降级），
	//  使得该比率不可解释，而不只是噪声。)
	const RATE_EXEMPT = new Set(["bash"])
	const noisy = toolRows.filter(
		(row) => !RATE_EXEMPT.has(row.name) && row.calls >= 20 && row.rate >= 0.2,
	)
	if (noisy.length > 0) {
		findings.push({
			severity: "notice",
			title: `${noisy.length} tool${noisy.length > 1 ? "s" : ""} failing above 20%`,
			detail: noisy
				.map((row) => `${row.name} ${fmtPct(row.rate)} (${row.errors}/${row.calls})`)
				.join(", "),
			lines: noisy.map(
				(row) => `${row.name}: ${row.errors} errors in ${row.calls} calls (${fmtPct(row.rate)})`,
			),
			fix: `These tools fail often enough to be worth a look: ${noisy
				.map((row) => `${row.name} at ${fmtPct(row.rate)} (${row.errors}/${row.calls})`)
				.join(
					", ",
				)}. A high rate usually means either a usage pattern the tool rejects, or a misconfiguration. Investigate representative failures and report what is going wrong — do not change tool configuration without asking.`,
			caveat:
				"Counted from toolResult.isError over tools with at least 20 calls. bash is excluded from this check because its errors are dominated by intentional non-zero exits; see the table for its raw rate.",
		})
	}

	// ---- compaction frequency(上下文压缩频率) ----
	if (scan.compactions > 0) {
		const perSession = scan.compactions / Math.max(1, scan.sessionFiles)
		findings.push({
			severity: perSession >= 0.5 ? "notice" : "ok",
			title: `${scan.compactions} compaction${scan.compactions > 1 ? "s" : ""} recorded`,
			detail: `${perSession.toFixed(2)} per session across ${scan.sessionFiles} sessions`,
			fix:
				perSession >= 0.5
					? `Sessions hit context compaction ${perSession.toFixed(2)} times each on average, which means conversations routinely run out of context window. Look for what fills the window: oversized tool outputs, large file reads, or a big resident system prompt. Report the biggest contributors before changing settings.`
					: undefined,
			caveat:
				"Counted from compaction entries in session files. Long productive sessions legitimately compact; a high rate only matters if it interrupts work.",
		})
	}

	// ---- storage footprint(存储占用) ----
	const overBudget = scan.totalBytes > 100 * 1024 * 1024
	findings.push({
		severity: overBudget ? "notice" : "ok",
		title: `sessions on disk ${fmtBytes(scan.totalBytes)}`,
		detail: `${scan.sessionFiles} sessions${
			scan.subagentFiles > 0 ? ` + ${scan.subagentFiles} subagent runs` : ""
		}, ${fmtCount(scan.totalLines)} entries${scan.emptySessions > 0 ? `, ${scan.emptySessions} empty` : ""}`,
		lines: scan.largest.map(
			(file) => `${fmtBytes(file.bytes).padStart(8)}  ${file.path.replace(home, "~")}`,
		),
		fix: overBudget
			? `The session archive is ${fmtBytes(scan.totalBytes)} across ${scan.sessionFiles} sessions${
					scan.emptySessions > 0 ? ` (${scan.emptySessions} of them contain no messages)` : ""
				}. Sessions are the only record of past work and deleting them is irreversible, so do not delete anything without explicit confirmation. Report the largest files and the oldest date range, and offer archiving (move out of the sessions dir) as the default over deletion.`
			: undefined,
		caveat:
			"Size alone is not a problem — pi does not load the archive at startup. It matters only for disk usage and for how long a full doctor scan takes.",
	})

	if (scan.badLines > 0 || scan.unreadable.length > 0) {
		findings.push({
			severity: "notice",
			title: "some session data could not be parsed",
			detail: `${scan.badLines} unparseable lines, ${scan.unreadable.length} unreadable files`,
			lines: scan.unreadable.slice(0, 10).map((path) => path.replace(home, "~")),
			caveat:
				"Truncated final lines are normal for a session that is currently open or was killed mid-write; these are skipped and only slightly under-count the aggregates above.",
		})
	}

	return {
		key: "usage",
		title: "Usage & efficiency",
		findings,
		detailMarkdown: detail.length > 0 ? detail.join("\n\n") : undefined,
	}
}
