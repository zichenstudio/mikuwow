# mikuwow

**mikuwow** 是一个用 Bash 写的 Linux 随机壁纸切换工具：用 `curl` 从随机图 API 拉取图片，用 `feh` 设置为桌面壁纸，定时轮换，并附带去重、预加载与收藏功能。

默认图源是 [mikupara](https://www.mikupara.com/)，所以开箱就是 miku 的随机图。想换别的图源，`-a` 改一下即可。

## 特性

- **随机切换** — 定时从 API 拉取随机图片并设为壁纸
- **智能去重** — 基于 sha256 哈希记录历史，避免重复图片
- **预加载** — 提前下载下一张，切换时零等待
- **收藏系统** — 收藏喜欢的壁纸，随机或按序使用、随时管理
- **配置持久化** — 所有配置保存在 XDG 配置目录，改一次永久生效
- **单实例锁** — 基于 `flock`，避免多个实例同时运行
- **自动清理** — 定期清理旧壁纸，可限制历史哈希行数
- **日志记录** — 运行日志自动截断，不会无限膨胀

## 依赖

| 依赖 | 说明 |
| --- | --- |
| `bash` | 4.0+ |
| `feh` | 设置壁纸 |
| `curl` | 下载图片 |
| `sha256sum` | 图片哈希（coreutils） |
| `flock` | 单实例锁（util-linux） |

（其实这些大多发行版都自带了）安装：

```bash
# Arch Linux
sudo pacman -S feh curl util-linux coreutils

# Debian / Ubuntu
sudo apt install feh curl util-linux coreutils

# Fedora
sudo dnf install feh curl util-linux coreutils
```

## 安装

```bash
git clone https://github.com/zichenstudio/mikuwow.git
cd mikuwow
chmod +x mikuwow.sh
```

也可以直接下载单脚本使用，无需其他文件。

## 快速开始

```bash
./mikuwow.sh
```

首次运行会提示选择随机图 API：

- 直接回车使用默认的 `https://api.mikupara.com/api/h`
- 输入 `2` 可自定义 API 地址

之后脚本会立即切换一次壁纸，并每隔 15 分钟自动轮换。

## 用法

```bash
./mikuwow.sh              # 使用已保存的配置启动
./mikuwow.sh -n           # 立即切换一次（独立执行，不加锁）
./mikuwow.sh -s           # 查看运行状态与当前配置
```

### 运行控制

| 选项 | 说明 |
| --- | --- |
| `-n` | 立即切换一次后退出 |
| `-s` | 显示状态（配置、进程、缓存、收藏、日志） |
| `-h` | 显示帮助 |

### 修改配置（自动保存）

| 选项 | 说明 |
| --- | --- |
| `-i <秒>` | 切换间隔，默认 `900` |
| `-k <数量>` | 保留图片数，默认 `3` |
| `-r <次数>` | 最大重试数，默认 `5` |
| `-H <行数>` | 历史哈希上限，默认 `0`（不限制） |
| `-d <目录>` | 缓存目录，默认 `~/.cache/mikuwow` |
| `-a <URL>` | 随机图 API 地址 |
| `-C` | 重置所有配置为默认值 |

### 收藏

| 选项 | 说明 |
| --- | --- |
| `-f` | 收藏当前壁纸 |
| `-u` | 取消收藏当前壁纸 |
| `-F` | 列出所有收藏 |
| `-N` | 随机使用一张收藏 |
| `-N <序号>` | 使用第 N 张收藏（按时间倒序） |
| `--purge-fav` | 删除全部收藏 |

### 清理

| 选项 | 说明 |
| --- | --- |
| `-c` | 删除所有缓存图片（保留哈希与收藏） |
| `-ca` | 删除所有缓存图片并清空哈希记录（保留收藏） |

## 配置说明

配置文件路径固定为：

```
${XDG_CONFIG_HOME:-$HOME/.config}/mikuwow/config.conf
```

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `API_URL` | `https://api.mikupara.com/api/h` | 随机图 API 地址 |
| `INTERVAL` | `900` | 切换间隔（秒） |
| `KEEP_COUNT` | `3` | 缓存中保留的图片数量 |
| `MAX_RETRY` | `5` | 下载/去重失败的最大重试次数 |
| `MAX_HASH` | `0` | 历史哈希上限行数，`0` 表示不限 |
| `CACHE_DIR` | `~/.cache/mikuwow` | 缓存目录（图片/历史/日志/收藏） |

> 通过命令行选项修改配置时会自动写回配置文件，下次启动无需重复指定。

## 目录结构

默认缓存目录 `~/.cache/mikuwow`：

```
~/.cache/mikuwow/
├── 1712345678-1234-foo.jpg     # 缓存的壁纸
├── 1712345999-5678-bar.png     # ...
├── current                     # 当前壁纸的路径
├── history                     # 已使用图片的哈希记录
├── mikuwow.log                 # 运行日志（自动截断）
├── mikuwow.lock                # 单实例锁
├── mikuwow.pid                 # 后台进程 PID
└── favorites/                  # 收藏目录
    └── 0123456789abcdef-foo.jpg
```

## 后台运行

脚本不带 `-n` / `-s` / 收藏 / 清理等参数时会进入前台循环。推荐用 systemd user service 常驻：

`~/.config/systemd/user/mikuwow.service`

```ini
[Unit]
Description=mikuwow random wallpaper
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart=%h/path/to/mikuwow.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
```

**%h/path/to/mikuwow.sh改成自己的路径。**

启用：

```bash
systemctl --user daemon-reload
systemctl --user enable --now mikuwow
systemctl --user status mikuwow
```

或简单粗暴地用 `nohup`：

```bash
nohup ./mikuwow.sh >/dev/null 2>&1 &
```

## FAQ

- **feh 报错无法设置壁纸？**<br>
`feh` 只支持 X11 会话，Wayland 下请使用 `swaybg`、`hyprpaper` 等工具，或通过 XWayland 运行。

- **怎么更换 API？**<br>
`./mikuwow.sh -a "https://your.api/random"`，配置会持久化保存。

- **收藏的图片存在哪？**<br>
默认在 `~/.cache/mikuwow/favorites/`，文件名以哈希前缀开头便于去重。

- **如何彻底重置一切？**

```bash
./mikuwow.sh -C            # 重置配置
./mikuwow.sh -ca           # 清空图片与哈希
./mikuwow.sh --purge-fav   # 清空收藏
```

- **会重复下载同一张图吗？**<br>
脚本会对比 `history` 中的 sha256 哈希。若达到 `MAX_RETRY` 仍重复，会保留最后一张并直接使用（不写入 history），保证壁纸仍能切换。

- **缓存越来越大会不会占满磁盘？**<br>
每次切换后按 `KEEP_COUNT` 保留最新若干张；日志超过 5000 行会自动截断；历史记录也可用 `-H` 限制。彻底清理用 `-c` / `-ca`。

- **被中断后缓存目录里多了奇怪的文件？**<br>
下载过程中 `curl` 会先在缓存目录创建 `dl.XXXXXX` 和 `hd.XXXXXX` 两个临时文件（dl. 存图片内容，hd. 存响应头）。如果 `curl` 被 `Ctrl+C`或进程被杀中断，这两个文件可能没来得及清理，会残留在缓存目录里。不过不必在意这些，每次启动脚本开始循环时会删除更改超过1分钟的残留。

- **为什么我 `-d` 之后原来的收藏不见了？**<br>
因为 `-d` 不迁移原目录里的文件，请手动 `mv`。

- **为什么默认的 API 是 miku？**<br>
因为世界需要更多 miku。如果说桌面每小时换一张，一天下来就是几十次和 miku 见面——这比任何理由都充分，所以，额，把你 mikumiku 掉～

## 反馈问题

本脚本最初用于满足我的个人需求，感觉还不错就分享出来了，是我速学 Bash 在大概一天的时间里写出来的，所以可能有不少 bug。

遇到 bug 或有功能建议，欢迎提 [issue](https://github.com/zichenstudio/mikuwow/issues)。

## 鸣谢

- 默认图源 [mikupara](https://www.mikupara.com/)，提供 miku 的随机图
- 以及所有提过 issue、反馈过问题的朋友

## 许可证

[BSD-3-Clause](LICENSE)
