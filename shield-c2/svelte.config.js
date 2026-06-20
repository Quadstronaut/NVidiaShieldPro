import adapter from '@sveltejs/adapter-node';

/** @type {import('@sveltejs/kit').Config} */
const config = {
  kit: {
    // adapter-node => one Node process serves UI + API, can open the unix
    // docker socket and read the bind-mounted host /proc + /sys (D1).
    adapter: adapter()
  }
};

export default config;
