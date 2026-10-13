/// <reference types="vite/client" />

// 声明 ?raw 导入返回字符串（用于 SQL 文件内联）
declare module "*.sql?raw" {
  const content: string;
  export default content;
}

// 声明 ?raw 通用导入
declare module "*?raw" {
  const content: string;
  export default content;
}
