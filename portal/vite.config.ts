import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// codegen.mjs requires exactly one JS + one CSS at these fixed names; CI drift gate is byte-exact.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    sourcemap: false,
    target: 'es2022',
    cssCodeSplit: false,
    rollupOptions: {
      output: {
        entryFileNames: 'portal.js',
        assetFileNames: 'portal.[ext]',
        manualChunks: undefined,
        inlineDynamicImports: true,
      },
    },
  },
  server: {
    proxy: Object.fromEntries(
      ['/api', '/login', '/logout', '/stream'].map((p) => [
        p,
        { target: process.env.GOEL_DEV_TARGET ?? 'http://127.0.0.1:8899', changeOrigin: true },
      ]),
    ),
  },
})
