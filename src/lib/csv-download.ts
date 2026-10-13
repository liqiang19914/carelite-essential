/**
 * 表格数据导出成 CSV。Excel 打开中文要 BOM，否则一片乱码。
 */
export function convertToCSV(
  rows: Record<string, unknown>[] = [],
  headers: Record<string, string> = {},
): string {
  const keys = Object.keys(headers);
  const headerLine = keys.map((key) => headers[key]).join(",");
  const bodyLines = rows.map((row) =>
    keys
      .map((key) => {
        const raw = row[key];
        const text = raw === null || raw === undefined ? "" : String(raw);
        return /[",\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
      })
      .join(","),
  );
  return [headerLine, ...bodyLines].join("\n");
}

export function downloadCSV(content: string, filename: string): void {
  const blob = new Blob([`﻿${content}`], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  URL.revokeObjectURL(url);
}
