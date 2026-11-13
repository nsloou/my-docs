
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="/etc/cake-shaper"
CONFIG_FILE="$CONFIG_DIR/config"
APPLY_SCRIPT="/usr/local/sbin/cake-shaper-apply"
SERVICE_FILE="/etc/systemd/system/cake-shaper.service"
IFB="ifb0"

log() {
    echo "[CAKE] $*"
}

fail() {
    echo "[错误] $*" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || fail "请使用 root 运行"

for cmd in ip tc awk systemctl grep modprobe; do
    command -v "$cmd" >/dev/null || fail "缺少命令：$cmd"
done

# 自动识别出口网卡
detect_wan() {
    local dev=""

    dev=$(ip -o route get 1.1.1.1 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')

    if [[ -z "$dev" ]]; then
        dev=$(ip -o route show default 2>/dev/null |
            awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    fi

    if [[ -z "$dev" ]]; then
        dev=$(ip -6 -o route show default 2>/dev/null |
            awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    fi

    [[ -n "$dev" && "$dev" != "lo" && "$dev" != "$IFB" ]] || return 1
    echo "$dev"
}

validate_rate() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
        awk -v n="$1" 'BEGIN {exit !(n > 0 && n <= 100000)}'
}

WAN=$(detect_wan) || fail "无法识别出口网卡"

OLD_DOWN="125"
OLD_UP="125"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    OLD_DOWN="${DOWN:-125}"
    OLD_UP="${UP:-125}"
fi

echo
echo "========== CAKE 双向限速配置 =========="
echo "自动识别网卡：$WAN"
echo "入口 IFB：$IFB"
echo

read -r -p "请输入下载限速 Mbps [$OLD_DOWN]：" DOWN
DOWN=${DOWN:-$OLD_DOWN}

read -r -p "请输入上传限速 Mbps [$OLD_UP]：" UP
UP=${UP:-$OLD_UP}

validate_rate "$DOWN" || fail "下载带宽数值无效"
validate_rate "$UP" || fail "上传带宽数值无效"

echo
echo "出口网卡：$WAN"
echo "下载限速：${DOWN} Mbps"
echo "上传限速：${UP} Mbps"
echo

read -r -p "确认覆盖并应用配置？[Y/n]：" CONFIRM
CONFIRM=${CONFIRM:-Y}

[[ "$CONFIRM" =~ ^[Yy]$ ]] || {
    echo "已取消"
    exit 0
}

mkdir -p "$CONFIG_DIR"

# 原子更新配置
cat > "$CONFIG_FILE.tmp" <<EOF
DOWN='$DOWN'
UP='$UP'
IFB='$IFB'
WAN='$WAN'
EOF

mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

# 安装实际应用程序
cat > "$APPLY_SCRIPT" <<'APPLY'
#!/usr/bin/env bash
set -Eeuo pipefail

source /etc/cake-shaper/config

log() {
    echo "[CAKE] $*"
}

fail() {
    echo "[错误] $*" >&2
    exit 1
}

# 检查物理网卡
ip link show dev "$WAN" >/dev/null 2>&1 ||
    fail "网卡 $WAN 不存在"

# 加载模块
for module in ifb sch_cake sch_ingress cls_matchall act_mirred; do
    modprobe "$module" 2>/dev/null || true
done

# 检查 IFB
if ! ip link show dev "$IFB" >/dev/null 2>&1; then
    ip link add "$IFB" type ifb ||
        fail "创建 IFB 失败"
else
    ip -d link show dev "$IFB" | grep -qw ifb ||
        fail "$IFB 已存在但不是 IFB 设备"
fi

ip link set dev "$IFB" up ||
    fail "启动 IFB 失败"

# 检查 ingress
if ! tc qdisc show dev "$WAN" |
    grep -Eq 'qdisc ingress ffff:'; then

    tc qdisc add dev "$WAN" handle ffff: ingress 2>/dev/null ||
        tc qdisc show dev "$WAN" |
        grep -Eq 'qdisc ingress ffff:' ||
        fail "创建 ingress 失败"
fi

# 配置上传 CAKE
tc qdisc replace dev "$WAN" root cake \
    bandwidth "${UP}mbit" \
    besteffort \
    triple-isolate \
    nat \
    nowash \
    no-ack-filter \
    split-gso \
    rtt 100ms \
    raw overhead 0 ||
    fail "出口 CAKE 配置失败"

# 配置下载 CAKE
tc qdisc replace dev "$IFB" root cake \
    bandwidth "${DOWN}mbit" \
    besteffort \
    triple-isolate \
    nat \
    nowash \
    ingress \
    no-ack-filter \
    split-gso \
    rtt 100ms \
    raw overhead 0 ||
    fail "入口 CAKE 配置失败"

# 检查现有重定向规则
FILTER_INFO=$(tc -s filter show dev "$WAN" parent ffff: 2>&1 || true)

if echo "$FILTER_INFO" | grep -Fq "device $IFB"; then

    log "入口重定向已正确指向 $IFB，直接复用"

elif echo "$FILTER_INFO" | grep -Eq 'pref 10([[:space:]]|$)'; then

    fail "pref 10 已被其他规则占用，拒绝覆盖，避免破坏现有规则"

else

    log "没有发现入口重定向，准备创建"

    tc filter add dev "$WAN" parent ffff: protocol all pref 10 \
        matchall \
        action mirred egress redirect dev "$IFB" ||
        fail "创建入口重定向失败"
fi

# 最终验证
FILTER_INFO=$(tc -s filter show dev "$WAN" parent ffff: 2>&1 || true)

echo "$FILTER_INFO" | grep -Fq "device $IFB" ||
    fail "入口重定向验证失败"

tc qdisc show dev "$WAN" | grep -q 'qdisc cake' ||
    fail "出口 CAKE 验证失败"

tc qdisc show dev "$IFB" | grep -q 'qdisc cake' ||
    fail "入口 CAKE 验证失败"

log "双向限速配置成功"
log "网卡：$WAN"
log "上传：${UP} Mbps"
log "下载：${DOWN} Mbps"

echo
echo "===== 出口 CAKE ====="
tc -d qdisc show dev "$WAN"

echo
echo "===== 入口 CAKE ====="
tc -d qdisc show dev "$IFB"

echo
echo "===== 入口重定向 ====="
tc -s filter show dev "$WAN" parent ffff:
APPLY

chmod 755 "$APPLY_SCRIPT"

# systemd 服务
cat > "$SERVICE_FILE" <<'SERVICE'
[Unit]
Description=CAKE Bidirectional Bandwidth Shaper
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cake-shaper-apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

chmod 644 "$SERVICE_FILE"

# 创建快捷命令
cat > /usr/local/sbin/cake-shaper <<'WRAPPER'
#!/usr/bin/env bash
exec /bin/bash /root/cake-shaper.sh "$@"
WRAPPER

chmod 755 /usr/local/sbin/cake-shaper

# 更新并启用服务
systemctl daemon-reload
systemctl enable cake-shaper.service >/dev/null

# 应用配置
systemctl restart cake-shaper.service ||
    fail "服务启动失败，请查看 journalctl -u cake-shaper.service"

echo
echo "========== 配置完成 =========="
echo "网卡：$WAN"
echo "上传：${UP} Mbps"
echo "下载：${DOWN} Mbps"
echo "开机自启：已启用"
