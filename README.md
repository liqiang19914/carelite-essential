# 小凯同学HMS 开源版：基于凯同AI Ignition 健康模型的本地优先 AI健康管理工作站

> 一套开箱即用的开源 **AI健康管理** 产品。零后端依赖、零数据泄露、本地运行。基于凯同AI **Ignition 多模态 MoE 健康模型**打造，专为健康师（营养师 / 健身教练 / 健康顾问）设计，管理客户档案、追踪体成分趋势、生成 AI 智能体，所有数据仅存于浏览器 IndexedDB。面向大健康行业的 AI健康管理 开源解决方案。

---

## 🔬 关于 Ignition 健康模型

小凯同学HMS 的 AI 能力底层来自**凯同AI 自研的 Ignition 健康模型**——国内首个面向大健康行业的**多模态 MoE（Mixture of Experts）世界模型**。

### Ignition 是什么？

> 一套模型、五个专家、按需协同、一个答案。

传统 AI 健康问答要么通用大模型不懂行业，要么垂直模型回答太窄。Ignition 的做法是：**一次提问，按需唤起五个专业专家协同推理，最终只输出一个可直接使用的答案**。

### Ignition 五大专家模块

| 专家 | 英文 | 能力 | 举例 |
|---|---|---|---|
| **循证医学** | Evidence | 自动检索 PubMed / Semantic Scholar 520 万+ 篇论文，结论可溯源可核验 | "NMN 对线粒体的证据强度有多高？" |
| **健康管理** | Profile | 记住用户的健康档案、体成分、历史打卡，给出个性化建议 | "根据我的体检指标给出改善方向" |
| **多模态感知** | Perception | 读取体检报告（PDF/图片）、识别食材照片、理解视频内容 | 拍下体检报告自动解读关键指标 |
| **内容与交互** | Content | 把结构化结论写成能直接发给客户的文案、短视频脚本、打卡内容 | "给我写一条适合朋友圈的营养小贴士" |
| **合规与增长** | Growth | 5 万+ 合规词库自动把关广告法 / 食品安全法红线，同时给出增长建议 | "这条健康声明合规吗？怎么改更安全？" |

### Ignition 的技术底座

- **自研大健康垂直大模型**：天然理解行业合规边界和用户心理，行业语义精准度远超通用模型
- **知识-数据双驱动飞轮**：创业者经营数据、用户健康数据、合规数据三类数据相互增强，越用越准
- **全链路合规引擎**：覆盖广告法、食品安全法、医疗器械法规，支持图文、视频、直播多模态实时审核
- **对标海外 OpenEvidence**：国内率先落地知识-数据双驱动的可信可解释健康 AI

### 官网链接

- 🧬 **Ignition 健康模型专属页**：<https://cell.caplinkai.com/>
- 🏢 **凯同AI 官网**：<https://caplinkai.com/>

---

## 🏥 关于小凯同学 HMS

**小凯同学**是凯同AI旗下的 **B2B2C 模式 AI 健康管理系统**，让大健康创业者（健康管理师 / 营养师 / 健身教练）用 AI 真正服务好他们的用户。

### 五维健康模型

小凯同学的核心健康框架——**每一维度均有诺贝尔奖级科研背书**：

| 维度 | 说明 | 科研背景 |
|---|---|---|
| 🥗 **饮食营养** | AI 定制个性化膳食方案，识别拍照分析食材营养成分 | 基于诺贝尔奖级营养科学研究 |
| 😴 **睡眠管理** | AI 优化睡眠质量，追踪睡眠周期，给出改善建议 | 整合诺贝尔生理学奖昼夜节律研究 |
| 💭 **情绪管理** | AI 赋能情绪健康干预，冥想引导、情绪日记、心理分析 | 结合诺贝尔奖级心理学研究成果 |
| 🏃 **运动打卡** | AI 制定科学运动计划并追踪执行，运动姿态分析 | 融合运动科学前沿研究 |
| 🧬 **长寿科技** | AI 辅助端粒酶与衰老研究，探索抗衰方案 | 汇聚诺贝尔奖级端粒酶与衰老研究 |

### 小凯同学商用版数据

- **10 万+ 服务用户**
- **500+ 企业客户**
- **20+ 软著**
- **200% 业务增长率**
- **服务效率提升 400%**（某健康管理机构案例）
- **用户复购率提升 180%**（某大健康 IP 案例）

### 凯同AI 生态

小凯同学是**凯同AI 三大核心产品线**之一：

| 产品线 | 定位 |
|---|---|
| **凯同AIP** | 大健康一站式 AI 营销平台（内容创作 → 精准获客全链路） |
| **小凯同学 HMS** | B2B2C AI 健康管理系统（商用版 + 本开源版） |
| **OpenClaw 私有家庭健康管家** | 基于小凯同学的私有化部署版本 |

### 凯同AI 公司背景

- **北京凯同汇联科技有限公司**旗下品牌
- 获得美元基金 **律格资本** 早期投资
- 作为律格资本投资生态成员，整合 **流量 + 技术 + 资本** 全方位服务
- 服务京东健康、美年健康、同仁堂、汤臣倍健、元气森林等 50+ 头部大健康企业

---

## 🏠 小凯同学HMS 开源版简介

**小凯同学HMS 开源版**（CapLite-Essential）是从商用产品裁出的**开源简版**。保留 Local-First 核心架构（PGlite + Tauri + WorkBuddy + Ignition 接入层），移除所有商业敏感模块（企微 / 支付 / OEM / 商户后台），打造一款**开箱即用、数据不出本机**的 AI 健康管理前端产品。

### 为什么选择 Local-First？

| 痛点 | 传统 SaaS | 小凯同学HMS 开源版 |
|---|---|---|
| 数据隐私 | 客户档案在第三方服务器 | **数据全存本机 IndexedDB** |
| 网络依赖 | 断网不可用 | **离线照常工作** |
| 部署成本 | 需要 Supabase / 后端 | **npm install 即可跑** |
| 定制门槛 | 锁死在供应商 API | **Supabase 兼容层可切换** |
| 桌面体验 | 只能挂浏览器标签 | **Tauri 打包原生桌面应用** |
| AI 底座 | 通用大模型不懂行业 | **可选接凯同AI Ignition 健康模型** |

### 两套开源仓库

| 仓库 | 定位 | 地址 |
|---|---|---|
| **GitHub caplite-essential** | 官方开源主仓库 | <https://github.com/liqiang19914/carelite-essential> |
| **GitCode hms** | CSDN 同步镜像 | <https://gitcode.com/m0_71921473/hms> |

---

## ✨ 核心特性

### 1. 🗄️ PGlite —— 浏览器里跑真 PostgreSQL

不像 Dexie / LocalStorage 这种 NoSQL 玩具，小凯同学HMS 开源版使用 **@electric-sql/pglite** 在浏览器 WASM 里运行真正的 PostgreSQL：

- **支持完整 SQL**：JOIN / 子查询 / 窗口函数 / 事务
- **890 张表的完整迁移**：从 HMS 商用版搬来，开箱即有数据结构
- **IndexedDB 持久化**：浏览器关闭后数据不丢
- **Supabase 兼容 API**：`supabase-adapter.ts` 让你写 `from().select().eq()` 跟真 Supabase 一模一样

### 2. 🤖 WorkBuddy 原生集成

WorkBuddy 是腾讯桌面 AI Agent 工作台。小凯同学HMS 开源版内置 WorkBuddy 技能注册体系（`src/lib/workbuddy.ts` + `src/skills/`）：

- **技能清单**：`manifest.json` 声明每个技能的 id / 参数 / 说明
- **技能实现**：TypeScript 编写，调用 PGlite 查询数据库
- **技能打包**：`npm run skills:pack` 生成 WorkBuddy 可直接加载的技能包
- **调用示例**：WorkBuddy 中对 AI 说「给我李强本周的体重趋势」→ AI 调用 `client-summary` 技能 → 返回结构化数据 + 文本摘要

### 3. 🖥️ Tauri 2 桌面壳

项目内置 `src-tauri/`，一行命令打包 Windows / macOS / Linux 桌面应用：

```bash
npm run tauri:build     # 打包当前平台安装包
npm run tauri:dev       # 桌面端开发模式
```

比 Electron 小 10 倍、内存占用低 3 倍。

### 4. 🧠 可选接入凯同AI Ignition 健康模型

开源版内置 LLM 接入层（`src/lib/deepseek.ts`），用户可以：

- **默认本地 mock**：不填任何 API Key，内置关键词匹配的健康建议示例
- **填自己的 LLM API Key**：走真实对话
- **接入凯同AI Ignition API**：获得完整的五维专家协同推理能力

### 5. 🔐 隐私保护

- **无 .env / 无密钥 / 无生产配置**：开源仓库里找不到任何 API Key 或生产域名
- **90+ 边缘函数 / 80+ 迁移 / 商户后台**：全部从开源版移除
- **Local-First 默认**：不填任何 env 直接运行，数据永远在本机
- **可切换自托管 Supabase**：如果团队需要多人协作，填一个 Supabase URL + Key 即可切换到远程模式

---

## 🏗️ 技术架构

```
┌──────────────────────────────────────────────────────────────┐
│               小凯同学HMS 开源版 (CapLite-Essential)           │
│                                                              │
│  ┌─────────────────┐  ┌────────────────┐  ┌─────────────┐  │
│  │  Tauri 2 桌面壳  │  │  浏览器直接运行  │  │  WorkBuddy  │  │
│  └────────┬────────┘  └───────┬────────┘  └──────┬──────┘  │
│           │                   │                  │          │
│  ┌────────▼───────────────────▼──────────────────▼────┐    │
│  │         React 18 + TypeScript + Vite 5               │    │
│  │  Router v7 · TanStack Query · Radix UI · Tailwind    │    │
│  └───────────────────────┬─────────────────────────────┘    │
│                          │                                   │
│  ┌───────────────────────▼─────────────────────────────┐    │
│  │      Supabase 兼容适配层 (supabase-adapter.ts)         │    │
│  │  from() / select() / insert() / rpc() / auth         │    │
│  └───────────────────────┬─────────────────────────────┘    │
│                          │                                   │
│  ┌───────────────────────▼─────────────────────────────┐    │
│  │  PGlite (WASM PostgreSQL) + IndexedDB 本地持久化      │    │
│  │         890 迁移 + seed 示例数据 + RLS 策略             │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │   可选接入：凯同AI Ignition 健康模型 API               │    │
│  │   (cell.caplinkai.com)                                │    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

### 技术栈一览

| 层 | 技术 |
|---|---|
| 前端 | React 18 + TypeScript + Vite 5 |
| 路由 | React Router v7 |
| 状态管理 | TanStack Query v5 |
| UI 组件 | Radix UI + Tailwind CSS + Lucide Icons |
| 本地数据库 | **@electric-sql/pglite** (PostgreSQL in WASM) |
| 桌面壳 | **Tauri 2** (比 Electron 小 10x) |
| AI 底座 | **凯同AI Ignition 健康模型** (可选接入) |
| LLM 兼容 | DeepSeek / OpenAI 兼容接口 |
| 技能系统 | WorkBuddy 原生技能注册体系 |
| 表单 | React Hook Form + Zod |

---

## 🚀 快速开始

### 环境要求

- Node.js **>= 18**
- npm 或 pnpm

### 一键运行

```bash
# 1. 克隆仓库
git clone https://github.com/liqiang19914/carelite-essential.git
cd carelite-essential

# 2. 安装依赖
npm install

# 3. 启动开发服务器（浏览器直接跑，无需任何 env）
npm run dev

# 4. 浏览器访问
# http://localhost:1420
```

### 打包桌面应用（可选）

```bash
# Windows NSIS 安装包
npm run tauri:build

# 或开发模式
npm run tauri:dev
```

### 连接自托管 Supabase（可选）

如果团队需要多人协作，可以切换到远程模式：

```bash
cp .env.example .env.local
# 填入 VITE_SUPABASE_URL 和 VITE_SUPABASE_ANON_KEY
```

### 接入凯同AI Ignition 健康模型（可选）

在设置页填入你的 Ignition API Key（联系凯同AI 获取），即可获得完整的五维专家协同推理能力：

- 📖 **循证医学**：自动检索 520 万+ 篇医学论文
- 🧠 **健康管理**：个性化档案与建议
- 👁️ **多模态感知**：拍照 / 体检报告识别
- ✍️ **内容与交互**：生成可直接使用的健康内容
- ⚖️ **合规与增长**：5 万+ 合规词库把关

---

## 🛠️ 功能模块

### 当前 v0.2.0 已实现

| 模块 | 路径 | 说明 |
|---|---|---|
| 平台端 | `/platform/*` | 用户与档案管理 |
| 健康师工作台 | `/merchant/*` | 客户档案 + 跟进管理 + 智能体 |
| 设置中心 | `/settings` | API Key 配置 / 数据管理 |
| PGlite 后端 | `src/lib/pglite-db.ts` | 浏览器端 PostgreSQL |
| Supabase 适配 | `src/lib/supabase-adapter.ts` | 800+ 行完整兼容层 |
| WorkBuddy 技能 | `src/lib/workbuddy.ts` + `src/skills/` | 技能注册 / 清单 / 打包 |
| LLM 接入 | `src/lib/deepseek.ts` | 流式对话 / Markdown |
| **Ignition 接入层** | `src/lib/` 可选接入 | 接凯同AI 健康模型 API |

### Roadmap

| Phase | 内容 | 状态 |
|---|---|---|
| 1 | 骨架（空目录 + PGlite 底座 + 配置 + 占位组件） | ✅ v0.1.0 |
| 2 | 品牌更名 + 顶部导航 + 开发指南页 | ✅ v0.2.0 |
| 3 | 用户端 AI 专家（6 个健康专家对话） | 🚧 迁移中 |
| 4 | 打卡面板（运动/情绪/睡眠/冥想/称重） | 🚧 迁移中 |
| 5 | 健康师完整工作台（仪表盘/称重/商品/课程/内容） | 🚧 迁移中 |
| 6 | Tauri 正式打包 + auto-update | 📋 规划中 |
| 7 | WorkBuddy 内置技能集（客户概况 / 体重趋势 / 营养分析） | 📋 规划中 |
| 8 | Ignition API 正式对接 + 示例 prompt 库 | 📋 规划中 |

---

## 🎯 WorkBuddy 集成详解

### 什么是 WorkBuddy？

WorkBuddy 是腾讯推出的桌面 AI Agent 工作台，能加载外部技能扩展能力。小凯同学HMS 开源版是首批内置 WorkBuddy 技能注册体系的开源健康管理项目。

### 技能体系架构

```
src/skills/
├── manifest.json       # 技能清单（id / 参数 / 说明）
├── builtin.ts          # 内置技能实现
└── (未来更多技能文件)

src/lib/
└── workbuddy.ts        # 技能注册 / 执行 / 校验 核心层
```

### 内置技能示例

```typescript
// 注册一个技能
registerSkill({
  id: "client-summary",
  name: "客户概况统计",
  description: "查询指定客户的基本档案与健康概况",
  parameters: [
    { name: "clientId", description: "客户 ID", required: true },
  ],
  run: async ({ clientId }) => {
    const { data } = await supabase
      .from("profiles")
      .select("*, weight_records(*)")
      .eq("id", clientId as string)
      .single();
    return {
      ok: true,
      output: `客户档案：${data?.name}，最近体重 ${data?.weight_records?.[0]?.weight}kg`,
      data,
    };
  },
});
```

### 打包成 WorkBuddy 可加载的技能

```bash
npm run skills:pack
# 输出 dist/skills/ 目录，WorkBuddy 可直接加载
```

---

## 📁 项目结构

```
carelite-essential/
├── src/
│   ├── pages/
│   │   ├── platform/      # 平台端（用户管理）
│   │   ├── merchant/      # 健康师工作台
│   │   └── settings/      # 设置中心
│   ├── lib/
│   │   ├── pglite-db.ts      # PGlite 初始化 + bootstrap + seed
│   │   ├── supabase-adapter.ts # Supabase 兼容适配层（835 行）
│   │   ├── workbuddy.ts      # WorkBuddy 技能注册体系
│   │   ├── deepseek.ts       # LLM API 封装
│   │   └── ignition.ts       # 凯同AI Ignition 接入层（可选）
│   ├── skills/
│   │   ├── manifest.json     # 技能清单
│   │   └── builtin.ts        # 内置技能实现
│   ├── components/           # Radix UI + 业务组件
│   ├── contexts/              # Auth / Brand 等 Context
│   ├── hooks/                 # TanStack Query hooks
│   ├── App.tsx                # 路由入口
│   └── main.tsx               # React 入口
├── src-tauri/                 # Tauri 2 桌面壳
│   ├── Cargo.toml
│   ├── tauri.conf.json
│   └── build.rs
├── supabase/
│   └── migrations/            # 890 个迁移 + seed 数据
├── docs/                      # 开发文档
├── package.json
├── vite.config.ts
├── tailwind.config.js
└── README.md
```

---

## 🔒 隐私与安全

| 措施 | 说明 |
|---|---|
| 开源仓库无密钥 | `.env.local` / `.env` 已 `.gitignore`，仓库内零 API Key |
| Local-First 默认 | 不填任何 env 也能跑，数据仅存 IndexedDB |
| 迁移文件全公开 | 890 个 SQL 迁移可审计，无隐藏逻辑 |
| Edge Function 删干净 | 90+ 边缘函数全部移除，用本地处理器替代 |
| 商业敏感模块移除 | 企微 / 支付 / OEM / 商户后台 / SuperRun / miniprogram 均不包含 |

---

## 📦 与商用版的关系

| 维度 | 小凯同学HMS 商用版 (私有) | 小凯同学HMS 开源版 (public) |
|---|---|---|
| 定位 | 完整商业产品 | 本地优先 AI 健康师工作站 |
| 部署 | SuperRun 壳 / Capacitor / SXX | PGlite + Tauri |
| 数据 | Supabase + 90+ 边缘函数 | 浏览器 PGlite / 可选自托管 |
| AI 底座 | **Ignition 健康模型** 深度集成 | 可选接入 Ignition / 默认 mock |
| 功能 | 商户后台 / OEM / 企微 / 支付 / 小程序 | 健康师工作台 + WorkBuddy |
| 仓库 | `liqiang19914/CAPLINK-HMS` (private) | `liqiang19914/carelite-essential` (public) |

**开源版 = 商用版裁掉商业敏感模块 + 换上 PGlite Local-First 后端 + 内置 WorkBuddy 技能体系。**

---

## 🔗 相关链接

### 小凯同学 HMS 开源版

| 链接 | 地址 |
|---|---|
| GitHub 开源主仓库 | <https://github.com/liqiang19914/carelite-essential> |
| GitCode CSDN 镜像 | <https://gitcode.com/m0_71921473/hms> |
| HMS 商用版（私有） | <https://github.com/liqiang19914/CAPLINK-HMS> |

### 凯同AI 官方

| 链接 | 地址 |
|---|---|
| 凯同AI 官网 | **<https://caplinkai.com/>** |
| Ignition 健康模型 | **<https://cell.caplinkai.com/>** |
| 小凯同学 HMS 产品页 | <https://hms.caplinkai.com/presentation> |
| 凯同AIP AI 营销平台 | <https://tool.caplinkai.com/> |
| OpenClaw 私有管家 | <https://hms.caplinkai.com/openclaw-guide> |
| 大健康产业云图 | <https://hao.caplinkai.com/> |

### 技术参考

| 链接 | 地址 |
|---|---|
| PGlite 官方仓库 | <https://github.com/electric-sql/pglite> |
| Tauri 官方文档 | <https://tauri.app> |

---

## 📄 许可证

**MIT License** — 可自由使用、修改、分发、商用。详见仓库根目录 `LICENSE` 文件。

---

## 🤝 欢迎贡献

Issue / PR 一律欢迎。特别是：

- 🧪 帮我们完善 TypeScript 严格检查警告（~20 个待修）
- 🧩 贡献更多 WorkBuddy 内置技能
- 📖 改进文档 / 翻译多语言 README
- 🖥️ 测试不同平台 Tauri 打包
- 🔬 帮我们接入 Ignition 健康模型的更多能力

**让健康管理软件变得透明、私密、开箱即用。**

---

## 💡 关于凯同AI

**凯同AI** 是北京凯同汇联科技有限公司旗下品牌，获得美元基金 **律格资本** 早期投资。聚焦健康新消费产业，以 AI 驱动行业进步为使命，提供：

- **技术驱动**：Ignition 健康模型 + 全链路合规引擎 + 行业数据飞轮
- **产业深耕**：500+ 企业客户，10 万+ 服务用户
- **生态优势**：依托律格资本投资生态，整合流量 / 技术 / 资本资源
- **合规安全**：严格遵守健康数据隐私法规

让我们一起，用 AI 赋能健康新消费产业未来。
