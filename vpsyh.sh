#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# 通用 VPS 初始优化脚本 (Swap + 智能BBR参数)
# 适用：各种配置的 VPS (512M / 1G / 2G / 4G...)
# 功能：
# 1. 自动检查 Swap，如果没有或不够，自动创建 (小内存救星)
# 2. 自动识别 VPS 内存大小，计算最佳 TCP 窗口参数 (防止 OOM)
# 3. 清理旧的 sysctl 冲突配置
# ==============================================================================

# --- 全局配置 (可按需微调) ---
# 默认带宽 (Mbps)，如果不想手动输，就按这个算 (1Gbps是目前主流)
DEFAULT_BW=1000
# 默认延迟 (ms)，通用值 150ms 适合大多数美西/欧洲线路。如果是东亚直连，BBR 会自动适应，不用太纠结
DEFAULT_RTT=150

# 颜色
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
PLAIN='\033[0m'

echo_info() { echo -e "${BLUE}[信息]${PLAIN} $1"; }
echo_ok()   { echo -e "${GREEN}[成功]${PLAIN} $1"; }
echo_warn() { echo -e "${YELLOW}[注意]${PLAIN} $1"; }
echo_err()  { echo -e "${RED}[错误]${PLAIN} $1"; }

require_root() { if [ "${EUID:-$(id -u)}" -ne 0 ]; then echo_err "请使用 root 运行"; exit 1; fi; }

# ==============================================================================
# 第一部分：智能 Swap 配置
# 逻辑：
# 1. 如果已有 Swap，跳过。
# 2. 如果内存 < 2GB，创建 1.5GB Swap (小鸡保命)。
# 3. 如果内存 >= 2GB，创建 1GB Swap (够用就行)。
# ==============================================================================
configure_swap() {
    echo_info "Step 1/2: 检查 Swap 配置..."
    
    # 检查是否存在 swap
    if [ $(free -m | grep -i swap | awk '{print $2}') -gt 0 ]; then
        echo_ok "检测到系统已存在 Swap，跳过创建。"
    else
        # 获取物理内存大小 (MB)
        MEM_TOTAL_MB=$(free -m | awk '/^Mem:/{print $2}')
        
        # 确定 Swap 大小
        if [ "$MEM_TOTAL_MB" -lt 2048 ]; then
            SWAP_SIZE="1536M" # 1.5GB
        else
            SWAP_SIZE="1024M" # 1GB
        fi
        
        echo_warn "未检测到 Swap，检测到物理内存 ${MEM_TOTAL_MB}MB，准备创建 ${SWAP_SIZE} Swap..."
        
        fallocate -l $SWAP_SIZE /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=${SWAP_SIZE%M}
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        
        # 写入 fstab
        if grep -q "/swapfile" /etc/fstab; then
            echo_ok "fstab 已存在配置"
        else
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        
        echo_ok "Swap 创建成功！"
    fi
}

# ==============================================================================
# 第二部分：BBR 调优 (自动获取内存版)
# ==============================================================================
optimize_bbr() {
    echo_info "Step 2/2: 开始 BBR 智能调优..."
    
    # --- 自动获取参数 ---
    # 1. 自动获取内存 (GiB)
    MEM_G=$(awk '/MemTotal/ { printf "%.2f", $2/1024/1024 }' /proc/meminfo)
    
    # 2. 设定带宽和延迟 (使用默认值，或者你可以改成 read 交互式，但一键脚本建议自动化)
    # 这里为了通用性，直接使用顶部定义的默认值，不再询问
    BW_Mbps=$DEFAULT_BW
    RTT_ms=$DEFAULT_RTT
    
    echo_info "检测配置 -> 内存: ${MEM_G} GiB | 设定基准 -> 带宽: ${BW_Mbps} Mbps, 延迟: ${RTT_ms} ms"

    # --- 计算逻辑 (核心) ---
    # BDP = Mbps * 125 * ms (bytes)
    BDP_BYTES=$(awk -v bw="$BW_Mbps" -v rtt="$RTT_ms" 'BEGIN{ printf "%.0f", bw*125*rtt }')
    MEM_BYTES=$(awk -v g="$MEM_G" 'BEGIN{ printf "%.0f", g*1024*1024*1024 }')
    
    # 限制最大 buffer：min(2*BDP, 3%RAM, 64MB)
    TWO_BDP=$(( BDP_BYTES*2 ))
    RAM3_BYTES=$(awk -v m="$MEM_BYTES" 'BEGIN{ printf "%.0f", m*0.03 }')
    CAP64=$(( 64*1024*1024 ))
    
    MAX_NUM_BYTES=$(awk -v a="$TWO_BDP" -v b="$RAM3_BYTES" -v c="$CAP64" 'BEGIN{ m=a; if(b<m)m=b; if(c<m)m=c; printf "%.0f", m }')

    # 向下取整到 {4,8,16,32,64} MB 桶
    bucket_le_mb() {
      local mb="${1:-0}"
      if   [ "$mb" -ge 64 ]; then echo 64
      elif [ "$mb" -ge 32 ]; then echo 32
      elif [ "$mb" -ge 16 ]; then echo 16
      elif [ "$mb" -ge  8 ]; then echo 8
      elif [ "$mb" -ge  4 ]; then echo 4
      else echo 4
      fi
    }
    
    MAX_MB_NUM=$(( MAX_NUM_BYTES/1024/1024 ))
    MAX_MB=$(bucket_le_mb "$MAX_MB_NUM")
    MAX_BYTES=$(( MAX_MB*1024*1024 ))

    # 设定默认读写值
    if [ "$MAX_MB" -ge 32 ]; then
      DEF_R=262144; DEF_W=524288
    elif [ "$MAX_MB" -ge 8 ]; then
      DEF_R=131072; DEF_W=262144
    else
      DEF_R=131072; DEF_W=131072
    fi

    TCP_RMEM_MIN=4096; TCP_RMEM_DEF=87380; TCP_RMEM_MAX=$MAX_BYTES
    TCP_WMEM_MIN=4096; TCP_WMEM_DEF=65536; TCP_WMEM_MAX=$MAX_BYTES

    # --- 清理冲突 ---
    SYSCTL_TARGET="/etc/sysctl.d/999-net-bbr-fq.conf"
    KEY_REGEX='^(net\.core\.default_qdisc|net\.core\.rmem_max|net\.core\.wmem_max|net\.core\.rmem_default|net\.core\.wmem_default|net\.ipv4\.tcp_rmem|net\.ipv4\.tcp_wmem|net\.ipv4\.tcp_congestion_control)[[:space:]]*='

    # 清理 sysctl.conf
    if [ -f "/etc/sysctl.conf" ]; then
        if grep -Eq "$KEY_REGEX" "/etc/sysctl.conf"; then
            echo_warn "发现 /etc/sysctl.conf 存在冲突，正在注释..."
            awk -v re="$KEY_REGEX" '$0 ~ re && $0 !~ /^[[:space:]]*#/ { print "# " $0; next } { print $0 }' "/etc/sysctl.conf" > "/etc/sysctl.conf.tmp"
            mv "/etc/sysctl.conf.tmp" "/etc/sysctl.conf"
        fi
    fi
    
    # 删除 sysctl.d 下的冲突文件
    if [ -d "/etc/sysctl.d" ]; then
        for f in /etc/sysctl.d/*.conf; do
            [ -e "$f" ] || continue
            [ "$(readlink -f "$f")" = "$(readlink -f "$SYSCTL_TARGET")" ] && continue
            if grep -Eq "$KEY_REGEX" "$f"; then
                echo_warn "删除冲突文件: $f"
                rm -f "$f"
            fi
        done
    fi

    # --- 启用 BBR ---
    if command -v modprobe >/dev/null 2>&1; then modprobe tcp_bbr 2>/dev/null || true; fi

    # --- 写入配置 ---
    cat >"$SYSCTL_TARGET" <<EOF
# Auto-generated by VPS Optimization Script
# Optimized for: RAM=${MEM_G}GiB, Bucket=${MAX_MB}MB

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_default = ${DEF_R}
net.core.wmem_default = ${DEF_W}
net.core.rmem_max = ${MAX_BYTES}
net.core.wmem_max = ${MAX_BYTES}

net.ipv4.tcp_rmem = ${TCP_RMEM_MIN} ${TCP_RMEM_DEF} ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = ${TCP_WMEM_MIN} ${TCP_WMEM_DEF} ${TCP_WMEM_MAX}

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
EOF

    # 应用配置
    sysctl --system >/dev/null
    
    echo_ok "BBR 优化完成！当前限制桶值: ${MAX_MB} MB"
}

# ==============================================================================
# 主执行流程
# ==============================================================================
main() {
    require_root
    configure_swap
    optimize_bbr
    
    echo_ok "------------------------------------------------"
    echo_ok " 所有优化已完成！建议重启一次 VPS 以确保 Swap 挂载稳定。"
    echo_ok "------------------------------------------------"
}

main
