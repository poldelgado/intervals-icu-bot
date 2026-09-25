#!/usr/bin/env bash
# Reconstruye la imagen con las versiones fijadas y reinicia el servicio.
# Para cambiar versiones, editá CLAUDE_CODE_VERSION / INTERVALS_MCP_VERSION / BUN_VERSION
# en el .env (o pasalas como variables de entorno) antes de correr esto.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

[ -f .env ] || { echo "Falta .env (copiá .env.example)." >&2; exit 1; }
say "Reconstruyendo la imagen..."
dc build --pull
say "Reiniciando..."
dc up -d
say "Versión de Claude Code en el contenedor:"
sleep 3
in_container claude --version || true
