#!/bin/bash

# 定义 VM ID 范围
START_ID=119
END_ID=124

# 循环启动 VM
for (( id=$START_ID; id<=$END_ID; id++ ))
do
    echo "Starting VM $id..."
    qm start $id
    if [ $? -eq 0 ]; then
        echo "VM $id started successfully."
    else
        echo "Failed to start VM $id."
    fi
    # 避免同时启动过多 VM，增加短暂延迟
    sleep 2
done

echo "All VMs from $START_ID to $END_ID have been processed."
