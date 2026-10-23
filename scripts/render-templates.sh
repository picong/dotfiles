#!/usr/bin/env bash
# Render templates/**/*.tmpl into $HOME, filling ${VAR} from the secrets file.
# (把 templates 下的 *.tmpl 渲染到 $HOME，用私密文件里的变量替换 ${VAR})
#
# Only variables that appear in secrets.env (plus HOME) are substituted, so other
# `$` text in the configs stays intact. Existing targets are kept unless FORCE=1,
# because tools like Claude/Codex rewrite their own config at runtime.
# (只替换 secrets.env 中声明的变量和 HOME，其余 `$` 文本保持原样；目标已存在时默认不覆盖，
#  因为 Claude/Codex 等会在运行时改写自己的配置，FORCE=1 才覆盖并先备份)

set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$DOTFILES/templates"
SECRETS_FILE="${SECRETS_FILE:-$HOME/.secrets/secrets.env}"
FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"

. "$DOTFILES/scripts/lib.sh"

have envsubst || { err "envsubst missing: sudo pacman -S gettext"; exit 1; }
[[ -r "$SECRETS_FILE" ]] || { err "Secrets file not found: $SECRETS_FILE"; exit 1; }

set -a
# shellcheck disable=SC1090
. "$SECRETS_FILE"
set +a

# Build the whitelist "${A} ${B} ..." for envsubst. (构造 envsubst 变量白名单)
vars='${HOME}'
while IFS= read -r name; do
    vars+=" \${$name}"
done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$SECRETS_FILE" | tr -d '=')

missing=0
while IFS= read -r -d '' tmpl; do
    rel="${tmpl#"$TEMPLATE_DIR/"}"
    rel="${rel%.tmpl}"
    target="$HOME/$rel"

    # Warn about placeholders that have no value. (检查未赋值的占位符)
    for v in $(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$tmpl" | sort -u | tr -d '${}'); do
        if [[ -z "${!v:-}" ]]; then
            warn "$rel: \${$v} is empty — set it in $SECRETS_FILE"
            missing=1
        fi
    done

    if [[ -e "$target" && "$FORCE" != 1 ]]; then
        ok "Kept existing ~/$rel (use --render -f to overwrite)"
        continue
    fi
    if [[ -e "$target" ]]; then
        backup="$target.bak-$(date +%Y%m%d-%H%M%S)"
        run cp -a "$target" "$backup"
    fi
    run mkdir -p "$(dirname "$target")"
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '   [dry-run] render %s\n' "~/$rel"
    else
        (umask 077; envsubst "$vars" <"$tmpl" >"$target")
        chmod 600 "$target"
    fi
    ok "Rendered ~/$rel"
done < <(find "$TEMPLATE_DIR" -type f -name '*.tmpl' -print0 | sort -z)

[[ "$missing" == 0 ]] || warn "Some placeholders are empty; see README.md (密钥配置)"
