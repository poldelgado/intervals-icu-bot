#!/usr/bin/env bash
# Utilidades comunes de los scripts de ayuda (se usa con `source`).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

SERVICE=canal
# shellcheck disable=SC2034  # lo usan los scripts que hacen source
SESSION=claude

if docker compose version >/dev/null 2>&1; then
  dc() { docker compose "$@"; }
else
  echo "Necesitás Docker con el plugin Compose v2 ('docker compose')." >&2
  exit 1
fi

# Ejecuta un comando dentro del contenedor (con TTY si hay terminal).
in_container() {
  if [ -t 0 ]; then dc exec "${SERVICE}" "$@"; else dc exec -T "${SERVICE}" "$@"; fi
}

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
pause() { read -r -p "$* [Enter para continuar] " _; }
