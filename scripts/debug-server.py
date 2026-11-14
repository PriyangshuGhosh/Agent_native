#!/usr/bin/env python3
"""Laptop end of the Pi debug link (rootfs/debian/usr/libexec/agentos/debug-client). Files live in build/debug/.
  debug-server.py card /media/$USER/AGENTOS [--ip IP]   put the link's settings on a card's FAT partition
  debug-server.py serve [--bind IP]                     run the server; the journal arrives in build/debug/pi.log
  debug-server.py send 'command'                        run a command on the Pi as root and print its output ('-': read it from stdin)
Delete agentos-debug.env from the card to turn the link off."""
import argparse, base64, hashlib, hmac, http.server, os, secrets, ssl, subprocess, sys, tempfile, time
from pathlib import Path

DIR = Path(os.environ.get("DEBUG_DIR") or Path(__file__).resolve().parent.parent / "build/debug")
PORT, MAX_BODY = 8443, 4_000_000
CMD, OUT, CRT, KEY, TOKEN = DIR / "cmd", DIR / "out", DIR / "server.crt", DIR / "server.key", DIR / "token"


def init():
    """Key, certificate and token, made once and readable only by this user."""
    for d in (DIR, CMD, OUT):
        d.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not KEY.exists():
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "3650",
                        "-subj", "/CN=agentos-debug", "-keyout", KEY, "-out", CRT], check=True, capture_output=True)
        KEY.chmod(0o600)
    if not TOKEN.exists():
        TOKEN.touch(mode=0o600)
        TOKEN.write_text(secrets.token_urlsafe(32))


def pin():
    der = subprocess.run(["openssl", "x509", "-in", CRT, "-noout", "-pubkey"], check=True, capture_output=True).stdout
    der = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"], input=der, check=True, capture_output=True).stdout
    return base64.b64encode(hashlib.sha256(der).digest()).decode()


def settings(ip):
    return f"DEBUG_URL=https://{ip}:{PORT}\nDEBUG_TOKEN={TOKEN.read_text()}\nDEBUG_PIN={pin()}\n"


def default_ip():
    r = subprocess.run(["ip", "-4", "route", "get", "1.1.1.1"], check=True, capture_output=True, text=True).stdout.split()
    return r[r.index("src") + 1]


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body=b"", headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        ok = hmac.compare_digest(self.headers.get("Authorization", "").encode(), f"Bearer {TOKEN.read_text()}".encode())
        if not ok:
            self.reply(403)
        return ok

    def do_GET(self):
        if not self.authed():
            return
        if self.path != "/next":
            return self.reply(404)
        todo = sorted(p for p in CMD.iterdir() if not (OUT / p.name).exists())
        if not todo:
            return self.reply(200)
        self.reply(200, todo[0].read_bytes(), [("X-Cmd-Id", todo[0].name)])

    def do_POST(self):
        if not self.authed():
            return
        n = int(self.headers.get("Content-Length", 0))
        if not 0 <= n <= MAX_BODY:
            return self.reply(413)
        body = self.rfile.read(n)
        if self.path == "/report":
            with open(DIR / "pi.log", "ab") as f:
                f.write(body)
        elif self.path.startswith("/result/") and self.path[8:].isdigit():
            (OUT / self.path[8:]).write_bytes(body)
        else:
            return self.reply(404)
        self.reply(200)

    def log_message(self, *a):
        pass


def serve(bind):
    srv = http.server.ThreadingHTTPServer((bind, PORT), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CRT, KEY)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print(f"listening on {bind}:{PORT}; journal in {DIR / 'pi.log'}", flush=True)
    srv.serve_forever()


def send(command, wait):
    # The id is the time, so commands run in the order sent and never collide with one already answered.
    name = f"{time.time_ns()}"
    with tempfile.NamedTemporaryFile("w", dir=DIR, delete=False) as f:
        f.write(command + "\n")
    os.replace(f.name, CMD / name)  # atomic: the server never hands out half a command
    for _ in range(wait):
        if (OUT / name).exists():
            sys.stdout.buffer.write((OUT / name).read_bytes())
            return 0
        time.sleep(1)
    print(f"no answer in {wait} s; it stays queued, and the output will be in {OUT / name}", file=sys.stderr)
    return 1


def main():
    a = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = a.add_subparsers(dest="what", required=True)
    c = sub.add_parser("card")
    c.add_argument("path")
    c.add_argument("--ip")
    s = sub.add_parser("serve")
    s.add_argument("--bind")
    n = sub.add_parser("send")
    n.add_argument("command")
    n.add_argument("--wait", type=int, default=150)
    a = a.parse_args()
    init()
    if a.what == "card":
        (Path(a.path) / "agentos-debug.env").write_text(settings(a.ip or default_ip()))
    elif a.what == "serve":
        serve(a.bind or default_ip())
    else:
        return send(sys.stdin.read() if a.command == "-" else a.command, a.wait)


sys.exit(main())
