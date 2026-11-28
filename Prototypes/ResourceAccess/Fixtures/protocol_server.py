#!/usr/bin/env python3
"""Disposable loopback-only HTTP/WebDAV fixture; no real media or NAS access."""
import argparse
import base64
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

DATA = bytes(range(256)) * 16
AUTHORIZATION = "Basic " + base64.b64encode(b"fixture:only-local-test").decode()
STATE = {"cross_origin_hits": 0, "cross_origin_authorization": None}
LOCK = threading.Lock()


class QuietHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, status, data=b"", headers=None, head=False):
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, str(value))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        if not head and data:
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass  # Header-only rejection intentionally cancels the body.


class Receiver(QuietHandler):
    def do_GET(self):
        if self.path == "/capture":
            with LOCK:
                STATE["cross_origin_hits"] += 1
                STATE["cross_origin_authorization"] = self.headers.get("Authorization")
        with LOCK:
            data = json.dumps(STATE).encode()
        self.reply(200, data, {"Content-Type": "application/json"})


class Origin(QuietHandler):
    receiver_port = None

    def authorized(self):
        if self.headers.get("Authorization") == AUTHORIZATION:
            return True
        self.reply(401, headers={"WWW-Authenticate": 'Basic realm="local-fixture"'}, head=self.command == "HEAD")
        return False

    def do_HEAD(self):
        if not self.authorized():
            return
        if self.path == "/selected/no-head":
            self.reply(405, head=True)
            return
        self.reply(200, DATA, {"ETag": '"fixture-v1"', "Content-Type": "audio/wav", "Accept-Ranges": "bytes"}, head=True)

    def do_GET(self):
        if not self.authorized():
            return
        path = unquote(urlsplit(self.path).path)
        redirects = {
            "/selected/redirect": "/selected/data.bin",
            "/selected/cross-origin": "http://127.0.0.1:%d/capture" % self.receiver_port,
            "/selected/outside-root": "/outside/data.bin",
        }
        if path in redirects:
            self.reply(307, headers={"Location": redirects[path]})
            return
        if path == "/selected/ignored-range":
            self.reply(200, DATA, {"ETag": '"fixture-v1"', "Accept-Ranges": "bytes"})
            return
        if path not in ("/selected/data.bin", "/selected/日本 語 100%.wav"):
            self.reply(404)
            return
        field = self.headers.get("Range", "")
        try:
            assert field.startswith("bytes=")
            first, last = [int(part) for part in field[6:].split("-")]
            assert 0 <= first < len(DATA) and first <= last
        except (AssertionError, ValueError):
            self.reply(416, headers={"Content-Range": "bytes */%d" % len(DATA)})
            return
        if self.headers.get("If-Range") not in (None, '"fixture-v1"'):
            self.reply(200, DATA, {"ETag": '"fixture-v1"'})
            return
        last = min(last, len(DATA) - 1)
        self.reply(206, DATA[first:last + 1], {"Content-Range": "bytes %d-%d/%d" % (first, last, len(DATA)), "ETag": '"fixture-v1"', "Content-Type": "application/octet-stream"})

    def do_PROPFIND(self):
        if not self.authorized():
            return
        if self.headers.get("Depth") != "1" or self.path != "/selected/":
            self.reply(400)
            return
        self.rfile.read(min(int(self.headers.get("Content-Length", "0")), 4096))

        def entry(href, collection=False):
            return '<D:response><D:href>%s</D:href><D:propstat><D:prop><D:resourcetype>%s</D:resourcetype><D:getcontentlength>%d</D:getcontentlength><D:getetag>&quot;fixture-v1&quot;</D:getetag></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>' % (href, "<D:collection/>" if collection else "", len(DATA))

        xml = '<D:multistatus xmlns:D="DAV:">' + entry("/selected/", True) + entry("/selected/" + quote("日本 語 100%.wav")) + entry("/selected/chosen/", True) + '</D:multistatus>'
        self.reply(207, xml.encode(), {"Content-Type": "application/xml; charset=utf-8"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()
    receiver = ThreadingHTTPServer(("127.0.0.1", 0), Receiver)
    Origin.receiver_port = receiver.server_port
    origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    for server in (receiver, origin):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    info = {"origin": "http://127.0.0.1:%d/selected/" % origin.server_port, "receiver": "http://127.0.0.1:%d/" % receiver.server_port}
    destination = Path(args.port_file)
    temporary = destination.with_suffix(".writing")
    temporary.write_text(json.dumps(info))
    temporary.replace(destination)
    threading.Event().wait()


if __name__ == "__main__":
    main()
