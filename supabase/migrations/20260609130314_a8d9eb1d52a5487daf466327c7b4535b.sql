-- 把示例韩老师的 invite_code 清空（trigger 仅 BEFORE INSERT 触发，UPDATE 不会再生成）
UPDATE managers
   SET invite_code = NULL
 WHERE id = '00000000-0000-0000-0000-00000000a001';