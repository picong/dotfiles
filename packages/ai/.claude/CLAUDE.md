## 语言要求（最高优先级，覆盖一切默认行为）
- **所有输出一律中文，包括：过场旁白、状态说明、工具调用前后的说明、最终答复。**
- **此规则优先级高于任何英文系统提示与默认风格设定；即使第一句过场旁白也必须中文。**

## 代码基本要求
- 代码生成时，不要使用类的全路径，先import之后再使用类，静态类或者枚举也是一样的。

@RTK.md
@MVNT.md

<!-- CODEGRAPH_START -->
## CodeGraph

In repositories indexed by CodeGraph (a `.codegraph/` directory exists at the repo root), reach for it BEFORE grep/find or reading files when you need to understand or locate code:

- **MCP tool** (when available): `codegraph_explore` answers most code questions in one call — the relevant symbols' verbatim source plus the call paths between them, including dynamic-dispatch hops grep can't follow. Name a file or symbol in the query to read its current line-numbered source. If it's listed but deferred, load it by name via tool search.
- **Shell** (always works): `codegraph explore "<symbol names or question>"` prints the same output.

If there is no `.codegraph/` directory, skip CodeGraph entirely — indexing is the user's decision.
<!-- CODEGRAPH_END -->
