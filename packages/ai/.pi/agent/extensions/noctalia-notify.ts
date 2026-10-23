import { execFile } from "node:child_process"
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"

const NOCTALIA = "/usr/bin/noctalia"

export default function (pi: ExtensionAPI) {
  pi.on("agent_settled", async (_event, ctx) => {
    if (!ctx.hasUI || !ctx.isIdle()) return

    execFile(
      NOCTALIA,
      [
        "msg",
        "notification-show",
        "Pi 任务已完成",
        "任务已处理完毕，等待你的下一步指令。",
      ],
      () => {},
    )
  })
}
