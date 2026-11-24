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
- `fonts/`: Instrument Serif, Hanken Grotesk y los kanji (solo los caracteres que se usan).

## Normas

- Nada de precios, reseñas ni cifras inventadas. Lo que aún no existe se dice tal cual («Precio al abrir el drop»).
- La lista de espera todavía no guarda correos (lo dice la propia web). «Mi lista» se guarda solo en el navegador de cada visitante.
- Sin claves ni contraseñas en el repositorio.

## Servidor

- **Máquina**: CubePath, proyecto `uraoni`, VPS `uraoni-web-01` (gp.nano), Barcelona, Ubuntu 24. IPv4 `194.26.100.38`, IPv6 `2607:a2c0::47`. Cortafuegos `uraoni-web`: entrada 22, 80 y 443.
- **Acceso**: solo con clave SSH (claves «Botigo» del PC del dueño y «GitHub-Deploy» para GitHub Actions).
- **Dominio**: `uraoni.es` en DonDominio. Registros: A `@` → `194.26.100.38`, AAAA `@` → `2607:a2c0::47`, CNAME `www` → `uraoni.es` (redirige a `uraoni.es`). La misma zona está preparada en CubePath DNS por si algún día se cambian los servidores DNS a `atlas.ns.cubepath.com` y `titan.ns.cubepath.com`.
- **En el servidor**: Caddy (HTTPS automático) con `/etc/caddy/Caddyfile` (sale de `servidor/Caddyfile`) y la web en `/var/www/uraoni`.
- **Publicar**: `.github/workflows/publicar.yml` se lanza solo con cada cambio en `main` (o a mano en Actions). La primera vez instala Caddy.
- **Registros**: Actions → «Ver registros del servidor».
- **Secretos de GitHub** (Settings → Secrets and variables → Actions): `SERVER_SSH_KEY`, la clave privada «GitHub-Deploy» (fichero `botigo_deploy` del PC del dueño, la misma que usa Botigo).
