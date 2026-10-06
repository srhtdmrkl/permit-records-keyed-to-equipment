// Serves the folder locally so the app can load the SQL files and PGlite.
// No dependencies. Usage: npm start

import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { join, extname, normalize, dirname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { exec } from 'node:child_process';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const port = Number(process.env.PORT) || 4400;

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.sql': 'text/plain; charset=utf-8',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
  '.data': 'application/octet-stream',
  '.gz': 'application/gzip',
  '.map': 'application/json',
};

createServer(async (req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  if (path === '/') {
    res.writeHead(302, { Location: '/app/' });
    return res.end();
  }
  let file = normalize(join(root, path));
  if (file !== root && !file.startsWith(root + sep)) {
    res.writeHead(403);
    return res.end();
  }
  try {
    if ((await stat(file)).isDirectory()) {
      // /app must become /app/, or the page's relative app.css and app.js resolve to /app.css and 404.
      if (!path.endsWith('/')) {
        const { search } = new URL(req.url, 'http://localhost');
        res.writeHead(301, { Location: `${path}/${search}` });
        return res.end();
      }
      file = join(file, 'index.html');
    }
    const body = await readFile(file);
    res.writeHead(200, { 'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream' });
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end('Not found');
  }
}).listen(port, '127.0.0.1', () => {
  const url = `http://localhost:${port}/app/`;
  console.log(`Permit Register running at ${url}  (Ctrl+C to stop)`);
  if (process.platform === 'darwin' && !process.env.NO_OPEN) exec(`open ${url}`);
});
