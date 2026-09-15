#!/usr/bin/env python3
"""Serve ios/Tests/Fixtures over HTTPS for the Password AutoFill check (#008AB).

iOS Password AutoFill is origin-scoped, so the fixture login page has to live on
a real https origin with a name — a `file://` page or a bare IP will not do. The
simulator shares the Mac's network stack and resolver, so `zen.localtest.me`
(public DNS, answers 127.0.0.1) reaches this process with no /etc/hosts edit.

Run it from `ios/`:

    python3 Tests/Fixtures/serve.py

It makes its own CA and leaf certificate under /tmp/zensync-fixtures on first
run and prints the one command that makes the simulator trust them:

    xcrun simctl keychain <udid> add-root-cert /tmp/zensync-fixtures/ca.pem

POST /submitted answers with a signed-in page rather than a 501, because WebKit
only offers to save a password when the submission navigates somewhere that
loads.
"""

import argparse
import http.server
import os
import ssl
import subprocess
import sys

DEFAULT_PORT = 8443
HOST = "zen.localtest.me"
CERT_DIR = "/tmp/zensync-fixtures"
FIXTURES = os.path.dirname(os.path.abspath(__file__))

SIGNED_IN = b"""<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width, initial-scale=1">
<title>Signed in</title>
<body style="font:17px -apple-system,system-ui;padding:40px 20px">
<h1>Signed in</h1><p>The fixture form accepted the submission.</p>
"""


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=FIXTURES, **kwargs)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(SIGNED_IN)))
        self.end_headers()
        self.wfile.write(SIGNED_IN)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def ensure_certificate():
    """Make a CA and a leaf for `zen.localtest.me` if they are not there yet."""
    server_pem = os.path.join(CERT_DIR, "server.pem")
    ca_pem = os.path.join(CERT_DIR, "ca.pem")
    if os.path.exists(server_pem) and os.path.exists(ca_pem):
        return server_pem, ca_pem
    os.makedirs(CERT_DIR, exist_ok=True)
    ext = os.path.join(CERT_DIR, "ext.cnf")
    with open(ext, "w") as handle:
        handle.write(
            "basicConstraints=CA:FALSE\n"
            "keyUsage=critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\n"
            "subjectAltName=DNS:zen.localtest.me,DNS:localtest.me,"
            "DNS:localhost,IP:127.0.0.1\n"
        )
    run = lambda cmd: subprocess.run(cmd, check=True, cwd=CERT_DIR,
                                     stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
    run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256",
         "-days", "3650", "-nodes", "-keyout", "ca.key", "-out", "ca.pem",
         "-subj", "/CN=Zen Fixture CA/O=Zen iOS tests",
         "-addext", "basicConstraints=critical,CA:TRUE",
         "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
    run(["openssl", "req", "-newkey", "rsa:2048", "-nodes",
         "-keyout", "leaf.key", "-out", "leaf.csr",
         "-subj", "/CN=zen.localtest.me"])
    run(["openssl", "x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem",
         "-CAkey", "ca.key", "-CAcreateserial", "-out", "leaf.pem",
         "-days", "3650", "-sha256", "-extfile", "ext.cnf"])
    with open(server_pem, "w") as out:
        for part in ("leaf.pem", "leaf.key"):
            with open(os.path.join(CERT_DIR, part)) as handle:
                out.write(handle.read())
    return server_pem, ca_pem


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument(
        "--http", action="store_true",
        help="serve cleartext instead of TLS, to check what AutoFill needs")
    options = parser.parse_args()

    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", options.port), Handler)
    scheme = "http"
    if not options.http:
        server_pem, ca_pem = ensure_certificate()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(server_pem)
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"
        print(f"trust the CA once: xcrun simctl keychain <udid> add-root-cert {ca_pem}")
    print(f"serving {FIXTURES} at {scheme}://{HOST}:{options.port}/login.html")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
