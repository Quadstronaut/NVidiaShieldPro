import { json } from '@sveltejs/kit';
import { startContainer } from '$lib/server/docker.js';

// POST-only mutation (I8'). A GET to this path has no handler => 405, never mutates.
export async function POST({ params }) {
  try {
    await startContainer(params.id);
    return new Response(null, { status: 204 });
  } catch (err) {
    return json(
      { error: 'start failed', detail: err?.detail ?? err?.message ?? String(err) },
      { status: err?.status && err.status < 600 ? err.status : 502 }
    );
  }
}
