// Central runtime config. All values come from the environment so the launcher
// and Dockerfile fully control behaviour. NO token here (A2: no auth).

const intervalRaw = Number(process.env.SHIELD_C2_INTERVAL_MS ?? 2000);

export const config = {
  port: Number(process.env.SHIELD_C2_PORT ?? 8888),
  // Floor at 1000 ms (D2) to protect the eMMC from over-reading /proc.
  intervalMs: Number.isFinite(intervalRaw) ? Math.max(1000, intervalRaw) : 2000,
  hostProc: process.env.HOST_PROC ?? '/host/proc',
  hostSys: process.env.HOST_SYS ?? '/host/sys',
  hostData: process.env.HOST_DATA ?? '/host/data',
  // Where the launcher bind-mounts the host docker socket inside the container.
  dockerSocket: process.env.DOCKER_SOCKET ?? '/var/run/docker.sock'
};
