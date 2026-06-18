// LAN -> WSL browserless bridge.
//
// Why this exists: WSL2 is in NAT mode on this host, and the Windows host can only
// reach WSL services via the *transparent* localhost relay (127.0.0.1:<port>), not
// via the WSL VM IP. `netsh portproxy ... connectaddress=127.0.0.1` does NOT get
// carried by that relay (kernel-layer mismatch -> connection reset). A normal
// userspace process connecting to 127.0.0.1 DOES get relayed into WSL. So this Node
// process listens on the LAN IP and dials 127.0.0.1, bridging the Shield's Kuma
// (10.0.0.88) to browserless running in WSL.
//
//   Shield -> 10.0.0.73:3000  ->  [this forwarder]  ->  127.0.0.1:3000  ->  WSL relay  ->  browserless
//
// Run:  node wsl-bridge/browserless-forward.js
// (For persistence across reboots, register it as a logon Scheduled Task.)

const net = require('net');

const LISTEN_HOST = process.env.FWD_LISTEN_HOST || '10.0.0.73';
const LISTEN_PORT = Number(process.env.FWD_LISTEN_PORT || 3000);
const TARGET_HOST = process.env.FWD_TARGET_HOST || '127.0.0.1';
const TARGET_PORT = Number(process.env.FWD_TARGET_PORT || 3000);

const server = net.createServer((client) => {
  const upstream = net.connect(TARGET_PORT, TARGET_HOST);
  const kill = () => { client.destroy(); upstream.destroy(); };
  client.on('error', kill);
  upstream.on('error', kill);
  client.pipe(upstream);
  upstream.pipe(client);
});

server.on('error', (e) => {
  console.error(`[fwd] listen error on ${LISTEN_HOST}:${LISTEN_PORT}: ${e.message}`);
  process.exit(1);
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(`[fwd] ${LISTEN_HOST}:${LISTEN_PORT} -> ${TARGET_HOST}:${TARGET_PORT}`);
});
