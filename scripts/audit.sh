#!/usr/bin/env bash
# Static audit of the LIVE migration playbooks. Contacts NO host — safe to run any time,
# including before a window and immediately after editing anything in playbooks/ or tasks/.
#
#   ./scripts/audit.sh
#
# Picks the same ansible/interpreter that the project uses: $ANSIBLE_PLAYBOOK if set, then
# .venv-check/ (the local syntax-check venv), then whatever is on PATH.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

if [[ -n "${AUDIT_ANSIBLE_PLAYBOOK:-}" ]]; then
  BIN="$(dirname "$AUDIT_ANSIBLE_PLAYBOOK")"
elif [[ -x .venv-check/bin/ansible-playbook ]]; then
  BIN="$HERE/.venv-check/bin"
else
  BIN="$(dirname "$(command -v ansible-playbook || echo /usr/bin/ansible-playbook)")"
fi

echo "using ansible from: $BIN"
AUDIT_ANSIBLE_PLAYBOOK="$BIN/ansible-playbook" \
AUDIT_ANSIBLE_DOC="$BIN/ansible-doc" \
  "$BIN/python3" "$HERE/scripts/audit.py"
