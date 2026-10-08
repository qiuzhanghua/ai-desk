#!/usr/bin/env bash
# 把 tauri build 的产物打成一个 cpi 分发包：
#     dist/ai-desk-<版本>-<平台>-<架构>.zip
#
# 用法：
#   tools/package.sh -c /path/to/cpi                     # 本机平台
#   tools/package.sh -c ./cpi -t aarch64-apple-darwin    # 指定 target
#
# 选项：
#   -c  cpi 二进制（必填。CI 里从 cpi-go 的 release 下载对应平台那一个）
#   -t  cargo 的 target 三元组（产物在 target/<三元组>/release 下）
#   -o  输出目录（默认 dist）
#   -h  帮助
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"

cpi_bin=${CPI_BIN:-}
target_triple=${TARGET:-}
out=${OUT:-dist}

while getopts "c:t:o:h" opt; do
  case $opt in
    c) cpi_bin=$OPTARG ;;
    t) target_triple=$OPTARG ;;
    o) out=$OPTARG ;;
    h) sed -n '2,14p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

[ -n "$cpi_bin" ] || { echo "缺少 -c <cpi 二进制>" >&2; exit 2; }
[ -f "$cpi_bin" ] || { echo "找不到 cpi 二进制：$cpi_bin" >&2; exit 1; }

# ---- 从 tauri.conf.json 读显示名与版本 ----
conf=src-tauri/tauri.conf.json
read_conf() { python3 -c "import json;print(json.load(open('$conf'))['$1'])"; }
product=$(read_conf productName)
version=$(read_conf version)

id=ai-desk   # 包 id，同时也是 Cargo 包名与 cpi 账本里的键
cmd=ad       # 装完在终端里敲的命令

# ---- 平台与 target 目录 ----
if [ -n "$target_triple" ]; then
  case $target_triple in
    *apple-darwin) os=darwin ;;
    *windows*)     os=windows ;;
    *linux*)       os=linux ;;
    *) echo "认不出这个 target：$target_triple" >&2; exit 1 ;;
  esac
  case $target_triple in
    aarch64*|arm64*) arch=arm64 ;;
    x86_64*|amd64*)  arch=amd64 ;;
    *) echo "认不出这个 target 的架构：$target_triple" >&2; exit 1 ;;
  esac
  rel=src-tauri/target/$target_triple/release
else
  case $(uname -s) in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) echo "不认识的系统：$(uname -s)" >&2; exit 1 ;;
  esac
  case $(uname -m) in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *) echo "不认识的架构：$(uname -m)" >&2; exit 1 ;;
  esac
  rel=src-tauri/target/release
fi

# ---- 找 tauri 的产物 ----
case $os in
  darwin)
    src="$rel/bundle/macos/$product.app"
    [ -d "$src" ] || { echo "找不到 $src" >&2; echo "先跑：./node_modules/.bin/tauri build --bundles app" >&2; exit 1; }
    entry="  darwin: { bundle: \"$product.app\" }"
    extra_mode="  mode: activate"      # macOS 上默认“激活式”：等价于双击
    ;;
  windows)
    src="$rel/ai-desk.exe"
    [ -f "$src" ] || { echo "找不到 $src" >&2; echo "先跑：./node_modules/.bin/tauri build" >&2; exit 1; }
    entry="  windows: { exe: ai-desk.exe }"
    extra_mode=""
    ;;
  linux)
    src="$rel/ai-desk"
    [ -f "$src" ] || { echo "找不到 $src" >&2; echo "先跑：./node_modules/.bin/tauri build" >&2; exit 1; }
    entry="  linux: { exe: ai-desk }"
    extra_mode=""
    ;;
esac

# ---- 组装 ----
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
pkg="$root/pkg"
mkdir -p "$pkg/payload"

case $os in
  darwin)  cp -R "$src" "$pkg/payload/" ;;
  windows) cp "$src" "$pkg/payload/ai-desk.exe" ;;
  linux)   cp "$src" "$pkg/payload/ai-desk"; chmod +x "$pkg/payload/ai-desk" ;;
esac

cat > "$pkg/manifest.yaml" <<EOF
id: $id
name: $product
version: $version
entry:
$entry
launch:
  cmd: $cmd
$extra_mode
EOF

cat > "$pkg/install.sh" <<'EOF'
#!/bin/sh
set -eu
cd "$(dirname "$0")"
chmod +x ./cpi 2>/dev/null || true
exec ./cpi install . --dir "${CPI_HOME:-$HOME/ad}"
EOF
chmod +x "$pkg/install.sh"

cat > "$pkg/install.cmd" <<'EOF'
@echo off
setlocal
cd /d "%~dp0"
if not defined CPI_HOME set "CPI_HOME=%USERPROFILE%\ad"
cpi.exe install . --dir "%CPI_HOME%"
pause
EOF

cp "$cpi_bin" "$pkg/cpi"
chmod +x "$pkg/cpi"

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi
}
(
  cd "$pkg"
  find payload -type f -print0 | while IFS= read -r -d '' f; do hash_file "$f"; done | LC_ALL=C sort -k2 > SHA256SUMS
)

mkdir -p "$out"
zip_abs=$(cd "$out" && pwd)/"$id-$version-$os-$arch.zip"
rm -f "$zip_abs"
(cd "$pkg" && zip -q -r -y -X "$zip_abs" install.sh install.cmd cpi manifest.yaml payload SHA256SUMS)

echo "打好包：$zip_abs  ($(du -h "$zip_abs" | cut -f1))"
echo "包内："
(cd "$pkg" && find . -mindepth 1 -maxdepth 3 | LC_ALL=C sort | sed 's/^/  /')
