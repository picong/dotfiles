#!/usr/bin/env bash
# Add struct tags to the Go struct under the caret, IDEA/vscode-go style.
# 给光标所在的 Go struct 批量补标签，模仿 vscode-go 的 "Go: Add Tags"。
#
# Zed passes: ZED_FILE (abs path), ZED_ROW / ZED_COLUMN (caret pos, 1-based).
# gomodifytags wants a byte offset anywhere inside the struct, so convert.
# (Zed 给的是 1-based 行列；gomodifytags 要 struct 内任意位置的字节 offset，这里换算。)
#
# ---------------------------------------------------------------------------
# TAGS spec syntax (语法)  —— 用 ';' 分隔各个 tag key，因为 ',' 在 tag 值里有意义
#
#   json                     派生名     -> json:"check_in"
#   json=,omitempty          派生名+选项 -> json:"check_in,omitempty"
#   binding=required         固定值     -> binding:"required"
#   binding=required,gte=0   固定值+多选项（值内逗号原样保留）
#                                       -> binding:"required,gte=0"
#   time_format=2006-01-02   固定值含横线/冒号均可
#   gorm=primaryKey\;autoIncrement      值里要用字面分号时转义 '\;'
#                                       -> gorm:"primaryKey;autoIncrement"
#
# 为什么不能直接用 gomodifytags 的 -add-tags 'binding:required,gte=0'：
#   -add-tags 里 ',' 是 KEY 分隔符，上面那串会被解析成 key=binding(值 required)
#   + key=gte=0，且静态值会泄漏到后续所有 key，产出错误的
#   `binding:"required" gte=0:"required"`。实测确认。
#   正确机制是分两趟：-add-tags 建 key + 首个值，-add-options 追加其余选项。
#   本脚本负责把上面的 spec 拆成这两趟。
# ---------------------------------------------------------------------------
set -uo pipefail

BIN="${GOMODIFYTAGS:-$HOME/go/bin/gomodifytags}"
# 默认：gin 常用组合。可用环境变量整体覆盖（见 tasks.json 各任务）。
TAGS="${TAGS:-form;json;xml;binding=required}"
# snakecase | camelcase | lispcase | pascalcase | titlecase | keep
TRANSFORM="${TRANSFORM:-snakecase}"
# add | clear  —— clear 清掉整个 struct 的标签
MODE="${MODE:-add}"
# FIELD=caret 只处理光标所在那一行的字段；空=整个 struct。
# 用于 binding:"gtfield=CheckIn" 这类只属于单个字段的校验。
FIELD="${FIELD:-}"
# PROMPT=1 在任务终端里现场问一次 spec（Zed 没有输入框，只能走终端 read）。
PROMPT="${PROMPT:-}"

die() {
  echo "$1" >&2
  command -v notify-send >/dev/null 2>&1 && notify-send -u critical "Go add tags" "$1"
  exit 1
}

file="${ZED_FILE:-}"
[[ -n "$file" && -f "$file" ]] || die "no current file"
[[ "$file" == *.go ]] || die "not a Go file: $(basename "$file")"
[[ -x "$BIN" ]] || die "gomodifytags not found at $BIN (go install github.com/fatih/gomodifytags@latest)"

# Don't default these. Falling back to row=1 silently retargets the FIRST struct
# in the file and still reports success — the worst possible failure mode, since
# it edits a struct you weren't looking at. (不给默认值：回落到 row=1 会静默改到
# 文件里第一个 struct 还报成功，等于改错地方。)
row="${ZED_ROW:-}"
col="${ZED_COLUMN:-}"
[[ "$row" =~ ^[0-9]+$ ]] || die "no caret row (ZED_ROW=${ZED_ROW-unset}) — 需要 Zed 传入光标位置"
[[ "$col" =~ ^[0-9]+$ ]] || col=1

# Byte offset of the caret = bytes of all preceding lines (incl. their \n)
# plus bytes of the current line before the caret. LC_ALL=C makes awk's
# length() count BYTES, which is what gomodifytags indexes by.
# (LC_ALL=C 让 awk 的 length() 按字节算，gomodifytags 用的就是字节 offset。)
offset="$(LC_ALL=C awk -v r="$row" -v c="$col" '
  NR <  r { off += length($0) + 1; next }
  NR == r { print off + length(substr($0, 1, c - 1)); exit }
  END     { if (NR < r) print off }
' "$file")"

[[ "$offset" =~ ^[0-9]+$ ]] || die "cannot resolve caret offset (row=$row col=$col)"

# gomodifytags only accepts an offset strictly inside the struct body, so a
# caret on the `type X struct {` line itself (very common: you just typed the
# name) or on the doc comment above it gets rejected. Map every struct body in
# the file to "startLine endLine bodyOffset" and pick the innermost one that
# covers the caret, preferring an enclosing struct and falling back to the next
# struct below the caret (doc-comment case).
# (光标在 `type X struct {` 行或上方注释行时 gomodifytags 会拒绝，
#  所以扫出全文所有 struct 体区间，取包含光标的最内层，否则取光标下方最近的。)
struct_body_offset() {
  LC_ALL=C awk -v r="$row" '
    {
      lineoff = off; off += length($0) + 1
      line = $0
      sub(/\/\/.*/, "", line)          # drop line comments (花括号可能出现在注释里)
      n = length(line)
      for (i = 1; i <= n; i++) {
        ch = substr(line, i, 1)
        if (ch == "{") {
          depth++
          pre = substr(line, 1, i - 1)
          if (pre ~ /struct[[:space:]]*$/) {
            sp++; sStart[sp] = NR; sOff[sp] = lineoff + i; sDepth[sp] = depth
          }
        } else if (ch == "}") {
          if (sp > 0 && sDepth[sp] == depth) {
            print sStart[sp] " " NR " " sOff[sp]; sp--
          }
          depth--
        }
      }
    }
  ' "$file" |
  awk -v r="$row" '
    # innermost struct enclosing the caret = smallest span containing r
    $1 <= r && r <= $2 { span = $2 - $1; if (!hit || span < best) { best = span; hit = $3 } }
    # otherwise the nearest struct starting below the caret (caret on doc comment)
    $1 >  r { if (!below || $1 < belowLine) { belowLine = $1; below = $3 } }
    END { print (hit ? hit : below) }
  '
}

# Compile the TAGS spec into gomodifytags invocations:
#   tagGroups[] -> one -add-tags run each
#   addOptions  -> a single -add-options run
# For `key=v1,v2,v3`, v1 becomes the tag's value (-add-tags key:v1) and v2..
# become options (-add-options key=v2,key=v3). A leading comma
# (`json=,omitempty`) means "keep the derived field name, just add options".
#
# Why several -add-tags runs instead of one: inside -add-tags a static value
# carries over to every *later* bare key, so 'gorm:primaryKey,json' yields the
# wrong `gorm:"primaryKey" json:"primaryKey"` — json should have been derived
# from the field name. Verified. Bare keys are therefore batched into one run
# and each statically-valued key gets its own.
# (一趟 -add-tags 里静态值会沿用到后面所有裸 key，产出错误的
#  json:"primaryKey"；故裸 key 合成一趟，每个带静态值的 key 各自一趟。)
parse_spec() {
  tagGroups=()
  addOptions=""
  local bare="" entry key rest first
  # ';' separates keys so that ',' stays available inside tag values. A literal
  # semicolon in a value (gorm uses them) is escaped as '\;' — swap those to \x01
  # before splitting, then swap back. (值里的字面分号写 '\;'，先换成 \x01 再切分。)
  local spec="${TAGS//\\;/$'\x01'}"
  local IFS=';'
  for entry in $spec; do
    entry="${entry//$'\x01'/;}"                  # restore literal semicolons
    entry="${entry#"${entry%%[![:space:]]*}"}"   # ltrim
    entry="${entry%"${entry##*[![:space:]]}"}"   # rtrim
    [[ -z "$entry" ]] && continue

    if [[ "$entry" == *=* ]]; then
      key="${entry%%=*}"
      rest="${entry#*=}"
    else
      key="$entry"
      rest=""
    fi
    [[ -z "$key" ]] && die "bad TAGS spec entry: '$entry'"

    if [[ -z "$rest" ]]; then
      # bare key -> derived name from the field (裸 key，值由字段名派生)
      bare+="${bare:+,}${key}"
      continue
    fi

    first="${rest%%,*}"           # value before the first comma
    if [[ -z "$first" ]]; then
      bare+="${bare:+,}${key}"                       # keep derived name
    else
      tagGroups+=("${key}:${first}")                 # static value, own run
    fi

    # remaining comma-separated pieces become options on the same key
    if [[ "$rest" == *,* ]]; then
      local opts="${rest#*,}" opt
      local OIFS="$IFS"; IFS=','
      for opt in $opts; do
        [[ -z "$opt" ]] && continue
        addOptions+="${addOptions:+,}${key}=${opt}"
      done
      IFS="$OIFS"
    fi
  done
  # Bare keys first: one run, no static value in play, so each derives its name.
  # (裸 key 合成一趟放最前，无静态值干扰，各自按字段名派生。)
  [[ -n "$bare" ]] && tagGroups=("$bare" "${tagGroups[@]}")
  [[ ${#tagGroups[@]} -gt 0 ]] || die "TAGS spec produced nothing: '$TAGS'"
}

run_tags() {
  local off="$1"

  # FIELD=caret scopes every pass to the caret's line via -line, so options like
  # binding:"gtfield=CheckIn" land on one field only. -line on a non-field line
  # (e.g. the `type X struct {` line) is a harmless no-op — verified.
  # (FIELD=caret 用 -line 把作用域收窄到光标那一行；-line 落在非字段行无副作用。)
  local -a scope=(-offset "$off")
  [[ "$FIELD" == "caret" ]] && scope=(-line "$row")

  if [[ "$MODE" == "clear" ]]; then
    "$BIN" -file "$file" "${scope[@]}" -clear-tags -quiet -w 2>&1
    return
  fi

  # Create the keys with their first value, one run per group.
  # No -override: keeps hand-tuned existing tags (e.g. json:"user_id,omitempty")
  # and only fills in the missing keys. (不加 -override，保留已有的手写标签值。)
  local group
  for group in "${tagGroups[@]}"; do
    "$BIN" -file "$file" "${scope[@]}" \
           -add-tags "$group" -transform "$TRANSFORM" \
           -skip-unexported -quiet -w 2>&1 || return 1
  done

  # Then append the remaining options. Keys must already exist, which is why
  # this cannot be merged into the runs above (-add-options no-ops on missing keys).
  # (最后追加选项；-add-options 对不存在的 key 不生效，故必须在建 key 之后。)
  if [[ -n "$addOptions" ]]; then
    "$BIN" -file "$file" "${scope[@]}" \
           -add-options "$addOptions" \
           -skip-unexported -quiet -w 2>&1 || return 1
  fi
}

if [[ -n "$PROMPT" && "$MODE" != "clear" ]]; then
  # Zed has no input-box API for tasks, so ask in the task terminal instead
  # (this task runs with reveal:always). Empty input keeps the default spec.
  # (Zed 任务没有输入框 API，只能在任务终端里问；该任务配了 reveal:always。)
  printf 'tag spec (\x27;\x27 separated, e.g. form;binding=required,gte=0)\n[%s]: ' "$TAGS"
  IFS= read -r reply || reply=""
  [[ -n "$reply" ]] && TAGS="$reply"
fi

tagGroups=()
addOptions=""
[[ "$MODE" == "clear" ]] || parse_spec

before_sum="$(cksum < "$file")"

if ! out="$(run_tags "$offset")"; then
  fallback="$(struct_body_offset)"
  if [[ "$fallback" =~ ^[0-9]+$ && "$fallback" -gt 0 ]]; then
    out="$(run_tags "$fallback")" || die "${out:-gomodifytags failed}"
  else
    # gomodifytags reports e.g. "offset is not inside a struct" on stderr.
    # (光标不在任何 struct 里。)
    die "${out:-no struct at or below the caret}"
  fi
fi

# -clear-tags leaves trailing whitespace where the tag used to be, and dropping
# tags changes the column widths gofmt aligns on. (清标签会留行尾空格并打乱对齐。)
command -v gofmt >/dev/null 2>&1 && gofmt -w "$file" 2>/dev/null

# Report whether the file actually changed. Without this a no-op looks identical
# to a success: gomodifytags exits 0 and writes nothing when every requested key
# already exists, so a spec that is a subset of the current tags (e.g. asking for
# json+binding on a struct that already has them) appeared to "do nothing".
# (没有这段的话，空操作和成功长得一样：请求的 key 都已存在时 gomodifytags 退出 0
#  且不写任何东西，于是 spec 是现有标签子集时看着就像"快捷键没反应"。)
after="$(cksum < "$file")"
if [[ "$after" == "$before_sum" ]]; then
  msg="no change — 标签已是最新 ($TAGS)"
  [[ "$MODE" == "clear" ]] && msg="no change — 该 struct 没有标签"
  echo "$msg"
  command -v notify-send >/dev/null 2>&1 && notify-send -u low "Go tags" "$msg"
  exit 0
fi

if [[ "$MODE" == "clear" ]]; then
  echo "tags cleared"
else
  echo "tags added: $TAGS ($TRANSFORM)"
fi
