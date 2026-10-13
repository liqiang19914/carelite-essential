import React from "react";
import ReactDOM from "react-dom/client";
import App from "@/App";
import "@/index.css";
import { getDb } from "@/lib/pglite-db";

// 初始化本地 PGlite 数据库后再渲染应用
// 首次加载需要执行 890 个迁移 + seed（约 10-30 秒）
// 后续加载仅检查是否已初始化（毫秒级）
const root = document.getElementById("root")!;
root.innerHTML =
  '<div style="display:flex;align-items:center;justify-content:center;height:100vh;font-family:sans-serif;color:#666;"><div style="text-align:center"><h2>正在初始化本地数据库...</h2><p>首次加载需要约 10-30 秒，请稍候</p></div></div>';

getDb()
  .then(() => {
    ReactDOM.createRoot(root).render(
      <React.StrictMode>
        <App />
      </React.StrictMode>
    );
  })
  .catch((err) => {
    root.innerHTML =
      '<div style="display:flex;align-items:center;justify-content:center;height:100vh;font-family:sans-serif;color:#c00;"><div style="text-align:center"><h2>数据库初始化失败</h2><pre style="text-align:left;max-width:600px;overflow:auto;font-size:12px">' +
      err.message +
      "</pre></div></div>";
  });
