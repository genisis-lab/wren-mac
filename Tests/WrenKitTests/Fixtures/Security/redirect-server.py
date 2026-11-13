"""Two loopback origins for credential/redirect regression tests; no external traffic."""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

hits = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.do_GET()

    def do_GET(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.server is destination:
            hits.append(self.path)
        if self.path == '/cross':
            self.send_response(307)
            self.send_header('Location', target + '/caught')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path == '/same':
            self.send_response(307)
            self.send_header('Location', source + '/ok')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path == '/jmap/session':
            payload = dict(apiUrl=source + '/cross', uploadUrl=source + '/cross',
                           downloadUrl=source + '/cross', eventSourceUrl=source + '/cross',
                           username='test', capabilities={}, accounts={})
        elif self.path == '/hits':
            payload = dict(count=len(hits))
        else:
            payload = dict(auth=self.headers.get('Authorization'), admin=self.headers.get('X-Wren-Admin'),
                           body=body.decode(), method=self.command)
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


destination = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
origin = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
target = 'http://127.0.0.1:' + str(destination.server_port)
source = 'http://127.0.0.1:' + str(origin.server_port)
threading.Thread(target=destination.serve_forever, daemon=True).start()
Path(sys.argv[1]).write_text(json.dumps(dict(source=source, target=target)))
origin.serve_forever()
