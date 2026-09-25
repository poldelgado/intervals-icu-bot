#!/usr/bin/env bash
# Funciones comunes. Se usa con `source`.

log() { printf '%s [asistente] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"; }

die() { log "ERROR: $*" >&2; exit 1; }

SESSION_NAME="${SESSION_NAME:-claude}"
export SESSION_NAME

has_claude_credentials() {
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -s "${CLAUDE_CONFIG_DIR}/.credentials.json" ]
}

# --- Validaciones compartidas por los servicios -----------------------------------
require_vars() {
  local missing=() v
  for v in "$@"; do [ -n "${!v:-}" ] || missing+=("$v"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    log "Faltan variables obligatorias: ${missing[*]}" >&2
    log "Copiá .env.example a .env, completalo y volvé a levantar (docker compose up -d)." >&2
    exit 1
  fi
}

validate_common() {
  require_vars INTERVALS_ICU_API_KEY INTERVALS_ICU_ATHLETE_ID TELEGRAM_BOT_TOKEN TELEGRAM_USER_ID
  [[ "${INTERVALS_ICU_ATHLETE_ID}" =~ ^i?[0-9]+$ ]] \
    || die "INTERVALS_ICU_ATHLETE_ID inválido (formato esperado: i123456)"
  [[ "${TELEGRAM_BOT_TOKEN}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] \
    || die "TELEGRAM_BOT_TOKEN inválido (formato esperado: 123456789:AAH...)"
  [[ "${TELEGRAM_USER_ID}" =~ ^[0-9]+$ ]] \
    || die "TELEGRAM_USER_ID debe ser numérico (obtenelo con @userinfobot)"
  CLAUDE_MODEL="${CLAUDE_MODEL:-haiku}"
  [[ "${CLAUDE_MODEL}" =~ ^[A-Za-z0-9._-]+$ ]] || die "CLAUDE_MODEL inválido: ${CLAUDE_MODEL}"
  MEMORIA_ENABLED="${MEMORIA_ENABLED:-true}"
  validate_bool MEMORIA_ENABLED
  export CLAUDE_MODEL MEMORIA_ENABLED
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    log "AVISO: ANTHROPIC_API_KEY está definida y pisaría la suscripción; la ignoro." >&2
    unset ANTHROPIC_API_KEY
  fi
}

validate_time() {  # validate_time VAR  (HH:MM, 24 h)
  [[ "${!1}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "$1 inválido (formato HH:MM, 24 h): ${!1}"
}

validate_bool() {
  [[ "${!1}" =~ ^(true|false)$ ]] || die "$1 debe ser true o false: ${!1}"
}

validate_int() {  # validate_int VAR MIN MAX (acepta negativos)
  [[ "${!1}" =~ ^-?[0-9]+$ ]] && [ "${!1}" -ge "$2" ] && [ "${!1}" -le "$3" ] \
    || die "$1 debe ser un entero entre $2 y $3: ${!1}"
}

# --- Intervals.icu ----------------------------------------------------------------
# intervals_api /ruta?query  → JSON por stdout. La API key va por stdin (no por argv).
intervals_api() {
  printf 'user = "API_KEY:%s"\n' "${INTERVALS_ICU_API_KEY}" \
    | curl -sS -f -m 30 -K - "https://intervals.icu/api/v1/athlete/${INTERVALS_ICU_ATHLETE_ID}$1"
}

# --- Telegram (Bot API) ------------------------------------------------------------
# Envía un mensaje por la Bot API al chat del usuario. El token va por stdin
# (curl -K -) para que no aparezca en la lista de procesos.
telegram_notify() {
  local text="$1"
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_USER_ID:-}" ] || return 1
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "${TELEGRAM_BOT_TOKEN}" \
    | curl -sS -m 20 -o /dev/null -f -K - \
        --data-urlencode "chat_id=${TELEGRAM_USER_ID}" \
        --data-urlencode "text=${text}"
}

# Como telegram_notify, pero parte los textos largos (límite de Telegram: 4096) por líneas.
telegram_notify_long() {
  local text="$1" chunk="" line max=3800
  if [ "${#text}" -le "${max}" ]; then
    telegram_notify "${text}"
    return
  fi
  while IFS= read -r line || [ -n "${line}" ]; do
    if [ $(( ${#chunk} + ${#line} + 1 )) -gt "${max}" ] && [ -n "${chunk}" ]; then
      telegram_notify "${chunk}" || return 1
      chunk=""
    fi
    chunk+="${line:0:${max}}"$'\n'
  done <<< "${text}"
  [ -z "${chunk}" ] || telegram_notify "${chunk}"
}

# --- Fechas en castellano --------------------------------------------------------------
DIAS_ES=(domingo lunes martes miércoles jueves viernes sábado)

fecha_larga() {  # fecha_larga [YYYY-MM-DD] → "jueves 2026-09-25"
  local d="${1:-$(date +%F)}"
  printf '%s %s' "${DIAS_ES[$(date -d "${d}" +%w)]}" "${d}"
}
