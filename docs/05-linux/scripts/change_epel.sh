#!/bin/bash

# Rocky Linux 9 更换 EPEL 国内源脚本
# 用法：./change_epel_repo.sh [源名称]，如 ./change_epel_repo.sh aliyun 或不指定使用默认 (aliyun)

set -e

# 镜像源配置
declare -A MIRRORS=(
    ["aliyun"]="https://mirrors.aliyun.com/epel"
    ["ustc"]="https://mirrors.ustc.edu.cn/epel"
    ["tsinghua"]="https://mirrors.tuna.tsinghua.edu.cn/epel"
)

# 默认源
MIRROR=${1:-"aliyun"}
MIRROR_URL=${MIRRORS[$MIRROR]}

if [[ -z $MIRROR_URL ]]; then
    echo "错误：不支持的源 '$MIRROR'。支持：${!MIRRORS[*]}"
    exit 1
fi

echo "使用 EPEL 镜像源：$MIRROR ($MIRROR_URL)"

# EPEL 配置文件
REPO_FILES=(
    "/etc/yum.repos.d/epel.repo"
    "/etc/yum.repos.d/epel-testing.repo"
)

# 检查 EPEL 是否安装
if [[ ! -f /etc/yum.repos.d/epel.repo ]]; then
    echo "错误：EPEL 仓库未安装，请先运行 'sudo dnf install epel-release'"
    exit 1
fi

# 替换配置
for file in "${REPO_FILES[@]}"; do
    if [[ ! -f $file ]]; then
        echo "警告：文件 $file 不存在，跳过。"
        continue
    fi

    # 备份原文件
    sudo cp "$file" "${file}.bak"
    echo "备份：${file} -> ${file}.bak"

    # 替换 mirrorlist 为 baseurl
    sudo sed -i \
        -e 's|^mirrorlist=|#mirrorlist=|g' \
        -e "s|^#baseurl=.*|baseurl=${MIRROR_URL}/\$releasever/Everything/\$basearch|g" \
        "$file"

    echo "已更新：$file"
done

echo "EPEL 源更换完成！运行 'dnf clean all && dnf makecache' 更新缓存。"
echo "查看仓库：dnf repolist"
