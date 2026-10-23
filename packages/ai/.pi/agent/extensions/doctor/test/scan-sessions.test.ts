import { mkdirSync, writeFileSync, rmSync } from "node:fs"
import { scanSessions, coverageLine } from "../scan-sessions.ts"

const root = "/tmp/scan-fixture"
rmSync(root, { recursive: true, force: true })
mkdirSync(root + "/proj", { recursive: true })
mkdirSync(root + "/proj/sub", { recursive: true })
mkdirSync(root + "/proj/subagent-artifacts", { recursive: true })

const now = Date.now()
const iso = (msAgo: number) => new Date(now - msAgo).toISOString()
const DAY = 86400000

// normal session: in-window usage + tools + skill + compaction
writeFileSync(root + "/proj/a.jsonl", [
  JSON.stringify({type:"session",version:3,id:"a",timestamp:iso(2*DAY),cwd:"/x"}),
  JSON.stringify({type:"model_change",provider:"p",modelId:"m1"}),
  JSON.stringify({type:"message",message:{role:"user",timestamp:iso(2*DAY),content:[{type:"text",text:'<skill name="alpha" >x</skill> and <skill name="beta">y'}]}}),
  JSON.stringify({type:"message",message:{role:"assistant",timestamp:iso(2*DAY),provider:"p",model:"m1",usage:{input:100,output:10,cacheRead:900,cacheWrite:100,cost:{total:0.5}},content:[{type:"toolCall",name:"read"},{type:"toolCall",name:"bash"}]}}),
  JSON.stringify({type:"message",message:{role:"toolResult",timestamp:iso(2*DAY),toolName:"bash",isError:true}}),
  JSON.stringify({type:"message",message:{role:"toolResult",timestamp:iso(2*DAY),toolName:"Agent",isError:false,details:{subagentType:"Explore"}}}),
  JSON.stringify({type:"compaction",timestamp:iso(2*DAY)}),
  JSON.stringify({type:"custom",customType:"doctor:report"}),
  '{"broken json',                       // unparseable line(不可解析行)
  "",                                     // blank line(空行)
].join("\n"))

// out-of-window session: counts in all-time only
writeFileSync(root + "/proj/b.jsonl", [
  JSON.stringify({type:"session",version:3,id:"b",timestamp:iso(100*DAY),cwd:"/y"}),
  JSON.stringify({type:"message",message:{role:"assistant",timestamp:iso(100*DAY),provider:"p",model:"old",usage:{input:7,output:3,cacheRead:0,cacheWrite:0,cost:{total:0}}}}),
].join("\n"))

// empty session(空会话)
writeFileSync(root + "/proj/empty.jsonl", JSON.stringify({type:"session",version:3,id:"c",timestamp:iso(DAY),cwd:"/z"}))
// subagent transcript at depth 2(深度 2 的子代理记录)
writeFileSync(root + "/proj/sub/s.jsonl", JSON.stringify({type:"message",message:{role:"assistant",timestamp:iso(DAY),provider:"p",model:"m1",usage:{input:1,output:1,cacheRead:0,cacheWrite:0,cost:{total:0}}}}))
// must be skipped(必须被跳过)
writeFileSync(root + "/proj/subagent-artifacts/ignored.jsonl", JSON.stringify({type:"message",message:{role:"assistant",usage:{input:999999,output:0,cacheRead:0,cacheWrite:0}}}))
// non-jsonl must be ignored(非 jsonl 必须忽略)
writeFileSync(root + "/proj/notes.txt", "ignore me")

const s = scanSessions(root, 30)
const eq = (label: string, got: unknown, want: unknown) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? "PASS" : `FAIL got=${JSON.stringify(got)} want=${JSON.stringify(want)}`), label)

eq("sessionFiles=3", s.sessionFiles, 3)
eq("subagentFiles=1", s.subagentFiles, 1)
eq("badLines=1", s.badLines, 1)
eq("emptySessions=1", s.emptySessions, 1)
eq("compactions=1", s.compactions, 1)
eq("skill alpha", s.skillInvocations.get("alpha"), 1)
eq("skill beta", s.skillInvocations.get("beta"), 1)
eq("toolCalls read", s.toolCalls.get("read"), 1)
eq("toolErrors bash", s.toolErrors.get("bash"), 1)
eq("no Agent error", s.toolErrors.get("Agent"), undefined)
eq("subagentType Explore", s.subagentTypes.get("Explore"), 1)
eq("customEntryTypes", s.customEntryTypes.get("doctor:report"), 1)
eq("artifacts dir skipped (input excludes 999999)", s.usageAll.input, 100+7+1)
eq("window excludes 100d-old", s.usageWindow.input, 100+1)
eq("costedResponses=1", s.usageAll.costedResponses, 1)
eq("cacheWriteReports=1", s.usageAll.cacheWriteReports, 1)
eq("byModel has p/m1", s.usageByModel.has("p/m1"), true)
eq("byModel excludes p/old (out of window)", s.usageByModel.has("p/old"), false)
eq("largest capped at 5", s.largest.length <= 5, true)
console.log("coverage:", coverageLine(s))

// missing dir must not throw(目录不存在不得抛异常)
const m = scanSessions("/tmp/definitely-does-not-exist-xyz", 30)
eq("missing dir -> 0 sessions", m.sessionFiles, 0)
eq("missing dir records unreadable", m.unreadable.length, 1)
rmSync(root, { recursive: true, force: true })
