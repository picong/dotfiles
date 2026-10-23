import { readFileSync, writeFileSync, rmSync } from "node:fs"
// Extract buildFixPrompt by importing the module with a stubbed pi API
// (通过 stub pi API 导入模块，提取 buildFixPrompt)
const src = readFileSync(new URL("../index.ts", import.meta.url), "utf8")
  .replace(/^import \{[\s\S]*?\} from "@earendil-works\/pi-coding-agent"$/m,
    'const getAgentDir=()=>"/home/picong/.pi/agent", getMarkdownTheme=()=>({}), loadSkillsFromDir=()=>({skills:[]}), parseFrontmatter=(s:string)=>({frontmatter:{},body:s}), VERSION="test"; type ExtensionAPI=any; type ExtensionCommandContext=any;')
  .replace(/^import \{ Box, Markdown, Text \} from "@earendil-works\/pi-tui"$/m,
    'class Box{constructor(...a:any[]){}addChild(c:any){}}; class Markdown{constructor(...a:any[]){}}; class Text{constructor(...a:any[]){}};')
  .replace(/^export default function/m, "export function register")
  + "\nexport { buildFixPrompt, summaryLines, detailMarkdown, plainText }\n"
const underTest = new URL("../.doctor-under-test.ts", import.meta.url)
writeFileSync(underTest, src)
const mod = await import(underTest.href)

const report = {
  version: "test", snapshot: ["model: x"], coverage: "Scanned 3 sessions",
  elapsedMs: 5,
  sections: [{ key: "install" as const, title: "Install", findings: [
    { severity: "critical" as const, title: "C1", detail: "d1", fix: "do the critical thing", caveat: "cav1" },
    { severity: "notice" as const,  title: "N1", detail: "d2", fix: "consider the notice thing" },
    { severity: "ok" as const,      title: "OK1", detail: "fine" },
    { severity: "critical" as const, title: "C2 no fix", detail: "d3" },
  ]}],
}
const prompt = mod.buildFixPrompt(report)!
console.log("has C1 fix:", prompt.includes("do the critical thing"))
console.log("has N1 fix:", prompt.includes("consider the notice thing"))
console.log("marks CRITICAL:", prompt.includes("[CRITICAL] C1"))
console.log("marks NOTICE:", prompt.includes("[NOTICE] N1"))
console.log("carries caveat:", prompt.includes("Caveat: cav1"))
console.log("excludes ok finding:", !prompt.includes("OK1"))
console.log("excludes fixless critical:", !prompt.includes("C2 no fix"))
console.log("has ground rules:", prompt.includes("Do not commit anything"))
// empty case(空场景)
const none = mod.buildFixPrompt({ ...report, sections: [{ key:"install" as const, title:"I", findings:[{severity:"ok" as const,title:"a"}] }] })
console.log("no-op returns undefined:", none === undefined)
// summary / plain text(摘要与纯文本)
const sum = mod.summaryLines(report)
console.log("summary skips ok lines:", sum.length === 2 + 3 && !sum.join("|").includes("OK1"))
console.log("summary tally:", sum[1])
console.log("plainText nonempty:", mod.plainText(report).length > 100)
rmSync(underTest, { force: true })
