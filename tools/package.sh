#!/usr/bin/env bash
#
# 组装 AI Desk 的分发包（zip）。
#
# 分工很清楚：这个脚本只负责「把构建产物摆成一个装配目录」，
# 打包本身交给 gpm pack。算 sha256、保住可执行位、处理符号链接这三件事
# 在 shell 里做不对 —— Windows 的 Git Bash 连 zip 都没有，sha256sum 也不保证有，
# 而 macOS 的 .app 内部可能有符号链接，普通 zip 会把它们展开。
#
# 用法: tools/package.sh -c <gpm 可执行文件> [-t <cargo target 三元组>] [-o <输出目录>]
#
#   -c  gpm 可执行文件（也可以设环境变量 GPM_BIN）—— 会被嵌进包里
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

usage() {
  awk 'NR==1{next} /^set -euo/{exit} {sub(/^# ?/,""); print}' "$0"
}

while getopts "c:t:o:v:n:h" opt; do
  case $opt in
    c) gpm_bin=$OPTARG ;;
    t) triple=$OPTARG ;;
    o) outdir=$OPTARG ;;
    v) version=$OPTARG ;;
    n) product=$OPTARG ;;
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

# 清单描述的是「形态」，不是「平台」—— 一份清单可以三平台通用，
# 打包时按目标平台挑 entry。这里只写当前这一个平台。
{
  echo "id: ai-desk"
  echo "name: $product"
  echo "version: $version"
  echo "entry:"
  echo "$entry_block"
  echo "launch:"
  echo "  cmd: ad"
  [ "$os" = darwin ] && echo "  mode: activate"
} > "$stage/manifest.yaml"

zip_path="$here/$outdir/ai-desk-$version-$os-$arch.zip"
mkdir -p "$(dirname "$zip_path")"
rm -f "$zip_path"

"$gpm_bin" pack "$stage" \
  --out "$zip_path" \
  --os "$os" \
  --arch "$arch" \
  --gpm "$gpm_bin" \
  --default-dir "~/ad"

echo
echo "分发包：$zip_path"
echo "里面装着 gpm 自己，用户解压后直接跑 install.sh / install.cmd 就行。"
