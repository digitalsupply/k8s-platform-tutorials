#!/usr/bin/env bash
# 自动扩展 /dev/sda2 -> LVM PV -> 根文件系统 (安全版)
# 适用于磁盘扩容后 /dev/sda2 剩余空间未利用的场景。
# by Lei's DevOps helper

set -euo pipefail

echo "===== 自动扩容脚本开始 ====="

# 1️⃣ 基本检查
for cmd in lsblk growpart partprobe pvresize lvextend lvs vgs pvs; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "缺少命令: $cmd，请先安装。"
        missing=1
    fi
done
if [ "${missing:-0}" = 1 ]; then
    echo "请先安装缺少的命令后再运行。"
    exit 1
fi

# 2️⃣ 确认磁盘存在
if [ ! -b /dev/sda ]; then
    echo "未检测到 /dev/sda"
    exit 1
fi

# 3️⃣ 检测磁盘大小变化
disk_size=$(blockdev --getsize64 /dev/sda)
part_size=$(blockdev --getsize64 /dev/sda2 2>/dev/null || echo 0)
echo "磁盘: $((disk_size/1024/1024/1024))G, 分区: $((part_size/1024/1024/1024))G"

if [ "$disk_size" -le "$part_size" ]; then
    echo "磁盘与分区大小一致，无需扩容。"
else
    echo "检测到磁盘扩大，准备扩展 /dev/sda2 ..."
    if command -v growpart >/dev/null 2>&1; then
        growpart /dev/sda 2
    else
        parted -s /dev/sda resizepart 2 100%
    fi
    partprobe /dev/sda
    sleep 1
fi

# 4️⃣ 扩展 PV
echo ">>> 扩展 PV /dev/sda2 ..."
pvresize /dev/sda2

# 5️⃣ 获取 VG / LV 信息
vg_name=$(pvs --noheadings -o vg_name /dev/sda2 | awk 'NF{print $1; exit}')
[ -z "$vg_name" ] && { echo "未找到VG"; exit 1; }

root_lv=$(findmnt -n -o SOURCE /)
[ -z "$root_lv" ] && { echo "未找到根LV"; exit 1; }

echo "VG名称: $vg_name"
echo "根LV: $root_lv"

# 6️⃣ 查看 VG 可用空间
vg_free=$(vgs --noheadings -o vg_free --units g --nosuffix "$vg_name" | awk '{print int($1)}')
echo "VG可用空间: ${vg_free}G"

if [ "$vg_free" -le 0 ]; then
    echo "没有可用空间，无需扩容。"
    exit 0
fi

# 7️⃣ 扩展 root LV 到 VG 剩余空间
echo ">>> 扩展 LV ..."
lvextend -L +${vg_free}G "$root_lv" -r

# 若 -r 不可用，则分两步做（lvextend + 文件系统扩展）
if [ $? -ne 0 ]; then
    echo "lvextend -r 失败，尝试分步扩展..."
    lvextend -L +${vg_free}G "$root_lv"
    fs=$(findmnt -n -o FSTYPE /)
    if [ "$fs" = "xfs" ]; then
        xfs_growfs /
    elif [[ "$fs" =~ ext[234] ]]; then
        resize2fs "$root_lv"
    else
        echo "未知文件系统类型 $fs，请手动扩展。"
    fi
fi

# 8️⃣ 输出结果
echo "===== 扩容完成 ====="
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
vgs "$vg_name"
lvs -a -o +devices
df -hT /

echo "✅ 根分区扩容已完成！"

