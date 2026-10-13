# CareLite-Essential 迁移工单

源项目：`D:\dev\hms`（健康管理主项目）
目标项目：`D:\dev\carelite-essential`（开源健康师本地 AI 工作站）
本地化基线：`D:\dev\carelite`（已完成 PGlite + supabase-adapter，可直接复用）

## 标签约定

- `[KEEP]` 原样迁入
- `[KEEP-SIMPLIFY]` 迁入并简化
- `[REPLACE]` 替换为本地实现（PGlite / bcrypt / DeepSeek 直连）
- `[REMOVE]` 不迁入
- `[NEW]` 源项目无，需新建

## Phase 划分

- **Phase 1** 底座层（必先做）：client.ts / AuthContext / edgeInvoke / UI 组件 / brand
- **Phase 2** 业务层：用户管理 / 客户管理 / AI 对话
- **Phase 3** 设置层：DeepSeek 配置 / 数据库路径 / WorkBuddy 技能注册
- **Phase 4** 桌面打包：Tauri CI 出包 / Skill 分支发布

---

## Phase 1 — 底座层（迁移第一优先级）

> ✅ **Phase 1 已完成（2026-10-12）**
> - 复制类（直接复用 carelite 现成文件）：1.3 / 1.4 / 1.5 / 1.14 / 1.15 ✅
> - 重写类（基于 carelite/hms 改造）：1.1 / 1.2 / 1.6 / 1.9 / 1.11 / 1.12 ✅
> - 复制类（hms 原样迁入）：1.8 / 1.13 ✅
> - 新建类：1.10 已在骨架创建 ✅
> - 推迟类：1.7 edgeInvoke → localAiService 抽象层 留到 Phase 2C AI 对话时处理 ⏸️
> - 收尾验证：补 33 个 shadcn 依赖（@radix-ui/* / cmdk / embla-carousel-react / input-otp / react-day-picker / react-hook-form / react-resizable-panels / next-themes / zod / @hookform/resolvers）；创建 src/vite-env.d.ts 声明 ?raw 与 vite/client；tsconfig 加 allowImportingTsExtensions；build 脚本改为 `vite build`（与 carelite/hms 一致，不阻塞打包），新增 `typecheck` 脚本（可选）；`npm install` 346 包通过；`npm run build` 产物完整（dist/index.html + index.css + index.js + 3 个 WASM 资源）✅
> - 微调：pglite-db.ts 的 DATA_DIR 改为 `idb://carelite-essential`；supabase-adapter.ts 的 sessionKey 改为 `carelite_essential_session`（区分 carelite 项目，避免开发期 IndexedDB/localStorage 共用）

| # | 源路径 | 目标路径 | 标签 | 改造点 |
|---|--------|----------|------|--------|
| 1.1 | `src/integrations/supabase/client.ts` | `src/integrations/supabase/client.ts` | [REPLACE] | 改为 `export const supabase = localSupabase`（直接复用 `D:\dev\carelite\src\lib\supabase-adapter.ts`） |
| 1.2 | `src/integrations/supabase/types.ts` | 同 | [REPLACE] | 删除 reportInterpretation 字段后重生成 |
| 1.3 | `D:\dev\carelite\src\lib\pglite-db.ts` | `src/lib/pglite-db.ts` | [KEEP] | 直接复用，含 bootstrap/migrations/patches/seed 流程 |
| 1.4 | `D:\dev\carelite\src\lib\supabase-adapter.ts` | `src/lib/supabase-adapter.ts` | [KEEP] | 直接复用，已实现 from/auth/rpc/functions.invoke |
| 1.5 | `D:\dev\carelite\public\wasm\*` | `public/wasm/` | [KEEP] | pglite.wasm / initdb.wasm / pglite.data，3 个 WASM 资源 |
| 1.6 | `src/contexts/AuthContext.tsx` | `src/contexts/AuthContext.tsx` | [REPLACE] | 重写为本地 session：去掉 mp_token / 双身份 / Supabase Auth；保留 session/user 基本结构 |
| 1.7 | `src/lib/edgeInvoke.ts` | `src/lib/edgeInvoke.ts` | [REPLACE] | 全站 77 文件依赖的 Edge Functions 入口；改为本地 `localAiService` 抽象层，路由到 DeepSeek 直连 |
| 1.8 | `src/components/ui/`（46 个 shadcn/ui） | `src/components/ui/` | [KEEP] | 整目录复制：accordion/alert-dialog/avatar/badge/button/card/checkbox/dialog/dropdown-menu/form/input/label/popover/select/separator/sheet/skeleton/sonner/switch/table/tabs/textarea/tooltip 等 |
| 1.9 | `src/contexts/BrandContext.tsx` | `src/contexts/BrandContext.tsx` | [REPLACE] | 全是 OEM 白牌逻辑（mp_manager → sessionStorage → system_settings 覆盖），重写为读 `src/config/brand.ts` 静态常量 |
| 1.10 | — | `src/config/brand.ts` | [NEW] | 已在骨架创建，静态 `{ name, tagline, version }` |
| 1.11 | `src/components/ProtectedRoute.tsx` | 同 | [KEEP-SIMPLIFY] | 改读本地 session，去掉 mp_manager 分支 |
| 1.12 | `D:\dev\carelite\src\main.tsx` | `src/main.tsx` | [KEEP-SIMPLIFY] | 复用加载屏 + getDb() 初始化流程，去掉 miniprogram/iPad/WeChat 设置 |
| 1.13 | `src/lib/utils.ts`（cn 函数等） | 同 | [KEEP] | Tailwind className 合并工具 |
| 1.14 | `D:\dev\carelite\supabase\bootstrap.sql` / `patches.sql` / `seed.sql` | `supabase/` | [KEEP] | 直接复用 CareLite 已跑通的 PGlite 启动脚本 |
| 1.15 | `D:\dev\carelite\supabase\migrations\`（890 个，82.5% 成功） | `supabase/migrations/` | [KEEP] | 直接复用，失败迁移已被 patches.sql 修补 |

**风险**：HMS 主项目 200+ supabase migrations 是增量 SQL，但 CareLite 已经验证 890 个迁移在 PGlite 上跑通，**不要从 HMS 重新迁**，直接用 CareLite 的现成数据库层。

---

## Phase 2 — 业务层

> ✅ **2A 平台端用户管理已完成（2026-10-12）**
> - 2A.1 UsersPage.tsx：搜索/注册时间筛选/统计卡（总数·正常·已禁用）/响应式列表/禁用·启用·重置密码(bcrypt 直写 auth.users)·删除账号；去掉商户绑定、积分、一键登录、开通商户身份、商城会员
> - 2A.2 useUsers.ts：PGlite 直查 profiles + health_records GROUP BY 档案数；无 edgeInvoke
> - 2A.3 UserProfilePage.tsx：新建档案详情页（基本信息 + 健康档案列表 + 最近体征）
> - 2A.4/2A.5 ListPagination / RegisteredDateRangeFilter 原样迁入；补 useIsMobile(去 iPad 检测) / usePagination / QueryErrorState / rpc-error
> - ⚠️ 顺带修复 Phase 1 缺口：tailwind.config.js 补全 shadcn 主题 token（colors/radius/shadow/font/keyframes + container-queries 插件），index.css 补全 :root/.dark 变量与 status-tag/pc-*/chat-bubble/animate-fade-up 组件类
> - `npm run build` 通过（8.14s）

> ✅ **2B 商户端客户管理已完成（2026-10-12）**
> - 2B.1 ClientsPage.tsx：搜索/建档日期/提醒日期/BMI/标签筛选、列显隐（localStorage `client-table-hidden-columns`）、DataTable（多选/sticky 客户列/BmiStatusBadge/提醒 overdue·today·upcoming 图标）、批量打标签+导出所选 CSV、详情/编辑双模式 Sheet（editDirty + UnsavedLeaveDialog）、删除确认、回收站入口
> - 2B.2 useClients.ts [REPLACE]：PGlite 直查 client_relations LEFT JOIN profiles（替代源项目 RPC get_manager_clients）；标签经适配器查 client_tag_relations 带 FK join；提醒用 DISTINCT ON 取最新 next_follow_up_at；BMI 由 vital_signs 最新体重 + health_records 户主身高 LATERAL 计算，内存筛选；createClient 按手机号复用/新建 profiles 再建 client_relations；addFollowUp 插记录并刷新 last_contact_at；导出 useFollowUpRecords
> - 2B.3 useClientsWorkbench.ts [KEEP-SIMPLIFY]：去掉企业管理员/权限/会员套餐逻辑，纯单健康师编排层（筛选/分页/表单/标签切换）
> - 2B.4-2B.9 详情/表单/编辑/跟进/标签创建/回收站组件全部迁入；ClientDetailPanel 去掉 AssignmentHistorySection、TransferClientDialog、useEnterpriseAccess、商城会员行、企微条件禁用；导出 TAG_CHIP_CLASS 供列表复用
> - 2B.10 ClientAttributesImportDialog 未迁移（依赖 clientAttributesImportTemplate lib，按需后补）⏸️
> - 2B.11-2B.14 批量转移/积分历史/会员联系/称重导入 [REMOVE] ✅
> - 2B.15 clientRelations.ts [REPLACE]：softDelete/restore/purge/rename 本地实现，purge 走 db.transaction 级联删 tag_relations + follow_up_records + relation
> - 支撑层：desktop/shell（PageContainer 去 density/PageHeader/PanelCard）、desktop/data（DataTable/FilterBar/BulkActionBar/StatusBadge）、desktop/form（FieldGrid/UnsavedLeaveDialog）、BmiStatusBadge、useDesktopTableSelection、lib（bmiStatus/phone-mask/csv-download）
> - 收尾修复：注册 `/merchant/clients/:id` 路由（复用 UserProfilePage，返回按钮改 navigate(-1) 双入口兼容）；详情面板"进入健康档案"修正为传 client_id（原误传 relation id）；确认 client_relations.customer_name 列在迁移 20260822224412 中已存在，无需补丁
> - `npm run build` 通过（8.46s；路由修复后复验 5.43s）

> ✅ **2C 健康师智能体已完成（2026-10-12）**
> - 2C.1 AssistantPanel.tsx [NEW]：源 SiteChatPanel 是建站智能体，仅借鉴流式 UI 骨架；新建健康师视角面板（快捷话术 4 条/消息气泡/复制按钮/流式光标/TypingDots/错误条/字数限制 2000）
> - 2C.2 useAssistantChat.ts [REPLACE]：SYSTEM_PROMPT 健康师人设；send({message, context}) 把客户档案注入 system prompt；callDeepSeekStream onDelta 累加 streamingText
> - 2C.3 确认 UserManagerChat 是用户（客户）视角，健康师视角无现成承载页 → 新建 AssistantPage（Select 客户选择器，选中后传 clientName/clientContext）
> - 2C.4 deepseek.ts [NEW]：直连 `https://api.deepseek.com/v1/chat/completions`，API Key 从 system_settings 读（key=`deepseek_api_key`，与 Phase 3 设置页衔接），SSE 解析 `data: ` 行 + `[DONE]` 终止；callDeepSeek / callDeepSeekStream / hasDeepSeekApiKey
> - 2C.5-2C.7 报告解读 hook/卡片/报告页 [REMOVE] ✅
> - `npm run build` 通过（8.41s）

### 2A 平台端 · 用户管理

| # | 源路径 | 目标路径 | 标签 | 改造点 |
|---|--------|----------|------|--------|
| 2A.1 | `src/pages/desktop/AdminCustomers.tsx` | `src/pages/platform/UsersPage.tsx` | [KEEP-SIMPLIFY] | 实际入口（不是 AdminUsers.tsx 死代码）；去掉 merchant 绑定、adminReviewManager EF 调用 |
| 2A.2 | `src/hooks/useUsers.ts` | `src/hooks/useUsers.ts` | [REPLACE] | 改用 PGlite 直查 profiles + system_settings；去掉 edgeInvoke |
| 2A.3 | — | `src/pages/platform/UserProfilePage.tsx` | [NEW] | HMS 平台端无独立档案页（在 AdminCustomers 内联），需新建抽屉式详情面板 |
| 2A.4 | `src/components/ListPagination.tsx` | 同 | [KEEP] | 分页组件 |
| 2A.5 | `src/components/RegisteredDateRangeFilter.tsx` | 同 | [KEEP] | 日期筛选 |
| 2A.6 | `src/pages/desktop/AdminUsers.tsx` | — | [REMOVE] | 已是死代码，**不要被文件名误导** |
| 2A.7 | `src/pages/desktop/AdminMerchants.tsx` | — | [REMOVE] | 商户管理页（多租户）不迁入 |

### 2B 商户端 · 客户管理

| # | 源路径 | 目标路径 | 标签 | 改造点 |
|---|--------|----------|------|--------|
| 2B.1 | `src/pages/desktop/manager/ManagerClientsDesktop.tsx` | `src/pages/merchant/ClientsPage.tsx` | [KEEP-SIMPLIFY] | 客户工作台主页；去掉 WeighingImportDialog / PointsHistoryDialog / useTransferManagerClients |
| 2B.2 | `src/hooks/useClients.ts` | 同 | [KEEP-SIMPLIFY] | 去掉 `services/managerWecom`、`services/privacySettings`，保留 `services/clientRelations` |
| 2B.3 | `src/hooks/controllers/useClientsWorkbench.ts` | 同 | [KEEP-SIMPLIFY] | 列表/筛选/批量编排层 |
| 2B.4 | `src/components/desktop/manager/ClientDetailPanel.tsx` | 同 | [KEEP] | 客户详情抽屉 |
| 2B.5 | `src/components/desktop/manager/ClientFormDialog.tsx` + `ClientFormFields.tsx` | 同 | [KEEP] | 客户表单 |
| 2B.6 | `src/components/desktop/manager/ClientEditSheet.tsx` | 同 | [KEEP] | 编辑侧栏 |
| 2B.7 | `src/components/desktop/manager/ClientFollowUpDialog.tsx` | 同 | [KEEP] | 跟进弹窗 |
| 2B.8 | `src/components/desktop/manager/ClientTagCreateDialog.tsx` | 同 | [KEEP] | 标签创建 |
| 2B.9 | `src/components/desktop/manager/ClientRecycleBinSheet.tsx` | 同 | [KEEP] | 回收站 |
| 2B.10 | `src/components/desktop/manager/ClientAttributesImportDialog.tsx` | 同 | [KEEP] | 属性导入 |
| 2B.11 | `src/components/desktop/manager/BulkTransferClientDialog.tsx` | — | [REMOVE] | 批量转移（多租户逻辑） |
| 2B.12 | `src/components/desktop/manager/PointsHistoryDialog.tsx` | — | [REMOVE] | 积分历史 |
| 2B.13 | `src/components/manager/MembershipContactDialog.tsx` | — | [REMOVE] | 会员联系 |
| 2B.14 | `src/components/desktop/WeighingImportDialog.tsx` | — | [REMOVE] | 称重导入 |
| 2B.15 | `src/services/clientRelations.ts` | 同 | [KEEP-SIMPLIFY] | 客户关系 service，去 wecom 引用 |

### 2C 健康师智能体 / AI 对话

| # | 源路径 | 目标路径 | 标签 | 改造点 |
|---|--------|----------|------|--------|
| 2C.1 | `src/components/site/SiteChatPanel.tsx` | `src/components/merchant/AssistantPanel.tsx` | [KEEP-SIMPLIFY] | ⚠️ 这是建站智能体，非健康师对话；保留对话 UI 骨架，改 prompt 模板 |
| 2C.2 | `src/hooks/useSiteAiChat.ts` | `src/hooks/useAssistantChat.ts` | [REPLACE] | SSE 流式 hook，改为直连 DeepSeek `/v1/chat/completions` stream |
| 2C.3 | `src/pages/mobile/UserXiaokaiChat.tsx` / `UserOpenClawChat.tsx` / `UserManagerChat.tsx` | — | [INVESTIGATE] | 健康师对话具体承载页未确认，需读源码确认哪个是健康师 vs 用户视角 |
| 2C.4 | — | `src/lib/deepseek.ts` | [NEW] | DeepSeek 直连：API Key 从 system_settings 读，SSE 流式 + messages 历史 + 客户档案注入 context |
| 2C.5 | `src/hooks/useReportInterpretation.ts` | — | [REMOVE] | 报告解读 hook |
| 2C.6 | `src/components/mobile/ReportInterpretationCard.tsx` | — | [REMOVE] | 报告解读卡片 |
| 2C.7 | `src/pages/mobile/UserReports.tsx` | — | [REMOVE] | 报告页（含 reportInterpretation） |

---

## Phase 3 — 设置层

> ✅ **Phase 3 设置层已完成（2026-10-13）**
> - 3.1 SettingsPage.tsx [KEEP-SIMPLIFY]：DeepSeek 配置卡（API Key 密文/显示切换、模型 Select deepseek-chat·deepseek-reasoner、接口地址兼容 …/ 或 …/v1，自动拼 /chat/completions）；保存 upsert system_settings 三键（deepseek_api_key / deepseek_model / deepseek_base_url）；测试连接用表单当前值直连（callDeepSeekDirect，非 Edge Function）
> - 3.2 数据库卡 [KEEP-SIMPLIFY]：只读信息（引擎 PGlite / 存储位置 idb://carelite-essential / 活跃客户·跟进·档案计数 / IndexedDB 持久化 + 数据备份提示），合并到 SettingsPage 单页
> - 3.5 workbuddy.ts [NEW]：WorkBuddySkill/Result/Parameter 类型 + registerSkill/getRegisteredSkills/runSkill（存在性检查 + 必填参数校验 + 异常降级）+ getSkillManifest/validateManifest 清单校验；约定：src/skills/manifest.json 声明清单、技能文件调 registerSkill() 注册、外部经 runSkill(id, params) 调用
> - 3.6 skills/manifest.json [NEW]：3 个技能清单（client-summary 客户概况统计 / health-check 健康档案速览 / followup-suggest 跟进提醒盘点）；skills/builtin.ts [NEW] 内置技能实现（PGlite 参数化查询，BMI 分级/逾期优先排序），SettingsPage 挂载时幂等注册并在技能卡展示注册状态
> - 配套改造：deepseek.ts 重构为配置化（getDeepSeekConfig 从 system_settings 读三键有默认值回退；chatUrl 兼容 baseUrl 变体；callDeepSeekDirect 显式配置供测试连接），与设置页保存即时衔接
> - `npm run build` 通过（5.58s）；typecheck 本批新文件零错误（遗留错误均为 Phase 1/2 既有文件，另计）

| # | 源路径 | 目标路径 | 标签 | 改造点 |
|---|--------|----------|------|--------|
| 3.1 | `src/pages/desktop/AdminModels.tsx:153-158` | `src/pages/settings/SettingsPage.tsx` | [KEEP-SIMPLIFY] | DeepSeek provider 配置（baseUrl=`https://api.deepseek.com`，model=`deepseek-chat, deepseek-reasoner`）；从 system_settings 读写 key |
| 3.2 | `src/pages/desktop/AdminSystem.tsx` | `src/pages/settings/SettingsPage.tsx` | [KEEP-SIMPLIFY] | 数据库路径切换入口（合并到 SettingsPage 单页） |
| 3.3 | `src/pages/desktop/AdminDisplaySettings.tsx` | — | [REMOVE] | OEM 品牌配置，开源版用静态 brand.ts |
| 3.4 | `src/pages/desktop/AdminMiniProgram.tsx` | — | [REMOVE] | 小程序品牌配置 |
| 3.5 | — | `src/lib/workbuddy.ts` | [NEW] | WorkBuddy 技能注册入口：定义技能目录约定、入口协议 |
| 3.6 | — | `src/skills/manifest.json` | [NEW] | 技能清单（HealthCheck / ClientSummary / FollowupSuggest 等） |

---

## Phase 4 — 桌面打包

> ✅ **Phase 4 已完成（2026-10-13）**
> - 4.1 src-tauri 骨架核对：Cargo.toml（carelite-essential 0.1.0）/ build.rs / main.rs / capabilities（default: core:default）与 carelite 参考一致；tauri.conf.json 确认 devUrl 1420 = vite server.port、frontendDist ../dist 对应 vite build 产物；bundle.targets 由 `["nsis","msi"]` 改为 `"all"`（避免 macOS/Linux CI 按 Windows 固定目标构建失败）✅
> - 4.2 图标：文生图 API 产出源图（JPEG）→ PowerShell System.Drawing 转 1024×1024 PNG（app-icon.png，仓库根目录）→ 本机 `npx tauri icon`（@tauri-apps/cli v2 devDependency，纯 JS 无需 Rust）生成全套图标（32x32 / 128x128 / 128x128@2x / icon.icns / icon.ico / Square*Logo / StoreLogo），删除 android/ios 移动端图标目录；package.json 新增 `icons` 再生成脚本 ✅
> - 4.3 CI 出包：新建 `.github/workflows/release.yml`（推送 `v*` 标签触发）：tauri-action 多平台矩阵（windows-latest / macos-latest aarch64+x86_64 / ubuntu-22.04），Node 20 + Rust stable + rust-cache（src-tauri → target），Linux 装 webkit2gtk-4.1 等系统依赖；自动创建 GitHub Release 并上传各平台安装包 ✅
> - 4.4 Skill 分支发布：新建 `scripts/pack-skills.mjs`（读 src/skills/manifest.json → 生成 `dist-skills/<skill-id>/SKILL.md` + README.md + manifest.json，frontmatter 含 name/description 供 WorkBuddy 识别）；CI 第二 job 用 peaceiris/actions-gh-pages@v4 将 dist-skills 发布到 `skills` 分支（force_orphan，每次发版覆盖）；npm 脚本 `skills:pack`；本地已跑通（3 技能：client-summary / health-check / followup-suggest）✅
> - 收尾验证：`npm run build` 通过（5.63s）；tauri.conf.json JSON 校验通过；本机无 Rust 工具链（Windows SAC 阻塞），桌面安装包编译验证由 CI 承担
> - ⚠️ 前置依赖：项目尚未 git init / 配置 GitHub 远程 — 推送到 GitHub 并打 `v0.1.0` 标签后，release workflow 才会出包、skills 分支才会生成

| # | 任务 | 标签 | 说明 |
|---|------|------|------|
| 4.1 | 复用 `D:\dev\carelite\src-tauri\` 结构 | [KEEP-SIMPLIFY] | 骨架已建，Cargo.toml/build.rs/main.rs/tauri.conf.json 就位 |
| 4.2 | 图标生成 | [NEW] | 用 `cargo tauri icon` 生成全套图标 |
| 4.3 | CI 编译配置 | [NEW] | GitHub Actions workflow（Windows SAC 阻塞本机编译，必须走 CI） |
| 4.4 | Skill 分支发布 | [NEW] | 打包为 WorkBuddy 可识别的技能目录结构 |

---

## 要移除的模块清单（不迁入）

### 商城
- `src/pages/mobile/UserShop*.tsx`、`UserOrders.tsx`、`UserCheckout.tsx`、`StorefrontShopPage.tsx`、`ProductShareRedirect.tsx`
- `src/pages/desktop/AdminShop.tsx`、`AdminOrders.tsx`、`AdminStores.tsx`
- `src/services/shopOrders.ts`、`store.ts`、`shopModules.ts`、`platformWechatPay.ts`、`managerWechatPay.ts`、`orderLifecycle.ts`、`managerOrders.ts`
- ⚠️ `shopModules.ts` 含 `merchant_module_grants`，是移除多租户授权的源头

### 企微
- `src/pages/wecom/WecomSidebarPage.tsx`、`src/pages/desktop/manager/wecomsuper/`（MassComposer / shared）
- `src/services/managerWecom*.ts`、`wecomKf.ts`
- `src/hooks/useWechatVoice.ts`、`useWechatScan.ts`、`useWechatLogin.ts`

### 小程序壳
- `src/lib/miniprogram-utils.ts`、`src/components/MpEnvSync.tsx`、`src/lib/appNavigation.ts`（isWechatMiniProgramEnvSync）
- `src/hooks/useWechatMiniProgram.ts`、`src/pages/desktop/AdminMiniProgram.tsx`

### OEM 白牌
- `src/services/oemBrand.ts`
- `src/contexts/BrandContext.tsx`（全部重写，不保留原逻辑）

### 营销 / 积分 / 会员
- `src/pages/mobile/UserPromotionCenter.tsx`、`UserLottery.tsx`、`UserLive.tsx`、`UserPoints.tsx`、`UserReputation*.tsx`、`PromoterLanding.tsx`
- `src/services/points.ts`、`managerCard.ts`、`acquisitionIntegration.ts`、`merchantChannels.ts`
- `src/pages/desktop/AdminMembershipLeads.tsx`、`AdminAcquisition.tsx`、`AdminCourses.tsx`、`AdminContent.tsx`

---

## 鉴权重写要点

- `supabase.auth` 调用统计：17 个文件 37 处（重灾区：LoginPage 8、AuthContext 4、store 4、UserProfile 3）
- 全量改写为本地 service：`supabase.auth.signInWithPassword` → `localSupabase.auth.signInWithPassword`（supabase-adapter 已实现）
- `src/components/ProtectedRoute.tsx` / `ManagerApprovalGate.tsx` / `ManagerAccessGate.tsx` 改读本地 session
- `src/lib/identityAccess.ts` / `src/services/myEmployments.ts`：双身份/就业关系，开源版裁剪为单角色

---

## 关键风险提示

1. **不要从 HMS 重新迁数据库**：CareLite 已经验证 890 个迁移在 PGlite 上跑通（82.5% 成功，patches.sql 补救），直接复用 `D:\dev\carelite\supabase\`
2. **77 文件依赖 Edge Functions**：必须先建 `src/lib/localAiService.ts` 抽象层再逐文件替换，不要一次性全改
3. **WorkBuddy 技能注册在源项目零代码积累**：是新建项，不是迁移项
4. **AdminUsers.tsx 是死代码**：不要被文件名误导，实际入口是 `AdminCustomers.tsx`
5. **SiteChatPanel 是建站智能体**：不是健康师对话，保留 UI 骨架但需改 prompt 模板；健康师对话具体承载页需读 `UserXiaokaiChat` / `UserManagerChat` 确认
6. **Tauri 本机编译被 SAC 阻塞**：必须走 CI 出包，本机只跑前端 dev
7. **BrandContext 全是 OEM 逻辑**：重写，不要试图改造

---

## Top 10 必迁入文件（按优先级）

1. `src/integrations/supabase/client.ts` → PGlite client（全局数据访问底座）
2. `src/contexts/AuthContext.tsx` → 本地 bcrypt session Provider
3. `src/lib/edgeInvoke.ts` → 本地 AI service 入口（77 文件依赖）
4. `src/hooks/useUsers.ts` + `src/pages/desktop/AdminCustomers.tsx` → 平台端用户管理
5. `src/hooks/useClients.ts` + `src/hooks/controllers/useClientsWorkbench.ts` → 商户端客户管理
6. `src/pages/desktop/manager/ManagerClientsDesktop.tsx` + `src/components/desktop/manager/Client*.tsx`（9 件套）→ 客户工作台
7. `src/components/ui/`（46 个 shadcn/ui）→ UI 底座，整目录复制
8. `src/contexts/BrandContext.tsx` → 重写为开源版品牌 Provider
9. `src/pages/desktop/AdminModels.tsx` → DeepSeek API Key 配置入口
10. `src/components/site/SiteChatPanel.tsx` + `src/hooks/useSiteAiChat.ts` → AI 对话面板骨架

---

## 执行顺序建议

```
Week 1: Phase 1.1-1.7 底座层（client/AuthContext/edgeInvoke/UI/brand/pglite-db/adapter）
Week 2: Phase 1.8-1.15 补齐底座（main.tsx/ProtectedRoute/utils/migrations）
Week 3: Phase 2A 平台端用户管理
Week 4: Phase 2B 商户端客户管理
Week 5: Phase 2C 健康师智能体 + DeepSeek 直连
Week 6: Phase 3 设置层 + WorkBuddy 技能注册
Week 7: Phase 4 Tauri CI + Skill 分支
```
