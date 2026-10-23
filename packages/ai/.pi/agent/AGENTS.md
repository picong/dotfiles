## 适用范围与冲突处理
- 本文件仅记录跨项目的个人偏好，不重复运行环境已有的通用工具、安全、Git 和验证规则。
- 在运行环境规定的指令层级内，内容冲突按以下顺序处理：用户当前请求的明确要求 > 目标项目的明确规范 > 本文件的全局默认约定 > skill 的流程偏好。多个 skill 之间的生效优先级见「Skill 使用」。

## 语言与表达
- 除非用户当前请求明确指定其他语言，面向用户的自然语言说明统一使用中文，包括进度说明、分析和最终答复。
- 代码、标识符、命令、路径、配置项、错误原文、日志和引用内容保持必要或原始语言。
- 表达直接、紧凑、结论优先；删除寒暄、重复和无信息量的过场，同时保留必要的不确定性、风险和证据。

## 代码约定
- 优先遵循目标项目已有规范；以下约定仅在项目未规定时适用。
- 新增且必要、用于解释非显然逻辑的代码注释使用中英双语，格式：`English comment(中文注释)`。不为显然代码补注释，不为统一格式批量改写现有注释。
- 新增或修改的日志消息使用英文，不为统一语言修改无关日志。
- 遵循语言惯用的 import 风格；默认通过 import 使用类型和成员，仅在名称冲突、语言惯例或框架要求时使用全限定名。

## 工具与工作方式
- 结构性代码问题优先遵循目标项目的代码图规则。CodeGraph 已索引（仓库根有 `.codegraph/`）的仓库按全局 CodeGraph 块的规则优先用 `mcp__codegraph__codegraph_explore`（pi 中 MCP 只有这一个工具）；轻量/细粒度查询走 CLI：`codegraph query/callers/callees/impact/affected -p <项目根> -j`，热点符号限 `-l`/`-d` 防单次 20KB+ 灌上下文；explore 类调用（MCP 或 CLI）同为大输出，宽范围探索派子代理。
- 模糊文件名或概念定位优先使用 `fffind`；简单文本检索优先使用 `ffgrep`，搜索 1–2 次后读取最高匹配。复杂正则、精确穷举或计数、管道处理使用 `rg`；搜索隐藏或忽略内容时使用 `rg -uu`。避免递归 `grep`。
- 大文件写入失败时改用小批量操作；修改已有文件优先使用精确 `edit`，避免以不完整内容覆盖原文件。
- **Maven 项目跑测试用全局命令 `mvnt`，不裸跑 `mvn test`**：裸 `mvn` 单次测试往上下文灌 13–64KB 日志，而 bash 工具 50KB 就截断，关键 `[ERROR]` 反而被砍；`mvnt` 完整日志落盘、只回显一行摘要（实测 13KB→122B、42KB→106B）。用法 `mvnt [<module>] <TestPattern> [--am|--online|--verbose] [额外 mvn 参数]`，`TestPattern` 支持 `'ClassName#methodName'` 单方法与 `'*Payment*'` 通配。
- `mvnt` 选项：`--am` 带上游模块一起编（改了上游 module / facade / common 后必加）、`--online` 去掉默认 `-o` 允许访问远端仓库（首次拉依赖时用）、`--verbose` 打印完整 Maven 日志。默认附带 `-o` 离线与 `-Dsurefire.failIfNoSpecifiedTests=false`（多模块 `--am` 时上游模块无该测试类不会 BUILD FAILURE）。
- `mvnt` 退出码：`0` 通过 / `1` Maven 失败 / `2` 用法错误 / **`3` 一个用例都没匹配到**。`3` 专用于防假绿——测试类名打错时裸 `mvn` 会静默 `BUILD SUCCESS`（已实测），`mvnt` 转成 WARN + rc=3。进上下文的只有一行 `PASS/FAIL tests=.. failures=.. errors=.. skipped=..` 摘要，失败时追加失败用例的异常与栈帧及完整日志路径。
- `mvnt` 失败详情从 **surefire XML 报告** 解析，不受 `-q` / `printSummary=false` 影响；编译错误只回显去重后的 javac 诊断行，依赖解析等其他失败回显精简后的 Maven 错误。装在 `~/.local/bin/mvnt`（已在 PATH），自动从仓库根执行（任意子目录调用都行）、存在 `./mvnw` 时优先用 wrapper、栈帧过滤按项目 groupId 推断。仅 `command -v mvnt` 为空时回退裸命令：`mvn -o -q -pl <module> -Dtest=<Pattern> -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.test.redirectTestOutputToFile=true test > /tmp/mvn.log 2>&1 || tail -40 /tmp/mvn.log`。
- **禁用 `-Dmaven.compiler.useIncrementalCompilation=false`**：它确实能提速，但实测会静默吐掉真实编译错误——改被调用方签名、调用方不改时，加该参数 `compile` 返回 rc=0（调用方未重编、留旧 class），不加则正确报「找不到符号」。假绿构建比慢构建贵得多。
- 简单任务直接处理；复杂、跨文件、可独立并行，或大量探索会污染父会话上下文时，可按需委派子代理完成探索、规划、实现、测试或评审。
- 低风险、可逆且请求范围内的实现细节自行决定；超出范围、不可逆，或显著影响架构和公共接口的决策先征求用户确认。

## Skill 使用
- 用户当前请求显式指定 skill 时优先使用，不被其他自动匹配的流程 skill 覆盖。
- 其他 skill 按其 description 和项目规则自动匹配。

## 外部研究
- 仅在需要外部事实时联网：检索用 `web_search`，已知 URL 用 `fetch_content`，需段落级引用或核实关键断言时用 `source_check`。
- 关键外部结论附来源；工具不可用时明确说明，不虚构检索结果。研究任务同样适用上述子代理规则。
