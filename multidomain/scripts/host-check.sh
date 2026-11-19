#!/bin/bash
# vps-mcp ホスト(subdomain/ multidomain/ full)の読み取り専用チェック。
# 何も変更しない。本番データ(ログの中身、IPアドレス、ファイル一覧など)は出さず、
# 版番号・設定値・件数だけを出力する。
#
# 使い方: make hostcheck  (または sudo bash scripts/host-check.sh)
# https://github.com/paijp/vps-mcp
# 結果をそのまま貼り付けて共有してよい形にしてある。

set -u
export LC_ALL=C
[ "$(id -u)" = 0 ] || { echo "root で実行してください (sudo bash $0)"; exit 1; }

h() { printf '\n== %s\n' "$*"; }
pkgs() { for p in "$@"; do rpm -q "$p" 2>/dev/null | grep -v 'not installed'; done; }
http2_count() { nginx -T 2>/dev/null | grep -cE '^[^#]*(http2[[:space:]]+on|listen[^;]*http2)'; }

h "host / os"
head -2 /etc/os-release | tr '\n' ' '; echo
echo "kernel(running): $(uname -r)   boot: $(uptime -s)"
echo "kernel(installed): $(rpm -q kernel-core 2>/dev/null | sed 's/kernel-core-//' | tr '\n' ' ')"
echo "reboot needed: $(dnf -q needs-restarting -r >/dev/null 2>&1 && echo no || echo YES)"

h "pending security updates (host)"
n=$(dnf -q updateinfo list --security 2>/dev/null | wc -l)
echo "count: $n"
[ "$n" -gt 0 ] && dnf -q updateinfo list --security 2>/dev/null | awk '{print $1, $2, $3}' | sort -u | head -30

h "all pending updates (host, security + other)"
o=$(dnf -q check-update 2>/dev/null | grep -cE '^[[:alnum:]_.+-]+\.(x86_64|noarch|aarch64|i686)[[:space:]]')
echo "count: $o"
[ "$o" -gt 0 ] && dnf -q check-update 2>/dev/null | grep -E '^[[:alnum:]_.+-]+\.(x86_64|noarch|aarch64|i686)[[:space:]]' | awk '{print $1, $2, $3}' | head -15

h "auto update / reboot"
grep -hE '^(upgrade_type|apply_updates|reboot) ' /etc/dnf/automatic.conf 2>/dev/null | tr '\n' ' '; echo
for t in dnf-automatic.timer dnf-automatic-install.timer vps-mcp-reboot.timer weekly-reboot.timer; do
  e=$(systemctl is-enabled "$t" 2>/dev/null); printf '%s=%s ' "$t" "${e:--}"
done; echo
systemctl list-timers --all --no-legend 2>/dev/null | grep -E 'reboot|dnf-automatic' | awk '{print $NF, "next:", $1, $2, $3}'

h "journald"
[ -d /var/log/journal ] && echo "persistent: yes" || echo "persistent: NO (volatile)"
journalctl --disk-usage 2>/dev/null
grep -rhE '^\s*SystemMaxUse' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/ 2>/dev/null || echo "SystemMaxUse: (default)"

h "sshd"
echo "drop-ins: $(ls /etc/ssh/sshd_config.d/ 2>/dev/null | tr '\n' ' ')"
echo "sysconfig OPTIONS: $(grep -hE '^OPTIONS=' /etc/sysconfig/sshd 2>/dev/null)"
echo "running: $(ps -o args= -C sshd | grep listener | head -1)"
sshd -T 2>/dev/null | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication) ' | tr '\n' ' '; echo
echo "(注) 起動引数の -oPasswordAuthentication=no は sshd -T に反映されない"
echo "failed password (7d): $(journalctl -u sshd --since -7days --no-pager 2>/dev/null | grep -c 'Failed password')"
echo "invalid user   (7d): $(journalctl -u sshd --since -7days --no-pager 2>/dev/null | grep -c 'Invalid user')"
echo "accepted login (7d): $(journalctl -u sshd --since -7days --no-pager 2>/dev/null | grep -c 'Accepted ')"

h "NoisyTCP (CVE-2026-99288) mitigation status"
echo "net.ipv4.tcp_syncookies=$(sysctl -n net.ipv4.tcp_syncookies)  rps_sock_flow_entries=$(cat /proc/sys/net/core/rps_sock_flow_entries)"
for d in /sys/class/net/*; do
  n=${d##*/}
  case "$n" in lo|veth*|podman*|cni*|virbr*|vpsmcp*|br-*) continue ;; esac
  q=$(ls -d "$d"/queues/rx-* 2>/dev/null | wc -l)
  rps=$(cat "$d"/queues/rx-0/rps_cpus 2>/dev/null)
  echo "$n rx_queues=$q rps_cpus=$rps"
done

h "host packages of interest"
pkgs nginx httpd mod_http2 php-fpm nodejs java-21-openjdk-headless java-25-openjdk-headless bind openssh-server openssl glibc postfix
for s in nginx httpd php-fpm named postfix vps-proxy443.socket vps-proxy80.socket; do
  printf '%s=%s ' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
done; echo
[ -f /etc/named.conf ] && echo "named GSS-TSIG directives: $(grep -rcE 'tkey-gssapi' /etc/named.conf /etc/named/ 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
echo "host nginx http2 directives: $(command -v nginx >/dev/null && http2_count || echo n/a)"

h "failed units / errors since boot"
echo "failed units: $(systemctl --failed --no-legend | wc -l)"
echo "err-level log lines since boot: $(journalctl -b -p err --no-pager 2>/dev/null | wc -l)"

h "disk"
df -h / | tail -1
podman system df 2>/dev/null

h "containers (running)"
if ! command -v podman >/dev/null; then echo "podman なし"; exit 0; fi
printf '%-36s %-6s %-12s %-6s %-14s %-16s %-10s %-10s %-5s %s\n' NAME OS NGINX HTTP2 PHP-FPM HTTPD MOD_HTTP2 NODE JAVA SECUPD
for c in $(podman ps --format '{{.Names}}'); do
  podman exec "$c" sh -c '
    os=$(sed -n "s/.*release \([0-9.]*\).*/\1/p" /etc/rocky-release 2>/dev/null)
    v() { rpm -q --qf "%{VERSION}-%{RELEASE}" "$1" 2>/dev/null | grep -v "not installed" | sed "s/\.el10.*//" || true; }
    st() { systemctl is-active "$1" 2>/dev/null | cut -c1-3; }
    ng=$(v nginx); h2=$(nginx -T 2>/dev/null | grep -cE "^[^#]*(http2[[:space:]]+on|listen[^;]*http2)")
    php=$(v php-fpm); [ -n "$php" ] && php="$php($(st php-fpm))"
    hd=$(v httpd);    [ -n "$hd" ]  && hd="$hd($(st httpd))"
    m2=$(v mod_http2)
    nd=$(v nodejs)
    jv=$(rpm -qa "java-*-openjdk-headless" 2>/dev/null | wc -l)
    su=$(dnf -q -C updateinfo list --security 2>/dev/null | wc -l)
    printf "%-6s %-12s %-6s %-14s %-16s %-10s %-10s %-5s %s\n" "${os:--}" "${ng:--}" "$h2" "${php:--}" "${hd:--}" "${m2:--}" "${nd:--}" "$jv" "$su"
  ' 2>/dev/null | sed "s|^|$(printf '%-36s ' "$c")|"
done
echo
echo "stopped containers: $(podman ps -a --filter status=exited --format '{{.Names}}' | wc -l)"
echo "(注) SECUPD はコンテナ内のキャッシュ(dnf -C)による件数。0 でも最新とは限らない"
