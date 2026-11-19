#!/bin/sh
# GitHub 私有仓库单文件下载器：兼容 Debian /bin/sh 与 Alpine ash。
# Token 在本地缓存 24 小时；缓存权限为 600，目录权限为 700。
set +x
set +a
set -eu
umask 077
LC_ALL=C
export LC_ALL
unset fetch_token fetch_key fetch_cache_token
fetch_tmp=
fetch_cache_tmp=
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
    unset fetch_token fetch_key fetch_cache_token
    if [ -n "$fetch_tmp" ]; then
        if ! rm -f -- "$fetch_tmp"; then
            printf '错误：下载临时文件未能删除，请检查：%s\n' "$fetch_tmp" >&2
            fetch_status=1
        fi
    fi
    if [ -n "$fetch_cache_tmp" ]; then
        if ! rm -f -- "$fetch_cache_tmp"; then
            printf '错误：Token 临时文件未能删除，请检查：%s\n' "$fetch_cache_tmp" >&2
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
command -v stat >/dev/null 2>&1 || die '缺少 stat 命令，无法安全检查 Token 缓存权限。'
command -v mktemp >/dev/null 2>&1 || die '缺少 mktemp 命令。'

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

# Token 缓存目录位于当前用户 HOME 下；不跟随目录或缓存文件的符号链接。
fetch_home=${HOME:-}
case "$fetch_home" in
    /*) ;;
    *) die 'HOME 未设置或不是绝对路径，无法安全保存 Token 缓存。' ;;
esac
fetch_config_dir=$fetch_home/.config
fetch_cache_dir=$fetch_config_dir/github
fetch_cache_file=$fetch_cache_dir/fetch-token
fetch_uid=$(id -u) || die '无法确定当前用户 ID。'

[ ! -L "$fetch_config_dir" ] || die '配置目录是符号链接，拒绝使用 Token 缓存。'
[ ! -L "$fetch_cache_dir" ] || die 'Token 缓存目录是符号链接，拒绝继续。'
mkdir -p "$fetch_cache_dir" || die '无法创建 Token 缓存目录。'
[ -d "$fetch_cache_dir" ] && [ ! -L "$fetch_cache_dir" ] ||
    die 'Token 缓存路径不是安全的普通目录。'
fetch_dir_uid=$(stat -c '%u' "$fetch_cache_dir") ||
    die '无法检查 Token 缓存目录所有者。'
[ "$fetch_dir_uid" = "$fetch_uid" ] ||
    die 'Token 缓存目录不属于当前用户，请检查目录所有权。'
chmod 700 "$fetch_cache_dir" || die '无法设置 Token 缓存目录权限。'

# 读取缓存：第一行是 Unix 过期时间，第二行是 Token。
fetch_token=
fetch_cache_valid=0
if [ -e "$fetch_cache_file" ] || [ -L "$fetch_cache_file" ]; then
    [ -f "$fetch_cache_file" ] && [ ! -L "$fetch_cache_file" ] ||
        die 'Token 缓存不是普通文件或是符号链接，拒绝读取。'
    fetch_file_uid=$(stat -c '%u' "$fetch_cache_file") ||
        die '无法检查 Token 缓存文件所有者。'
    [ "$fetch_file_uid" = "$fetch_uid" ] ||
        die 'Token 缓存文件不属于当前用户，拒绝读取。'
    chmod 600 "$fetch_cache_file" || die '无法设置 Token 缓存文件权限。'
    fetch_cache_expiry=
    fetch_cache_token=
    {
        IFS= read -r fetch_cache_expiry || :
        IFS= read -r fetch_cache_token || :
    } <"$fetch_cache_file"
    case "$fetch_cache_expiry" in
        ''|*[!0-9]*) ;;
        *)
            fetch_now=$(date +%s) || die '无法读取系统时间。'
            case "$fetch_now" in
                ''|*[!0-9]*) die '系统时间格式异常。' ;;
            esac
            if [ -n "$fetch_cache_token" ] &&
                [ "$fetch_cache_expiry" -gt "$fetch_now" ] 2>/dev/null; then
                fetch_token=$fetch_cache_token
                fetch_cache_valid=1
            fi
            ;;
    esac
fi
unset fetch_cache_token

# 交互式隐藏输入；保留原脚本的退格、清空及即时提示行为。
read_token() {
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
    fetch_tty=$(stty -g </dev/tty) || die '无法读取终端设置。'
    stty -echo -icanon min 1 time 0 </dev/tty || die '无法设置隐藏输入模式。'
    printf '请粘贴 GitHub Token，然后回车：' >/dev/tty
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
    stty "$fetch_tty" </dev/tty || die '无法恢复终端设置。'
    fetch_tty=
    printf '\n' >/dev/tty
    [ -n "$fetch_token" ] || die 'Token 不能为空。'
}

# 同目录临时文件 + mv，确保缓存更新时不会留下半份凭据。
save_token() {
    fetch_now=$(date +%s) || die '无法读取系统时间。'
    case "$fetch_now" in
        ''|*[!0-9]*) die '系统时间格式异常。' ;;
    esac
    fetch_expiry=$((fetch_now + 86400))
    fetch_cache_tmp=$(mktemp "$fetch_cache_dir/.fetch-token.XXXXXXXX") ||
        die '无法创建 Token 缓存临时文件。'
    chmod 600 "$fetch_cache_tmp" || die '无法设置 Token 临时文件权限。'
    printf '%s\n%s\n' "$fetch_expiry" "$fetch_token" >"$fetch_cache_tmp" ||
        die '无法写入 Token 缓存。'
    mv -f -- "$fetch_cache_tmp" "$fetch_cache_file" ||
        die '无法安全更新 Token 缓存。'
    fetch_cache_tmp=
}

if [ "$fetch_cache_valid" -eq 1 ]; then
    printf '已读取本地 Token 缓存。\n' >&2
else
    if [ -e "$fetch_cache_file" ]; then
        printf '本地 Token 缓存不存在有效凭据或已过期，需要更新。\n' >&2
    fi
    read_token
    save_token
fi
printf '正在下载……\n' >&2

fetch_tmp=$(mktemp './.fetch.XXXXXXXX') || die '无法创建下载临时文件。'
fetch_attempt=0
while :; do
    : >"$fetch_tmp" || die '无法写入下载临时文件。'
    fetch_curl_status=0
    fetch_http=$(printf 'Authorization: Bearer %s\n' "$fetch_token" |
        curl -q --fail --show-error --location --globoff \
            --proto '=https' --proto-redir '=https' \
            --connect-timeout 15 --max-time 120 \
            --header @- \
            --header 'Accept: application/vnd.github.raw+json' \
            --write-out '%{http_code}' \
            --output "$fetch_tmp" "$fetch_api") || fetch_curl_status=$?

    # Token 可能被提前撤销：只允许重新输入并重试一次。
    if [ "$fetch_http" = 401 ] && [ "$fetch_attempt" -eq 0 ]; then
        printf 'GitHub 认证失败，当前 Token 可能已失效。\n' >&2
        unset fetch_token
        read_token
        save_token
        fetch_attempt=1
        continue
    fi
    break
done
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
    401) die 'GitHub 认证失败，新 Token 仍不可用，请检查 Token。' ;;
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
