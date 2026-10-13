# CareLite-Essential

> 开源健康师本地 AI 工作站 —— git clone 即用，连接 DeepSeek 帮健康师管理客户档案。

**状态：开发中（骨架阶段）**

## Quick Start

```bash
# 1. 克隆仓库
git clone https://github.com/your-org/carelite-essential.git
cd carelite-essential

# 2. 安装依赖
npm install

# 3. 启动开发服务器
npm run dev
```

浏览器访问 http://localhost:1420 即可。如需桌面打包，见 [docs/QUICK_START.md](docs/QUICK_START.md)。

## 功能模块

三端 + 一入口：

| 端 | 路径 | 说明 |
|----|------|------|
| 平台端 platform | `/platform/*` | 用户与档案管理 |
| 商户端 merchant | `/merchant/*` | 健康师工作台：客户档案 + 智能体 |
| 设置 settings | `/settings` | DeepSeek API Key 等配置 |

## 项目结构

```
carelite-essential/
├─ src/
│  ├─ pages/
│  │  ├─ platform/      # 平台端（用户管理）
│  │  ├─ merchant/      # 商户端（健康师工作台）
│  │  └─ settings/      # 设置
│  ├─ config/brand.ts   # 品牌常量
│  ├─ lib/              # pglite / deepseek / 适配层
│  ├─ App.tsx           # 路由入口
│  ├─ main.tsx          # React 入口
│  └─ index.css         # Tailwind + CSS 变量
├─ src-tauri/            # Tauri 2 桌面壳
├─ docs/                 # 文档
└─ index.html
```

## Roadmap

- **Phase 1：骨架** ← 当前。空目录 + 配置 + 占位组件。
- **Phase 2：模块迁移** —— 从 HMS 主项目 cherry-pick 用户/客户/智能体模块。
- **Phase 3：Tauri 打包** —— 桌面应用分发（nsis / msi）。
- **Phase 4：WorkBuddy 技能** —— 作为 WorkBuddy 技能被调用，详见 [docs/SKILL.md](docs/SKILL.md)。

## License

MIT
