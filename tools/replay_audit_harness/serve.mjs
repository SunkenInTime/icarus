import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const harnessDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(harnessDir, '..', '..');
const port = Number(process.argv[2] ?? 4173);
const mime = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
};

const server = http.createServer((request, response) => {
  const requestPath = decodeURIComponent(new URL(request.url, `http://${request.headers.host}`).pathname);
  const relative = requestPath === '/'
    ? 'tools/replay_audit_harness/index.html'
    : requestPath.endsWith('/')
      ? `${requestPath.slice(1)}index.html`
      : requestPath.slice(1);
  const absolute = path.resolve(repoRoot, relative);
  if (!absolute.startsWith(repoRoot + path.sep)) {
    response.writeHead(403).end('Forbidden');
    return;
  }
  fs.stat(absolute, (error, stats) => {
    if (error || !stats.isFile()) {
      response.writeHead(404).end('Not found');
      return;
    }
    response.writeHead(200, {
      'content-type': mime[path.extname(absolute).toLowerCase()] ?? 'application/octet-stream',
      'cache-control': 'no-store',
      'access-control-allow-origin': '*',
    });
    fs.createReadStream(absolute).pipe(response);
  });
});

server.listen(port, '127.0.0.1', () => {
  console.log(`Icarus replay audit harness: http://127.0.0.1:${port}/tools/replay_audit_harness/`);
});
