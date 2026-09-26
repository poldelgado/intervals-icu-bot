#!/usr/bin/env bash
# Sano = existe la sesión tmux, el proceso claude está vivo y el canal de Telegram
# (el poller `bun server.ts` del plugin) está corriendo. Sin poller el bot no recibe mensajes.
set -uo pipefail
tmux has-session -t "${SESSION_NAME:-claude}" 2>/dev/null || exit 1
pgrep -x claude >/dev/null || exit 1
pgrep -f '[b]un server.ts' >/dev/null || exit 1
exit 0
