import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// codegen.mjs requires exactly one JS + one CSS at these fixed names, plus the font files; the CI
// drift gate is byte-exact.
export default defineConfig(({ command }) => ({
  plugins: [react()],
  // Relative asset URLs in the built CSS: the stylesheet is served from /assets/, so a font at
  // `font-figtree-<hash>.woff2` resolves to /assets/font-figtree-<hash>.woff2 — same origin, as the
  // CSP's `font-src 'self'` requires. The dev server keeps the default root.
  base: command === 'build' ? './' : '/',
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    sourcemap: false,
    target: 'es2022',
    cssCodeSplit: false,
    // Fonts stay files (served from /assets/), never data: URIs the CSP would block.
    assetsInlineLimit: (file) => (file.endsWith('.woff2') ? false : undefined),
    rollupOptions: {
      output: {
        entryFileNames: 'portal.js',
        assetFileNames: (info) =>
          (info.names?.[0] ?? '').endsWith('.woff2') ? 'font-[name]-[hash][extname]' : 'portal.[ext]',
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
}))
