#!/usr/bin/env python3
"""Lista de espera de URAONI.

Servicio pequeño (solo biblioteca estándar de Python) que escucha en 127.0.0.1:8787.
Caddy le pasa /api/* desde uraoni.es.

  POST /api/lista   {"email": "...", "web": ""}  -> guarda el correo y envía la confirmación
  GET  /api/baja?t=TOKEN                          -> página para darse de baja
  POST /api/baja?t=TOKEN                          -> baja (también la de un clic de Gmail/Apple)

Los correos se guardan en /var/lib/uraoni-lista/lista.db (SQLite).
La confirmación sale por el Mailcow del propio servidor (127.0.0.1:587, con usuario).
Usuario y contraseña de envío: /etc/uraoni/lista.env (lo escribe servidor/correo/instalar.sh).
"""
import html
import json
import os
import re
import secrets
import smtplib
import sqlite3
import ssl
import sys
import threading
import time
from email.message import EmailMessage
from email.utils import formataddr, make_msgid, formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DB = os.path.join(os.environ.get("STATE_DIRECTORY", "/var/lib/uraoni-lista"), "lista.db")
SITE = os.environ.get("SITE", "https://uraoni.es")
SMTP_HOST = os.environ.get("SMTP_HOST", "127.0.0.1")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASS = os.environ.get("SMTP_PASS", "")
FROM_ADDR = os.environ.get("FROM_ADDR", "hola@uraoni.es")
REPLY_TO = os.environ.get("REPLY_TO", "hola@uraoni.es")

EMAIL_RE = re.compile(r"^[^\s@<>\"',;]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,24}$")
LIMIT_PER_HOUR = 6          # altas por IP y hora (la IP no se guarda en disco)
MAX_BODY = 2048

_lock = threading.Lock()
_hits: dict[str, list[float]] = {}


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def db():
    con = sqlite3.connect(DB, timeout=10)
    con.execute("""CREATE TABLE IF NOT EXISTS lista(
        email TEXT PRIMARY KEY,
        alta TEXT NOT NULL,
        token TEXT NOT NULL UNIQUE,
        confirmacion TEXT,
        baja TEXT)""")
    return con


def limited(ip: str) -> bool:
    now = time.time()
    with _lock:
        hits = [t for t in _hits.get(ip, []) if now - t < 3600]
        hits.append(now)
        _hits[ip] = hits
        if len(_hits) > 5000:
            for k in list(_hits)[:2500]:
                _hits.pop(k, None)
        return len(hits) > LIMIT_PER_HOUR


# ---------------------------------------------------------------- correo
TXT = """Hola:

Hemos recibido tu correo y ya estás en la lista de espera de URAONI.

El Drop 01 todavía no tiene fecha, pero sale pronto. Serás de los primeros en saberlo: te escribiremos antes de que abra la tienda, con tiempo para elegir tu talla.

Mientras tanto, el día a día va en Instagram: @uraoni.official
https://instagram.com/uraoni.official

Calma por fuera. Oni por dentro.
URAONI · 裏鬼

--
Te escribimos porque te apuntaste en uraoni.es. Si no fuiste tú o ya no quieres avisos, date de baja aquí:
{baja}
"""

HTML = """<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light only"><title>Estás en la lista del Drop 01</title></head>
<body style="margin:0;padding:0;background:#ede6da;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#ede6da;">
<tr><td align="center" style="padding:40px 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#f6f1e8;border:1px solid #d9cfbf;border-radius:6px;">
<tr><td style="padding:34px 32px 8px;font-family:Georgia,'Times New Roman',serif;font-size:26px;letter-spacing:.14em;color:#1b1714;">
URAONI<span style="color:#a3142a;">.</span></td></tr>
<tr><td style="padding:18px 32px 0;font-family:Georgia,'Times New Roman',serif;font-size:30px;line-height:1.15;color:#1b1714;">
Estás en la lista.</td></tr>
<tr><td style="padding:16px 32px 0;font-family:Helvetica,Arial,sans-serif;font-size:16px;line-height:1.6;color:#3b352f;">
Hemos recibido tu correo y ya estás en la lista de espera del <strong style="color:#1b1714;">Drop 01</strong>.</td></tr>
<tr><td style="padding:12px 32px 0;font-family:Helvetica,Arial,sans-serif;font-size:16px;line-height:1.6;color:#3b352f;">
Todavía no tiene fecha, pero sale pronto. Serás de los primeros en saberlo: te escribiremos antes de que abra la tienda, con tiempo para elegir tu talla.</td></tr>
<tr><td style="padding:12px 32px 0;font-family:Helvetica,Arial,sans-serif;font-size:16px;line-height:1.6;color:#3b352f;">
Mientras tanto, el día a día va en Instagram:
<a href="https://instagram.com/uraoni.official" style="color:#a3142a;">@uraoni.official</a></td></tr>
<tr><td style="padding:28px 32px 32px;font-family:Georgia,'Times New Roman',serif;font-size:18px;font-style:italic;color:#1b1714;">
Calma por fuera. Oni por dentro.</td></tr>
</table>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;">
<tr><td style="padding:18px 8px 0;font-family:Helvetica,Arial,sans-serif;font-size:12px;line-height:1.6;color:#5a534b;">
Te escribimos porque te apuntaste en <a href="{site}" style="color:#5a534b;">uraoni.es</a>.
Si no fuiste tú o ya no quieres avisos, <a href="{baja}" style="color:#5a534b;">date de baja aquí</a>.
</td></tr></table>
</td></tr></table>
</body></html>
"""


def send_confirmation(email: str, token: str):
    if not (SMTP_USER and SMTP_PASS):
        log("lista: sin credenciales SMTP todavía; alta guardada, la confirmación saldrá al conectar el correo")
        return
    baja = f"{SITE}/api/baja?t={token}"
    msg = EmailMessage()
    msg["Subject"] = "Estás en la lista del Drop 01"
    msg["From"] = formataddr(("URAONI", FROM_ADDR))
    msg["To"] = email
    msg["Reply-To"] = REPLY_TO
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid(domain=FROM_ADDR.split("@")[-1])
    msg["List-Unsubscribe"] = f"<{baja}>, <mailto:{REPLY_TO}?subject=baja>"
    msg["List-Unsubscribe-Post"] = "List-Unsubscribe=One-Click"
    msg.set_content(TXT.format(baja=baja))
    msg.add_alternative(HTML.format(baja=html.escape(baja), site=SITE), subtype="html")

    ctx = ssl.create_default_context()
    # Conexión local al Mailcow de esta misma máquina: el certificado es de mail.uraoni.es, no de 127.0.0.1.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    for intento in range(3):
        try:
            with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30) as s:
                s.starttls(context=ctx)
                s.login(SMTP_USER, SMTP_PASS)
                s.send_message(msg)
            with db() as con:
                con.execute("UPDATE lista SET confirmacion=? WHERE email=?", (time.strftime("%Y-%m-%d %H:%M:%S"), email))
            log("lista: confirmación enviada")
            return
        except Exception as e:  # noqa: BLE001
            log(f"lista: fallo al enviar (intento {intento + 1}):", repr(e))
            time.sleep(5 * (intento + 1))


# ---------------------------------------------------------------- web
PAGE = """<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>{title} · URAONI</title>
<style>body{{margin:0;min-height:100vh;display:grid;place-items:center;background:#ede6da;color:#1b1714;
font:16px/1.6 Helvetica,Arial,sans-serif}}main{{max-width:440px;padding:32px}}
h1{{font:400 34px/1.1 Georgia,serif;margin:0 0 12px}}p{{color:#3b352f}}a{{color:#a3142a}}
button{{font:inherit;min-height:48px;padding:0 22px;border:0;border-radius:999px;background:#1b1714;color:#ede6da;cursor:pointer}}</style>
</head><body><main><h1>{title}</h1>{body}<p><a href="/">Volver a uraoni.es</a></p></main></body></html>"""


class H(BaseHTTPRequestHandler):
    server_version = "uraoni-lista"
    sys_version = ""

    def log_message(self, fmt, *args):  # sin IPs ni correos en los registros
        pass

    def _ip(self):
        return (self.headers.get("X-Forwarded-For") or self.client_address[0]).split(",")[0].strip()

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False))

    def _page(self, code, title, body):
        self._send(code, PAGE.format(title=title, body=body), "text/html; charset=utf-8")

    def _read(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > MAX_BODY:
            return None
        raw = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        if "json" in (self.headers.get("Content-Type") or ""):
            try:
                d = json.loads(raw or "{}")
                return d if isinstance(d, dict) else {}
            except ValueError:
                return {}
        return {k: v[0] for k, v in parse_qs(raw).items()}

    # ---- rutas
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/api/salud":
            return self._json(200, {"ok": True})
        if u.path == "/api/baja":
            t = parse_qs(u.query).get("t", [""])[0]
            with db() as con:
                row = con.execute("SELECT baja FROM lista WHERE token=?", (t,)).fetchone()
            if not row:
                return self._page(404, "Enlace no válido", "<p>Este enlace de baja no existe o ya no funciona.</p>")
            if row[0]:
                return self._page(200, "Ya estás de baja", "<p>No te enviaremos más avisos.</p>")
            return self._page(200, "Darte de baja",
                              "<p>Si confirmas, borramos tu correo de la lista y no te escribiremos más.</p>"
                              f'<form method="post" action="/api/baja?t={html.escape(t)}"><button>Confirmar la baja</button></form>')
        return self._json(404, {"ok": False})

    def do_POST(self):
        u = urlparse(self.path)
        if u.path == "/api/lista":
            return self._alta()
        if u.path == "/api/baja":
            t = parse_qs(u.query).get("t", [""])[0]
            with db() as con:
                cur = con.execute("UPDATE lista SET baja=?, email='baja-'||token WHERE token=? AND baja IS NULL",
                                  (time.strftime("%Y-%m-%d %H:%M:%S"), t))
            if cur.rowcount == 0:
                with db() as con:
                    ok = con.execute("SELECT 1 FROM lista WHERE token=?", (t,)).fetchone()
                if not ok:
                    return self._page(404, "Enlace no válido", "<p>Este enlace de baja no existe o ya no funciona.</p>")
            return self._page(200, "Hecho, estás de baja", "<p>Hemos borrado tu correo de la lista. No te escribiremos más.</p>")
        return self._json(404, {"ok": False})

    def _alta(self):
        d = self._read()
        if d is None:
            return self._json(413, {"ok": False, "error": "Demasiado largo."})
        if (d.get("web") or "").strip():          # campo trampa para bots
            return self._json(200, {"ok": True})
        email = (d.get("email") or "").strip().lower()
        if len(email) > 254 or not EMAIL_RE.match(email):
            return self._json(400, {"ok": False, "error": "Ese correo no parece completo."})
        if limited(self._ip()):
            return self._json(429, {"ok": False, "error": "Demasiados intentos. Prueba otra vez en un rato."})
        token = secrets.token_urlsafe(24)
        with db() as con:
            cur = con.execute("INSERT OR IGNORE INTO lista(email, alta, token) VALUES(?,?,?)",
                              (email, time.strftime("%Y-%m-%d %H:%M:%S"), token))
            nuevo = cur.rowcount == 1
        if nuevo:
            threading.Thread(target=send_confirmation, args=(email, token), daemon=True).start()
        # Misma respuesta si ya estaba: no revelamos quién está en la lista.
        return self._json(200, {"ok": True})


def pendientes():
    """Confirmaciones que no salieron (correo aún sin conectar): se envían al arrancar."""
    if not (SMTP_USER and SMTP_PASS):
        return
    with db() as con:
        filas = con.execute("SELECT email, token FROM lista WHERE confirmacion IS NULL AND baja IS NULL").fetchall()
    for email, token in filas:
        send_confirmation(email, token)
        time.sleep(2)


def main():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    db().close()
    threading.Thread(target=pendientes, daemon=True).start()
    host, port = os.environ.get("LISTEN", "127.0.0.1:8787").rsplit(":", 1)
    srv = ThreadingHTTPServer((host, int(port)), H)
    log(f"lista: escuchando en {host}:{port}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
