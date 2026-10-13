import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  server: {
    port: 1420,
    host: true,
  },
  optimizeDeps: {
    exclude: ["@electric-sql/pglite"],
  },
  assetsInclude: ["**/*.wasm", "**/*.data"],
  chunkSizeWarningLimit: 1500,
});
