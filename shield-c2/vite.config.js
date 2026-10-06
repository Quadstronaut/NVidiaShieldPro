import { sveltekit } from '@sveltejs/kit/vite';
import adapter from '@sveltejs/adapter-node';
import { defineConfig } from 'vite';

// SvelteKit 3 reads its config from the sveltekit() plugin; svelte.config.js is no longer used.
export default defineConfig({
  plugins: [
    sveltekit({
      // adapter-node => one Node process serves UI + API, can open the unix
      // docker socket and read the bind-mounted host /proc + /sys (D1).
      adapter: adapter()
    })
  ]
});



