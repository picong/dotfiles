# Dotfiles

Arch Linux + niri/noctalia 桌面的个人配置，用 GNU Stow 管理。配置文件入库，所有密钥只放在本机的 `~/.secrets/secrets.env`，绝不入库。

## 快速开始

新机器：

```bash
git clone git@github.com:picong/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh --all        # 安装软件 → 链接配置 → 渲染密钥模板
```

首次运行会从 `secrets/secrets.env.example` 生成 `~/.secrets/secrets.env`。填好真实值后执行：

```bash
./install.sh --render -f  # 用真实密钥重新渲染模板
```

建议先用 `./install.sh -n --all` 演练一遍，只打印要执行的命令，不做任何修改。

## install.sh 用法

| 命令 | 作用 |
|------|------|
| `./install.sh` | 链接全部配置包，生成本地私有文件，渲染模板，安装 fisher/tpm 插件 |
| `./install.sh --all` | 先装软件，再执行上面的步骤 |
| `./install.sh --packages` | 只装软件 |
| `./install.sh --link [包...]` | 只链接指定（或全部）配置包 |
| `./install.sh --unlink [包...]` | 移除指定配置包的链接 |
| `./install.sh --render [-f]` | 只渲染密钥模板，`-f` 覆盖已存在的文件（会先备份） |
| `./install.sh -n ...` | 演练模式 |

被替换的已有文件会备份到 `~/.dotfiles-backup/<时间>/`。stow 使用 `--no-folding`，只链接单个文件，不会把整个目录变成软链。这样 fish、noctalia 等程序照常在同一目录写运行时文件（比如 `fish_variables`、主题生成文件），也不会把这些文件带进仓库。

## 目录结构

```
dotfiles/
├── install.sh              # 一键入口
├── packages/               # stow 配置包，目录结构 = 相对 $HOME 的路径
├── templates/              # 含密钥占位符的配置模板（*.tmpl）
├── secrets/                # 私密文件的示例（只有示例，没有真实值）
├── packages-list/          # 软件清单
└── scripts/                # 安装软件、渲染模板等脚本
```

### 配置包

| 包 | 内容 |
|----|------|
| `fish` | config.fish、fisher 插件清单、自定义函数（插件本体由 fisher 安装，不入库） |
| `bash` | .bashrc / .bash_profile（交互式 bash 会 exec 到 fish） |
| `git` | .gitconfig、全局 ignore（身份信息在 `~/.gitconfig.local`） |
| `nvim` | LazyVim 配置，含 Java/ctags 等自定义模块 |
| `vim` | .vimrc、.ideavimrc |
| `kitty` / `ghostty` / `foot` | 终端 |
| `tmux` | tmux.conf（插件用 TPM 安装） |
| `zed` | settings、keymap、tasks、snippets、主题、脚本 |
| `niri` | niri 配置与配套脚本 |
| `noctalia` | noctalia shell 设置 |
| `desktop` | fuzzel、mako、mpv、GTK/Qt/Kvantum、fontconfig、portal、environment.d、xremap、浏览器 flags |
| `fcitx5` | fcitx5 配置与 rime 自定义 |
| `cli` | lazygit、btop、cava、fastfetch、herdr、rtk、go-musicfox |
| `systemd` | 用户服务（代理、网关转发、wecom 守护等） |
| `bin` | `~/.local/bin`、`~/bin` 下的自写脚本 |
| `ai` | Claude Code / Codex / pi / opencode 的提示词、agents、hooks、扩展（不含密钥的部分） |

单独安装一个包：`./install.sh --link nvim`，或直接用 `stow -d packages -t ~ --no-folding nvim`。

### 刻意不入库的内容

- 由主题工具自动生成的文件：matugen/noctalia 每次换壁纸都会重写 `starship.toml`、`yazi/theme.toml`、`fuzzel/colors.ini`、`niri/noctalia.kdl`、`gtk-*/noctalia.css`、kitty 主题等。
- 插件和缓存：fish 插件、tmux 插件、`node_modules`、`lazy-lock.json` 之外的插件目录。
- 登录态与令牌：`gh/hosts.yml`、`~/.codex/auth.json`、`~/.pi/agent/auth.json`、浏览器和聊天软件的数据目录。
- 工作相关的配置：公司项目的 skills/插件、服务器别名、git 身份，都放在本地私有文件里（见下一节）。

## 密钥配置

所有私密信息集中在一个文件里：`~/.secrets/secrets.env`（权限 600，目录权限 700）。格式为每行一个 `KEY='value'`，完整的变量列表见 [secrets/secrets.env.example](secrets/secrets.env.example)。

```bash
mkdir -p ~/.secrets && chmod 700 ~/.secrets
cp secrets/secrets.env.example ~/.secrets/secrets.env
chmod 600 ~/.secrets/secrets.env
$EDITOR ~/.secrets/secrets.env
./install.sh --render -f
```

这个文件通过两种方式生效：

1. **环境变量**：fish（`config.fish`）和 bash（`.bashrc`）启动时读取并导出全部变量，比如 `OPENAI_API_KEY`、`GEMINI_API_KEY`、`FEISHU_APP_SECRET`、`WEREAD_API_KEY`。
2. **配置模板**：有些工具只能把 key 写在自己的配置文件里。这类文件以 `templates/<相对 $HOME 的路径>.tmpl` 的形式入库，key 用 `${变量名}` 占位，再由 `./install.sh --render` 渲染到真实位置（权限 600）。

| 变量 | 用在哪里 |
|------|----------|
| `AI_GATEWAY_URL` | 网关地址：Claude Code、Codex、crush、opencode、pi，以及 bash 的 `ANTHROPIC_BASE_URL` |
| `GW_KEY_CLAUDE` | `~/.claude/settings.json`、`~/.codex/config.toml`、`~/.config/crush/crush.json`、opencode、pi |
| `GW_KEY_GPT` | opencode、pi、`~/.config/environment.d/zed-codex.conf` |
| `GW_KEY_OTHER` | opencode、pi（DeepSeek / GLM / Kimi 等模型） |
| `OPENAI_API_KEY` / `LOCAL_API_KEY` / `GEMINI_API_KEY` | shell 环境变量 |
| `FEISHU_APP_ID` / `FEISHU_APP_SECRET` | shell 环境变量，飞书 CLI |
| `WEREAD_API_KEY` | shell 环境变量，微信读书 skill |
| `GREENLIGHT_DB_DSN` | shell 环境变量，本地开发数据库 |
| `SSW_HOST` | `~/.config/terminal-adaptive-proxy/config.yaml` 中固定直连的服务器 |

注意：

- 渲染时只替换 `secrets.env` 里声明过的变量和 `${HOME}`，配置里其他的 `$` 文本保持原样。
- 渲染出来的文件默认**不覆盖**已有文件，因为 Claude Code、Codex 运行时会改写自己的配置（比如信任的项目、插件状态）。只有在 key 变了或要重置配置时，才用 `--render -f`，旧文件会备份为 `*.bak-<时间>`。
- 在工具里改了模板对应的配置后（比如往 opencode 加了模型），记得把改动同步回 `templates/` 里的模板，同时把 key 换回 `${...}` 占位符。
- 新增一个密钥的步骤：先在 `secrets.env` 和 `secrets.env.example` 里各加一行，然后在模板里写 `${NEW_KEY}`，或者直接作为环境变量使用。

### 其他本机私有文件

| 文件 | 内容 | 示例 |
|------|------|------|
| `~/.gitconfig.local` | git 用户名和邮箱（由 `.gitconfig` 的 `[include]` 引入） | [secrets/gitconfig.local.example](secrets/gitconfig.local.example) |
| `~/.config/fish/local.fish` | ssh 主机别名、工作相关的 abbr（由 `config.fish` 加载） | [secrets/local.fish.example](secrets/local.fish.example) |

`install.sh` 在这两个文件不存在时，会自动从示例生成。

### 迁移密钥到新机器

`~/.secrets/`、`~/.gitconfig.local`、`~/.config/fish/local.fish` 需要手动通过安全渠道复制，比如密码管理器或加密 U 盘。也可以打一个加密包：

```bash
tar czf - ~/.secrets ~/.gitconfig.local ~/.config/fish/local.fish | gpg -c > dotfiles-private.tar.gz.gpg
# 新机器上(on the new machine):
gpg -d dotfiles-private.tar.gz.gpg | tar xzf - -C /
```

## 软件安装

`./install.sh --packages` 会调用 `scripts/install-packages.sh`，依次执行下面这些步骤，也可以单独执行其中一步，比如 `scripts/install-packages.sh aur npm`：

| 步骤 | 清单 | 说明 |
|------|------|------|
| `repo` | — | 添加 `[archlinuxcn]` 源（USTC 镜像），检查 `[multilib]` |
| `pacman` | [pacman.txt](packages-list/pacman.txt) | 官方源和 archlinuxcn 的软件 |
| `aur` | [aur.txt](packages-list/aur.txt) | 用 paru（没有就用 yay）逐个安装，单个失败不影响其他包 |
| `flatpak` | [flatpak.txt](packages-list/flatpak.txt) | flathub 用户级安装 |
| `npm` | [npm-global.txt](packages-list/npm-global.txt) | 全局包装到 `~/.npm-global`，使用 npmmirror 镜像 |
| `cargo` / `go` / `uv` | [cargo.txt](packages-list/cargo.txt) / [go.txt](packages-list/go.txt) / [uv-tools.txt](packages-list/uv-tools.txt) | 语言工具链装的工具 |
| `extras` | [install-extras.sh](scripts/install-extras.sh) | 用官方脚本安装的工具，已装的会跳过 |
| `hardware` | [pacman-hardware.txt](packages-list/pacman-hardware.txt) | **默认不执行**：内核、NVIDIA/Intel/AMD 驱动、grub/snapper 等，换硬件前先检查 |

### 用官方脚本安装的工具

| 工具 | 安装命令 |
|------|----------|
| Claude Code | `curl -fsSL https://claude.ai/install.sh \| bash` |
| Zed | `curl -f https://zed.dev/install.sh \| sh` |
| uv | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| opencode | `curl -fsSL https://opencode.ai/install \| bash` |
| pi coding agent | `curl -fsSL https://pi.dev/install.sh \| sh` |
| herdr | `curl -fsSL https://herdr.dev/install.sh \| sh` |
| rtk | `curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh \| sh`（不要用 `cargo install rtk`，那是另一个同名项目） |
| codegraph | `curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh \| sh` |
| tuicr | `curl -fsSL https://tuicr.dev/install.sh \| sh` |
| fff-mcp | `curl -L https://dmtrkovalenko.dev/install-fff-mcp.sh \| bash` |
| moshi-hook | `curl -fsSL https://getmoshi.app/install.sh \| sh` |
| hermes agent | `curl -fsSL https://hermes-agent.nousresearch.com/install.sh \| bash` |
| maestro | `curl -fsSL https://get.maestro.mobile.dev \| bash`（需要 Java 17+） |

### 需要手动处理的软件

- **玲珑（linyaps）应用**：企业微信（`com.qq.weixin.work.deepin`）、玲珑商店。先装好 `linyaps`，然后执行 `ll-cli install <id>`。
- **EasyConnect**、**Deepin Wine 版企业微信**：依赖公司提供的安装包，需要手动安装。
- **Go 多版本**：`~/sdk/go1.x` 用 `go install golang.org/dl/go1.22.12@latest && go1.22.12 download` 安装。`GOTOOLCHAIN=auto` 已在 fish 里设置好。
- 安装完成后的一次性操作：`rtk init -g`、`codegraph install`、`moshi-hook service install`。另外按需启用用户服务，比如 `systemctl --user enable --now terminal-adaptive-proxy`。

## 日常维护

- 修改配置：直接改 `~` 下的文件（它们就是指向仓库的软链），然后在 `~/dotfiles` 里 `git diff` 查看并提交。
- 收录一个新配置：先把文件挪到 `packages/<包>/<相对 $HOME 的路径>`，再执行 `./install.sh --link <包>`。
- 更新软件清单：

  ```bash
  pacman -Qqen > /tmp/native && comm -13 <(sort packages-list/pacman.txt packages-list/pacman-hardware.txt) <(sort /tmp/native)  # 新装但没进清单的
  pacman -Qqem   # 对照 aur.txt
  ```

- 提交前检查有没有密钥：

  ```bash
  git diff --cached | grep -nE 'sk-[A-Za-z0-9]{16,}|AIza|gh[pousr]_|BEGIN .*PRIVATE KEY'
  ```
