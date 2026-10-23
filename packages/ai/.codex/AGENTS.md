## 语言要求
- 始终保持使用中文回复。

## 代码基本要求
- 代码生成时，注释内容使用中英双语，示例：英文注释(中文注释)。
- 代码生成时，日志内容始终使用英文。
- 代码生成时，不要使用类的全路径，先import之后再使用类，静态类或者枚举也是一样的。

## RTK - 命令输出 Token 优化代理

shell 命令尽量用 `rtk` 前缀包裹，`rtk` 会在输出进入上下文前先过滤/压缩，省 token：

```bash
rtk git status
rtk ls
rtk read <file>
rtk grep <pattern>
rtk cargo test
rtk pytest -q
```

元命令：`rtk gain`（token 节省统计）、`rtk gain --history`（历史）、`rtk proxy <cmd>`（不过滤直接跑）。验证：`rtk --version` / `which rtk`。

## mvnt - Maven 测试的省上下文封装（全局命令）

**任何 Maven 项目跑测试用 `mvnt`，不要裸跑 `mvn test`。** 裸 `mvn` 一次测试往上下文灌 13–64KB 日志，且超长输出会被 harness 截断（pi 为 50KB），关键 `[ERROR]` 反而被砍掉；`mvnt` 完整日志落盘、只回显一行摘要（实测 13KB→122B、42KB→106B）。

```bash
mvnt <TestPattern>                        # 单模块项目
mvnt <module> <TestPattern>               # 多模块项目
mvnt <module> <TestPattern> [flags] [额外 mvn 参数]

mvnt UserServiceTest
mvnt 'UserServiceTest#testRegister'       # 只跑一个方法
mvnt core '*Payment*'                     # 通配匹配
mvnt <module> <Test> --am                 # 改了上游 module/facade/common 后必须加
```

- 选项：`--am` 带上游模块一起编 / `--online` 去掉默认 `-o` 允许访问远端仓库（首次拉依赖时用）/ `--verbose` 打完整日志。
- 退出码：`0` 通过 / `1` Maven 失败 / `2` 用法错误 / **`3` 一个用例都没匹配到**。`3` 很重要——测试类名打错时裸 `mvn` 静默报 `BUILD SUCCESS`（已实测），`mvnt` 转成 WARN + rc=3，不给假绿。
- 输出形态（进上下文的全部内容）：`PASS tests=26 failures=0 errors=0 skipped=0 8s  (module :: TopUpUtilsTest)`；失败时为 `FAIL rc=1 tests=3 failures=1 errors=1 ...` 加 `--- failures ---` 段（失败用例的异常与栈帧）和 `--- full log: /tmp/mvnt-logs/....log ---`。
- 失败详情从 **surefire XML 报告** 解析，不受 `-q` / `printSummary=false` 影响；编译错误只回显去重后的 javac 诊断行，依赖解析之类的其他失败回显精简后的 Maven 错误。自动从仓库根执行（任意子目录调用都行）、有 `./mvnw` 优先用 wrapper、栈帧过滤按项目 groupId 推断。
- 默认 `-o` 离线 + `-Dsurefire.failIfNoSpecifiedTests=false`（多模块 `--am` 时上游模块无该测试类不会 BUILD FAILURE）。
- 装在 `~/.local/bin/mvnt`（已在 PATH）。`command -v mvnt` 为空才回退：`mvn -o -q -pl <module> -Dtest=<P> -Dsurefire.failIfNoSpecifiedTests=false -Dmaven.test.redirectTestOutputToFile=true test > /tmp/mvn.log 2>&1 || tail -40 /tmp/mvn.log`
- **禁用 `-Dmaven.compiler.useIncrementalCompilation=false`**：它确实能提速，但实测会静默吐掉真实编译错误——改被调用方签名、调用方不改时，加该参数 `compile` 返回 rc=0（调用方未重编、留旧 class），不加则正确报「找不到符号」。假绿构建比慢构建贵得多。

<!-- CODEGRAPH_START -->
## CodeGraph

In repositories indexed by CodeGraph (a `.codegraph/` directory exists at the repo root), reach for it BEFORE grep/find or reading files when you need to understand or locate code:

- **MCP tool** (when available): `codegraph_explore` answers most code questions in one call — the relevant symbols' verbatim source plus the call paths between them, including dynamic-dispatch hops grep can't follow. Name a file or symbol in the query to read its current line-numbered source. If it's listed but deferred, load it by name via tool search.
- **Shell** (always works): `codegraph explore "<symbol names or question>"` prints the same output.

If there is no `.codegraph/` directory, skip CodeGraph entirely — indexing is the user's decision.
<!-- CODEGRAPH_END -->
