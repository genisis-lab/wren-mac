"""Loopback-only SSE fixture: a silent stream and a healthy unchanged mailbox."""
import base64
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == '/jmap/session':
            payload = dict(apiUrl=origin + '/jmap', uploadUrl=origin + '/upload',
                           downloadUrl=origin + '/download', eventSourceUrl=origin + '/events',
                           username='fixture', capabilities={}, accounts={})
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == '/events':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            self.wfile.flush()
            auth = self.headers.get('Authorization', '').removeprefix('Basic ')
            if base64.b64decode(auth).decode().startswith('stalled:'):
                time.sleep(5)
            else:
                self.wfile.write(b'event: state\ndata: {"changed":{"account":{"Email":"unchanged"}}}\n\n')
                self.wfile.flush()
        else:
            self.send_error(404)


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
origin = 'http://127.0.0.1:' + str(server.server_port)
Path(sys.argv[1]).write_text(origin)
server.serve_forever()
