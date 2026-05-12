# Realm 转发管理面板

一个轻量化、交互式的命令行面板，专为快速部署和管理 Realm 端口转发服务而设计。

## 项目定位

Realm 是一款高效的网络中继工具。本脚本旨在通过 Shell 交互界面，屏蔽底层的系统服务配置与规则文件编写细节，使运维人员能够以更直观、安全的方式进行转发节点的增删改查操作，降低多节点管理的复杂度。

## 快速开始

提供两种调用方式，请根据目标服务器的网络连通性与实际使用场景选择：

**方式一：标准流式安装（推荐，适用于快速部署）**
```bash
curl -sSL https://raw.githubusercontent.com/NX2406/realm-deploy-script/refs/heads/main/realm_deploy.sh | bash
