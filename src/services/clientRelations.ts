import { supabase } from "@/integrations/supabase/client";
import { getDb } from "@/lib/pglite-db";

/**
 * 客户关系 service（本地 PGlite 版）
 * 单健康师场景：manager_id 即当前登录用户，无企业/多租户概念。
 */

/**
 * 软删除客户关系（移入回收站）
 */
export async function softDeleteClientRelation(relationId: string): Promise<void> {
  const { error } = await supabase
    .from("client_relations")
    .update({ status: "deleted" })
    .eq("id", relationId);
  if (error) throw error;
}

/**
 * 恢复回收站中的客户关系
 */
export async function restoreClientRelation(relationId: string): Promise<void> {
  const { error } = await supabase
    .from("client_relations")
    .update({ status: "active" })
    .eq("id", relationId);
  if (error) throw error;
}

/**
 * 彻底删除客户关系（级联清理标签关联与跟进记录）
 */
export async function purgeClientRelation(relationId: string): Promise<void> {
  const db = await getDb();
  await db.transaction(async (tx) => {
    await tx.query(`DELETE FROM client_tag_relations WHERE client_relation_id = $1`, [relationId]);
    await tx.query(`DELETE FROM follow_up_records WHERE client_relation_id = $1`, [relationId]);
    await tx.query(`DELETE FROM client_relations WHERE id = $1`, [relationId]);
  });
}

/**
 * 修改客户备注姓名（写关系级字段）
 */
export async function renameRelationClient(
  relationId: string,
  customerName: string,
): Promise<void> {
  const { error } = await supabase
    .from("client_relations")
    .update({ customer_name: customerName })
    .eq("id", relationId);
  if (error) throw error;
}
