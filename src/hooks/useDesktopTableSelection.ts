import { useCallback, useMemo, useState } from "react";

/**
 * 表格多选状态。只管选择，不管业务动作——批量动作由页面自己接。
 */
export function useDesktopTableSelection(allKeys: string[] = []) {
  const [selected, setSelected] = useState<Set<string>>(new Set());

  const visible = useMemo(() => new Set(allKeys), [allKeys]);

  const toggle = useCallback((key: string) => {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }, []);

  const toggleAll = useCallback(() => {
    setSelected((prev) => {
      const allPicked = allKeys.length > 0 && allKeys.every((k) => prev.has(k));
      if (allPicked) return new Set();
      return new Set(allKeys);
    });
  }, [allKeys]);

  const clear = useCallback(() => setSelected(new Set()), []);

  const selectedKeys = useMemo(
    () => Array.from(selected).filter((k) => visible.has(k)),
    [selected, visible],
  );

  const allSelected = allKeys.length > 0 && selectedKeys.length === allKeys.length;
  const someSelected = selectedKeys.length > 0 && !allSelected;

  return { selected, selectedKeys, count: selectedKeys.length, toggle, toggleAll, clear, allSelected, someSelected };
}
