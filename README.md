# Dotfiles

使用 GNU Stow 管理的配置文件。

## 包列表

| 包名 | 说明 |
|------|------|
| fish | Fish shell 配置 |
| starship | Starship 提示符 |
| nvim | Neovim (LazyVim) 配置 |
| vim | Vim 基础配置 |
| kitty | Kitty 终端配置 |
| tmux | Tmux 配置 |
| niri | Niri 窗口管理器 |
| ideavim | JetBrains IDE Vim 模拟 |

## 使用方法

### 安装所有配置

```bash
cd ~/dotfiles
stow */
```

### 安装单个配置

```bash
cd ~/dotfiles
stow fish    # 只安装 fish 配置
stow nvim    # 只安装 nvim 配置
```

### 卸载配置

```bash
cd ~/dotfiles
stow -D fish    # 卸载 fish 配置
stow -D */      # 卸载所有配置
```

### 更新配置

编辑 dotfiles 中的文件，符号链接会自动指向最新版本。

## 注意事项

- 使用 stow 前，需要先删除原有的配置文件/目录
- stow 会自动创建符号链接到 `~` 目录