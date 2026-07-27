import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The build feeds `scripts/codegen.mjs`, which embeds the output into
// Sources/GoelCore/Remote/Generated/PortalBundle.swift. Two constraints follow
// from that and neither is negotiable:
//
//  1. Exactly one JS file and one CSS file, at fixed names. The Swift side
//     serves them from /assets/portal-<contenthash>.<ext>; the hash is computed
//     by the codegen, not by Vite, so that the Swift constant and the URL can
//     never disagree. Code-splitting would mean dynamic import() at runtime,
//     which the portal's CSP ('self', no inline) would have to grow to allow —
//     for no benefit on a single-screen app.
//
//  2. No hashed filenames from Vite. A hash here would churn the generated
//     Swift file on every build even when the bytes are identical, and the CI
//     drift gate compares that file byte-for-byte.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    // The daemon serves this over plain HTTP on a LAN. Sourcemaps would double
    // the embedded payload inside the Swift binary for every user in order to
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
