#!/usr/bin/env bash
# Se conecta a la sesión de tmux de Claude Code. Para salir SIN cerrarla: Ctrl+b y luego d.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
echo "Para desconectarte sin cerrar la sesión: Ctrl+b, después d."
exec docker compose exec "${SERVICE}" tmux attach -t "${SESSION}"
