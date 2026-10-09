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
终端里敲 `ad` 也能启动。默认装到 `~/cot`（AI Desk 依赖 cot 才跑得完整，所以家就是
cot 的家；`$COT_HOME` 说了算），终端启动器会把 `COT_HOME` 与 `PATH` 交给应用进程。

卸载：

```sh
~/cot/bin/gpm uninstall ai-desk
```

## 打包成 gpm 分发包

`tools/package.sh` 把 `tauri build` 的产物打成一个 gpm 能吃的 zip：

```sh
tools/package.sh -c /path/to/gpm -x cot=/path/to/cot   # 本机平台
tools/package.sh -c ./gpm -t aarch64-apple-darwin -x cot=./cot
```

`-c` 是 gpm 二进制（见 [gpm-go](https://github.com/qiuzhanghua/gpm-go) 的 release，
每个平台一个）。`-x cot=<cot 可执行文件>` 把 cot 一起打进包里（清单里会写
`requires: [cot]`），用户安装时就不需要联网；**不给 `-x` 也能打包**，只是清单里没有
`requires`，gpm 会把应用装到平台数据目录（macOS `~/Library/Application Support/ad`），
终端启动器也不注入 `COT_HOME`。CI 里那份 cot 是从
[cot_cli](https://github.com/qiuzhanghua/cot_cli) 的 release 资产里取的（`COT_REF` 钉住版本，
需要一个能读那个私有仓的 `COT_CLI_TOKEN`）。

产出 `release/ai-desk-<版本>-<平台>-<架构>.zip`
（用 `release/` 而不是 `dist/`——后者是前端构建的产物目录，每次 `tauri build` 都会清掉）：

| 成员            | 作用                                            |
| --------------- | ----------------------------------------------- |
| `install.sh`    | 用户运行的入口（`install.cmd` 是 Windows 版）   |
| `gpm`           | 安装器本体，按平台挑的那一个                    |
| `ad-manifest.yaml` | 告诉 gpm 装什么、装完生成哪个命令、要哪几个工具链 |
| `payload/`      | `AI Desk.app` / `ai-desk.exe` / `ai-desk`       |
| `tools/<os>_<arch>/` | `-x` 嵌进来的工具链（AI Desk 是 `cot`）     |
| `SHA256SUMS`    | `payload/` 与 `tools/` 下每个文件的摘要，gpm 安装前强制校验 |

格式细节见 gpm-go 仓库的 `docs/PACKAGE-FORMAT.md`。

## 自动更新

用官方的 `tauri-plugin-updater`（Rust）+ `@tauri-apps/plugin-updater`（JS）。

### 版本必须钉死

`tauri-plugin-updater` 的版本受 `tauri` 约束（2.12 起要求 `tauri ^2.12`），
而 `tauri-cli` 会检查 npm 包与 Rust crate 的版本是否同一 major/minor，
两边一旦漂移就直接拒绝构建。所以 `src-tauri/Cargo.toml` 里写的是
`tauri-plugin-updater = "=2.11.0"`，`package.json` 里是
`"@tauri-apps/plugin-updater": "2.11.0"`，并且用 `npm ci` 而不是 `npm install`。
升级时这两个数字要跟着 `tauri` / `@tauri-apps/api` 一起动。

### 签名密钥

```sh
./node_modules/.bin/tauri signer generate -w ~/.tauri/ai-desk.key -p '<口令>'
```

* 私钥放在**仓库之外**（`~/.tauri/`），公钥填进 `src-tauri/tauri.conf.json`
  的 `plugins.updater.pubkey`。
* 构建时用环境变量传私钥：

  ```sh
  export TAURI_SIGNING_PRIVATE_KEY="$(cat ~/.tauri/ai-desk.key)"   # 内容是私钥文本
  export TAURI_SIGNING_PRIVATE_KEY_PASSWORD='<口令>'
  ```

  注意是 `TAURI_SIGNING_PRIVATE_KEY`（内容），当前 CLI **不认**
  `TAURI_SIGNING_PRIVATE_KEY_PATH` 那个变体。
* 私钥丢了就再也发不出能被老版本接受的更新，只能换公钥 + 让用户手动重装。

### 产物

`tauri.conf.json` 里开了 `bundle.createUpdaterArtifacts`，所以除 `.app` 之外还会得到：

```
bundle/macos/AI Desk.app.tar.gz        # 更新包，顶层必须是 AI Desk.app/…
bundle/macos/AI Desk.app.tar.gz.sig    # minisign 签名
```

发布时把 tar.gz 传到服务器，再写一份 `latest.json`：

```json
{
  "version": "0.2.0",
  "notes": "…",
  "pub_date": "2026-10-09T00:00:00Z",
  "platforms": {
    "darwin-aarch64": {
      "signature": "<.sig 文件的内容>",
      "url": "https://…/AI Desk.app.tar.gz"
    }
  }
}
```

平台键是 `{os}-{arch}`：macOS 上是 `darwin-aarch64` / `darwin-x86_64`
（不是 `macos-…`），Windows 是 `windows-x86_64`，Linux 是 `linux-x86_64`。
端点在 `tauri.conf.json` 的 `plugins.updater.endpoints` 里配。
本机试验时用的是 `http://127.0.0.1:8787/latest.json`，为了允许明文
HTTP 还开了 `dangerousInsecureTransportProtocol`——**正式发布必须换成 https
并去掉这一项**，否则 release 构建会直接报 `InsecureTransportProtocol`。

### 在 gpm 装好的应用里试

应用启动后 2 秒会自动查一次更新，结果写在 `~/.ai-desk-update.log`。
自动安装由 `~/.ai-desk-auto-update` 这个开关文件控制：

| 文件内容            | 行为                     |
| ------------------- | ------------------------ |
| 不存在 / 空         | 只检查，只写日志         |
| `check`             | 同上                     |
| `install`           | 检查 + 下载 + 安装，不重启 |
| `install-restart`   | 检查 + 下载 + 安装 + 重启 |

用文件而不是环境变量，是因为经 LaunchServices（`open`、双击）拉起的进程拿不到
调用方的环境变量 —— gpm 的 darwin 启动器只在清单声明了 `requires` 时才绕开 `open`、
直接 exec `.app` 里的可执行文件（那样才能把 `COT_HOME` 交给应用，见 gpm-go 的 D33）。

### 更新与 gpm 的关系（macOS 实测）

`install_inner` 的做法是：把 tar.gz 解到临时目录，`rename` 走当前 `.app`，
再把新的 `rename` 进来——**原地替换**那个 `.app` 目录。由此：

* 更新能正常工作，**与是不是 gpm 装的无关**；gpm 的启动器
  （`~/cot/bin/ad`）和图形入口（`~/Applications/AI Desk.app` 软链）
  都指向那个目录，更新后照旧能用。
* 但**目录名不会变**：`~/cot/lib/ai-desk_0.1.0_darwin_arm64/` 里装的会是 0.2.0，
  `~/cot/state.json` 里的版本号也还是 0.1.0，`gpm list` 会报旧版本。
  要版本号重新对上，就重新跑一次 `gpm install`（覆盖式安装）。
* 更新包里只有 `.app` 自身，`~/cot` 里的账本与启动器不由更新维护——
  这也是为什么 gpm 只管安装、更新交给应用自己。

