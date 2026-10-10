#!/usr/bin/env bash
#
# 把「本机打一个 AI Desk 分发包」要用的四样外部东西取到 .cache/ 里，
# 反复跑不会重复下载 —— 这就是「免得每次重下 cot / tdp / gpm / GUI-Setup」的那一步。
#
# 四样都是从各自仓库的 release 下载现成资产（跟 CI 一样，CI 现在也不就地编了）：
# 分发包里装的必须就是用户自己下得到的那个二进制。所以 GPM_REF / GSETUP_REF
# 指的是 release 的 tag，不是分支。
#
# 版本不另立一份：脚本直接从 .github/workflows/release.yml 的 env 里读 CI 钉住的
# 那几个（GPM_REF / GSETUP_REF / COT_VERSION / TDP_VERSION / DL_REPO），所以本地
# 拿到的和 CI 打进包里的是同一份东西，改 pin 只改一处。也可以用同名环境变量覆盖。
#
# 用法: tools/fetch-deps.sh [-p <os>_<arch>] [-d <缓存目录>] [--latest] [--force]
#                           [--no-gpm] [--no-gsetup] [--pack] [--smoke]
#
#   -p  目标平台，默认当前机器（darwin_arm64 / linux_amd64 / windows_amd64 …）。
#       四样都跟着它 —— 六个平台都有现成资产，所以给别的平台预取也行。
#   -d  缓存目录，默认 .cache（已经在 .gitignore 里）。
#   --latest   cot / tdp 不按 pin，改成到 dl 上挑该平台最新的那一份资产。
#   --force    已经缓存过的也重新取。
#   --no-gpm / --no-gsetup   跳过其中一样。
#   --pack     取完直接调 tools/package.sh 打出 zip（要求 tauri 的构建产物已经在了）。
#   --smoke    再跑一遍 tools/smoke-test.sh：临时 HOME 里装一遍、卸一遍，验落位与回放。
#              配合 --pack 时用它刚打出来的那个 zip，否则挑 release/ 里最新的。
#   -h         这个帮助。
#
# 缓存布局（都在 -d 之下；两个 release 取下来的东西按平台分开放，给别的平台
# 预取时不会覆盖本平台那一份）：
#   dl/<资产名>                            cot / tdp 的裸二进制（资产名里带平台）
#   gpm/<ref>/<os>_<arch>/gpm[.exe]         gpm-go release 里的 gpm
#   gsetup/<ref>/<os>_<arch>/GUI-Setup[.app|.exe]   gsetup-go release 里的安装器
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
fetch() { # <仓库> <ref/tag> <资产名> <目标目录>
  local repo=$1 ref=$2 asset=$3 dir=$4
  mkdir -p "$dir"
  if [ -f "$dir/$asset" ] && [ "$force" = 0 ]; then
    echo "已缓存 $asset"
    return 0
  fi
  echo "取 $repo@$ref 的 $asset …"
  ( cd "$dir" && gh release download "$ref" -R "$repo" -p "$asset" --clobber )
}
fetch "$DL_REPO" cot "$cot_asset" "$dl_dir"
fetch "$DL_REPO" tdp "$tdp_asset" "$dl_dir"
cot_bin="$dl_dir/$cot_asset"
tdp_bin="$dl_dir/$tdp_asset"
chmod +x "$cot_bin" "$tdp_bin" 2>/dev/null || true

# ---------- gpm：gpm-go release 里的现成二进制 ----------
gpm_bin=""
if [ "$with_gpm" = 1 ]; then
  gpm_dir="$cache/gpm/$GPM_REF/$platform"
  gpm_bin="$gpm_dir/gpm$ext"
  if [ -f "$gpm_bin" ] && [ "$force" = 0 ]; then
    echo "已缓存 gpm（$GPM_REF）"
  else
    asset="gpm-${GPM_REF#v}-${os}-${arch}${ext}"
    # 不再就地编：包里那份 gpm 必须就是用户自己下得到的那个二进制
    # （CI 也是这么取的）。GPM_REF 指到分支上时这里会直接失败。
    fetch qiuzhanghua/gpm-go "$GPM_REF" "$asset" "$gpm_dir" || {
      echo "gpm-go 的 $GPM_REF 里没有 $asset —— GPM_REF 要指 release 的 tag。" >&2
      exit 1
    }
    mv -f "$gpm_dir/$asset" "$gpm_bin"
    chmod +x "$gpm_bin" 2>/dev/null || true
  fi
fi

# ---------- GUI-Setup：gsetup-go release 里的现成安装器 ----------
setup_path=""
setup_name=""
case $os in
  darwin)  setup_name="GUI-Setup.app" ;;
  windows) setup_name="GUI-Setup.exe" ;;
  linux)   setup_name="GUI-Setup" ;;
esac

if [ "$with_gsetup" = 1 ]; then
  setup_path="$cache/gsetup/$GSETUP_REF/$platform/$setup_name"
  if [ -e "$setup_path" ] && [ "$force" = 0 ]; then
    echo "已缓存 GUI-Setup（$GSETUP_REF）"
  else
    gv="${GSETUP_REF#v}"
    gdir="$cache/gsetup/$GSETUP_REF/$platform"
    case $os in
      darwin)
        asset="GUI-Setup-${gv}-darwin-${arch}.zip"
        fetch qiuzhanghua/gsetup-go "$GSETUP_REF" "$asset" "$gdir"
        rm -rf "$setup_path"
        # 用 ditto 解：.app 里的符号链接与 x 位只有它认得住（unzip 会丢）。
        if command -v ditto >/dev/null 2>&1; then
          ditto -x -k "$gdir/$asset" "$gdir"
        else
          unzip -q -o "$gdir/$asset" -d "$gdir"
        fi
        ;;
      windows)
        asset="GUI-Setup-${gv}-windows-${arch}.exe"
        fetch qiuzhanghua/gsetup-go "$GSETUP_REF" "$asset" "$gdir"
        mv -f "$gdir/$asset" "$setup_path"
        ;;
      linux)
        asset="GUI-Setup-${gv}-linux-${arch}"
        fetch qiuzhanghua/gsetup-go "$GSETUP_REF" "$asset" "$gdir"
        mv -f "$gdir/$asset" "$setup_path"
        chmod +x "$setup_path" 2>/dev/null || true
        ;;
    esac
    if [ ! -e "$setup_path" ]; then
      echo "取完 $GSETUP_REF 却没见到 $setup_path —— 那边的资产名对不上？" >&2
      exit 1
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
  echo "（目标平台不是宿主，命令行那三份跳过试跑）"
fi

# GUI-Setup 是图形程序，命令行上问不出自己的版本 —— darwin 的 .app 读 Info.plist
# 里那个号（CI 也是拿它对号，保证包里那份就是 GSETUP_REF 那份）。
if [ -n "$setup_path" ] && [ "$os" = darwin ] && [ -x /usr/libexec/PlistBuddy ]; then
  declared=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$setup_path/Contents/Info.plist")
  echo "GUI-Setup $declared"
  if [ "$declared" != "${GSETUP_REF#v}" ]; then
    echo "GUI-Setup 自报 $declared，钉住的却是 $GSETUP_REF。" >&2
    exit 1
  fi
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
