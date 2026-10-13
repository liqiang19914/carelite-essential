/**
 * 内置技能实现：与 manifest.json 清单一一对应
 * 由 SettingsPage 挂载时调用 registerBuiltinSkills() 注册（幂等）
 */
import { registerSkill } from "@/lib/workbuddy";
import { getDb } from "@/lib/pglite-db";

const BMI_LABEL: Record<string, string> = {
  underweight: "偏瘦",
  normal: "正常",
  overweight: "超重",
  obese: "肥胖",
};

export function registerBuiltinSkills() {
  // ── 客户概况统计 ──
  registerSkill({
    id: "client-summary",
    name: "客户概况统计",
    description: "统计活跃客户总数、本周新增与回收站数量",
    parameters: [],
    run: async () => {
      const db = await getDb();
      const r = await db.query<{
        total: number;
        active: number;
        deleted: number;
        week_new: number;
      }>(
        `SELECT count(*)::int AS total,
                count(*) FILTER (WHERE status = 'active')::int AS active,
                count(*) FILTER (WHERE status = 'deleted')::int AS deleted,
                count(*) FILTER (WHERE created_at >= date_trunc('week', now()))::int AS week_new
         FROM client_relations`,
      );
      const s = r.rows[0];
      return {
        ok: true,
        output: `当前共 ${s.total} 名客户：活跃 ${s.active} 名（本周新增 ${s.week_new}），回收站 ${s.deleted} 条。`,
        data: s,
      };
    },
  });

  // ── 健康档案速览 ──
  registerSkill({
    id: "health-check",
    name: "健康档案速览",
    description: "按客户 ID 汇总健康档案列表与最近一次体征记录",
    parameters: [
      { name: "clientId", description: "客户档案 ID（profiles.id）", required: true },
    ],
    run: async (params) => {
      const clientId = String(params.clientId);
      const db = await getDb();

      const records = await db.query<{ name: string; is_head: boolean; height: number | null }>(
        `SELECT name, is_head, height FROM health_records WHERE user_id = $1 ORDER BY is_head DESC, created_at DESC`,
        [clientId],
      );
      if (records.rows.length === 0) {
        return { ok: true, output: "该客户暂无健康档案。", data: { records: [] } };
      }

      const latest = await db.query<{ weight: number | null; created_at: string }>(
        `SELECT vs.weight, vs.created_at
         FROM vital_signs vs
         JOIN health_records hr ON vs.record_id = hr.id
         WHERE hr.user_id = $1
         ORDER BY vs.created_at DESC
         LIMIT 1`,
        [clientId],
      );

      const head = records.rows.find((r) => r.is_head);
      const parts: string[] = [`共 ${records.rows.length} 份健康档案`];
      if (head) {
        parts.push(`户主「${head.name || "未命名"}」身高 ${head.height ? `${head.height}cm` : "未填写"}`);
      }
      if (latest.rows[0]) {
        const w = latest.rows[0].weight;
        parts.push(`最近体重 ${w ? `${w}kg` : "未测量"}（${new Date(latest.rows[0].created_at).toLocaleDateString("zh-CN")}）`);
        if (head?.height && w) {
          const bmi = w / Math.pow(head.height / 100, 2);
          const level =
            bmi < 18.5 ? "underweight" : bmi < 24 ? "normal" : bmi < 28 ? "overweight" : "obese";
          parts.push(`BMI ${bmi.toFixed(1)}（${BMI_LABEL[level]}）`);
        }
      } else {
        parts.push("尚无体征测量记录");
      }

      return {
        ok: true,
        output: `该客户${parts.join("，")}。`,
        data: { records: records.rows, latestVital: latest.rows[0] ?? null },
      };
    },
  });

  // ── 跟进提醒盘点 ──
  registerSkill({
    id: "followup-suggest",
    name: "跟进提醒盘点",
    description: "列出已到期或今日应跟进的客户，输出跟进优先级建议",
    parameters: [],
    run: async () => {
      const db = await getDb();
      const r = await db.query<{
        customer_name: string | null;
        next_follow_up_at: string;
        content: string;
      }>(
        `SELECT cr.customer_name, f.next_follow_up_at, f.content
         FROM follow_up_records f
         JOIN client_relations cr ON f.client_relation_id = cr.id
         WHERE f.next_follow_up_at IS NOT NULL
           AND f.next_follow_up_at < date_trunc('day', now()) + interval '1 day'
           AND cr.status = 'active'
         ORDER BY f.next_follow_up_at ASC
         LIMIT 20`,
      );

      if (r.rows.length === 0) {
        return { ok: true, output: "当前没有已到期或今日应跟进的客户，跟进节奏良好。", data: [] };
      }

      const todayEnd = new Date();
      todayEnd.setHours(23, 59, 59, 999);
      const overdue = r.rows.filter((row) => new Date(row.next_follow_up_at) < new Date(todayEnd.toDateString()));
      const lines = r.rows.slice(0, 10).map((row, i) => {
        const isOverdue = new Date(row.next_follow_up_at) < new Date(todayEnd.toDateString());
        const date = new Date(row.next_follow_up_at).toLocaleDateString("zh-CN");
        return `${i + 1}. ${row.customer_name || "未命名客户"}（${isOverdue ? "已逾期" : "今日"} · ${date}）：${row.content.slice(0, 40)}`;
      });

      return {
        ok: true,
        output:
          `共 ${r.rows.length} 条跟进提醒待处理（逾期 ${overdue.length} 条），建议优先处理逾期项：\n` +
          lines.join("\n"),
        data: r.rows,
      };
    },
  });
}
