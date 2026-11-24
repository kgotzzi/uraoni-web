# URAONI · uraoni.es

Web de URAONI (裏鬼): ropa de vestir para gente que entrena. «Calma por fuera. Oni por dentro.»

Es una web estática, sin build: un solo `index.html` con su CSS y JavaScript dentro, más imágenes y tipografías. Para verla en local:

```bash
python3 -m http.server 8090
```

y abrir http://localhost:8090.

## Estructura

- `index.html`: toda la página (portada con la tela que se despega, «Abre la prenda», perchero del Drop 01 con ficha y «Mi lista», Negro sobre negro, Hannya, El código, lista de espera y pie).
- `assets/plates/`: grabado del Oni, tela, washi, chaqueta recortada y tirador de la cremallera.
- `assets/rack/`: prendas recortadas del perchero (cerradas y abiertas).
- `assets/img/`: fotos de producto, campaña, interiores, etiqueta y logotipo.
- `privacidad.html`: qué se hace con el correo de la lista de espera (se sirve en `/privacidad`).
- `fonts/`: Instrument Serif, Hanken Grotesk y los kanji (solo los caracteres que se usan).
- `servidor/lista/`: servicio de la lista de espera (`lista.py`, Python sin dependencias) y su unidad de systemd.
- `servidor/correo/`: instalación de Mailcow (`instalar.sh`) y copia del certificado de Caddy al correo (`certs.sh`).

## Normas

- Nada de precios, reseñas ni cifras inventadas. Lo que aún no existe se dice tal cual («Precio al abrir el drop»).
- La lista de espera guarda solo el correo y la fecha (sin IP). Cada correo lleva enlace de baja, y la baja borra el correo. «Mi lista» se guarda solo en el navegador de cada visitante.
- Sin claves ni contraseñas en el repositorio.

## Servidor

- **Máquina**: CubePath, proyecto `uraoni`, VPS `uraoni-web-01` (gp.starter, 8 GB, para Mailcow), Barcelona, Ubuntu 24. IPv4 `194.26.100.38`, IPv6 `2607:a2c0::47`. Cortafuegos `uraoni-web`: entrada 22, 80, 443, y para el correo 25, 465, 587, 143, 993 y 4190. DNS inverso de la IPv4: `mail.uraoni.es`.
- **Acceso**: solo con clave SSH (claves «Botigo» del PC del dueño y «GitHub-Deploy» para GitHub Actions).
- **Dominio**: `uraoni.es` en DonDominio. Registros: A `@` → `194.26.100.38`, AAAA `@` → `2607:a2c0::47`, CNAME `www` → `uraoni.es` (redirige a `uraoni.es`). La misma zona está preparada en CubePath DNS por si algún día se cambian los servidores DNS a `atlas.ns.cubepath.com` y `titan.ns.cubepath.com`.
- **En el servidor**: Caddy (HTTPS automático) con `/etc/caddy/Caddyfile` (sale de `servidor/Caddyfile`) y la web en `/var/www/uraoni`.
- **Publicar**: `.github/workflows/publicar.yml` se lanza solo con cada cambio en `main` (o a mano en Actions). La primera vez instala Caddy.
- **Registros**: Actions → «Ver registros del servidor».
- **Secretos de GitHub** (Settings → Secrets and variables → Actions): `SERVER_SSH_KEY`, la clave privada «GitHub-Deploy» (fichero `botigo_deploy` del PC del dueño, la misma que usa Botigo).

## Lista de espera y correo

- **Lista**: el formulario hace `POST /api/lista`. Caddy lo pasa a `uraoni-lista` (127.0.0.1:8787), que guarda el correo en `/var/lib/uraoni-lista/lista.db` y envía la confirmación. Baja: `/api/baja?t=…` (también la de un clic de Gmail y Apple). Si el correo aún no está conectado, las altas se guardan y la confirmación sale sola al conectarlo.
- **Ver la lista** (en el servidor): `sqlite3 /var/lib/private/uraoni-lista/lista.db "select email, alta from lista where baja is null"`.
- **Correo**: Mailcow en `/opt/mailcow-dockerized`, instalado por `.github/workflows/correo.yml`. Mailcow solo escucha en local; Caddy pone el HTTPS de `mail.uraoni.es`.
  - Webmail: https://mail.uraoni.es/SOGo (usuario `hola@uraoni.es`). Panel: https://mail.uraoni.es/admin (usuario `admin`).
  - Buzones: `hola@` (el de verdad; también le llegan `info@`, `contacto@`, `postmaster@`, `abuse@` y `dmarc@`) y `noreply@`, con el que la web envía firmando como `hola@`.
  - Contraseñas: el secreto `MAIL_PASSWORD` de GitHub (opcional) es la de `hola@` y la del panel. Sin él se generan al azar y quedan solo en `/root/uraoni-correo.txt` del servidor.
- **DNS del correo en DonDominio**: A `mail` → `194.26.100.38`; MX `@` → `mail.uraoni.es` (prioridad 10); TXT `@` → `v=spf1 mx a -all`; TXT `dkim._domainkey` (el valor sale al final del flujo «Correo (Mailcow)»); TXT `_dmarc` → `v=DMARC1; p=none; rua=mailto:dmarc@uraoni.es`; CNAME `autodiscover` y `autoconfig` → `mail.uraoni.es`.
- **Puerto 25**: CubePath bloquea por defecto la salida por el 25 en servidores nuevos. Hay que pedir que lo abran (ticket de soporte) para que los correos salgan; mientras, se quedan en cola y salen solos después.
