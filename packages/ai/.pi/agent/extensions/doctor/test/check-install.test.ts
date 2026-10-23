import { mkdirSync, writeFileSync, rmSync, symlinkSync } from "node:fs"
import { homedir } from "node:os"
import { checkInstall } from "../check-install.ts"

const root = "/tmp/inst-fixture"
rmSync(root, { recursive: true, force: true })
const agentDir = root + "/agent"
mkdirSync(agentDir + "/skills/live", { recursive: true })
mkdirSync(agentDir + "/extensions/real", { recursive: true })
mkdirSync(agentDir + "/extensions/nosource", { recursive: true })
mkdirSync(agentDir + "/extensions/orphan", { recursive: true })
mkdirSync(agentDir + "/agents", { recursive: true })

writeFileSync(agentDir + "/skills/live/SKILL.md", "---\nname: live\ndescription: d\n---\nbody")
writeFileSync(agentDir + "/extensions/real/index.ts", "export default function(){}")
writeFileSync(agentDir + "/extensions/nosource/data.json", "{}")            // data dir, must NOT flag
writeFileSync(agentDir + "/extensions/orphan/main.ts", "export default 1")  // source but no entry -> flag
symlinkSync("/tmp/nope-missing-target", agentDir + "/skills/dangling")      // broken symlink -> flag

writeFileSync(agentDir + "/agents/good.md", "---\nname: good\ndescription: has both\n---\nbody")
writeFileSync(agentDir + "/agents/nodesc.md", "---\nname: nodesc\n---\nbody")          // missing description
writeFileSync(agentDir + "/agents/dupe.md", "---\nname: good\ndescription: dup\n---\n") // collision

writeFileSync(agentDir + "/settings.json", JSON.stringify({
  defaultModel: "x",                       // known key
  bogusLeftoverKey: 1,                     // unknown -> flag
  skills: [
    "-skills/live/SKILL.md",               // exists under agentDir -> must NOT flag
    "-skills/nonexistent/SKILL.md",        // truly missing -> flag
    "someGlob*",                           // bare glob -> skipped
  ],
}, null, 2))

const s = checkInstall(agentDir, "test", "/tmp")
const byTitle = (frag: string) => s.findings.find(f => f.title.includes(frag))
const has = (frag: string) => byTitle(frag) !== undefined
const eq = (label: string, got: unknown, want: unknown) =>
  console.log((JSON.stringify(got)===JSON.stringify(want) ? "PASS" : `FAIL got=${JSON.stringify(got)} want=${JSON.stringify(want)}`), label)

eq("flags unknown settings key", has("unknown settings key"), true)
eq("unknown key names bogusLeftoverKey", byTitle("unknown settings key")?.detail?.includes("bogusLeftoverKey"), true)
eq("does not flag defaultModel", byTitle("unknown settings key")?.detail?.includes("defaultModel"), false)

const deadF = byTitle("point at missing files")
// checkInstall also scans the real ~/.pi and ~/.agents, which is correct for a
// doctor tool, so scope assertions to fixture-owned entries
// (checkInstall 也会扫真实的 ~/.pi 与 ~/.agents，对体检工具而言是对的，
//  因此断言只限定在 fixture 自己的条目)
const fixtureDead = (deadF?.lines ?? []).filter(l => l.includes("nonexistent") || l.includes("skills/live"))
eq("flags exactly 1 fixture dead pattern", fixtureDead.length, 1)
eq("dead pattern is the nonexistent one", fixtureDead[0].includes("nonexistent"), true)
eq("live pattern NOT flagged", fixtureDead.some(l => l.includes("skills/live")), false)

const linkF = byTitle("broken symlink")
eq("flags broken symlink", linkF !== undefined, true)
eq("fixture dangling symlink flagged", (linkF?.lines ?? []).some(l => l.includes("inst-fixture") && l.includes("dangling")), true)

const agF = byTitle("broken agent definition")
eq("flags missing description", agF?.lines?.some(l => l.includes("nodesc")), true)
eq("collision flagged", has("agent name collision"), true)

const extF = byTitle("without a loadable entry")
eq("flags orphan source dir", extF?.lines?.some(l => l.includes("orphan")), true)
eq("does NOT flag data-only dir", extF?.lines?.some(l => l.includes("nosource")), false)
eq("does NOT flag valid extension", extF?.lines?.some(l => l.includes("real")), false)

// every non-ok finding must carry an actionable fix or an explicit caveat
// (每条非 ok 结论必须带可执行 fix 或明确口径说明)
const missingGuidance = s.findings.filter(f => f.severity !== "ok" && !f.fix && !f.caveat).map(f => f.title)
eq("all findings carry fix or caveat", missingGuidance, [])
rmSync(root, { recursive: true, force: true })

// ---- settings schema is read from the installed pi, not hardcoded ----
// (settings schema 来自已安装的 pi，而非硬编码)
const schemaProbe = "/tmp/inst-schema-probe"
rmSync(schemaProbe, { recursive: true, force: true })
mkdirSync(schemaProbe, { recursive: true })
writeFileSync(schemaProbe + "/settings.json", JSON.stringify({
  // sample of keys added across recent pi versions; a stale hardcoded list would
  // report these as dead config(近期 pi 版本新增键的抽样；陈旧硬编码列表会误报为死配置)
  tuiMode: "fullscreen", fullscreenScrollbar: "auto", showHardwareCursor: true,
  httpIdleTimeoutMs: 1, websocketConnectTimeoutMs: 1, thinkingBudgets: {},
  treeFilterMode: "default", doubleEscapeAction: "fork", outputPad: 1,
  definitelyNotARealKey: true,
}))
const s2 = checkInstall(schemaProbe, "test", "/tmp")
const unk = s2.findings.find(f => f.title.includes("unknown settings key"))
eq("recognises recently-added real keys", unk?.detail?.includes("tuiMode"), false)
eq("recognises fullscreenScrollbar", unk?.detail?.includes("fullscreenScrollbar"), false)
eq("recognises thinkingBudgets", unk?.detail?.includes("thinkingBudgets"), false)
eq("still flags the bogus key", unk?.detail?.includes("definitelyNotARealKey"), true)
eq("flags exactly 1 unknown key", unk?.detail?.split(": ")[1]?.split(", ").length, 1)
rmSync(schemaProbe, { recursive: true, force: true })

// ---- a key consumed by a local extension must not be reported dead ----
// (被本地扩展消费的键不得报为死配置)
const consumerRoot = "/tmp/inst-consumer"
rmSync(consumerRoot, { recursive: true, force: true })
mkdirSync(consumerRoot + "/extensions/reader", { recursive: true })
writeFileSync(consumerRoot + "/extensions/reader/index.ts",
  'export default function(pi:any){ const settings:any = {}; if (settings.myCustomKey) {} const v = settings["bracketKey"]; }')
writeFileSync(consumerRoot + "/settings.json", JSON.stringify({
  myCustomKey: 1,      // read via settings.myCustomKey -> must NOT flag
  bracketKey: 2,       // read via settings["bracketKey"] -> must NOT flag
  trulyOrphaned: 3,    // read by nobody -> must flag
}))
const s3 = checkInstall(consumerRoot, "test", "/tmp")
const unk3 = s3.findings.find(f => f.title.includes("unknown settings key"))
eq("dot-access key suppressed", unk3?.detail?.includes("myCustomKey"), false)
eq("bracket-access key suppressed", unk3?.detail?.includes("bracketKey"), false)
eq("orphaned key still flagged", unk3?.detail?.includes("trulyOrphaned"), true)
rmSync(consumerRoot, { recursive: true, force: true })
