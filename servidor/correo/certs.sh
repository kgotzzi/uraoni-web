#!/usr/bin/env bash
# Copia a Mailcow el certificado HTTPS que Caddy consigue para mail.uraoni.es,
# para que el correo (SMTP/IMAP) use el mismo certificado válido.
# Lo lanza cada día el temporizador uraoni-certs-correo.timer (y la instalación).
set -euo pipefail
MC=/opt/mailcow-dockerized
SRC=$(find /var/lib/caddy/.local/share/caddy/certificates -type d -name mail.uraoni.es 2>/dev/null | head -1 || true)
if [ -z "$SRC" ] || [ ! -s "$SRC/mail.uraoni.es.crt" ]; then
  echo "Todavía no hay certificado de mail.uraoni.es en Caddy (¿falta el registro DNS 'mail'?)."
  exit 0
fi
DST=$MC/data/assets/ssl
mkdir -p "$DST"
if cmp -s "$SRC/mail.uraoni.es.crt" "$DST/cert.pem" && cmp -s "$SRC/mail.uraoni.es.key" "$DST/key.pem"; then
  echo "Certificado del correo al día."
  exit 0
fi
install -m 644 "$SRC/mail.uraoni.es.crt" "$DST/cert.pem"
install -m 600 "$SRC/mail.uraoni.es.key" "$DST/key.pem"
cd "$MC"
docker compose restart postfix-mailcow dovecot-mailcow nginx-mailcow >/dev/null
echo "Certificado del correo actualizado."
