import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// envDir '..' lets the app read VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY from the repo's .env.local (live dev project)
// or from .env.stack via `vite --mode stack` (local stack).
export default defineConfig({
  plugins: [react()],
  envDir: '..',
  // Only public values: VITE_* (local stack) and NEXT_PUBLIC_* (what .env.local already names). The service key is
  // SUPABASE_SERVICE_ROLE_KEY, which neither prefix matches, so it can never reach the browser bundle.
  envPrefix: ['VITE_', 'NEXT_PUBLIC_'],
  server: { host: '127.0.0.1', port: 5173, strictPort: true },
  preview: { host: '127.0.0.1', port: 4173, strictPort: true },
  // asset-manifest.json lets the service worker (public/sw.js) precache every built file for offline start.
  build: { manifest: 'asset-manifest.json' },
  define: { __BUILD_ID__: JSON.stringify(Date.now().toString(36)) },
  test: { environment: 'jsdom', include: ['tests/**/*.test.tsx', 'tests/**/*.test.ts'], setupFiles: ['tests/setup.ts'] },
});
