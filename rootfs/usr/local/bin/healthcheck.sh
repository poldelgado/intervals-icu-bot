#!/usr/bin/env bash
# Sano = existe la sesión tmux y el proceso claude está vivo.
set -uo pipefail
tmux has-session -t "${SESSION_NAME:-claude}" 2>/dev/null || exit 1
pgrep -x claude >/dev/null || exit 1
exit 0
