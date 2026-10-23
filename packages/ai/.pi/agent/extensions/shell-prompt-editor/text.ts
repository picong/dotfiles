/**
 * Text sanitizers for bar segments.
 * (状态栏段落文本清理工具)
 */

// Any escape sequence we recognize: OSC (hyperlinks/titles), CSI, and simple
// two-byte escapes.(可识别的转义序列：OSC、CSI 与双字节转义。)
const ANSI_PATTERN =
  // eslint-disable-next-line no-control-regex
  /\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;:?]*[ -\/]*[@-~]|\x1b[@-Z\\-_]/g

// C0 controls (minus the whitespace handled separately) plus DEL.(除单独处理的空白外的 C0 控制符与 DEL。)
// eslint-disable-next-line no-control-regex
const CONTROL_PATTERN = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g

// SGR = CSI ... m. Only SGR is safe to keep inside a bar segment; cursor moves
// and erases would corrupt the line.(段落内只保留 SGR，光标移动/擦除会破坏整行。)
const SGR_PATTERN = /^\x1b\[([0-9;:]*)m$/

function cleanPlain(chunk: string): string {
  return chunk.replace(CONTROL_PATTERN, "").replace(/[\r\n\t]/g, " ").replace(/ +/g, " ")
}

/** True when this SGR clears the background (reset or default-bg).(该 SGR 会清掉背景。) */
function clearsBackground(params: string): boolean {
  if (params === "") return true // CSI m == CSI 0 m
  return params
    .split(";")
    .some((p) => {
      const code = p.split(":")[0]!
      return code === "" || code === "0" || code === "49"
    })
}

/**
 * Flatten an extension status into plain single-line text (no escapes), used
 * for width math.(把扩展状态压平为无转义纯文本，用于宽度计算。)
 */
export function sanitizeStatusText(text: string): string {
  return cleanPlain(text.replace(ANSI_PATTERN, "")).trim()
}

/**
 * Keep an extension status' own colors (e.g. the caveman campfire animation)
 * while preventing its embedded resets from punching a hole in the bar: after
 * every background-clearing SGR we re-apply the segment's own style.
 * (保留扩展状态自带配色（如 caveman 篝火动画），同时在每个会清背景的 SGR 后
 * 重新应用段落样式，避免内嵌 reset 在状态栏上留下断口。)
 *
 * @param restore SGR prefix that re-establishes the segment style (bg + fg + bold)
 */
export function restyleStatusText(text: string, restore: string): string {
  const parts = text.split(/(\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;:?]*[ -\/]*[@-~]|\x1b[@-Z\\-_])/)
  const out: string[] = []
  let plainSeen = false
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i]!
    if (part === "") continue
    if (i % 2 === 1) {
      const sgr = SGR_PATTERN.exec(part)
      if (!sgr) continue // drop non-SGR escapes (丢弃非 SGR 转义)
      out.push(part)
      if (clearsBackground(sgr[1]!)) out.push(restore)
      continue
    }
    let plain = cleanPlain(part)
    if (!plainSeen) plain = plain.replace(/^ +/, "")
    if (plain === "") continue
    plainSeen = true
    out.push(plain)
  }
  // Trim trailing spaces from the last plain chunk, keeping trailing SGR intact.
  // (去掉末尾纯文本的尾随空格，保留其后的 SGR。)
  for (let i = out.length - 1; i >= 0; i--) {
    const chunk = out[i]!
    if (chunk.startsWith("\x1b") || chunk === restore) continue
    out[i] = chunk.replace(/ +$/, "")
    break
  }
  if (!plainSeen) return ""
  return out.join("")
}
