# Fetch

从 GitHub 私有仓库下载单个文件。使用一个独立的 `fetch.sh`，兼容 Debian 12/13 的 `/bin/sh` 和 Alpine 的 `ash`，不需要额外安装 Bash、jq、Python 或 Git。

## 1. 最小安装 curl

在 VPS 上以 root 执行对应系统的命令，使用已配置且可信的发行版软件源。

### Debian 12 / 13

```sh
apt-get update &&
apt-get install -y --no-install-recommends curl ca-certificates &&
apt-get clean
```

不安装推荐包，只安装指定软件包及必要依赖；`ca-certificates` 用于 HTTPS 证书校验。配套重装系统已包含它，无需卸载或重复准备。最后清理下载的软件包缓存，不删除系统索引、日志，不执行 `autoremove`。

### Alpine

```sh
apk add --no-cache curl
```

curl 的官方依赖包含 libcurl 和 HTTPS 所需的 `ca-certificates-bundle`，无需为普通 HTTPS 下载额外安装完整的证书管理工具。`--no-cache` 不持久保存本次下载的索引缓存；不需要单独运行 `apk update`，也不需要安装 Bash。

以上是发行版官方软件包的最小正常安装方式，不自行编译或手动裁剪它们必需的库，不跳过 HTTPS 证书验证。

## 2. 保存脚本

使用已有的 `vi` 或 `nano` 新建 `fetch.sh`，粘贴下面完整内容并保存。无需为此额外安装编辑器。

```sh
#!/bin/sh
# GitHub 私有仓库单文件下载器：兼容 Debian /bin/sh 与 Alpine ash。
set +x
set +a
set -eu
umask 077
LC_ALL=C
export LC_ALL
unset fetch_token fetch_key
fetch_tmp=
fetch_tty=

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
cleanup() {
    fetch_status=$?
    trap - 0
    trap '' HUP INT TERM
    if [ -n "$fetch_tty" ]; then
        stty "$fetch_tty" </dev/tty || :
        printf '\n' >&2
    fi
    if [ -n "$fetch_tmp" ]; then
        if ! rm -f -- "$fetch_tmp"; then
            printf '错误：临时文件未能删除，请检查：%s\n' "$fetch_tmp" >&2
            fetch_status=1
        fi
    fi
    exit "$fetch_status"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

command -v curl >/dev/null 2>&1 || die '请先通过系统软件源安装 curl。'
printf '请粘贴 GitHub 文件页面网址：' >/dev/tty
IFS= read -r fetch_url </dev/tty || exit 1
fetch_url=${fetch_url%%[\?#]*}
case "$fetch_url" in
    https://github.com/*/*/blob/*/*) ;;
    *) die '请使用 GitHub 文件页面网址。' ;;
esac
fetch_path=${fetch_url#https://github.com/}
fetch_owner=${fetch_path%%/*}; fetch_path=${fetch_path#*/}
fetch_repo=${fetch_path%%/*}; fetch_path=${fetch_path#*/}
case "$fetch_path" in blob/*/*) ;; *) die '文件网址格式不正确。' ;; esac
fetch_path=${fetch_path#blob/}
fetch_ref=${fetch_path%%/*}; fetch_path=${fetch_path#*/}
[ -n "$fetch_owner" ] && [ -n "$fetch_repo" ] && [ -n "$fetch_ref" ] &&
    [ -n "$fetch_path" ] || die '文件网址缺少必要信息。'
fetch_api="https://api.github.com/repos/$fetch_owner/$fetch_repo/contents/$fetch_path?ref=$fetch_ref"

# 解码文件名中的 %HH，保留中文、空格和字面反斜线。
fetch_file=$(printf '%s\n' "${fetch_path##*/}" | awk '
BEGIN { digits="0123456789ABCDEF" }
{
    for (i=1; i<=length($0); i++) {
        c=substr($0,i,1)
        if (c=="%") {
            h=toupper(substr($0,i+1,2))
            a=index(digits,substr(h,1,1)); b=index(digits,substr(h,2,1))
            if (length(h)!=2 || !a || !b) exit 1
            n=(a-1)*16+b-1
            if (n<32 || n==127 || n==47) exit 1
            printf "%c", n
            i+=2
        } else {
            if (c ~ /[[:cntrl:]]/) exit 1
            printf "%s", c
        }
    }
}') || die '文件名编码不正确或含有不支持的字符。'
case "$fetch_file" in ''|.|..) die '文件名无效。' ;; esac
[ ! -e "./$fetch_file" ] && [ ! -L "./$fetch_file" ] ||
    die "当前目录已有同名文件，未覆盖：$fetch_file"

printf 'Token 内容不会回显；输入后会立即出现文字提示。\n' >/dev/tty
fetch_token=
fetch_notice=0
fetch_enter=$(printf '\n.')
fetch_return=$(printf '\r.')
fetch_backspace=$(printf '\010.')
fetch_delete=$(printf '\177.')
fetch_clear=$(printf '\025.')
fetch_clear_word=$(printf '\027.')
fetch_eof=$(printf '\004.')
fetch_tty=$(stty -g </dev/tty)
stty -echo -icanon min 1 time 0 </dev/tty
printf '请粘贴 GitHub Token，然后回车：' >/dev/tty
# 按字节读取只为即时反馈；末尾的点保留回车字节，不写入凭据文件。
while :; do
    fetch_key=$(dd bs=1 count=1 </dev/tty 2>/dev/null && printf '.') || exit 1
    case "$fetch_key" in
        "$fetch_enter"|"$fetch_return") break ;;
        .|"$fetch_eof") exit 1 ;;
        "$fetch_backspace"|"$fetch_delete") fetch_token=${fetch_token%?} ;;
        "$fetch_clear"|"$fetch_clear_word") fetch_token= ;;
        [[:print:]].) fetch_token=$fetch_token${fetch_key%.} ;;
        *) die '不支持的输入字符；请重新运行并直接粘贴 Token。' ;;
    esac
    if [ -n "$fetch_token" ] && [ "$fetch_notice" = 0 ]; then
        printf '已输入 Token，按回车开始下载。' >/dev/tty
        fetch_notice=1
    elif [ -z "$fetch_token" ] && [ "$fetch_notice" = 1 ]; then
        printf '\nToken 已清空，请重新粘贴：' >/dev/tty
        fetch_notice=0
    fi
done
unset fetch_key
stty "$fetch_tty" </dev/tty
fetch_tty=
printf '\n' >/dev/tty
[ -n "$fetch_token" ] || die 'Token 不能为空。'
printf '正在下载……\n' >&2

fetch_tmp=$(mktemp './.fetch.XXXXXXXX')
fetch_curl_status=0
fetch_http=$(printf 'Authorization: Bearer %s\n' "$fetch_token" |
    curl -q --fail --show-error --location --globoff \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 120 \
        --header @- \
        --header 'Accept: application/vnd.github.raw+json' \
        --write-out '%{http_code}' \
        --output "$fetch_tmp" "$fetch_api") || fetch_curl_status=$?
unset fetch_token

# 使用本次下载的结果判断，不额外请求认证接口、不保存错误响应。
if [ "$fetch_curl_status" -ne 0 ] && [ "$fetch_curl_status" -ne 22 ]; then
    case "$fetch_curl_status" in
        5|6) die '域名或代理解析失败，请检查网络和 DNS。' ;;
        7) die '无法建立连接，请检查网络或代理。' ;;
        28) die '下载超时，请检查网络后重试。' ;;
        35|51|60|77) die 'HTTPS 连接或证书校验失败，未降低安全校验。' ;;
        18|52|55|56) die '下载传输中断，文件未完整接收。' ;;
        23) die '无法完整写入下载文件，请检查磁盘空间和目录权限。' ;;
        *) die "下载失败（curl 状态：$fetch_curl_status），未保存为目标文件。" ;;
    esac
fi
case "$fetch_http" in
    200) [ "$fetch_curl_status" -eq 0 ] || die '下载未成功完成。' ;;
    401) die 'GitHub 认证失败，Token 可能输入有误、已过期或已撤销。' ;;
    403) die 'GitHub 拒绝访问，可能是权限、访问策略或请求频率限制。' ;;
    404) die '目标不可访问，请检查文件网址、分支和 Token 的仓库授权。' ;;
    429) die 'GitHub 请求过于频繁，请稍后重试。' ;;
    5??) die "GitHub 服务暂时异常（HTTP $fetch_http），请稍后重试。" ;;
    *) die "未收到预期的下载响应（HTTP ${fetch_http:-未知}），未保存为目标文件。" ;;
esac

# 同目录下载成功后才发布文件；即使出现同名文件竞争，也不覆盖。
ln -T -- "$fetch_tmp" "./$fetch_file" || die '保存失败，未覆盖任何已有文件。'
rm -f -- "$fetch_tmp"
fetch_tmp=
printf '\n下载成功：%s（尚未执行）\n' "$fetch_file"
```

## 3. 运行

在希望保存下载文件的目录中执行：

```sh
sh ./fetch.sh
```

不要求执行权限，不修改默认登录 Shell。如果脚本保存在其他目录，将 `./fetch.sh` 换成实际路径；下载文件仍保存到运行时的当前目录。

按提示依次输入：

1. 从 Chrome 复制的 GitHub 文件页面网址，例如 `https://github.com/username/aurora/blob/main/目录/文件.sh`。
2. 仅授权目标仓库、Contents 为 Read-only 的 GitHub Token。输入时不显示字符。

收到第一个输入字符后，会立即显示 `已输入 Token，按回车开始下载。`，无需先按回车；此时尚未开始下载。Token 本身、片段和长度均不显示。支持 Backspace 删除和 Ctrl+U 清空，清空后会提示重新粘贴；按回车后才提交下载，留空回车会提示 `Token 不能为空。`。这些提示仅确认输入状态，不代表已验证 Token 的完整性或 GitHub 权限。

支持多级文件夹、中文和空格文件名；分支名支持 `main`、`master` 等不含 `/` 的写法。下载使用原文件名，不覆盖已有同名文件，不自动执行下载内容。

## 下载失败时

回车后直接使用本次下载请求的结果判断，不额外调用认证接口，也不把格式检查当成 Token 有效性证明。

- `401`：提示 GitHub 认证失败，Token 可能输入有误、已过期或已撤销。
- `403`：提示可能存在权限、访问策略或频率限制；不直接归因于 Token 输入错误。
- `404`：提示检查文件网址、分支和仓库授权；不武断认定文件不存在。
- 网络、DNS、TLS、超时、传输中断和本地写入失败分别提示原因。

只有 curl 完整传输成功且最终返回 `200`，才保存为目标文件。输错 Token 或下载失败时，删除本次临时文件，不保留错误响应、残缺目标文件或 Token 缓存，不覆盖原有文件。如果文件系统故障导致临时文件无法删除，会明确报错并给出路径，不声称已经清理完成。

## 安全与清理

- Token 通过标准输入传给 curl，不放入 curl 的命令行参数或导出的环境变量，也不主动保存到文件。
- 强制 HTTPS，保留证书验证，限制连接和下载等待时间。
- 下载到当前目录的私有临时文件，成功后才发布为目标文件；最终文件权限为 `600`。
- 正常成功、下载失败或 Ctrl+C 退出时清理临时文件，并恢复终端回显。强制 `kill -9` 或断电不能触发清理，可能留下 `.fetch.*` 临时文件。
- 下载成功只代表传输完成，不代表脚本本身已经通过安全审查；执行前仍应核对独立可信的 SHA-256。
