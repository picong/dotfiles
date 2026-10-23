// Section A — installation and configuration health.
// (A 组 — 安装与配置健康。)
//
// Everything here is verified against the filesystem, so findings are either
// "critical" (provably harmful) or "notice" (probably wasteful, not provably wrong).
// (本组结论全部基于文件系统实证，因此只有 critical（确定有害）
//  与 notice（可能浪费但不一定是错）两级。)

import { execFileSync } from "node:child_process"
import {
	type Dirent,
	existsSync,
	lstatSync,
	readFileSync,
	readdirSync,
	realpathSync,
	statSync,
} from "node:fs"
import { homedir } from "node:os"
import { basename, dirname, join, relative, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { parseFrontmatter } from "@earendil-works/pi-coding-agent"
import { fmtBytes, type Finding, type Section } from "./types.ts"

/** Settings keys pi actually reads, parsed from the installed package's own
 *  Settings interface at runtime.
 *
 *  Deliberately not a hardcoded list: pi adds settings keys every few releases, and
 *  a stale literal would report freshly-added valid keys as dead config — the worst
 *  possible failure for a checker whose --fix path suggests deleting them. Reading
 *  the installed .d.ts means the check is always correct for the running version.
 *  Returns undefined when the schema cannot be located, so the caller can skip the
 *  check rather than guess.
 *  (运行时从已安装包自带的 Settings 接口解析 pi 真正读取的配置键。
 *   刻意不用硬编码列表：pi 每几个版本就新增配置键，陈旧的列表会把新增的
 *   合法键报成死配置——而 --fix 会建议删除它们，这是最糟的失败模式。
 *   读已安装的 .d.ts 能保证检查永远匹配当前运行版本。
 *   定位不到 schema 时返回 undefined，由调用方跳过检查而不是瞎猜。) */
function readKnownSettingsKeys(): Set<string> | undefined {
	let dtsPath: string
	try {
		const entry = fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))
		dtsPath = join(dirname(entry), "core", "settings-manager.d.ts")
	} catch {
		return undefined
	}
	let text: string
	try {
		text = readFileSync(dtsPath, "utf8")
	} catch {
		return undefined
	}
	const block = text.match(/export interface Settings \{\n([\s\S]*?)\n\}/)
	if (!block) return undefined
	const keys = new Set<string>()
	for (const line of block[1].split("\n")) {
		const key = line.match(/^\s*([A-Za-z_$][\w$]*)\??\s*:/)
		if (key) keys.add(key[1])
	}
	return keys.size > 0 ? keys : undefined
}

/** Extension sources that read a settings key directly, so an "unknown" key that an
 *  extension consumes is not reported as dead.
 *  (直接读取配置键的扩展源码；被扩展消费的“未知”键不当作死配置报告。) */
function keysReferencedByExtensions(agentDir: string): Set<string> {
	const found = new Set<string>()
	const extDir = join(agentDir, "extensions")
	const walk = (dir: string, depth: number): void => {
		if (depth > 3) return
		let entries: Dirent[]
		try {
			entries = readdirSync(dir, { withFileTypes: true })
		} catch {
			return
		}
		for (const entry of entries) {
			if (entry.name === "node_modules" || entry.name.startsWith(".")) continue
			const full = join(dir, entry.name)
			if (entry.isDirectory()) {
				walk(full, depth + 1)
				continue
			}
			if (!entry.name.endsWith(".ts") && !entry.name.endsWith(".js")) continue
			let src: string
			try {
				src = readFileSync(full, "utf8")
			} catch {
				continue
			}
			// settings.foo / settings["foo"] / getSetting("foo")
			for (const m of src.matchAll(
				/(?:settings|config)\s*(?:\.\s*([A-Za-z_$][\w$]*)|\[\s*["'`]([^"'`]+)["'`]\s*\])/g,
			)) {
				const key = m[1] ?? m[2]
				if (key) found.add(key)
			}
		}
	}
	walk(extDir, 0)
	return found
}

interface ResourcePattern {
	/** Settings field the pattern came from(模式所属的 settings 字段) */
	field: string
	/** Raw pattern text as written in settings(settings 中的原始模式文本) */
	raw: string
	/** Pattern with the +/-/! prefix stripped(去掉 +/-/! 前缀后的路径) */
	path: string
	prefix: "+" | "-" | "!" | ""
	/** Package source, when the pattern came from packages[](来自 packages[] 时的包源) */
	pkg?: string
}

function readJson(path: string): { value?: Record<string, unknown>; error?: string } {
	if (!existsSync(path)) return {}
	try {
		return { value: JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown> }
	} catch (err) {
		return { error: err instanceof Error ? err.message : String(err) }
	}
}

/** Collect +/-/! override patterns from a settings object, including packages[].
 *  Bare (unprefixed) patterns are globs and are not path-checkable, so they are skipped.
 *  (收集 settings 中的 +/-/! 覆盖模式，含 packages[]。
 *   无前缀模式是 glob，无法按路径校验，故跳过。) */
function collectPatterns(settings: Record<string, unknown>): ResourcePattern[] {
	const out: ResourcePattern[] = []
	const push = (field: string, list: unknown, pkg?: string): void => {
		if (!Array.isArray(list)) return
		for (const item of list) {
			if (typeof item !== "string") continue
			const prefix = item.startsWith("+")
				? "+"
				: item.startsWith("-")
					? "-"
					: item.startsWith("!")
						? "!"
						: ""
			if (prefix === "") continue
			out.push({ field, raw: item, path: item.slice(1), prefix, pkg })
		}
	}
	for (const field of ["extensions", "skills", "prompts", "themes"]) {
		push(field, settings[field])
	}
	const packages = settings.packages
	if (Array.isArray(packages)) {
		for (const entry of packages) {
			if (!entry || typeof entry !== "object") continue
			const pkg = entry as Record<string, unknown>
			const source = typeof pkg.source === "string" ? pkg.source : "?"
			for (const field of ["extensions", "skills", "prompts", "themes"]) {
				push(field, pkg[field], source)
			}
		}
	}
	return out
}

/** Resolve the on-disk base directory for a package source, mirroring how pi
 *  materialises npm:/git: packages under the agent dir.
 *  (解析包源在磁盘上的基目录，与 pi 把 npm:/git: 包落地到 agent 目录的方式一致。) */
function packageBaseDir(agentDir: string, source: string): string | undefined {
	if (source.startsWith("npm:")) {
		return join(agentDir, "npm", "node_modules", source.slice(4))
	}
	if (source.startsWith("git:")) {
		return join(agentDir, "git", source.slice(4))
	}
	const npmGuess = join(agentDir, "npm", "node_modules", source)
	return existsSync(npmGuess) ? npmGuess : undefined
}

/** Every base directory a non-package pattern can legitimately resolve against.
 *  pi applies one settings array against several resource roots, each with its own
 *  baseDir: `~/.pi/agent` for pi-scoped resources, `~/.agents` for agents-scoped
 *  skills, and the project equivalents. A pattern is only dead when it matches none
 *  of them, so checking a single baseDir produces false positives.
 *  (非包模式可能合法解析的全部基目录。pi 把一个 settings 数组应用于多个
 *   资源根，各有自己的 baseDir：pi 作用域用 ~/.pi/agent，agents 作用域的 skill
 *   用 ~/.agents，项目侧同理。只有全部不命中才算死指针，
 *   只查单一 baseDir 会产生误报。) */
function candidateBaseDirs(agentDir: string, settingsPath: string, cwd: string): string[] {
	const home = homedir()
	// Paths in ~/.pi/settings.json resolve relative to ~/.pi, not the agent dir
	// (~/.pi/settings.json 里的路径相对 ~/.pi 解析，不是 agent 目录)
	const settingsBase = dirname(settingsPath)
	return [
		settingsBase,
		agentDir,
		join(home, ".agents"),
		join(cwd, ".pi"),
		join(cwd, ".agents"),
	].filter((dir, index, all) => all.indexOf(dir) === index)
}

export function checkInstall(agentDir: string, version: string, cwd: string): Section {
	const findings: Finding[] = []
	const scanErrors: string[] = []
	const detail: string[] = []
	const home = homedir()

	// ---- duplicate / leftover pi installations(重复或遗留的 pi 安装) ----
	const runningPath = process.argv[1] ?? "?"
	let runningReal = runningPath
	try {
		runningReal = realpathSync(runningPath)
	} catch {
		/* keep raw path(保留原始路径) */
	}
	const installs: { bin: string; target: string; name: string; version: string }[] = []
	let pathEntries: string[] = []
	try {
		const which = execFileSync("bash", ["-lc", "type -aP pi 2>/dev/null || true"], {
			encoding: "utf8",
			timeout: 5000,
		})
		pathEntries = [...new Set(which.split("\n").filter((l) => l.trim().length > 0))]
	} catch {
		scanErrors.push("could not resolve `pi` on PATH")
	}
	for (const bin of pathEntries) {
		let target = bin
		try {
			target = realpathSync(bin)
		} catch {
			continue
		}
		// dist/cli.js -> package root is two levels up(dist/cli.js 的包根在上两级)
		let pkgRoot = dirname(dirname(target))
		let manifest = join(pkgRoot, "package.json")
		if (!existsSync(manifest)) {
			pkgRoot = dirname(target)
			manifest = join(pkgRoot, "package.json")
		}
		const { value } = readJson(manifest)
		if (!value) continue
		installs.push({
			bin,
			target,
			name: String(value.name ?? "?"),
			version: String(value.version ?? "?"),
		})
	}
	const uniqueInstalls = installs.filter(
		(entry, index) => installs.findIndex((other) => other.target === entry.target) === index,
	)
	const stale = uniqueInstalls.filter((entry) => entry.target !== runningReal)
	if (stale.length > 0) {
		findings.push({
			severity: "critical",
			title: `${stale.length} leftover pi installation${stale.length > 1 ? "s" : ""} on PATH`,
			detail: stale.map((entry) => `${entry.bin} → ${entry.name}@${entry.version}`).join(", "),
			lines: [
				`running: ${runningReal} (${version})`,
				...stale.map((entry) => `stale:   ${entry.bin} → ${entry.target} (${entry.name}@${entry.version})`),
			],
			fix: `Remove the leftover pi installation(s) so PATH order cannot silently switch versions: ${stale
				.map((entry) => `${entry.bin} → ${entry.target} (${entry.name}@${entry.version})`)
				.join("; ")}. Identify how each was installed (npm global prefix, distro package, manual symlink) before removing, and confirm with the user before deleting anything outside the home directory.`,
			caveat:
				"Which install wins depends on PATH order, so the stale copy may never run today — but it will the moment PATH changes.",
		})
	} else if (uniqueInstalls.length > 0) {
		findings.push({
			severity: "ok",
			title: "single pi installation",
			detail: `${runningReal} (${version})`,
		})
	}

	// ---- duplicate PATH entries(PATH 重复项) ----
	const rawPath = (process.env.PATH ?? "").split(":").filter((p) => p.length > 0)
	const pathCounts = new Map<string, number>()
	for (const entry of rawPath) pathCounts.set(entry, (pathCounts.get(entry) ?? 0) + 1)
	const dupes = [...pathCounts.entries()].filter(([, n]) => n > 1).sort((a, b) => b[1] - a[1])
	if (dupes.length > 0) {
		findings.push({
			severity: "notice",
			title: `${dupes.length} duplicated PATH entr${dupes.length > 1 ? "ies" : "y"}`,
			detail: dupes
				.slice(0, 4)
				.map(([p, n]) => `${p.replace(home, "~")} ×${n}`)
				.join(", "),
			lines: dupes.map(([p, n]) => `${p.replace(home, "~")} ×${n}`),
			fix: `Deduplicate PATH in the shell rc files. Duplicated entries: ${dupes
				.map(([p, n]) => `${p} ×${n}`)
				.join(", ")}. Typically a PATH export is run twice (e.g. both .profile and .zshrc, or an rc file sourced twice); find the duplicate export rather than adding dedup logic.`,
			caveat:
				"Duplicates only slow down command lookup slightly; they are a symptom of rc files being sourced twice, not a failure on their own.",
		})
	}

	// ---- settings files: parse errors and unknown keys(settings 解析错误与未知键) ----
	const globalSettingsPath = join(agentDir, "settings.json")
	const legacySettingsPath = join(home, ".pi", "settings.json")
	const settingsFiles = [globalSettingsPath, legacySettingsPath].filter(
		(path, index, all) => all.indexOf(path) === index && existsSync(path),
	)
	let globalSettings: Record<string, unknown> = {}
	const knownKeys = readKnownSettingsKeys()
	const extensionKeys = knownKeys ? keysReferencedByExtensions(agentDir) : new Set<string>()
	for (const path of settingsFiles) {
		const { value, error } = readJson(path)
		if (error) {
			findings.push({
				severity: "critical",
				title: "settings.json failed to parse",
				detail: `${path.replace(home, "~")}: ${error}`,
				fix: `Repair the JSON syntax in ${path}. Parse error: ${error}. Read the file, fix only the syntax, and keep every existing key.`,
				caveat: "pi silently falls back to defaults for an unparseable settings file, so the whole file is inert right now.",
			})
			continue
		}
		if (!value) continue
		if (path === globalSettingsPath) globalSettings = value
		// Without a parsed schema every key would look unknown, so skip rather than guess
		// (拿不到 schema 时所有键都会看起来未知，因此跳过而不瞎猜)
		if (!knownKeys) continue
		const unknown = Object.keys(value).filter(
			(key) => !knownKeys.has(key) && !extensionKeys.has(key),
		)
		if (unknown.length > 0) {
			findings.push({
				severity: "notice",
				title: `${unknown.length} unknown settings key${unknown.length > 1 ? "s" : ""}`,
				detail: `${path.replace(home, "~")}: ${unknown.join(", ")}`,
				fix: `The keys ${unknown.join(", ")} in ${path} are absent from pi ${version}'s Settings interface and no extension under ${join(agentDir, "extensions")} appears to read them, so pi never reads them. Confirm each one is genuinely unused before removing it, and keep the surrounding keys untouched.`,
				caveat: `Checked against the Settings interface in the installed pi ${version}, plus a source scan of local extensions for settings.<key> / settings["key"] access. A key read dynamically, or by an npm/git package extension rather than a local one, would still show up here.`,
			})
		}
	}

	// ---- resource patterns pointing at files that no longer exist(指向不存在文件的资源模式) ----
	const patterns: { pattern: ResourcePattern; baseDirs: string[] }[] = []
	for (const path of settingsFiles) {
		const settings = path === globalSettingsPath ? globalSettings : readJson(path).value
		if (!settings) continue
		for (const pattern of collectPatterns(settings)) {
			if (pattern.pkg) {
				const base = packageBaseDir(agentDir, pattern.pkg)
				// An unresolvable package source is reported separately below, not as a
				// dead pattern(无法解析的包源在下方单独报告，不算死指针)
				if (base) patterns.push({ pattern, baseDirs: [base] })
				continue
			}
			patterns.push({ pattern, baseDirs: candidateBaseDirs(agentDir, path, cwd) })
		}
	}
	const dead: string[] = []
	for (const { pattern, baseDirs } of patterns) {
		// A skill pattern may name either SKILL.md or its parent dir, and may resolve
		// against any of several resource roots
		// (skill 模式可以写 SKILL.md 也可以写其父目录，且可能对应多个资源根)
		const targets = baseDirs.map((baseDir) => resolve(baseDir, pattern.path))
		if (targets.some((target) => existsSync(target))) continue
		// lstat catches broken symlinks, which existsSync reports as missing
		// (lstat 能识别断链，existsSync 对断链返回 false)
		const broken = targets.some((target) => {
			try {
				lstatSync(target)
				return true
			} catch {
				return false
			}
		})
		dead.push(
			`${pattern.pkg ? `${pattern.pkg} ` : ""}${pattern.field}: ${pattern.raw}${
				broken ? " (broken symlink)" : ""
			}`,
		)
	}
	if (dead.length > 0) {
		findings.push({
			severity: "critical",
			title: `${dead.length} resource pattern${dead.length > 1 ? "s" : ""} point at missing files`,
			detail: dead.slice(0, 3).join("; ") + (dead.length > 3 ? ` … +${dead.length - 3}` : ""),
			lines: dead,
			fix: `Remove these dead +/-/! resource patterns from settings — each names a path that no longer exists, so the entry does nothing:\n${dead
				.map((line) => `  - ${line}`)
				.join(
					"\n",
				)}\nEdit only the listed array entries and leave every live pattern in place.`,
			caveat:
				"Only exact +/-/! patterns are checked, and each is tested against every base directory pi could resolve it against (~/.pi, ~/.pi/agent, ~/.agents, and the project equivalents). Bare patterns are globs that may legitimately match nothing, so they are skipped.",
		})
	}

	// ---- broken symlinks in resource directories(资源目录内的断链) ----
	const resourceDirs = [
		join(agentDir, "extensions"),
		join(agentDir, "skills"),
		join(agentDir, "prompts"),
		join(agentDir, "themes"),
		join(agentDir, "agents"),
		join(home, ".pi", "skills"),
		join(home, ".agents", "skills"),
	].filter((dir, index, all) => all.indexOf(dir) === index && existsSync(dir))
	const brokenLinks: string[] = []
	for (const dir of resourceDirs) {
		let entries: ReturnType<typeof readdirSync>
		try {
			entries = readdirSync(dir, { withFileTypes: true })
		} catch {
			scanErrors.push(`could not read ${dir.replace(home, "~")}`)
			continue
		}
		for (const entry of entries) {
			const path = join(dir, entry.name)
			if (!entry.isSymbolicLink()) continue
			// statSync follows the link, so it throws exactly when the target is gone
			// (statSync 会跟随链接，目标缺失时抛异常)
			try {
				statSync(path)
			} catch {
				brokenLinks.push(path.replace(home, "~"))
			}
		}
	}
	if (brokenLinks.length > 0) {
		// Group by parent dir so the summary stays short(按父目录聚合，保持摘要简短)
		const byDir = new Map<string, string[]>()
		for (const link of brokenLinks) {
			const dir = dirname(link)
			const list = byDir.get(dir) ?? []
			list.push(basename(link))
			byDir.set(dir, list)
		}
		findings.push({
			severity: "critical",
			title: `${brokenLinks.length} broken symlink${brokenLinks.length > 1 ? "s" : ""} in resource dirs`,
			detail: [...byDir.entries()].map(([dir, names]) => `${dir} (${names.length})`).join(", "),
			lines: brokenLinks,
			fix: `Delete these broken symlinks — their targets no longer exist, so the resources cannot load:\n${brokenLinks
				.map((link) => `  - ${link}`)
				.join(
					"\n",
				)}\nThese are symlinks, so removing them cannot lose real content. Ask the user to confirm before deleting, and afterwards also drop any settings patterns that referenced them.`,
			caveat: undefined,
		})
	}

	// ---- agent definitions: frontmatter and name collisions(agent 定义的 frontmatter 与撞名) ----
	const agentsDir = join(agentDir, "agents")
	if (existsSync(agentsDir)) {
		const seenNames = new Map<string, string[]>()
		const brokenAgents: string[] = []
		let files: string[] = []
		try {
			files = readdirSync(agentsDir).filter((name) => name.endsWith(".md"))
		} catch {
			scanErrors.push(`could not read ${agentsDir.replace(home, "~")}`)
		}
		for (const file of files) {
			const path = join(agentsDir, file)
			let content: string
			try {
				content = readFileSync(path, "utf8")
			} catch {
				brokenAgents.push(`${file}: unreadable`)
				continue
			}
			let name: string | undefined
			let description: unknown
			try {
				const parsed = parseFrontmatter<Record<string, unknown>>(content)
				name = typeof parsed.frontmatter.name === "string" ? parsed.frontmatter.name : undefined
				description = parsed.frontmatter.description
			} catch (err) {
				brokenAgents.push(`${file}: frontmatter parse failed (${err instanceof Error ? err.message : String(err)})`)
				continue
			}
			if (!name) {
				brokenAgents.push(`${file}: missing \`name\` in frontmatter`)
				continue
			}
			if (typeof description !== "string" || description.trim().length === 0) {
				brokenAgents.push(`${file}: missing \`description\` in frontmatter`)
			}
			const list = seenNames.get(name) ?? []
			list.push(file)
			seenNames.set(name, list)
		}
		const collisions = [...seenNames.entries()].filter(([, files]) => files.length > 1)
		if (brokenAgents.length > 0) {
			findings.push({
				severity: "critical",
				title: `${brokenAgents.length} broken agent definition${brokenAgents.length > 1 ? "s" : ""}`,
				detail: brokenAgents.slice(0, 2).join("; "),
				lines: brokenAgents,
				fix: `Repair these agent definitions under ${agentsDir}:\n${brokenAgents
					.map((line) => `  - ${line}`)
					.join("\n")}\nRead each file and add the missing frontmatter field; do not rewrite the body.`,
			})
		}
		if (collisions.length > 0) {
			findings.push({
				severity: "critical",
				title: `${collisions.length} agent name collision${collisions.length > 1 ? "s" : ""}`,
				detail: collisions.map(([name, files]) => `${name}: ${files.join(", ")}`).join("; "),
				fix: `Resolve duplicate agent \`name\` values in ${agentsDir}: ${collisions
					.map(([name, files]) => `${name} declared by ${files.join(" and ")}`)
					.join(
						"; ",
					)}. Only one definition per name can win, so rename or delete the redundant file after checking which one is actually referenced.`,
			})
		}
		if (brokenAgents.length === 0 && collisions.length === 0 && files.length > 0) {
			findings.push({
				severity: "ok",
				title: `${files.length} agent definitions valid`,
			})
		}
		detail.push(`Agents dir: ${agentsDir.replace(home, "~")} (${files.length} files)`)
	}

	// ---- extension directories that look loadable but are not(看似可加载但实际不能的扩展目录) ----
	// pi's discovery accepts a subdirectory only via package.json with a "pi".extensions
	// field, or index.ts / index.js. Anything else is silently skipped, so a directory
	// holding source files under a different entry name never loads and never warns.
	// Directories with no source files at all are data dirs, not failed extensions, so
	// they are not flagged.
	// (pi 的发现机制只接受带 "pi".extensions 字段的 package.json 或 index.ts/js，
	//  其余一律静默跳过；因此以其他入口名存放源码的目录既不加载也不报错。
	//  完全不含源码的目录是数据目录、不是失败的扩展，不予报告。)
	const extDir = join(agentDir, "extensions")
	if (existsSync(extDir)) {
		const missingEntries: string[] = []
		try {
			for (const entry of readdirSync(extDir, { withFileTypes: true })) {
				if (!entry.isDirectory() && !entry.isSymbolicLink()) continue
				const dir = join(extDir, entry.name)
				let children: string[] = []
				try {
					children = readdirSync(dir)
				} catch {
					continue
				}
				const hasSource = children.some(
					(name) => name.endsWith(".ts") || name.endsWith(".js"),
				)
				if (!hasSource) continue
				if (children.includes("index.ts") || children.includes("index.js")) continue
				const manifestPath = join(dir, "package.json")
				const manifest = readJson(manifestPath).value
				const declared = manifest?.pi
				const declaredList =
					declared && typeof declared === "object"
						? (declared as Record<string, unknown>).extensions
						: undefined
				if (Array.isArray(declaredList) && declaredList.length > 0) {
					const missing = declaredList
						.filter((rel): rel is string => typeof rel === "string")
						.filter((rel) => !existsSync(resolve(dir, rel)))
					if (missing.length > 0) {
						missingEntries.push(
							`${relative(agentDir, dir)}: package.json declares missing entr${missing.length > 1 ? "ies" : "y"} ${missing.join(", ")}`,
						)
					}
					continue
				}
				missingEntries.push(
					`${relative(agentDir, dir)}: has source files but no index.ts/index.js and no "pi".extensions in package.json`,
				)
			}
		} catch {
			scanErrors.push(`could not read ${extDir.replace(home, "~")}`)
		}
		if (missingEntries.length > 0) {
			findings.push({
				severity: "notice",
				title: `${missingEntries.length} extension director${missingEntries.length > 1 ? "ies" : "y"} without a loadable entry`,
				detail: missingEntries.join("; "),
				lines: missingEntries,
				fix: `These directories under ${extDir} contain extension source but expose no entry point pi's discovery recognises, so they never load and never report an error:\n${missingEntries
					.map((line) => `  - ${line}`)
					.join(
						"\n",
					)}\nEither rename the entry file to index.ts, declare it in package.json under "pi".extensions, or remove the directory if it is dead.`,
				caveat:
					"Discovery only looks one level deep. A directory intentionally loaded via an explicit settings path, or one holding shared helper modules for a sibling extension, would also appear here.",
			})
		}
	}

	return {
		key: "install",
		title: "Installation & configuration",
		findings,
		detailMarkdown: detail.length > 0 ? detail.join("\n\n") : undefined,
		scanErrors,
	}
}
