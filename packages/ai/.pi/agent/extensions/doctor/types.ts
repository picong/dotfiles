// Shared types for the /doctor health check(体检命令的共享类型)

/** Finding severity. Any finding that carries a `fix` enters the --fix task list,
 *  labelled so the model treats critical items as required and notices as judgement
 *  calls.
 *  (严重程度。凡带 `fix` 的结论都会进入 --fix 清单，
 *   并标注级别：critical 为必修，notice 需人工判断。) */
export type Severity = "critical" | "notice" | "ok"

export interface Finding {
	severity: Severity
	/** Short headline, shown in the collapsed summary(折叠态显示的短标题) */
	title: string
	/** One-line detail, e.g. the offending path(单行明细，例如问题路径) */
	detail?: string
	/** Extra lines shown only when expanded(仅展开态显示的补充行) */
	lines?: string[]
	/** Concrete remediation instruction, fed to the model by --fix
	 *  (具体修复指令，--fix 时交给模型) */
	fix?: string
	/** Why this conclusion may be wrong / what the data source cannot prove.
	 *  Always rendered so the user does not delete things based on a false positive.
	 *  (口径说明：该结论的推断局限，始终渲染，避免因误报误删) */
	caveat?: string
}

export interface Section {
	/** Group key used by the subcommand filter(分组键，供子命令过滤) */
	key: "install" | "context" | "usage"
	title: string
	findings: Finding[]
	/** Markdown appended after the findings, only in expanded mode
	 *  (明细 markdown，仅展开态渲染) */
	detailMarkdown?: string
	/** Non-fatal scan problems, e.g. unreadable files(扫描过程中的非致命问题) */
	scanErrors?: string[]
}

export interface DoctorReport {
	version: string
	/** Current-session snapshot lines(当前会话快照) */
	snapshot: string[]
	/** Session scan coverage line(会话扫描覆盖窗口) */
	coverage?: string
	sections: Section[]
	elapsedMs: number
}

export function countBySeverity(report: DoctorReport): {
	critical: number
	notice: number
	ok: number
} {
	let critical = 0
	let notice = 0
	let ok = 0
	for (const section of report.sections) {
		for (const finding of section.findings) {
			if (finding.severity === "critical") critical++
			else if (finding.severity === "notice") notice++
			else ok++
		}
	}
	return { critical, notice, ok }
}

/** chars/4 heuristic, matching pi's own estimateTokens
 *  (字符数/4 估算，与 pi 内部 estimateTokens 一致) */
export function estTokens(chars: number): number {
	return Math.ceil(chars / 4)
}

export function fmtBytes(bytes: number): string {
	if (bytes < 1024) return `${bytes}B`
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`
	return `${(bytes / 1024 / 1024).toFixed(1)}MB`
}

export function fmtCount(n: number): string {
	return n.toLocaleString("en-US")
}
