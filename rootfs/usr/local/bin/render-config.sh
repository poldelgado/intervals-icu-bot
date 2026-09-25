#!/usr/bin/env bash
# Genera la configuración en cada arranque. Es idempotente.
set -euo pipefail
# shellcheck source=lib.sh
source /usr/local/bin/lib.sh

WORKDIR="${WORKDIR:-/workspace}"
mkdir -p "${WORKDIR}/.claude" "${CLAUDE_CONFIG_DIR}" "${TELEGRAM_STATE_DIR}" "${ESTADO_DIR}" "${HOME}"
chmod 700 "${CLAUDE_CONFIG_DIR}" "${TELEGRAM_STATE_DIR}" "${ESTADO_DIR}"

# .mcp.json: los ${VAR} los expande Claude Code al leerlo; nada de secretos en disco.
if [ "${MEMORIA_ENABLED:-true}" = "true" ]; then
  mkdir -p "${MEMORIA_DIR}"
  chmod 700 "${MEMORIA_DIR}"
  jq --arg dir "${MEMORIA_DIR}" '
      .mcpServers.memoria = {
        command: "memoria-mcp",
        args: [],
        env: { MEMORIA_DIR: $dir, TZ: "${TZ}" }
      }
    ' /opt/asistente/mcp.tmpl.json > "${WORKDIR}/.mcp.json"
else
  cp /opt/asistente/mcp.tmpl.json "${WORKDIR}/.mcp.json"
fi

# CLAUDE.md del asistente + zona horaria efectiva.
{
  cat /opt/asistente/prompts/canal.md
  echo
  cat /opt/asistente/prompts/comun.md
  printf '\n## Entorno\n- Zona horaria (TZ): %s\n' "${TZ:-America/Argentina/Tucuman}"
} > "${WORKDIR}/CLAUDE.md"

# Copia de los permisos como settings de proyecto (la política real es la
# gestionada en /etc/claude-code, que ni el usuario ni el modelo pueden editar).
cp /etc/claude-code/managed-settings.json "${WORKDIR}/.claude/settings.json"

# Allowlist de Telegram sembrado: sin emparejamiento, solo TELEGRAM_USER_ID.
access="${TELEGRAM_STATE_DIR}/access.json"
[ -s "${access}" ] || echo '{}' > "${access}"
tmp="$(mktemp "${TELEGRAM_STATE_DIR}/.access.XXXXXX")"
jq --arg id "${TELEGRAM_USER_ID}" '
    .dmPolicy = "allowlist"
    | .allowFrom = ((.allowFrom // []) + [$id] | unique)
    | .groups = (.groups // {})
    | .pending = {}
  ' "${access}" > "${tmp}"
chmod 600 "${tmp}"
mv "${tmp}" "${access}"

# Evita los diálogos interactivos de primer arranque y de confianza del workspace.
cfg="${CLAUDE_CONFIG_DIR}/.claude.json"
[ -s "${cfg}" ] || echo '{}' > "${cfg}"
tmp="$(mktemp "${CLAUDE_CONFIG_DIR}/.cfg.XXXXXX")"
jq --arg w "${WORKDIR}" '
    .hasCompletedOnboarding = true
    | .projects[$w].hasTrustDialogAccepted = true
    | .projects[$w].hasCompletedProjectOnboarding = true
  ' "${cfg}" > "${tmp}"
chmod 600 "${tmp}"
mv "${tmp}" "${cfg}"

log "Configuración generada (workdir=${WORKDIR}, TZ=${TZ:-?})."
