#!/usr/bin/env bash
# Startup for the migration control session. Run *by screen*, not by ansible.
#
#   screen -L -Logfile /root/migration-logs/screen-<stamp>.log -S mig \
#          bash /root/ansible-prod-live-mongo/scripts/session-start.sh
#
# Everything here is about making the run survivable and auditable:
#   * the venv, so `ansible-playbook` is the pinned version and not whatever PATH finds
#   * ANSIBLE_VAULT_PASSWORD_FILE, so no step ever waits for a password prompt at 03:00
#   * ANSIBLE_LOG_PATH, a per-session structured log next to screen's raw log
#   * a unique prompt marker so "is it still running?" is answerable from the log alone
set -u

PROJECT="${PROJECT:-/root/ansible-prod-live-mongo}"
VENV="${VENV:-/root/ansible-venv}"
LOGS="${LOGS:-/root/migration-logs}"
PROMPT_MARKER="${PROMPT_MARKER:-[MIG] }"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$LOGS"
cd "$PROJECT" || { echo "FATAL: $PROJECT missing"; exec bash --norc -i; }
# shellcheck disable=SC1091
. "$VENV/bin/activate" 2>/dev/null || echo "FATAL: venv $VENV missing — run prepare-control-node.sh"

export ANSIBLE_VAULT_PASSWORD_FILE="${ANSIBLE_VAULT_PASSWORD_FILE:-/root/.ansible-vault-pass}"
export ANSIBLE_LOG_PATH="$LOGS/ansible-$STAMP.log"
export PS1="${PROMPT_MARKER}\\u@\\h:\\w\\$ "

# Cluster identity, read from the inventory rather than hard-coded, so this script never disagrees with
# what the playbooks will actually target.
RS="$(grep -E '^replset_name:' inventory/group_vars/prod_live/main.yml 2>/dev/null | awk '{print $2}')"
HOSTS="$(awk '/ansible_host:/{print $2}' inventory/prod-live.yml 2>/dev/null | paste -sd' ' -)"

echo "=============================================================="
echo " MIGRATION CONTROL SESSION — $(hostname) — $STAMP"
echo " cluster  : ${RS:-unknown}  [${HOSTS:-inventory not read}]"
echo " project  : $PROJECT"
echo " ansible  : $(ansible-playbook --version 2>/dev/null | head -1)"
echo " screenlog: $LOGS/screen-$STAMP.log"
echo " ansiblelog: $ANSIBLE_LOG_PATH"
echo "--------------------------------------------------------------"
echo " Before any window:   ./scripts/audit.sh   (must print 'clean')"
echo " Read-only rehearsal: ansible-playbook playbooks/00-preflight.yml"
echo " Detach: Ctrl-a d     Reattach: screen -r mig"
echo "=============================================================="

exec bash --norc -i
