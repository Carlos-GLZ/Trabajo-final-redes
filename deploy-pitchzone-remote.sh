#!/bin/bash
set -euo pipefail

echo "🔧 Configurando Apache..."
sudo yum -y install httpd || true
sudo systemctl enable --now httpd

# Conf básica
sudo bash -c 'cat > /etc/httpd/conf.d/pitchzone.conf' <<APACHEEOF
ServerTokens Prod
ServerSignature Off
<IfModule mod_headers.c>
  Header always set X-Frame-Options DENY
  Header always set X-Content-Type-Options nosniff
  Header always set Referrer-Policy "strict-origin-when-cross-origin"
</IfModule>
APACHEEOF
sudo systemctl restart httpd || true

# Docroot y assets
sudo mkdir -p /var/www/html/assets

# Mover assets si llegaron
[ -f /tmp/logo_pitchzone.png ] && sudo mv /tmp/logo_pitchzone.png /var/www/html/logo_pitchzone.png && sudo chown apache:apache /var/www/html/logo_pitchzone.png && sudo chmod 644 /var/www/html/logo_pitchzone.png
[ -f /tmp/proyectos.json ] && sudo mv /tmp/proyectos.json /var/www/html/proyectos.json && sudo chown apache:apache /var/www/html/proyectos.json && sudo chmod 644 /var/www/html/proyectos.json
[ -f /tmp/universidades.json ] && sudo mv /tmp/universidades.json /var/www/html/universidades.json && sudo chown apache:apache /var/www/html/universidades.json && sudo chmod 644 /var/www/html/universidades.json
[ -f /tmp/eventos.json ] && sudo mv /tmp/eventos.json /var/www/html/eventos.json && sudo chown apache:apache /var/www/html/eventos.json && sudo chmod 644 /var/www/html/eventos.json

# JSON unificado → /assets/alianzas.json (acepta ambos nombres)
if [ -f /tmp/alianzas.json ]; then
  SRC="/tmp/alianzas.json"
elif [ -f /tmp/universidades-empresas.json ]; then
  SRC="/tmp/universidades-empresas.json"
else
  SRC=""
fi

if [ -n "${SRC}" ]; then
  sudo mv "${SRC}" /var/www/html/assets/alianzas.json
  sudo chown apache:apache /var/www/html/assets/alianzas.json
  sudo chmod 644 /var/www/html/assets/alianzas.json
  # alias de compatibilidad (si quedara alguna referencia antigua)
  sudo ln -sf /var/www/html/assets/alianzas.json /var/www/html/assets/universidades-empresas.json
fi

# === HTML ===
USE_SNIPPET_ONLY=0
if [ -f /tmp/index.html ]; then
  if ! grep -qi "<html" /tmp/index.html; then
    USE_SNIPPET_ONLY=1
  fi
fi

if [ -f /tmp/index.html ] && [ "${USE_SNIPPET_ONLY}" -eq 0 ]; then
  echo "📄 Usando index.html subido por el usuario"
  sudo mv /tmp/index.html /var/www/html/index.html
  sudo chown apache:apache /var/www/html/index.html
  sudo chmod 644 /var/www/html/index.html
else
  echo "🎨 Generando index.html (fallback) ..."
  sudo bash -c 'cat > /var/www/html/index.html' <<'HTMLEOF'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>PitchZone - Súbelo. Preséntalo. Véndelo.</title>
<link href="https://fonts.googleapis.com/css2?family=Montserrat:wght@400;600;700;800&display=swap" rel="stylesheet">
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
</head>
<body>
<h1>PitchZone</h1>
<p>Fallback mínimo. Sube tu index.html para ver el sitio completo.</p>
<script>
const API_BASE="%%API_BASE%%"; // será reemplazado por el deploy
</script>
</body>
</html>
HTMLEOF
fi

if [ -f /tmp/index.html ] && [ "${USE_SNIPPET_ONLY}" -eq 1 ]; then
  echo "➕ Anexando snippet de index.html (envuelto en <script>)"
  sudo bash -c 'printf "\n<script>\n" >> /var/www/html/index.html'
  sudo bash -c 'cat /tmp/index.html >> /var/www/html/index.html'
  sudo bash -c 'printf "\n</script>\n" >> /var/www/html/index.html'
fi

sudo chown -R apache:apache /var/www/html/
sudo chmod -r 755 /var/www/html/ || true
sudo systemctl restart httpd
echo "✅ Sitio desplegado (sin inyectar JSON en el HTML)."
