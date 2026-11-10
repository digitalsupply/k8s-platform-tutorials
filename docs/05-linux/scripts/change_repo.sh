#!/bin/bash

# Rocky Linux 9 更换国内源脚本
# 作者：基于网络资源整理
# 用法：./change_repo.sh [源名称]，如 ./change_repo.sh aliyun 或不指定使用默认 (aliyun)

set -e  # 遇到错误立即退出

# 镜像源配置
declare -A MIRRORS=(
    ["aliyun"]="https://mirrors.aliyun.com/rockylinux"
    ["ustc"]="https://mirrors.ustc.edu.cn/rocky"
    ["sjtu"]="https://mirrors.sjtug.sjtu.edu.cn/rocky"
)

# 默认源
MIRROR=${1:-"aliyun"}
MIRROR_URL=${MIRRORS[$MIRROR]}

if [[ -z $MIRROR_URL ]]; then
    echo "错误：不支持的源 '$MIRROR'。支持：${!MIRRORS[*]}"
    exit 1
fi

echo "使用镜像源：$MIRROR ($MIRROR_URL)"

# 仓库文件列表（Rocky 9 默认仓库）
REPO_FILES=(
    "/etc/yum.repos.d/rocky.repo"
    "/etc/yum.repos.d/rocky-appstream.repo"
    "/etc/yum.repos.d/rocky-baseos.repo"
    "/etc/yum.repos.d/rocky-extras.repo"
)

# 检查文件是否存在
for file in "${REPO_FILES[@]}"; do
    if [[ ! -f $file ]]; then
        echo "警告：文件 $file 不存在，跳过。"
        continue
    fi

    # 备份原文件
    cp "$file" "${file}.bak"
    echo "备份：${file} -> ${file}.bak"

    # 替换配置：注释 mirrorlist，启用 baseurl
    sed -i \
        -e 's|^mirrorlist=|#mirrorlist=|g' \
        -e "s|^#baseurl=http://dl.rockylinux.org/\$contentdir|baseurl=${MIRROR_URL}|g" \
        "$file"

    echo "已更新：$file"
done

echo "更换完成！运行 'dnf clean all && dnf makecache' 更新缓存。"
echo "查看仓库：dnf repolist"
