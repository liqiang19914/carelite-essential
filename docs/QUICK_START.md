# Quick Start 详细步骤

## 1. 环境要求

- Node.js ≥ 18
- npm ≥ 9（或 pnpm / yarn）
- 如需桌面打包：Rust toolchain（`rustup`）+ Tauri 2 系统依赖

## 2. 安装

```bash
git clone https://github.com/your-org/carelite-essential.git
cd carelite-essential
npm install
```

## 3. 启动 Web 开发服务器

```bash
npm run dev
```

访问 http://localhost:1420。

## 4. 启动 Tauri 桌面应用（可选）

确保已安装 [Rust](https://rustup.rs) 与 Tauri 2 依赖：

```bash
npm run tauri:dev
```

## 5. 配置 DeepSeek API Key（待迁移）

> 当前为骨架，DeepSeek 接入待 cherry-pick。占位入口在 `/settings` 页面。

计划配置方式（待实现）：

在项目根目录创建 `.env.local`：

```bash
# DeepSeek API Key（从 https://platform.deepseek.com 获取）
VITE_DEEPSEEK_API_KEY=sk-xxxxxxxxxxxxxxxx
VITE_DEEPSEEK_BASE_URL=https://api.deepseek.com
```

> ⚠️ 开源版仅本地使用，Key 保存在本地不外发。

## 6. 构建

```bash
# Web 构建
npm run build

# 桌面打包
npm run tauri:build
```
