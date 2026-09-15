"""Receive audit exports from the local Figma development plugin."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
args = parser.parse_args()
directory = args.directory.resolve()
directory.mkdir(parents=True, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def response(self, code, body):
        self.send_response(code)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Content-Length', str(len(body.encode())))
        self.end_headers()
        self.wfile.write(body.encode())

    def do_OPTIONS(self):
        self.response(200, '')

    def do_GET(self):
        prefix = '/artifact/'
        name = self.path[len(prefix):] if self.path.startswith(prefix) else ''
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', name):
            return self.response(400, 'Invalid filename')
        target = directory / name
        if not target.is_file():
            return self.response(404, 'Missing artifact')
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Content-Length', str(target.stat().st_size))
        self.end_headers()
        self.wfile.write(target.read_bytes())

    def do_POST(self):
        if self.path != '/artifact':
            return self.response(404, 'Unknown endpoint')
        length = int(self.headers.get('Content-Length', 0))
        if not 0 < length < 100_000_000:
            return self.response(400, 'Invalid length')
        try:
            item = json.loads(self.rfile.read(length))
            name = item['name']
            if not re.fullmatch(r'[A-Za-z0-9_.-]+', name):
                raise ValueError('Invalid filename')
            target = directory / name
            data = item['data']
            payload = bytes(data) if isinstance(data, list) else data.encode('utf-8')
            if target.exists() and target.read_bytes() != payload:
                raise ValueError('Refusing to overwrite different evidence')
            target.write_bytes(payload)
            print(f'Saved {name}: {len(payload)} bytes', flush=True)
            self.response(200, 'Saved')
        except (ValueError, KeyError, TypeError) as error:
            self.response(400, str(error))

    def log_message(self, *_):
        pass


print(f'Listening on 127.0.0.1:47839; output {directory}', flush=True)
ThreadingHTTPServer(('127.0.0.1', 47839), Handler).serve_forever()
