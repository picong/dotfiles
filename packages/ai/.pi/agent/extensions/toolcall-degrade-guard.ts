// Tool-call degradation and incomplete-task guard(工具调用退化与未完成任务守卫)
//
// Pi intentionally ends an agent run when a model returns stop without a structured tool call.
// Some models occasionally announce more work or summarize early while tasks remain active.
// This guard queues a bounded follow-up for those observable incomplete states.
// (Pi 在模型返回 stop 且无结构化工具调用时会结束运行；部分模型会偶发宣布后续动作，
// 或在任务仍活动时提前总结。本守卫针对这些可观测的未完成状态进行有界续跑。)

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"

const SEMANTIC_MAX_NUDGES = 3
const TRUNCATION_MAX_NUDGES = 3
const DETAILED_TODO_NUDGE_FROM = 3
const TODO_TOOL_NAME = "todo"
const GOAL_STATE_ENTRY_TYPE = "goal-state"

// Minimum visible-prose length below which a `stopReason:"stop"` turn is treated
// as a genuine short final answer, never as a suspected mid-sentence truncation.
// (低于此可见正文长度的 stop 回合视为正常短回复，绝不判定为疑似截断。)
const MIN_TRUNCATION_PROSE_LENGTH = 40

// Sentence-final punctuation. A turn whose visible prose ends with one of these
// looks deliberately finished, so it is NOT flagged as a soft truncation.
// (句末标点；正文以这些收尾的回合视为有意收束，不判软截断。)
const SENTENCE_FINAL_PUNCTUATION = /[。！？.!?」』”)）\]】]\s*$/
// Fenced code / list / table continuations do not end a "sentence" but are still
// legitimate completions. (代码块/列表/表格结尾虽无句末标点，仍属正常完成。)
const STRUCTURED_TAIL = /(?:```|~~~|\|)\s*$|^\s*(?:[-*+]|\d+[.)])\s+/m

const TEXT_TOOL_CALL_PATTERNS: RegExp[] = [
  /(?:^|\n)\s*<invoke\s+name\s*=/i,
  /(?:^|\n)\s*<function_calls>\s*(?:\n|$)/i,
]

const ACTION_VERBS =
  "调用|执行|运行|跑|检查|核对|读取|搜索|查找|分析|解析|提取|修改|编辑|写入|创建|删除|验证|测试|修复|补上|发出|启动|恢复|重跑|统计|汇总|完成"

// Deferred-work verbs cover the grill-me / interview phase, where the model
// announces something still to be determined or investigated instead of asking
// a structured question or continuing. These extend the action set only for the
// "还需/仍需 + verb" deferral patterns below.
// (延迟工作动词覆盖 grill-me 访谈阶段：模型宣布"还需确定/仍需调查"却既不发起结构化提问也不继续。
//  仅供下方"还需/仍需 + 动词"延迟模式使用。)
const DEFERRED_ACTION_VERBS = `${ACTION_VERBS}|确定|明确|确认|澄清|调查|核实|梳理|排查|定位|评估`

const ACTION_PROMISE_PATTERNS: RegExp[] = [
  new RegExp(
    `(?:^|[。！？；\\n])\\s*(?:我\\s*)?(?:现在|接下来|随后|马上)\\s*(?:我\\s*)?(?:会|将|要|正在)?\\s*(?:继续|开始|先|直接|立即|马上)?\\s*(?:${ACTION_VERBS})`,
  ),
  new RegExp(
    `(?:^|[。！？；\\n])\\s*我\\s*(?:会|将|要|正在|马上|立即)\\s*(?:继续|开始|先|直接|立即|马上)?\\s*(?:${ACTION_VERBS})`,
  ),
  // Deferred determination: "还需确定X"/"仍需调查X"/"尚需核实X" ended a turn with
  // plain text and no tool call. A following 你/您 (e.g. "还需你确定") is a genuine
  // hand-off to the user and is excluded.
  // (延迟确定:"还需确定X"用纯文本收尾且未调用工具;紧跟 你/您 表示交还用户,排除。)
  new RegExp(
    `(?:^|[。！？；\\n])\\s*(?:目前|现在|当前)?\\s*(?:还|仍|尚)\\s*(?:需|须|要|得|待)\\s*(?:继续|进一步|再|先|去)?\\s*(?:${DEFERRED_ACTION_VERBS})`,
  ),
  // Direct unfinished need: "需要确定策略". Exclude "需要你/您确定",
  // which explicitly hands the decision to the user.
  // (直接表达待办；排除明确交还用户决定的句式。)
  new RegExp(
    `(?:^|[。！？；\\n])\\s*(?:目前|现在|当前)?\\s*(?:需要|需|待)\\s*(?!你|您)(?:继续|进一步|再|先|去)?\\s*(?:${DEFERRED_ACTION_VERBS})`,
  ),
  // Deferred next item/step: "接下来需要确定X"/"下一项需要确定X".
  // A following 你/您 is still excluded because the verb must immediately follow
  // the need marker. (延迟的下一项/下一步；交还用户的表达仍不匹配。)
  new RegExp(
    `(?:^|[。！？；\\n]|-\\s*)\\s*(?:接下来|下一步|下一项|下一个(?:问题|步骤|事项)|后续|之后)\\s*(?:我\\s*)?(?:(?:还)?\\s*(?:需要|需|要|待)\\s*)?(?:继续|进一步|再|先)?\\s*(?:${DEFERRED_ACTION_VERBS})`,
  ),
  // Bare immediate action: "先跑测试"/"我先检查配置". This intentionally
  // favours continuation over a false stop; quoted/code examples were stripped above.
  // (省略主语的立即行动；优先避免任务未完成时错误停顿。)
  new RegExp(
    `(?:^|[。！？；\\n])\\s*(?:我\\s*)?(?:先|再|接着|继续|立即|马上)\\s*(?:${ACTION_VERBS})`,
  ),
  // Explicitly unfinished work: "测试尚未完成"/"还没有验证完".
  // (明确表示工作尚未结束。)
  /(?:^|[。！？；\n])\s*[^。！？；\n]{0,80}?(?:尚未|仍未|还没(?:有)?)[^。！？；\n]{0,40}?(?:完成|结束|做完|验证完|测试完|处理完|解决|修复)(?:[。！？；\n]|$)/,
  /(?:^|[.!?\n])\s*(?:(?:Now|Next),?\s+)?I(?:'ll|\s+will|\s+am going to)\s+(?:now\s+|next\s+|continue\s+to\s+)?(?:call|run|check|inspect|read|search|analy[sz]e|parse|extract|edit|write|create|delete|verify|test|fix|resume|rerun|summarize)\b/i,
  // Deferred determination (English): "I still need to determine/clarify X".
  /(?:^|[.!?\n])\s*(?:I\s+)?still\s+need\s+to\s+(?:determine|clarify|confirm|figure\s+out|investigate|check|verify|decide|nail\s+down|work\s+out)\b/i,
]

const TOOL_CALL_NUDGE =
  "[系统自动提醒] 检测到上一回复包含文本形态的工具调用，但没有执行结构化工具调用。" +
  "请立即使用真正的结构化工具调用重发；不要把调用写成 XML 或普通正文。" +
  "如果本来不需要工具，请直接完成回答。"

const ACTION_PROMISE_NUDGE =
  "[系统自动提醒] 你在上一回复中宣布了接下来要执行的具体操作，却在没有调用工具时结束了回合。" +
  "请现在继续完成该操作：需要工具就立即发出结构化工具调用，不需要工具就直接完成最终回答；不要只再次描述计划。"

const ACTIVE_INTERVIEW_NUDGE =
  "[系统自动提醒] grill-me 访谈仍处于活动状态，但上一回合没有继续提问或请求方案审批。" +
  "请立即继续：若仍有未决项，使用 ask_user_question 提出一个具体问题；" +
  "若理解已经完整，先呈现最终理解与推荐计划，再使用 ask_user_question 请求用户批准、修改或停止。" +
  "不要只输出阶段总结或下一步说明。"

const TRUNCATION_NUDGE =
  "[系统自动提醒] 上一回复被判定为非正常结束（模型输出被截断或上游流中途断开），并非真正完成。" +
  "请从中断处继续：先简要接续上一回复未写完的内容，再按需调用结构化工具把任务做到真正完成；" +
  "不要重头重复已经输出的部分，也不要仅用文字宣称完成。"

export type ActiveTodo = {
  id: number
  subject: string
  activeForm?: string
  status: "pending" | "in_progress"
}

export type StallKind =
  | "text-tool-call"
  | "action-promise"
  | "active-todo"
  | "active-interview"
  | "truncated"

// A response pi marks with a non-normal stop is the strongest, provider-agnostic
// signal of an incomplete turn. pi normalizes every provider's stop reason to
// StopReason = "stop" | "length" | "toolUse" | "error" | "aborted".
//  - "length": the model hit the output-token ceiling → hard truncation.
//  - "error":  the upstream stream died mid-body (e.g. Kiro's "incomplete
//              chunked read" / TCP reset near the credit limit). The gateway
//              may still surface this as "stop" if it mislabels truncation, so
//              a soft heuristic (below) also covers the mislabeled case.
// "aborted" is a deliberate user cancel (Esc) and MUST never be nudged.
// (pi 把各家 provider 的停止原因归一成 5 值枚举。"length"=命中输出上限的硬截断；
//  "error"=上游流中途断开(Kiro incomplete chunked read / 额度附近 TCP reset)。
//  网关可能把截断误标成 "stop"，故另有软启发式兜底。"aborted"=用户主动取消，绝不追问。)
export function isHardTruncationStop(stopReason?: string): boolean {
  return stopReason === "length" || stopReason === "error"
}

// Soft-truncation heuristic for the mislabeled case: the gateway reported a
// normal "stop" but the visible prose is substantial AND ends mid-sentence
// (no sentence-final punctuation, not a code/list/table tail). Short answers,
// punctuated endings, and user hand-offs are all exempt to keep false positives
// near zero. (软截断启发式：网关报了正常 "stop"，但可见正文足够长且中途断句
//  —无句末标点、非代码/列表/表格结尾。短回复、有句末标点、交还用户的一律豁免以压低误报。)
export function looksMidSentenceTruncated(text: string, stopReason?: string): boolean {
  if (stopReason !== "stop") return false
  const prose = stripQuotedMarkdown(text).trim()
  if (prose.length < MIN_TRUNCATION_PROSE_LENGTH) return false
  if (SENTENCE_FINAL_PUNCTUATION.test(prose)) return false
  if (STRUCTURED_TAIL.test(prose)) return false
  return true
}

// Remove quoted/demo Markdown before recognizing executable-looking prose.
// (识别可执行文本前移除引用或演示用 Markdown。)
export function stripQuotedMarkdown(text: string): string {
  const visibleLines: string[] = []
  let fence: { char: string; length: number } | null = null

  for (const line of text.split("\n")) {
    const fenceMatch = line.match(/^\s{0,3}(`{3,}|~{3,})/)
    if (fenceMatch) {
      const marker = fenceMatch[1]
      if (!fence) {
        fence = { char: marker[0], length: marker.length }
      } else if (marker[0] === fence.char && marker.length >= fence.length) {
        fence = null
      }
      continue
    }
    if (fence || /^\s*>/.test(line)) continue
    visibleLines.push(line.replace(/(`+)(?:[^`]|`(?!\1))*?\1/g, " "))
  }

  return visibleLines.join("\n")
}

export function detectSemanticStall(text: string, stopReason?: string): StallKind | null {
  if (!text) return null
  const prose = stripQuotedMarkdown(text)
  if (TEXT_TOOL_CALL_PATTERNS.some((pattern) => pattern.test(prose))) {
    return "text-tool-call"
  }

  if (stopReason !== "stop" && stopReason !== "end_turn") return null
  const tail = prose.slice(-800)
  return ACTION_PROMISE_PATTERNS.some((pattern) => pattern.test(tail))
    ? "action-promise"
    : null
}

// Backward-compatible export used by the original guard tests.
export const detectStall = detectSemanticStall

export function isGpt56Family(modelId?: string): boolean {
  return /^gpt-5\.6-(?:sol|terra|luna)$/i.test(modelId ?? "")
}

function entriesFromContext(ctx: any): any[] {
  const manager = ctx?.sessionManager
  if (!manager) return []
  const entries = manager.getBranch?.() ?? manager.getEntries?.() ?? []
  return Array.from(entries)
}

export function hasActiveGoal(entries: readonly any[]): boolean {
  for (let index = entries.length - 1; index >= 0; index--) {
    const entry = entries[index]
    if (entry?.type !== "custom" || entry.customType !== GOAL_STATE_ENTRY_TYPE) continue
    return entry.data?.goal?.status === "active"
  }
  return false
}

function messageText(entry: any): string {
  const message = entry?.type === "message" ? entry.message : undefined
  if (!message || !Array.isArray(message.content)) return ""
  return message.content
    .filter((item: any) => item?.type === "text")
    .map((item: any) => String(item.text ?? ""))
    .join("\n")
}

function isFinalGrillDecision(question: string): boolean {
  return /(?:批准|同意|确认).*(?:计划|方案)|(?:计划|方案).*(?:批准|同意|确认)|开始(?:实现|执行)|实施计划/.test(question)
}

export function hasPendingGrillInterview(entries: readonly any[]): boolean {
  let seen = false
  let active = false

  for (const entry of entries) {
    const message = entry?.type === "message" ? entry.message : undefined
    if (!message) continue

    if (message.role === "user") {
      const text = messageText(entry)
      if (/<skill\s+name=["']grill-me["']/.test(text)) {
        seen = true
        active = true
        continue
      }
      if (seen && /^\s*(?:继续|恢复|接着).*(?:讨论|访谈|方案|计划|优化)/.test(text)) {
        active = true
        continue
      }
      if (!active) continue
      // A new unrelated user request pauses this interview until the user explicitly resumes it.
      // (新的无关用户请求会暂停访谈，直到用户明确恢复。)
      active = false
      continue
    }

    if (message.role !== "toolResult" || message.toolName !== "ask_user_question") continue
    const answers = Array.isArray(message.details?.answers) ? message.details.answers : []
    for (const answer of answers) {
      const question = String(answer?.question ?? "")
      if (!isFinalGrillDecision(question)) continue
      const value = String(answer?.answer ?? "")
      active = /(?:修改|修订|调整|重新)/.test(value)
    }
  }

  return active
}

export function replayActiveTodos(entries: readonly any[]): ActiveTodo[] {
  for (let index = entries.length - 1; index >= 0; index--) {
    const entry = entries[index]
    const message = entry?.type === "message" ? entry.message : undefined
    if (message?.role !== "toolResult" || message.toolName !== TODO_TOOL_NAME) continue
    if (!Array.isArray(message.details?.tasks)) continue

    return message.details.tasks
      .filter((task: any) => task?.status === "pending" || task?.status === "in_progress")
      .map((task: any) => ({
        id: Number(task.id),
        subject: String(task.subject ?? `Task #${String(task.id)}`),
        activeForm: typeof task.activeForm === "string" ? task.activeForm : undefined,
        status: task.status,
      }))
  }
  return []
}

export function classifyStall(params: {
  text: string
  stopReason?: string
  modelId?: string
  activeTodos: readonly ActiveTodo[]
  activeGoal: boolean
  activeInterview?: boolean
}): StallKind | null {
  // pi-goal owns continuation while a goal is active; never enqueue a competing follow-up.
  // (goal 活动时由 pi-goal 独占续跑，避免重复注入。)
  if (params.activeGoal) return null

  // Truncation is the strongest, provider-agnostic incomplete-turn signal and
  // takes priority over every semantic heuristic: a "length"/"error" stop, or a
  // "stop" whose prose is cut mid-sentence, means the turn did not finish no
  // matter what the closing words say. This closes the gap where a gateway that
  // mislabels a truncated Kiro stream as a normal stop (see kiro-gateway #113 /
  // #129) previously produced no nudge at all because the semantic paths only
  // fire on "stop"/"end_turn" AND require promise-shaped prose.
  // (截断是最强的、与 provider 无关的未完成信号，优先于所有语义启发式。)
  if (
    isHardTruncationStop(params.stopReason) ||
    looksMidSentenceTruncated(params.text, params.stopReason)
  ) {
    return "truncated"
  }

  if (
    isGpt56Family(params.modelId) &&
    (params.stopReason === "stop" || params.stopReason === "end_turn") &&
    params.activeTodos.length > 0
  ) {
    // Active work is the stronger signal for GPT-5.6: use the five-attempt Todo
    // protocol even when the same response also contains an action promise.
    // (活动任务是更强信号；即使同时出现行动承诺，也使用五次 Todo 协议。)
    return "active-todo"
  }

  if (
    params.activeInterview &&
    (params.stopReason === "stop" || params.stopReason === "end_turn")
  ) {
    return "active-interview"
  }

  return detectSemanticStall(params.text, params.stopReason)
}

function formatTodos(todos: readonly ActiveTodo[]): string {
  return todos
    .map((task) => `#${task.id} [${task.status}] ${task.subject}`)
    .join("；")
}

export function buildTodoNudge(todos: readonly ActiveTodo[], attempt: number): string {
  const summary = formatTodos(todos)
  if (attempt < DETAILED_TODO_NUDGE_FROM) {
    return (
      `[系统自动提醒] GPT-5.6 在仍有活动 todo 时提前结束了回合：${summary}。` +
      "请立即继续执行；不要只描述计划或总结。"
    )
  }
  return (
    `[系统自动提醒] GPT-5.6 连续提前结束，但以下 todo 尚未完成：${summary}。` +
    "本轮必须二选一并使用结构化工具：继续调用工作所需工具；或若任务确已完成，调用 todo update 将对应任务显式标记为 completed。" +
    "不得仅用文字宣称完成。"
  )
}

function maxNudgesFor(kind: StallKind): number | null {
  // Explicit active state is authoritative: do not stop automatically while it remains active.
  // Semantic-only inference stays bounded to avoid an unobservable infinite loop.
  // (显式活动状态下不自动停止；仅语义推断保留防死循环上限。)
  if (kind === "active-todo" || kind === "active-interview") return null
  // Truncation gets its own bounded budget: repeated upstream stream failures
  // (kiro-gateway #129) should retry a few times, then stop to avoid burning
  // tokens against a persistently broken stream.
  // (截断有独立的有界预算：上游反复断流时续跑数次后停止，避免对持续损坏的流空耗 token。)
  if (kind === "truncated") return TRUNCATION_MAX_NUDGES
  return SEMANTIC_MAX_NUDGES
}

function stalledWarning(kind: StallKind, todos: readonly ActiveTodo[], maxNudges: number): string {
  const todoSuffix = todos.length > 0 ? ` Active todos: ${formatTodos(todos)}.` : ""
  return (
    `[toolcall-degrade-guard] ${kind} persisted after ${maxNudges} automatic continuations; ` +
    `stopping to avoid an infinite token loop.${todoSuffix}`
  )
}

export default async function (pi: ExtensionAPI) {
  let consecutiveNudges = 0
  let lastStallKind: StallKind | null = null

  pi.on("turn_end", async (event, ctx) => {
    try {
      const message = event.message as any
      if (!message || message.role !== "assistant") return

      const content = Array.isArray(message.content) ? message.content : []
      const hasRealToolCall = content.some((item: any) => item?.type === "toolCall")
      if (hasRealToolCall || (Array.isArray(event.toolResults) && event.toolResults.length > 0)) {
        consecutiveNudges = 0
        lastStallKind = null
        return
      }

      const text = content
        .filter((item: any) => item?.type === "text")
        .map((item: any) => String(item.text ?? ""))
        .join("\n")
      const entries = entriesFromContext(ctx)
      const activeTodos = replayActiveTodos(entries)
      const stallKind = classifyStall({
        text,
        stopReason: String(message.stopReason ?? ""),
        modelId: ctx?.model?.id,
        activeTodos,
        activeGoal: hasActiveGoal(entries),
        activeInterview: hasPendingGrillInterview(entries),
      })

      if (!stallKind) {
        consecutiveNudges = 0
        lastStallKind = null
        return
      }
      if (stallKind !== lastStallKind) consecutiveNudges = 0
      lastStallKind = stallKind

      const maxNudges = maxNudgesFor(stallKind)
      if (maxNudges !== null && consecutiveNudges >= maxNudges) {
        const warning = stalledWarning(stallKind, activeTodos, maxNudges)
        console.warn(warning)
        if (ctx?.hasUI) ctx.ui.notify(warning, "error")
        return
      }

      consecutiveNudges++
      console.warn(
        `[toolcall-degrade-guard] detected ${stallKind} ` +
          `(stopReason=${String(message.stopReason ?? "unknown")}); ` +
          `auto-continuing (attempt ${consecutiveNudges}/${maxNudges ?? "unbounded-active-state"}).`,
      )

      const nudge =
        stallKind === "truncated"
          ? TRUNCATION_NUDGE
          : stallKind === "text-tool-call"
            ? TOOL_CALL_NUDGE
            : stallKind === "action-promise"
              ? ACTION_PROMISE_NUDGE
              : stallKind === "active-interview"
                ? ACTIVE_INTERVIEW_NUDGE
                : buildTodoNudge(activeTodos, consecutiveNudges)
      pi.sendUserMessage(nudge, { deliverAs: "followUp" })
    } catch (error) {
      // Fail open: a guard failure must not break Pi itself.(守卫异常不能破坏 Pi 本身。)
      console.warn("[toolcall-degrade-guard] unexpected error in turn_end handler; ignoring", error)
    }
  })
}
