import { json } from '@sveltejs/kit';
import { restartContainer } from '$lib/server/docker.js';

// POST-only mutation (I8').
export async function POST({ params }) {
  try {
    await restartContainer(params.id);
    return new Response(null, { status: 204 });
  } catch (err) {
    return json(
      { error: 'restart failed', detail: err?.detail ?? err?.message ?? String(err) },
      { status: err?.status && err.status < 600 ? err.status : 502 }
    );
  }
}
