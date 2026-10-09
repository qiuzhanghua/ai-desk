#!/usr/bin/env bash
#
# 组装 AI Desk 的分发包（zip）。
#
# 分工很清楚：这个脚本只负责「把构建产物摆成一个装配目录」，
# 打包本身交给 gpm pack。算 sha256、保住可执行位、处理符号链接这三件事
# 在 shell 里做不对 —— Windows 的 Git Bash 连 zip 都没有，sha256sum 也不保证有，
# 而 macOS 的 .app 内部可能有符号链接，普通 zip 会把它们展开。
#
# 用法: tools/package.sh -c <gpm 可执行文件> [-x <简称=路径>]... [-t <cargo target 三元组>] [-o <输出目录>]
#
#   -c  gpm 可执行文件（也可以设环境变量 GPM_BIN）—— 会被嵌进包里
#   -x  把一个命令行工具放进包里，形如 -x cot=/path/to/cot（可重复）。
#       它会被摆成 tools/<os>_<arch>/<简称>[.exe]，并在清单里写
#       requires: [<简称>]——gpm 安装时会拿它去铺那个家（离线，见
#       gpm-go 的 DESIGN.md D32）。只有 requires 非空时，终端启动器才会
#       注入 COT_HOME/TDP_HOME 并绕开 macOS 的 open（D33）。
#   -t  cargo target 三元组，例如 x86_64-apple-darwin；默认用宿主平台
#   -o  输出目录（默认 release —— 注意不能用 dist/，那是前端构建的产物目录）
#   -v  覆盖版本号（默认读 src-tauri/tauri.conf.json）
#   -n  覆盖产品名（默认读 src-tauri/tauri.conf.json）
#   -h  显示这个帮助
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
gpm_bin=${GPM_BIN:-}
triple=""
outdir="release"
version=""
product=""
cmd=ad           # 终端里的简称；清单叫 <简称>-manifest.yaml，见下面
embed=()         # -x 给的「简称=路径」，可以给多个

usage() {
  awk 'NR==1{next} /^set -euo/{exit} {sub(/^# ?/,""); print}' "$0"
}

while getopts "c:t:o:v:n:x:h" opt; do
  case $opt in
    c) gpm_bin=$OPTARG ;;
    t) triple=$OPTARG ;;
    o) outdir=$OPTARG ;;
    v) version=$OPTARG ;;
    n) product=$OPTARG ;;
    x) embed+=("$OPTARG") ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if [ -z "$gpm_bin" ]; then
  echo "缺少 -c <gpm 可执行文件>（或环境变量 GPM_BIN）。" >&2
  echo "它会被嵌进分发包，用户解压后不需要另外装 gpm。" >&2
  exit 2
fi
if [ ! -f "$gpm_bin" ]; then
  echo "找不到 gpm：$gpm_bin" >&2
  exit 2
fi
gpm_bin=$(cd "$(dirname "$gpm_bin")" && pwd)/$(basename "$gpm_bin")

# 解析 -x。名字只认 cot/tdp —— gpm 的清单校验只认这两个（KnownRequires），
# 别的名字就算塞进包里也没人认得，不如在这里就说清楚。
tc_names=()
tc_paths=()
for item in ${embed[@]+"${embed[@]}"}; do
  name=${item%%=*}
  path=${item#*=}
  if [ "$name" = "$item" ] || [ -z "$name" ] || [ -z "$path" ]; then
    echo "-x 要写成 -x <简称>=<可执行文件路径>，收到的是：$item" >&2
    exit 2
  fi
  case $name in
    cot|tdp) ;;
    *) echo "不认识的工具链简称：$name（只认 cot / tdp，见 gpm-go 的 PACKAGE-FORMAT.md §3）" >&2
       exit 2 ;;
  esac
  if [ ! -f "$path" ]; then
    echo "找不到工具链可执行文件：$path（-x $name=…）" >&2
    exit 2
  fi
  tc_names+=("$name")
  tc_paths+=("$(cd "$(dirname "$path")" && pwd)/$(basename "$path")")
done

# 读 tauri.conf.json。python 在三大平台的 CI 上都有；-v/-n 可以直接绕开它。
read_conf() {
  local key=$1 py
  for py in python3 python; do
    if command -v "$py" >/dev/null 2>&1; then
      "$py" -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" \
        "$here/src-tauri/tauri.conf.json" "$key"
      return
    fi
  done
  echo "读 src-tauri/tauri.conf.json 需要 python3（或者用 -v/-n 直接给值）" >&2
  exit 2
}

[ -n "$product" ] || product=$(read_conf productName)
[ -n "$version" ] || version=$(read_conf version)

# 目标平台与产物位置。cargo 的三元组和 Go 的 GOOS/GOARCH 是两套词，
# 这里统一成 Go 的写法，好和 gpm 的 lib/<id>_<version>_<os>_<arch> 对上。
if [ -n "$triple" ]; then
  case $triple in
    *windows*)          os=windows ;;
    *apple-darwin*)     os=darwin ;;
    *linux*)            os=linux ;;
    *) echo "看不懂的 target 三元组：$triple" >&2; exit 2 ;;
  esac
  case $triple in
    aarch64-*) arch=arm64 ;;
    x86_64-*)  arch=amd64 ;;
    *) echo "看不懂的架构：$triple" >&2; exit 2 ;;
  esac
  rel="$here/src-tauri/target/$triple/release"
else
  case $(uname -s) in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *) echo "宿主平台不受支持，请用 -t 指定 target 三元组" >&2; exit 2 ;;
  esac
  case $(uname -m) in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *) echo "看不懂的宿主架构：$(uname -m)" >&2; exit 2 ;;
  esac
  rel="$here/src-tauri/target/release"
fi

case $os in
  darwin)
    src="$rel/bundle/macos/$product.app"
    [ -d "$src" ] || { echo "没找到 $src，先跑 tauri build" >&2; exit 1; }
    entry_name="$product.app"
    entry_block="  darwin: { bundle: \"$product.app\" }"
    ;;
  windows)
    src="$rel/ai-desk.exe"
    [ -f "$src" ] || { echo "没找到 $src，先跑 tauri build" >&2; exit 1; }
    entry_name="ai-desk.exe"
    entry_block="  windows: { exe: ai-desk.exe }"
    ;;
  linux)
    src="$rel/ai-desk"
    [ -f "$src" ] || { echo "没找到 $src，先跑 tauri build" >&2; exit 1; }
    entry_name="ai-desk"
    entry_block="  linux: { exe: ai-desk }"
    ;;
esac

stage="$here/build/package"
rm -rf "$stage"
mkdir -p "$stage/payload"

if [ "$os" = darwin ]; then
  # ditto 而不是 cp -R：.app 里的符号链接与扩展属性要原样保留。
  ditto "$src" "$stage/payload/$entry_name"
else
  cp -R "$src" "$stage/payload/$entry_name"
fi

# 工具链进 tools/<os>_<arch>/，文件名就是 requires 里那个名字
# （Windows 上加 .exe）—— 这是 gpm installToolchains 认的契约。
if [ ${#tc_names[@]} -gt 0 ]; then
  mkdir -p "$stage/tools/${os}_${arch}"
  i=0
  while [ $i -lt ${#tc_names[@]} ]; do
    dest="$stage/tools/${os}_${arch}/${tc_names[$i]}"
    [ "$os" = windows ] && dest="$dest.exe"
    cp "${tc_paths[$i]}" "$dest"
    chmod 755 "$dest"
    echo "已嵌入工具链：${tc_names[$i]}（$(basename "${tc_paths[$i]}")）→ ${dest#$stage/}"
    i=$((i + 1))
  done
else
  echo "注意：这次没嵌工具链（-x <简称>=<路径>），清单里不会有 requires：" >&2
  echo "      装的时候不会去铺任何工具链，终端启动器也不注入 COT_HOME/TDP_HOME。" >&2
  echo "      装到哪儿仍由 --default-dir 决定（这个脚本给的是 ~/cot）。" >&2
fi

# 清单描述的是「形态」，不是「平台」—— 一份清单可以三平台通用，
# 打包时按目标平台挑 entry。这里只写当前这一个平台。
{
  echo "id: ai-desk"
  echo "name: $product"
  echo "version: $version"
  if [ ${#tc_names[@]} -gt 0 ]; then
    # 只要一家就够了：gpm 会把它当成「这个应用住哪个家」的依据（D21）。
    echo "requires: [${tc_names[0]}]"
  fi
  echo "entry:"
  echo "$entry_block"
  echo "launch:"
  echo "  cmd: $cmd"
  [ "$os" = darwin ] && echo "  mode: activate"
} > "$stage/$cmd-manifest.yaml"

case $outdir in
  /*) zip_path="$outdir/ai-desk-$version-$os-$arch.zip" ;;
  *)  zip_path="$here/$outdir/ai-desk-$version-$os-$arch.zip" ;;
esac
mkdir -p "$(dirname "$zip_path")"
rm -f "$zip_path"

"$gpm_bin" pack "$stage" \
  --out "$zip_path" \
  --os "$os" \
  --arch "$arch" \
  --gpm "$gpm_bin" \
  --default-dir "~/cot"

echo
echo "分发包：$zip_path"
echo "里面装着 gpm 自己，用户解压后直接跑 install.sh / install.cmd 就行。"
if [ ${#tc_names[@]} -gt 0 ]; then
  echo "工具链 ${tc_names[*]} 也在这个 zip 里，装的时候不需要联网。"
fi
