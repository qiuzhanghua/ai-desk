#!/usr/bin/env bash
#
# 拿一个已经打好的分发包（zip），在临时 HOME 里走一整遍「装 → 验 → 卸 → 验」：
#
#   解压 → ./install.sh --yes → 逐条断言落位 → <家>/bin/gpm uninstall <id> --yes → 逐条断言回放干净
#
# 全程 HOME 指到临时目录，不碰你真正的 ~/cot、~/tdp 和 shell 配置；也不需要联网
# （工具链在 zip 的 tools/ 里）。给 CI 或本地手工验包用：装完 / 卸完之后那几张
# 断言要是哪条不对，脚本会清楚告诉你是哪一条。
#
# 用法: tools/smoke-test.sh <zip> [--keep]
#
#   --keep   跑完不删临时目录（留现场，路径会打出来，里面还有 install.log /
#            uninstall.log）。
#
# 断言的都是契约里写死的东西：
#   装完  1. payload 里那唯一一个条目落到 <家>/ 下；
#         2. <家>/bin/<简称> 启动器在、可执行；
#         3. 账本 <家>/<家目录名>-state.json 里有这个 id、且 verified: true；
#         4. 家里恰有一处（或几处，各自一块）# >>> gpm >>> PATH 块；
#         5. 图形安装器（GUI-Setup）不会被铺进家里 —— 它是安装过程本身，不是装的东西。
#   卸完  6. 上面 1、2 两样全没了；
#         7. 账本不再记着这个 id（文件整个消失也算）；
#         8. 家里再也找不到 # >>> gpm >>> 块；
#         9. 工具链自己的东西（bin/ 下 cot、tdp、activate… ）一个没少。
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)

usage() { awk 'NR==1{next} /^set -euo/{exit} {sub(/^# ?/,""); print}' "$0"; }

zip=""
keep=0
while [ $# -gt 0 ]; do
  case $1 in
    --keep) keep=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "认不出的参数：$1" >&2; usage >&2; exit 2 ;;
    *) zip=$1; shift ;;
  esac
done
[ -n "$zip" ] || { usage >&2; exit 2; }
[ -f "$zip" ] || { echo "找不到 zip：$zip" >&2; exit 1; }
zip=$(cd "$(dirname "$zip")" && pwd)/$(basename "$zip")

case $(uname -s) in
  MINGW*|MSYS*|CYGWIN*)
    echo "这个脚本只跑 Unix（Windows 上 PATH 集成写的是注册表，验法不一样）。" >&2
    exit 2
    ;;
esac

# zip 的名字里带着它是给哪个平台打的：ai-desk-<version>-<os>-<arch>.zip
host_os=$(uname -s)
case $host_os in Darwin) host_os=darwin ;; Linux) host_os=linux ;; esac
zip_name=$(basename "$zip")
zip_os=$(echo "$zip_name" | sed -n 's/^.*-\(darwin\|linux\|windows\)-\(amd64\|arm64\)\.zip$/\1/p')
if [ -n "$zip_os" ] && [ "$zip_os" != "$host_os" ]; then
  echo "$zip_name 是给 $zip_os 打的，这台机器是 $host_os，跑不了。" >&2
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/ai-desk-smoke.XXXXXX")
cleanup() { if [ "$keep" = 1 ]; then echo; echo "现场留在：$work"; else rm -rf "$work"; fi; }
trap cleanup EXIT

pass=0
fail=0
ok()   { pass=$((pass + 1)); echo "  ✓ $1"; }
bad()  { fail=$((fail + 1)); echo "  ✗ $1" >&2; }
want_file() { if [ -e "$1" ]; then ok "$2"; else bad "$2 —— 没找到 $1"; fi; }
want_gone() { if [ -e "$1" ]; then bad "$2 —— $1 还在"; else ok "$2"; fi; }
want_same() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 —— 得到「$1」，想要「$2」"; fi; }

echo "包：$zip_name"
unzip -q "$zip" -d "$work/pk"

manifest=$(ls -1 "$work/pk"/*-manifest.yaml 2>/dev/null | head -1 || true)
[ -n "$manifest" ] || { echo "zip 顶层没有 <简称>-manifest.yaml" >&2; exit 1; }
short=$(basename "$manifest")
short=${short%-manifest.yaml}
id=$(sed -n 's/^id:[[:space:]]*//p' "$manifest" | head -1)
product=$(sed -n 's/^name:[[:space:]]*//p' "$manifest" | head -1)
version=$(sed -n 's/^version:[[:space:]]*//p' "$manifest" | head -1)
cmd=$(awk '/^launch:/{f=1;next} /^[^[:space:]]/{f=0} f' "$manifest" \
      | sed -n 's/^[[:space:]]*cmd:[[:space:]]*//p' | head -1)
[ -n "$id" ] && [ -n "$cmd" ] || { echo "清单里读不到 id / launch.cmd" >&2; exit 1; }

payload_entry=$(ls -A "$work/pk/payload" | head -1)
echo "简称：$short　id：$id　名字：$product $version　简称命令：$cmd　payload：$payload_entry"
echo

home="$work/home"
mkdir -p "$home"

# 只在 shell 配置里找 PATH 块 —— 不能对家里整个 grep：<家>/bin/gpm 这个二进制
# 里也嵌着 '# >>> gpm >>>' 这行模板，`grep -r` 会把它也算成"一处 PATH 块"。
rc_with_marker() {
  for f in "$home"/.zprofile "$home"/.zshrc "$home"/.profile \
           "$home"/.bashrc "$home"/.bash_profile "$home"/.bash_login \
           "$home"/.zlogin "$home"/.config/fish/config.fish; do
    [ -f "$f" ] || continue
    if grep -q '# >>> gpm >>>' "$f"; then echo "$f"; fi
  done
}

# ---------- 装 ----------
echo "== 装（临时 HOME：$home） =="
if ! ( cd "$work/pk" && env -u COT_HOME -u TDP_HOME HOME="$home" ./install.sh --yes ) \
     >"$work/install.log" 2>&1; then
  echo "install.sh 退出码非 0，日志尾部：" >&2
  tail -25 "$work/install.log" >&2
  exit 1
fi

ledger=$(ls -1 "$home"/*/*-state.json 2>/dev/null | head -1 || true)
[ -n "$ledger" ] || { echo "装完了却没看到账本（<家>/<家目录名>-state.json）" >&2; exit 1; }
app_home=$(dirname "$ledger")
home_base=$(basename "$app_home")

want_file "$app_home/$payload_entry" "$app_home/$payload_entry（payload 落位）"
want_file "$app_home/bin/$cmd" "$app_home/bin/$cmd（终端启动器）"
if [ -x "$app_home/bin/$cmd" ]; then ok "启动器带 x 位"; else bad "启动器没有 x 位"; fi
if grep -q "\"$id\"" "$ledger"; then ok "账本记着 $id"; else bad "账本里没有 $id"; fi
if grep -q '"verified": true' "$ledger"; then ok "账本 verified: true"; else bad "账本不是 verified: true"; fi

rc_files=$(rc_with_marker)
if [ -n "$rc_files" ]; then
  ok "PATH 块写进了：$(echo "$rc_files" | sed "s|$home/||" | tr '\n' ' ')"
  for f in $rc_files; do
    n=$(grep -c '# >>> gpm >>>' "$f" || true)
    want_same "$n" "1" "$(echo "$f" | sed "s|$home/||") 里恰好一块"
  done
  if echo "$rc_files" | xargs grep -l "$home_base/bin" >/dev/null 2>&1; then
    ok "PATH 块指向 $home_base/bin"
  else
    bad "PATH 块没指向 $home_base/bin"
  fi
else
  bad "装完没有任何 # >>> gpm >>> 块（--yes 应该做了 PATH 集成）"
fi

setup_leak=$(find "$home" -iname '*GUI-Setup*' 2>/dev/null || true)
if [ -z "$setup_leak" ]; then
  ok "图形安装器没有落进家里（它是安装过程本身）"
else
  bad "图形安装器被铺进了家里：$setup_leak"
fi

# 卸载前把工具链自己的文件记下来，卸完要对得上。
before_bins=""
if [ -d "$app_home/bin" ]; then before_bins=$(cd "$app_home/bin" && ls -1); fi

# ---------- 卸 ----------
echo
echo "== 卸（$app_home/bin/gpm uninstall $id --yes） =="
if ! env -u COT_HOME -u TDP_HOME HOME="$home" "$app_home/bin/gpm" uninstall "$id" --yes \
     >"$work/uninstall.log" 2>&1; then
  echo "gpm uninstall 退出码非 0，日志尾部：" >&2
  tail -25 "$work/uninstall.log" >&2
  exit 1
fi

want_gone "$app_home/$payload_entry" "$payload_entry 卸掉了"
want_gone "$app_home/bin/$cmd" "启动器卸掉了"
if [ -f "$ledger" ]; then
  if grep -q "\"$id\"" "$ledger"; then bad "账本里还留着 $id"; else ok "账本不再记着 $id"; fi
else
  ok "账本被整个摘掉了"
fi
left=$(rc_with_marker)
if [ -z "$left" ]; then ok "PATH 块摘干净了"; else bad "PATH 块还在：$left"; fi
for b in $before_bins; do
  case $b in "$cmd"|gpm|gpm.exe) continue ;; esac
  want_file "$app_home/bin/$b" "工具链 bin/$b 没被动"
done

# ---------- 收 ----------
echo
if [ "$fail" = 0 ]; then
  echo "== 通过 $pass 项，失败 0 项 =="
else
  echo "== 通过 $pass 项，失败 $fail 项 ==" >&2
  [ "$keep" = 1 ] || echo "（想看现场就加 --keep 再跑一遍）" >&2
  exit 1
fi
