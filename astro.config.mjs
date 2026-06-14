import { defineConfig } from 'astro/config';
import react from '@astrojs/react';

// https://astro.build/config
export default defineConfig({
  integrations: [react()],
  i18n: {
    defaultLocale: 'en',
    locales: ['en', 'de', 'fr', 'es'],
    routing: {
      prefixDefaultLocale: true,
      redirectToDefaultLocale: true
    }
  },
  devToolbar: {
    enabled: false
  },
  output: 'static',
  vite: {
    optimizeDeps: {
      include: ['react', 'react-dom', 'react-dom/client']
    }
  }
});
