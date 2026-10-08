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

由 [cpi](https://github.com/qiuzhanghua/cpi-go) 安装到 `~/ad`，装完可以从图形界面启动，
也可以在终端里敲 `ad` 启动：

```sh
unzip ai-desk-<版本>-<平台>-<架构>.zip -d ai-desk && cd ai-desk && ./install.sh
```

> 打包成 cpi 分发包（`manifest.yaml` + `payload/` + `SHA256SUMS` + 内嵌 `cpi`）的流程
> 还没做——见 cpi-go 仓库 `docs/PACKAGE-FORMAT.md`。
