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

`install.sh` 会把后面的参数原样交给 gpm（v0.6.3 起，gpm v3.12 的 D42），所以想装到别处
直接 `./install.sh --dir ~/tdp`；带上 `--yes` 就跳过"要不要写 PATH 块"的那次询问
（脚本、管道里没人回答问题，不加 `--yes` 就会跳过 PATH 集成）。

装完：图形界面里能点开（macOS 会出现在 `~/Applications`，也就是启动台里），
终端里敲 `ad` 也能启动。默认装到 `~/cot`（AI Desk 依赖 cot 才跑得完整，所以家就是
cot 的家；`$COT_HOME` 说了算），macOS 上 `.app` 落在家的顶层
（`~/cot/AI Desk.app`，v3.6 起不进 `lib/`），终端启动器会把 `COT_HOME`、`TDP_HOME` 与
`PATH` 交给应用进程。

包里还带着 tdp（清单里 `requires: [cot, tdp]`）。它不跟 AI Desk 同住：gpm 只让
`requires` 的第一家（cot）当应用的家，tdp 回它自己的家 —— `$TDP_HOME`，没设就是
`~/tdp`。

顺带一提：包里自带一份 gpm，装的时候会把它拷进 `~/cot/bin/gpm`；那儿**已经有**
一份时先比一次版本，包里这份更新才会替换（gpm v3.11 起，`--force` 才无视版本）。
所以装一次 AI Desk 也可能顺手把 gpm 自己升上去，而升级一次 AI Desk 之后
`~/cot/bin/gpm version` 报的就是包里那份的版本。

**覆盖安装（也就是升级）之前先把 AI Desk 退掉** —— 它还开着时 gpm 会拒绝动手，
理由与 `--force` 的用法见下面的「更新方式」。

### macOS：被 Gatekeeper 拦住了怎么办

分发包现在是**未签名**的。zip 只要经过浏览器或邮件，里面每个文件都会带上
`com.apple.quarantine`（下载标记）；带标记又没有 Developer ID 签名的 `.app`，
双击会被 Gatekeeper 直接拒掉（`open` 返回 `-128`，界面上是「Apple 无法检查它
是否包含恶意软件」）。

**正常的安装路径不受影响。** `./install.sh` 照跑，gpm 把 `.app` 复刻进 `~/cot` 时会清掉
带过来的标记（v3.10 起显式 `xattr -dr`，不再只靠"复制碰巧不搬扩展属性"），装完双击、
`ad` 都能启动（本机实测过）。会在哪儿撞上：在解压出来的
目录里**直接双击 `payload/AI Desk.app`**（跳过安装器）—— 那不是安装路径，别这么做。

万一还是被拦了，三条路，从推荐到将就：

1. 走「仍要打开」：**系统设置 → 隐私与安全性**，在下面找到被拦的提示点**仍要打开**
   （macOS 15 起，右键→「打开」这条老路基本失效了）。
2. 摘掉这个应用的下载标记：
   `xattr -dr com.apple.quarantine ~/cot/AI\ Desk.app`
3. 干脆全程走终端（`unzip` + `./install.sh`）：这条路不产生下载标记。

**根治办法是签名 + 公证**，那是 gpm-go 的 `DESIGN.md` R1 里记着的发布阻塞项。安装器
这边已经做了力所能及的一半：**gpm 从 v3.10 契约起，落地应用之后会递归清掉入口上的
`com.apple.quarantine`**（`DESIGN.md` D40、FR-28），所以上面第 2 条一般用不着手敲 ——
它只是让"装好了打不开"不再发生，并不解决"这个包值不值得信"：那要等签名 + 公证。

卸载：

```sh
~/cot/bin/gpm uninstall ai-desk
```

## 打包成 gpm 分发包

`tools/package.sh` 把 `tauri build` 的产物打成一个 gpm 能吃的 zip：

```sh
tools/package.sh -c /path/to/gpm -x cot=/path/to/cot -x tdp=/path/to/tdp   # 本机平台
tools/package.sh -c ./gpm -t aarch64-apple-darwin -x cot=./cot -x tdp=./tdp
```

`-c` 是 gpm 二进制（见 [gpm-go](https://github.com/qiuzhanghua/gpm-go) 的 release，
每个平台一个）。`-x cot=<cot 可执行文件>` 把 cot 一起打进包里，`-x tdp=…` 同理，
清单里写 `requires: [cot, tdp]`（可以只给一家）。**顺序有意义**：第一家是应用自己住的
那个家（AI Desk 给的是 cot，所以默认落在 `~/cot`），第二家往后各回自己的家
（tdp 住 `$TDP_HOME`，缺省 `~/tdp`）。用户安装时不需要联网；**不给 `-x` 也能打包**，
只是清单里没有 `requires`，gpm 会把应用装到平台数据目录
（macOS `~/Library/Application Support/ad`），终端启动器也不注入 `COT_HOME` / `TDP_HOME`。

CI 里那两份工具链从公开仓 [dl](https://github.com/qiuzhanghua/dl) 的两个滚动 tag
（`cot` / `tdp`）取，钉的是资产名里的版本号：`COT_VERSION: 2.0.1`、`TDP_VERSION: 27.0.6`。
（v0.3.1 起改走这里：以前 cot 从私有仓 `cot_cli` 取，要一个 `COT_CLI_TOKEN` secret，
现在公开仓的默认 token 就能读，那个 secret 不再需要 —— 也顺手支持了 Linux 上按 libc
分家的 gnu / musl 两套资产，我们取 gnu 那一支。）

安装时 gpm 的行为（本仓已跟到 gpm v3.10 契约）：如果 `~/cot/bin/cot` 已经在了，
**不会**拿包里那份重铺工具链——只打印一句"已经装好 cot（…），跳过"（要重铺得加
`--force`）；tdp 同理（看的是 `$TDP_HOME/bin/tdp`）。而 `.zprofile` / `.zshrc` /
`.profile`（Windows 是注册表里的 `Path`）缺少`# >>> gpm >>>` 标记块时照样补上。
应用本身每次都是覆盖式安装。

产出 `release/ai-desk-<版本>-<平台>-<架构>.zip`
（用 `release/` 而不是 `dist/`——后者是前端构建的产物目录，每次 `tauri build` 都会清掉）：

| 成员            | 作用                                            |
| --------------- | ----------------------------------------------- |
| `install.sh`    | 用户运行的入口（`install.cmd` 是 Windows 版）   |
| `gpm`           | 安装器本体，按平台挑的那一个                    |
| `ad-manifest.yaml` | 告诉 gpm 装什么、装完生成哪个命令、要哪几个工具链 |
| `payload/`      | `AI Desk.app` / `ai-desk.exe` / `ai-desk`       |
| `tools/<os>_<arch>/` | `-x` 嵌进来的工具链（AI Desk 是 `cot` 与 `tdp`） |
| `SHA256SUMS`    | `payload/` 与 `tools/` 下每个文件的摘要，gpm 安装前强制校验 |

包里那份 gpm 由 CI 从 gpm-go 的 **`v0.6.3`** 标记就地编出（`release.yml` 的
`GPM_REF`，跟 `COT_VERSION` / `TDP_VERSION` 一样钉死），编的时候把版本号注进去，所以
`<家>/bin/gpm version` 会自报 `0.6.3`，而不是开发期的默认值。

格式细节见 gpm-go 仓库的 `docs/PACKAGE-FORMAT.md`。

## 更新方式

**没有自动更新。** v0.2.1 起摘掉了 Tauri updater（Rust 的 `tauri-plugin-updater` +
JS 的 `@tauri-apps/plugin-updater`）：当时端点写的是开发期的
`http://127.0.0.1:8787/latest.json`，而发布流程里没有任何一步会上传更新包
（`.app.tar.gz` / `.sig`）或 `latest.json` —— 这个能力对用户从来没生效过，
只会在每次启动时白跑一次必然失败的请求、并往 `~/.ai-desk-update.log` 记一行。
与其留着"看着像有、其实没有"，不如去掉。

升级的办法就是重新装一次（覆盖式安装）：

```sh
~/cot/bin/gpm install <新的分发包目录或 zip>
```

**升级之前先把 AI Desk 退掉。** 它还开着的时候 gpm 会拒绝动手（退出码 `1`，一个字节
都不改），并说明后果：进程脚下的文件会被换掉或抽走，之后读到的资源、动态库、拉起的
子进程都可能是另一份（**版本混用**）；macOS 上还会留下一个**幽灵进程** —— 那个位置
一直指着旧进程，你下次点图标只会把它唤到前台，拿不到新的。这道闸同样盖住
`gpm uninstall`。脚本里确实不在乎的话加 `--force`。

（这套行为在 macOS 15.8.1 上整条走过一遍：运行中升级被拒 → `--force` 放行 → 幽灵进程
真的出现。过程记在 gpm-go 仓库 `DESIGN.md` 的 §3 与 D31/§2.9.1。）

账本里的版本号会跟着更新。`~/cot/bin/ad`、`~/Applications/AI Desk.app`（macOS 上的
软链）与 `~/cot/AI Desk.app` 指向同一个入口，覆盖安装之后照旧能用。

要重新加回自动更新，三件事缺一不可：Rust 侧与 JS 侧的版本必须钉同一个
major/minor（`tauri-cli` 会检查，漂移就直接拒绝构建）；端点与签名公钥写在
`src-tauri/tauri.conf.json` 的 `plugins.updater` 里，端点必须是 https
（否则得开 `dangerousInsecureTransportProtocol`，那一项不该进正式产物）；
发布流程里得真的把更新包与 `latest.json` 传上去。


