# AI Desk

跨平台的桌面应用，Tauri 2 + Vue 3 + TypeScript + Vite。

## 开发

```sh
export PATH="$HOME/.cargo/bin:$PATH"   # Rust 不在默认 PATH 里
npm run tauri dev
```

## 打包

```sh
./node_modules/.bin/tauri build --bundles app     # macOS：只要 .app，不生成 dmg
./node_modules/.bin/tauri build                   # Windows：裸 exe + NSIS 安装包
```

产物位置：

| 平台    | 产物                                                        |
| ------- | ----------------------------------------------------------- |
| macOS   | `src-tauri/target/release/bundle/macos/AI Desk.app`         |
| Windows | `src-tauri/target/release/ai-desk.exe`                      |
| Linux   | `src-tauri/target/release/ai-desk`                          |

## 安装

用户拿到分发包后：

```sh
unzip ai-desk-<版本>-<平台>-<架构>.zip -d ai-desk && cd ai-desk && ./install.sh
```

装完：图形界面里能点开（macOS 会出现在 `~/Applications`，也就是启动台里），
终端里敲 `ad` 也能启动。默认装到 `~/ad`，用 `CPI_HOME` 可以改。

卸载：

```sh
~/ad/bin/cpi uninstall ai-desk
```

## 打包成 cpi 分发包

`tools/package.sh` 把 `tauri build` 的产物打成一个 cpi 能吃的 zip：

```sh
tools/package.sh -c /path/to/cpi                    # 本机平台
tools/package.sh -c ./cpi -t aarch64-apple-darwin   # 指定 target
```

`-c` 是 cpi 二进制（见 [cpi-go](https://github.com/qiuzhanghua/cpi-go) 的 release，
每个平台一个）。产出 `dist/ai-desk-<版本>-<平台>-<架构>.zip`：

| 成员            | 作用                                            |
| --------------- | ----------------------------------------------- |
| `install.sh`    | 用户运行的入口（`install.cmd` 是 Windows 版）   |
| `cpi`           | 安装器本体，按平台挑的那一个                    |
| `manifest.yaml` | 告诉 cpi 装什么、装完生成哪个命令               |
| `payload/`      | `AI Desk.app` / `ai-desk.exe` / `ai-desk`       |
| `SHA256SUMS`    | payload 下每个文件的摘要，cpi 安装前强制校验    |

格式细节见 cpi-go 仓库的 `docs/PACKAGE-FORMAT.md`。
