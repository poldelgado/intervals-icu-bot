#!/usr/bin/env bash
# Guía interactiva de primera configuración.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

say "== Asistente de entrenamiento: configuración inicial =="

# --- Paso 0: .env -------------------------------------------------------------
if [ ! -f .env ]; then
  cp .env.example .env
  chmod 600 .env
  cat <<'MSG'

Creé .env a partir de .env.example. Completá ahora, con tu editor:
  - INTERVALS_ICU_API_KEY y INTERVALS_ICU_ATHLETE_ID
      Intervals.icu > Settings > Developer Settings > "API Key". El athlete ID (i123456) figura ahí.
  - TELEGRAM_BOT_TOKEN
      En Telegram, abrí @BotFather > /newbot > elegí nombre y usuario (termina en "bot") > copiá el token.
  - TELEGRAM_USER_ID
      Escribile a @userinfobot: te responde tu ID numérico.
MSG
  pause "Cuando termines de editar .env"
fi
chmod 600 .env 2>/dev/null || true

# --- Paso 1: levantar ----------------------------------------------------------
say "Paso 1/4: levantando el contenedor..."
dc up -d --build
sleep 5
if ! dc ps --status running --services | grep -qx "${SERVICE}"; then
  echo "El contenedor no está corriendo. Revisá el motivo con: docker compose logs ${SERVICE}" >&2
  exit 1
fi

# --- Paso 2: login de Claude Code ------------------------------------------------
say "Paso 2/4: login de Claude Code (suscripción Pro/Max)"
# shellcheck disable=SC2016  # las variables deben expandirse dentro del contenedor
if in_container bash -c '[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -s "${CLAUDE_CONFIG_DIR}/.credentials.json" ]' 2>/dev/null; then
  echo "Ya hay credenciales de Claude Code. Sigo."
else
  cat <<'MSG'
Elegí una opción:
  A) Token de larga duración (recomendado): en una máquina con navegador y Claude Code instalado
     corré   claude setup-token   , aprobá en el navegador, copiá el token, pegalo en .env como
     CLAUDE_CODE_OAUTH_TOKEN=... y volvé a correr este script (o: docker compose up -d).
  B) Login dentro del contenedor: se abrirá Claude Code. Escribí /login, abrí la URL en tu navegador,
     y pegá el código que te muestre el navegador. Cuando diga "Login successful", salí con /exit.
MSG
  read -r -p "¿Hacés el login B ahora? [s/N] " r
  if [[ "${r}" =~ ^[sSyY]$ ]]; then
    dc exec "${SERVICE}" claude || true
  else
    echo "Ok. Configurá el token en .env y corré de nuevo scripts/setup.sh."
    exit 0
  fi
fi

# --- Paso 3: reiniciar y verificar el canal --------------------------------------
say "Paso 3/4: reiniciando para que arranque el canal de Telegram..."
dc restart "${SERVICE}"
echo "Esperando la sesión (hasta 90 s)..."
for _ in $(seq 1 45); do
  if dc exec -T "${SERVICE}" tmux has-session -t "${SESSION}" 2>/dev/null; then ok=1; break; fi
  sleep 2
done
[ "${ok:-0}" = 1 ] || { echo "La sesión no arrancó. Mirá: scripts/logs.sh" >&2; exit 1; }

# --- Paso 4: probar --------------------------------------------------------------
say "Paso 4/4: probá el bot"
cat <<'MSG'
1. En Telegram, escribile "hola" a tu bot. Tu ID (TELEGRAM_USER_ID) ya está en el allowlist,
   así que no hace falta emparejar: debería contestarte.
2. Preguntale: "¿cómo dormí anoche?" o "¿qué entrené ayer?".
3. Si el bot pide un permiso o queda trabado, mirá la sesión con scripts/attach.sh.

Alternativa de emparejamiento manual (si preferís no sembrar el ID):
   scripts/attach.sh   -> escribí /telegram:access pair <código>
   luego               -> /telegram:access policy allowlist   (salís con Ctrl+b, d)
MSG
say "Listo."
