#!/usr/bin/env bash
#
# 把「本机打一个 AI Desk 分发包」要用的四样外部东西取到 .cache/ 里，
# 反复跑不会重复下载 —— 这就是「免得每次重下 cot / tdp / gpm / GUI-Setup」的那一步。
#
# 版本不另立一份：脚本直接从 .github/workflows/release.yml 的 env 里读 CI 钉住的
# 那几个（GPM_REF / GSETUP_REF / COT_VERSION / TDP_VERSION / DL_REPO），所以本地
# 拿到的和 CI 打进包里的是同一份东西，改 pin 只改一处。也可以用同名环境变量覆盖。
#
# 用法: tools/fetch-deps.sh [-p <os>_<arch>] [-d <缓存目录>] [--latest] [--force]
#                           [--no-gpm] [--no-gsetup] [--pack] [--smoke]
#
#   -p  目标平台，默认当前机器（darwin_arm64 / linux_amd64 / windows_amd64 …）。
#       它只影响 cot / tdp / gpm 三样；GUI-Setup 是 CGO + 系统 webview，只能编
#       宿主那一份，跨平台时会跳过并提醒（那份由 CI 出）。
#   -d  缓存目录，默认 .cache（已经在 .gitignore 里）。
#   --latest   cot / tdp 不按 pin，改成到 dl 上挑该平台最新的那一份资产。
#   --force    已经缓存过的也重新取。
#   --no-gpm / --no-gsetup   跳过其中一样。
#   --pack     取完直接调 tools/package.sh 打出 zip（要求 tauri 的构建产物已经在了）。
#   --smoke    再跑一遍 tools/smoke-test.sh：临时 HOME 里装一遍、卸一遍，验落位与回放。
#              配合 --pack 时用它刚打出来的那个 zip，否则挑 release/ 里最新的。
#   -h         这个帮助。
#
# 缓存布局（都在 -d 之下）：
#   dl/<资产名>                    cot / tdp 的裸二进制（dl 上放的就是裸文件）
#   gpm/<ref>/gpm[.exe]            内嵌的 gpm
#   gsetup/<ref>/GUI-Setup[.app]   wails 编出来的图形安装器
#   bin/wails                      wails CLI（v2.16.0，跟 CI 一致）
#   src/<repo>-<ref>/              上面两样用到的源码（浅克隆那个 tag）
#   gocache/                       没设 GOCACHE 时给 go 用的构建缓存
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"

cache=$here/.cache
platform=""
latest=0
force=0
with_gpm=1
with_gsetup=1
do_pack=0
do_smoke=0

usage() { awk 'NR==1{next} /^set -euo/{exit} {sub(/^# ?/,""); print}' "$0"; }

while [ $# -gt 0 ]; do
  case $1 in
    -p) platform=${2:?-p 后面要给 <os>_<arch>}; shift 2 ;;
    -d) cache=${2:?-d 后面要给目录}; shift 2 ;;
    --latest) latest=1; shift ;;
    --force) force=1; shift ;;
    --no-gpm) with_gpm=0; shift ;;
    --no-gsetup) with_gsetup=0; shift ;;
    --pack) do_pack=1; shift ;;
    --smoke) do_smoke=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "认不出的参数：$1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null 2>&1 || {
  echo "要 GitHub CLI（gh）：在 cot 环境里先 . ~/cot/bin/activate。" >&2
  exit 1
}
command -v git >/dev/null 2>&1 || { echo "要 git。" >&2; exit 1; }

# ---------- 平台 ----------
host_os=$(uname -s)
host_arch=$(uname -m)
case $host_os in
  Darwin) host_os=darwin ;;
  Linux) host_os=linux ;;
  MINGW*|MSYS*|CYGWIN*) host_os=windows ;;
esac
case $host_arch in
  arm64|aarch64) host_arch=arm64 ;;
  x86_64|amd64) host_arch=amd64 ;;
esac

if [ -z "$platform" ]; then platform="${host_os}_${host_arch}"; fi
os=${platform%%_*}
arch=${platform##*_}
case $os in darwin|linux|windows) ;; *) echo "认不出的平台：$platform（形如 darwin_arm64）" >&2; exit 2 ;; esac
case $arch in arm64|amd64) ;; *) echo "认不出的架构：$arch" >&2; exit 2 ;; esac

ext=""
if [ "$os" = windows ]; then ext=".exe"; fi

# 不能用 triple=$(case … esac)：macOS 自带的 bash 3.2 会把 case 模式里那个
# 右括号当成功命令替换的收尾，报 syntax error near `;;'。
triple=""
case "${os}_${arch}" in
  darwin_arm64)  triple=aarch64-apple-darwin ;;
  darwin_amd64)  triple=x86_64-apple-darwin ;;
  linux_arm64)   triple=aarch64-unknown-linux-gnu ;;
  linux_amd64)   triple=x86_64-unknown-linux-gnu ;;
  windows_arm64) triple=aarch64-pc-windows-msvc ;;
  windows_amd64) triple=x86_64-pc-windows-msvc ;;
esac

# ---------- 版本（跟 CI 同一处） ----------
pin()   { sed -n "s/^[[:space:]]*$1:.*||[[:space:]]*'\([^']*\)'.*/\1/p" .github/workflows/release.yml | head -1; }
plain() { sed -n "s/^[[:space:]]*$1:[[:space:]]*\([^[:space:]#]*\).*/\1/p" .github/workflows/release.yml | head -1; }

GPM_REF=${GPM_REF:-$(pin GPM_REF)}
GSETUP_REF=${GSETUP_REF:-$(pin GSETUP_REF)}
DL_REPO=${DL_REPO:-$(plain DL_REPO)}
COT_VERSION=${COT_VERSION:-$(plain COT_VERSION)}
TDP_VERSION=${TDP_VERSION:-$(plain TDP_VERSION)}
for name in GPM_REF GSETUP_REF DL_REPO COT_VERSION TDP_VERSION; do
  if [ -z "${!name}" ]; then
    echo "没能从 release.yml 里读到 $name，请显式设这个环境变量。" >&2
    exit 1
  fi
done

echo "平台：$platform（cargo 三元组 $triple）"
echo "版本：gpm $GPM_REF　GUI-Setup $GSETUP_REF　cot $COT_VERSION　tdp $TDP_VERSION　来自 $DL_REPO"
echo "缓存：${cache#$here/}"
echo

mkdir -p "$cache/src" "$cache/bin"
if [ -z "${GOCACHE:-}" ]; then export GOCACHE="$cache/gocache"; fi

# ---------- cot / tdp：dl 上的裸二进制 ----------
cot_asset="cot_${COT_VERSION}_${os}_${arch}"
tdp_asset="tdp_${TDP_VERSION}_${os}_${arch}"
case $os in
  linux) cot_asset="${cot_asset}_gnu" ;;   # dl 里 Linux 按 libc 分家，Tauri 的产物走 gnu
  windows) cot_asset="${cot_asset}.exe"; tdp_asset="${tdp_asset}.exe" ;;
esac

if [ "$latest" = 1 ]; then
  case $os in
    darwin) cot_pat="^cot_.*_darwin_${arch}\$"; tdp_pat="^tdp_.*_darwin_${arch}\$" ;;
    linux)  cot_pat="^cot_.*_linux_${arch}_gnu\$"; tdp_pat="^tdp_.*_linux_${arch}\$" ;;
    windows) cot_pat="^cot_.*_windows_${arch}\.exe\$"; tdp_pat="^tdp_.*_windows_${arch}\.exe\$" ;;
  esac
  newest() {
    gh release view "$1" -R "$DL_REPO" --json assets --jq '.assets[].name' 2>/dev/null \
      | grep -E "$2" | sort -V | tail -1
  }
  cot_asset=$(newest cot "$cot_pat")
  tdp_asset=$(newest tdp "$tdp_pat")
  if [ -z "$cot_asset" ] || [ -z "$tdp_asset" ]; then
    echo "--latest：dl 上没有匹配 $cot_pat / $tdp_pat 的资产。" >&2
    exit 1
  fi
  echo "--latest：cot 挑中 $cot_asset，tdp 挑中 $tdp_asset"
fi

dl_dir="$cache/dl"
fetch() { # <ref/tag> <资产名> <目标目录>
  local ref=$1 asset=$2 dir=$3
  mkdir -p "$dir"
  if [ -f "$dir/$asset" ] && [ "$force" = 0 ]; then
    echo "已缓存 $asset"
    return 0
  fi
  echo "取 $DL_REPO@$ref 的 $asset …"
  ( cd "$dir" && gh release download "$ref" -R "$DL_REPO" -p "$asset" --clobber )
}
fetch cot "$cot_asset" "$dl_dir"
fetch tdp "$tdp_asset" "$dl_dir"
cot_bin="$dl_dir/$cot_asset"
tdp_bin="$dl_dir/$tdp_asset"
chmod +x "$cot_bin" "$tdp_bin" 2>/dev/null || true

# ---------- gpm ----------
gpm_bin=""
if [ "$with_gpm" = 1 ]; then
  gpm_dir="$cache/gpm/$GPM_REF"
  gpm_bin="$gpm_dir/gpm$ext"
  if [ -f "$gpm_bin" ] && [ "$force" = 0 ]; then
    echo "已缓存 gpm（$GPM_REF）"
  else
    mkdir -p "$gpm_dir"
    asset="gpm-${GPM_REF#v}-${os}-${arch}${ext}"
    if ( cd "$gpm_dir" && gh release download "$GPM_REF" -R qiuzhanghua/gpm-go -p "$asset" --clobber ) 2>/dev/null; then
      mv -f "$gpm_dir/$asset" "$gpm_bin"
    else
      # GPM_REF 指到没有 Release 资产的地方（比如 main）时，照 CI 那样从源码编。
      echo "gpm-go 的 $GPM_REF 没有资产 $asset，改成从源码编（跟 CI 一样）。"
      src="$cache/src/gpm-go-$GPM_REF"
      if [ ! -d "$src" ]; then
        git clone --depth 1 --branch "$GPM_REF" https://github.com/qiuzhanghua/gpm-go "$src"
      fi
      ( cd "$src" && CGO_ENABLED=0 go build -trimpath \
          -ldflags "-s -w -X main.version=${GPM_REF#v}" -o "$gpm_bin" ./cmd/gpm )
    fi
    chmod +x "$gpm_bin" 2>/dev/null || true
  fi
fi

# ---------- GUI-Setup：浅克隆那个 tag，用 wails 就地编 ----------
setup_path=""
setup_name=""
case $os in
  darwin)  setup_name="GUI-Setup.app" ;;
  windows) setup_name="GUI-Setup.exe" ;;
  linux)   setup_name="GUI-Setup" ;;
esac

if [ "$with_gsetup" = 1 ]; then
  if [ "$os" != "$host_os" ]; then
    echo "跳过 GUI-Setup：CGO + 系统 webview 只能编宿主平台（要 $os，宿主是 $host_os），那份交给 CI。" >&2
  else
    setup_path="$cache/gsetup/$GSETUP_REF/$setup_name"
    if [ -e "$setup_path" ] && [ "$force" = 0 ]; then
      echo "已缓存 GUI-Setup（$GSETUP_REF）"
    else
      src="$cache/src/gsetup-go-$GSETUP_REF"
      if [ ! -d "$src" ]; then
        git clone --depth 1 --branch "$GSETUP_REF" https://github.com/qiuzhanghua/gsetup-go "$src"
      fi
      wails_bin="$cache/bin/wails"
      if [ ! -x "$wails_bin" ]; then
        echo "装 wails CLI（v2.16.0，跟 CI 一致）…"
        GOBIN="$cache/bin" go install github.com/wailsapp/wails/v2/cmd/wails@v2.16.0
      fi
      # Ubuntu 24.04 起只剩 webkit2gtk-4.1，Wails v2 要靠这个 tag 才去找它。
      tags=""
      if [ "$os" = linux ]; then tags="-tags webkit2_41"; fi
      echo "编 GUI-Setup（$GSETUP_REF，源码在 ${src#$here/}）…"
      ( cd "$src" && "$wails_bin" build -clean $tags >/dev/null )
      rm -rf "$setup_path"
      mkdir -p "$(dirname "$setup_path")"
      cp -R "$src/build/bin/$setup_name" "$setup_path"
    fi
  fi
fi

# ---------- 自报家门 ----------
echo
echo "== 自报家门 =="
if [ "$os" = "$host_os" ] && [ "$arch" = "$host_arch" ]; then
  "$cot_bin" --version
  "$tdp_bin" version
  if [ -n "$gpm_bin" ]; then "$gpm_bin" version; fi
else
  echo "（目标平台不是宿主，三份都跳过试跑）"
fi

# ---------- 交给 package.sh ----------
version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' src-tauri/tauri.conf.json | head -1)
product=$(sed -n 's/.*"productName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' src-tauri/tauri.conf.json | head -1)

rel() { echo "${1#$here/}"; }
pack_args=()
if [ -n "$gpm_bin" ]; then pack_args+=(-c "$(rel "$gpm_bin")"); fi
pack_args+=(-x "cot=$(rel "$cot_bin")" -x "tdp=$(rel "$tdp_bin")")
pack_args+=(-t "$triple" -v "$version" -n "$product")
if [ -n "$setup_path" ]; then pack_args+=(-s "$(rel "$setup_path")"); fi

echo
echo "== 装配命令（tauri 的产物要先生成好：npx tauri build …） =="
printf 'bash tools/package.sh'; printf ' %q' "${pack_args[@]}"; echo
echo

zip_path=""
if [ "$do_pack" = 1 ]; then
  echo "== 打包 =="
  bash tools/package.sh "${pack_args[@]}"
  zip_path="$here/release/ai-desk-$version-$os-$arch.zip"
  [ -f "$zip_path" ] || { echo "打包跑完了却没看到 $zip_path" >&2; exit 1; }
fi

if [ "$do_smoke" = 1 ]; then
  if [ -z "$zip_path" ]; then
    zip_path=$(ls -t "$here"/release/*.zip 2>/dev/null | head -1 || true)
    if [ -z "$zip_path" ]; then
      echo "--smoke 要一个 zip：先 --pack，或先把包放进 release/。" >&2
      exit 1
    fi
    echo "（用 release/ 里最新的那个 zip：$(rel "$zip_path")）"
  fi
  bash tools/smoke-test.sh "$zip_path"
fi
