#!/usr/bin/env bash
# Instala y mantiene el correo de uraoni.es con Mailcow (Docker) en este servidor.
# Lo ejecuta GitHub Actions (.github/workflows/correo.yml) como root. Se puede repetir sin miedo:
# lo que ya está hecho no se vuelve a hacer.
#
# Crea:
#   hola@uraoni.es     buzón para leer y responder (webmail en https://mail.uraoni.es/SOGo)
#   noreply@uraoni.es  buzón técnico con el que la web envía la confirmación, firmando como hola@
#
# Contraseñas: nunca en el repositorio.
#   - Si existe /root/.uraoni-mailpass (lo sube el flujo desde el secreto MAIL_PASSWORD), es la
#     contraseña de hola@uraoni.es y del panel de administración (usuario "admin").
#   - Si no, se generan al azar y se guardan solo en /root/uraoni-correo.txt (permiso 600).
#   - La de noreply@ se genera al azar y solo la conoce el servicio de la lista (/etc/uraoni/lista.env).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

DOMINIO=uraoni.es
HOST_CORREO=mail.uraoni.es
MC=/opt/mailcow-dockerized
CRED=/root/uraoni-correo.txt
ENVF=/etc/uraoni/lista.env
umask 022   # Mailcow necesita leer sus ficheros desde los contenedores; los secretos se protegen uno a uno

paso(){ echo; echo "== $*"; }
aleatoria(){ python3 -c 'import secrets;print(secrets.token_urlsafe(18))'; }

# ---------------------------------------------------------------- 0. Memoria
paso "Comprobando memoria"
mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
if [ "$mem_kb" -lt 7000000 ]; then
  echo "::error::El servidor tiene $((mem_kb/1024)) MB de RAM. Mailcow necesita el plan gp.starter (8 GB)."
  exit 1
fi
if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "Swap de 2 GB creada."
fi

# ---------------------------------------------------------------- 1. Docker
paso "Docker"
if [ ! -f /etc/docker/daemon.json ]; then
  # Sin "userland-proxy", Mailcow ve la IP real de quien conecta (necesario para no ser relay abierto por IPv6).
  mkdir -p /etc/docker && printf '{\n  "userland-proxy": false\n}\n' > /etc/docker/daemon.json
fi
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  apt-get update -q
  apt-get install -y -q docker.io docker-compose-v2 git curl jq
fi
command -v jq >/dev/null || apt-get install -y -q jq
systemctl enable --now docker
docker --version; docker compose version

# ---------------------------------------------------------------- 2. Mailcow
paso "Mailcow"
if [ ! -d "$MC/.git" ]; then
  git clone -q https://github.com/mailcow/mailcow-dockerized "$MC"
fi
cd "$MC"
if [ ! -f mailcow.conf ]; then
  # Rama estable (master) y sin IPv6 (el correo sale solo por la IPv4, que es la que tiene DNS inverso).
  printf '1\n' | MAILCOW_HOSTNAME=$HOST_CORREO MAILCOW_TZ=Europe/Madrid ENABLE_IPV6=false ./generate_config.sh
fi

ajusta(){ # clave valor
  if grep -q "^$1=" mailcow.conf; then sed -i "s|^$1=.*|$1=$2|" mailcow.conf; else echo "$1=$2" >> mailcow.conf; fi
}
# La web (80/443) es de Caddy: Mailcow solo escucha en local y Caddy le pasa mail.uraoni.es.
ajusta HTTP_PORT 8080
ajusta HTTP_BIND 127.0.0.1
ajusta HTTPS_PORT 8443
ajusta HTTPS_BIND 127.0.0.1
ajusta HTTP_REDIRECT n
ajusta SKIP_LETS_ENCRYPT y     # el certificado lo pone Caddy (certs.sh)
ajusta SKIP_FTS y              # búsqueda dentro de los correos: no hace falta y ahorra memoria
ajusta ENABLE_IPV6 false
grep -q '^API_KEY=' mailcow.conf || echo "API_KEY=$(openssl rand -hex 24)" >> mailcow.conf
ajusta API_ALLOW_FROM 127.0.0.1,172.22.1.1
chmod 600 mailcow.conf

# Arreglo de una primera instalación hecha con permisos demasiado cerrados (umask 077)
if [ "$(stat -c %a data/conf)" != 755 ]; then
  echo "Reparando permisos de Mailcow."
  chmod -R u+rwX,go+rX "$MC"
  chmod 600 mailcow.conf
  REINICIAR=1
fi

docker compose pull -q
docker compose up -d --remove-orphans
[ "${REINICIAR:-0}" = 1 ] && docker compose restart

API_KEY=$(grep '^API_KEY=' mailcow.conf | cut -d= -f2)
api(){ # método ruta [json]
  local extra=()
  [ $# -ge 3 ] && extra=(--data-binary "$3")
  curl -sk --max-time 30 -X "$1" -H "X-API-Key: $API_KEY" -H 'Content-Type: application/json' \
    "${extra[@]}" "https://127.0.0.1:8443/api/v1/$2"
}

paso "Esperando a que Mailcow arranque (la primera vez tarda unos minutos)"
for i in $(seq 1 60); do
  docker compose logs --no-color --tail 200 php-fpm-mailcow 2>/dev/null | grep -q 'ready to handle connections' && break
  sleep 10
done
# nginx guarda la dirección interna de PHP al arrancar; tras reinicios puede quedarse con una vieja
docker compose restart nginx-mailcow rspamd-mailcow >/dev/null
sleep 5
for i in $(seq 1 120); do
  if api GET get/status/version 2>/dev/null | jq -e '.version' >/dev/null 2>&1; then echo "Listo."; break; fi
  if [ "$i" = 120 ]; then
    echo "::error::Mailcow no responde"
    docker compose ps --format 'table {{.Service}}\t{{.Status}}'
    for s in mysql-mailcow php-fpm-mailcow nginx-mailcow; do echo "--- $s"; docker compose logs --no-color --tail 40 "$s" 2>&1 | grep -viE 'password|pass=' ; done
    free -m; df -h /; docker info 2>/dev/null | grep -iE 'version|storage|cgroup|security' 
    exit 1
  fi
  sleep 10
done

# ---------------------------------------------------------------- 3. Certificado
paso "Certificado del correo"
install -m 755 /tmp/uraoni-correo/certs.sh /usr/local/bin/uraoni-certs-correo
cat > /etc/systemd/system/uraoni-certs-correo.service <<'EOF'
[Unit]
Description=URAONI · copiar el certificado de mail.uraoni.es de Caddy a Mailcow
[Service]
Type=oneshot
ExecStart=/usr/local/bin/uraoni-certs-correo
EOF
cat > /etc/systemd/system/uraoni-certs-correo.timer <<'EOF'
[Unit]
Description=URAONI · revisar cada día el certificado del correo
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now uraoni-certs-correo.timer
/usr/local/bin/uraoni-certs-correo || true

# ---------------------------------------------------------------- 4. Contraseñas
paso "Cuentas"
[ -f "$CRED" ] || install -m 600 /dev/null "$CRED"
lee(){ grep "^$1=" "$CRED" 2>/dev/null | head -1 | cut -d= -f2- || true; }
guarda(){ install -m 600 /dev/null "$CRED.tmp"; grep -v "^$1=" "$CRED" >> "$CRED.tmp" || true; echo "$1=$2" >> "$CRED.tmp"; mv "$CRED.tmp" "$CRED"; chmod 600 "$CRED"; }

if [ -s /root/.uraoni-mailpass ]; then
  PASS_HUMANA=$(cat /root/.uraoni-mailpass); rm -f /root/.uraoni-mailpass
  ORIGEN="el secreto MAIL_PASSWORD de GitHub"
else
  PASS_HUMANA=$(lee hola); [ -n "$PASS_HUMANA" ] || PASS_HUMANA=$(aleatoria)
  ORIGEN="/root/uraoni-correo.txt (en el servidor)"
fi
guarda hola "$PASS_HUMANA"
guarda admin "$PASS_HUMANA"
PASS_NOREPLY=$(lee noreply); [ -n "$PASS_NOREPLY" ] || PASS_NOREPLY=$(aleatoria)
guarda noreply "$PASS_NOREPLY"

# Contraseña del panel de administración (sustituye la de fábrica "moohoo")
source <(grep -E '^(DBUSER|DBPASS|DBNAME)=' mailcow.conf)
HASH=$(PW="$PASS_HUMANA" python3 -c '
import os,hashlib,base64,secrets
s=secrets.token_hex(8).encode(); p=os.environ["PW"].encode()
print("{SSHA256}"+base64.b64encode(hashlib.sha256(p+s).digest()+s).decode())')
docker compose exec -T mysql-mailcow mysql -u"$DBUSER" -p"$DBPASS" "$DBNAME" \
  -e "UPDATE admin SET password='$HASH' WHERE username='admin';" 2>/dev/null
echo "Panel de administración: usuario admin, contraseña de $ORIGEN."

# Dominio
if [ "$(api GET get/domain/$DOMINIO | jq -r '.domain_name // empty')" != "$DOMINIO" ]; then
  api POST add/domain "$(jq -nc --arg d "$DOMINIO" '{domain:$d,description:"URAONI",aliases:"50",mailboxes:"10",defquota:"2048",maxquota:"10240",quota:"20480",active:"1",restart_sogo:"10",key_size:"2048",dkim_selector:"dkim"}')" | jq -c '.[0].msg'
fi

buzon(){ # local nombre contraseña
  local dir="$1@$DOMINIO"
  if [ "$(api GET get/mailbox/$dir | jq -r '.username // empty')" != "$dir" ]; then
    api POST add/mailbox "$(jq -nc --arg l "$1" --arg d "$DOMINIO" --arg n "$2" --arg p "$3" \
      '{local_part:$l,domain:$d,name:$n,quota:"2048",password:$p,password2:$p,active:"1",force_pw_update:"0",tls_enforce_in:"1",tls_enforce_out:"1"}')" | jq -c '.[0].msg'
  else
    api POST edit/mailbox "$(jq -nc --arg u "$dir" --arg p "$3" '{items:[$u],attr:{password:$p,password2:$p}}')" | jq -c '.[0].msg'
  fi
}
buzon hola "URAONI" "$PASS_HUMANA"
buzon noreply "URAONI (web)" "$PASS_NOREPLY"
# noreply@ puede enviar como hola@, así las confirmaciones salen de hola@uraoni.es
api POST edit/mailbox "$(jq -nc --arg u "noreply@$DOMINIO" --arg s "hola@$DOMINIO" '{items:[$u],attr:{sender_acl:[$s]}}')" | jq -c '.[0].msg'
# Alias habituales hacia hola@
for a in info contacto postmaster abuse dmarc; do
  if [ "$(api GET get/alias/$a@$DOMINIO | jq -r '.address // empty')" != "$a@$DOMINIO" ]; then
    api POST add/alias "$(jq -nc --arg a "$a@$DOMINIO" --arg g "hola@$DOMINIO" '{address:$a,goto:$g,active:"1"}')" | jq -c '.[0].msg'
  fi
done

# ---------------------------------------------------------------- 5. Servicio de la lista
paso "Conectar la lista de espera con el correo"
mkdir -p /etc/uraoni
install -m 600 /dev/null "$ENVF"
cat > "$ENVF" <<EOF
SMTP_HOST=127.0.0.1
SMTP_PORT=587
SMTP_USER=noreply@$DOMINIO
SMTP_PASS=$PASS_NOREPLY
FROM_ADDR=hola@$DOMINIO
REPLY_TO=hola@$DOMINIO
EOF
chmod 600 "$ENVF"
systemctl restart uraoni-lista 2>/dev/null || true

# ---------------------------------------------------------------- 6. DNS que hay que poner en DonDominio
paso "Registros DNS para DonDominio"
DKIM=$(api GET get/dkim/$DOMINIO | jq -r '.dkim_txt // empty')
IP4=194.26.100.38
cat <<EOF
Tipo   Nombre                 Valor
A      mail                   $IP4
MX     @ (prioridad 10)       $HOST_CORREO
TXT    @                      v=spf1 mx a -all
TXT    dkim._domainkey        $DKIM
TXT    _dmarc                 v=DMARC1; p=none; rua=mailto:dmarc@$DOMINIO
CNAME  autodiscover           $HOST_CORREO
CNAME  autoconfig             $HOST_CORREO
SRV    _autodiscover._tcp     0 1 443 $HOST_CORREO
EOF

paso "Comprobación del DNS (desde fuera, con 1.1.1.1)"
command -v dig >/dev/null || apt-get install -y -q dnsutils >/dev/null
mira(){ printf '%-22s %s\n' "$1 $2" "$(dig +short @1.1.1.1 "$2" "$1" | tr '\n' ' ' | cut -c1-110)"; }
mira A mail.$DOMINIO; mira MX $DOMINIO; mira TXT $DOMINIO; mira TXT dkim._domainkey.$DOMINIO; mira TXT _dmarc.$DOMINIO
mira CNAME autodiscover.$DOMINIO; mira CNAME autoconfig.$DOMINIO; mira PTR "$(echo 194.26.100.38 | awk -F. '{print $4"."$3"."$2"."$1".in-addr.arpa"}')"

paso "Certificado HTTPS de mail.uraoni.es"
if ! find /var/lib/caddy/.local/share/caddy/certificates -type d -name "$HOST_CORREO" 2>/dev/null | grep -q .; then
  systemctl reload caddy || true    # que Caddy vuelva a intentarlo ya, sin esperar a su reintento
  for i in $(seq 1 18); do find /var/lib/caddy/.local/share/caddy/certificates -type d -name "$HOST_CORREO" 2>/dev/null | grep -q . && break; sleep 10; done
fi
/usr/local/bin/uraoni-certs-correo || true
python3 - "$ENVF" <<'PY'
import smtplib,ssl,sys
env=dict(l.strip().split('=',1) for l in open(sys.argv[1]) if '=' in l)
ctx=ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
try:
    with smtplib.SMTP('127.0.0.1',587,timeout=20) as s:
        s.starttls(context=ctx)
        c=s.sock.getpeercert(binary_form=True)
        from hashlib import sha256
        s.login(env['SMTP_USER'],env['SMTP_PASS'])
        print('Puerto 587: STARTTLS y usuario noreply correctos')
except Exception as e:
    print('::warning::Puerto 587 falla:',repr(e))
PY
openssl x509 -in "$MC/data/assets/ssl/cert.pem" -noout -subject -issuer -enddate 2>/dev/null || true
echo "--- Últimos registros de la lista de espera"
journalctl -u uraoni-lista -n 15 --no-pager -o cat || true
echo "--- Cola de correo (se reintenta ya lo que esté esperando)"
docker compose exec -T postfix-mailcow postqueue -f 2>/dev/null || true
sleep 40
docker compose exec -T postfix-mailcow postqueue -p 2>/dev/null | tail -5 || true
echo "--- Últimas entregas"
docker compose logs --no-color --since 5m postfix-mailcow 2>/dev/null | grep -E 'status=(sent|deferred|bounced)' | sed -E 's/to=<[^@>]{1,3}[^@>]*@/to=<***@/' | tail -8 || true

paso "Prueba de salida por el puerto 25 (IPv4; CubePath lo bloquea hasta que lo pidas)"
IP_GMAIL=$(dig +short @1.1.1.1 A gmail-smtp-in.l.google.com | head -1)
if timeout 8 bash -c "echo > /dev/tcp/$IP_GMAIL/25" 2>/dev/null; then   # por IPv4, que es por donde sale el correo
  echo "Puerto 25 de salida: ABIERTO. Los correos ya pueden salir."
else
  echo "::warning::Puerto 25 de salida BLOQUEADO. Los correos se quedan en cola hasta que CubePath lo abra (ver README)."
fi
docker compose ps --format 'table {{.Service}}\t{{.Status}}'
