import { json } from '@sveltejs/kit';
import { listContainers } from '$lib/server/docker.js';

// list (allowlist). No auth (A2).
export async function GET() {
  try {
    return json(await listContainers());
  } catch (err) {
    return json(
      { error: 'list failed', detail: err?.detail ?? err?.message ?? String(err) },
      { status: err?.status && err.status < 600 ? err.status : 502 }
    );
  }
}
