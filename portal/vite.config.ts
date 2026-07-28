import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Feeds `scripts/codegen.mjs`, which embeds output into Generated/PortalBundle.swift. Non-negotiable:
// exactly one JS + one CSS at FIXED names — codegen hashes them, and the CI drift gate is byte-exact.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    // Sourcemaps would double the payload embedded in the Swift binary for every user in order to
    // help exactly one developer, who can build locally instead.
    sourcemap: false,
    // Aligns with the browsers that can run the portal at all: it needs
    // EventSource, fetch, and CSS custom properties.
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
    // `npm run dev` talks to a real daemon so the UI is developed against real
    // data instead of fixtures. Point it elsewhere with GOEL_DEV_TARGET.
    proxy: Object.fromEntries(
      ['/api', '/login', '/logout', '/stream'].map((p) => [
        p,
        { target: process.env.GOEL_DEV_TARGET ?? 'http://127.0.0.1:8899', changeOrigin: true },
      ]),
    ),
  },
})
