#!/usr/bin/env bash
# Stage one cluster member as the Ansible CONTROL HOST, from your workstation.
#
#   ./scripts/stage-control-node.sh --dry-run     # show what would change, change nothing
#   ./scripts/stage-control-node.sh               # do it
#
#   CONTROL=10.0.0.11 MEMBERS="10.0.0.11 10.0.0.12 10.0.0.13" ./scripts/stage-control-node.sh
#
# WHY RUN FROM A CLUSTER MEMBER AT ALL: playbooks/04-encrypt-nodes.yml reads the Phase-0 baseline with
# lookup('file', artifacts/baseline-*.json) — a LOCAL file on the control host. A baseline taken on
# another machine is invisible there and the per-leg completeness gate then fails closed *after* a wipe.
# If you migrate from a workstation instead, never move the control host mid-change.
#
# What it does, in order (all additive — nothing touches mongod, its config, /DATA or any service):
#   1. a dedicated ed25519 key for root ON the control host (created there if absent — never copied in)
#   2. that public key installed in root@authorized_keys on every member
#   3. the project rsynced to /root/ansible-prod-live-mongo (no venv, no caches, no key material)
#   4. the vault password file copied to /root/.ansible-vault-pass (0600)
#   5. TLS material staged IF present locally — ca.crt + *.pem ONLY. The CA PRIVATE KEY never travels
#   6. scripts/prepare-control-node.sh run on the node (venv + ansible-core + audit)
#
# The key is generated ON the node and only its PUBLIC half moves, so no private key is ever copied
# between machines by this script.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# The control host defaults to the first member of the example inventory. Override for your estate.
CONTROL="${CONTROL:-10.0.0.11}"
MEMBERS="${MEMBERS:-10.0.0.11 10.0.0.12 10.0.0.13}"
REMOTE_DIR="${REMOTE_DIR:-/root/ansible-prod-live-mongo}"
VAULT_PASS="${VAULT_PASS:-$HOME/.ansible-vault-pass}"
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

say()  { echo "== $*"; }
run()  { if [[ $DRY -eq 1 ]]; then echo "   [dry-run] $*"; else "$@"; fi; }
# NOTE: root@ is explicit. A bare `ssh $CONTROL` uses your LOCAL username, which the nodes do not have.
rrun() { if [[ $DRY -eq 1 ]]; then echo "   [dry-run] ssh root@$CONTROL: $*"; else ssh -o BatchMode=yes "root@$CONTROL" "$@"; fi; }
die()  { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$PROJECT_DIR/ansible.cfg" ]] || die "run this from the project (ansible.cfg not found)"
[[ -f "$VAULT_PASS" ]] || die "vault password file $VAULT_PASS not found"

say "0. workstation -> $CONTROL reachability"
ssh -o BatchMode=yes -o ConnectTimeout=8 "root@$CONTROL" 'hostname' >/dev/null \
  || die "cannot ssh to root@$CONTROL without a password (set up key auth first)"
echo "   ok: $(ssh -o BatchMode=yes "root@$CONTROL" 'hostname')"

say "0b. refuse to re-stage while a migration session is live"
# Ansible reads task files as it walks the play, so overwriting tasks/*.yml underneath a running window
# changes the run mid-flight. Staging is a pre-window activity, by construction.
if [[ $DRY -eq 0 ]] && ssh -o BatchMode=yes "root@$CONTROL" \
     'screen -ls 2>/dev/null | grep -qE "[0-9]+\.mig"' 2>/dev/null; then
  die "a 'mig' screen session is ACTIVE on $CONTROL. Do not re-stage under a running window —
       finish or end that session first (screen -ls / screen -r mig)."
fi
echo "   ok: no active 'mig' session"

say "1. dedicated ssh key for root on the control host (for ansible's own connections)"
if [[ $DRY -eq 0 && "$(rrun 'test -f /root/.ssh/id_ed25519 && echo yes || echo no')" == "yes" ]]; then
  echo "   ok: key already exists on the node (not regenerated)"
else
  rrun 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && ssh-keygen -t ed25519 -N "" -C "ansible-control" -f /root/.ssh/id_ed25519 >/dev/null && echo "   created /root/.ssh/id_ed25519"'
fi
PUB="$(ssh -o BatchMode=yes "root@$CONTROL" 'cat /root/.ssh/id_ed25519.pub 2>/dev/null' || true)"
[[ -n "$PUB" ]] || { [[ $DRY -eq 1 ]] && PUB="ssh-ed25519 AAAA...dry-run"; }
echo "   public key: ${PUB:0:60}..."

say "2. install that public key on every member (idempotent)"
for h in $MEMBERS; do
  if ssh -o BatchMode=yes -o ConnectTimeout=8 "root@$h" \
       "grep -qF '$PUB' /root/.ssh/authorized_keys 2>/dev/null" 2>/dev/null; then
    echo "   ok: already authorised on $h"
  else
    run ssh -o BatchMode=yes "root@$h" \
      "mkdir -p /root/.ssh && chmod 700 /root/.ssh && printf '%s\n' '$PUB' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && echo '   added to $h'"
  fi
done

say "3. verify the control host can now reach every member with the key (no password, no sshpass)"
if [[ $DRY -eq 0 ]]; then
  for h in $MEMBERS; do
    ssh -o BatchMode=yes "root@$CONTROL" \
      "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 root@$h hostname" \
      || die "$CONTROL cannot ssh to $h with a key — ansible will fail on the first task"
  done
  echo "   ok: all members reachable from $CONTROL"
else
  echo "   [dry-run] skipped"
fi

say "4. project -> $CONTROL:$REMOTE_DIR"
run ssh -o BatchMode=yes "root@$CONTROL" "mkdir -p '$REMOTE_DIR'"
# `--delete` keeps the node a true mirror of what was audited, BUT it must never remove the artifacts
# produced ON the node: the baseline-*.json taken inside a window is the reference every encryption leg
# compares against, and artifacts/fcbis-evidence/ is the only proof a leg used file-copy resync. The
# `P` (protect) filter blocks deletion of those paths while still letting local copies land.
RSYNC=(rsync -a --delete
  --filter='P artifacts/***'
  --exclude '.venv-check/' --exclude '.git/' --exclude '__pycache__/'
  --exclude 'artifacts/tls/' --exclude '*.log' --exclude '.DS_Store')
run "${RSYNC[@]}" "$PROJECT_DIR/" "root@$CONTROL:$REMOTE_DIR/"
# `rsync -a` preserves the SOURCE uid/gid. From a Mac that is uid 501 / gid 20 ("games" on RHEL),
# leaving the whole tree owned by a non-root account on the node — harmless until a task runs as
# another user, and it hides real permission errors.
run ssh -o BatchMode=yes "root@$CONTROL" "chown -R root:root '$REMOTE_DIR'; chmod 700 '$REMOTE_DIR/artifacts' '$REMOTE_DIR/artifacts/tls' 2>/dev/null; chmod 600 '$REMOTE_DIR'/artifacts/tls/*.pem 2>/dev/null; true"

say "5. vault password file (0600 on the node)"
run scp -q "$VAULT_PASS" "root@$CONTROL:/root/.ansible-vault-pass"
run ssh -o BatchMode=yes "root@$CONTROL" 'chmod 600 /root/.ansible-vault-pass'
echo "   NOTE: while the migration is in flight this file is a secret on a DB host."
echo "         Remove it (/root/.ansible-vault-pass) once the change record is signed."

say "6. TLS material — only if it already exists locally, and only the certificate parts"
if [[ -f "$PROJECT_DIR/artifacts/tls/ca.crt" ]] && compgen -G "$PROJECT_DIR/artifacts/tls/*.pem" >/dev/null; then
  run ssh -o BatchMode=yes "root@$CONTROL" "mkdir -p '$REMOTE_DIR/artifacts/tls'"
  for f in "$PROJECT_DIR"/artifacts/tls/ca.crt "$PROJECT_DIR"/artifacts/tls/*.pem; do
    run scp -q "$f" "root@$CONTROL:$REMOTE_DIR/artifacts/tls/"
  done
  run ssh -o BatchMode=yes "root@$CONTROL" "chmod 600 '$REMOTE_DIR'/artifacts/tls/*.pem; chmod 644 '$REMOTE_DIR'/artifacts/tls/ca.crt"
  echo "   ok: ca.crt + node .pem copied. ca.key NOT copied (it must stay off the database hosts)."
else
  echo "   skipped: no PKI yet. Before Window 3:"
  echo "     ./scripts/issue-certs.sh          # then re-run this script"
fi

say "7. prepare the node (venv + ansible-core + screen + readiness + audit)"
run ssh -o BatchMode=yes "root@$CONTROL" \
  "PROJECT='$REMOTE_DIR' MEMBERS='$MEMBERS' CONTROL='$CONTROL' bash '$REMOTE_DIR/scripts/prepare-control-node.sh'"

cat <<EOF

== done ==
Next, on the control host:

  ssh root@$CONTROL
  cd $REMOTE_DIR
  screen -L -Logfile /root/migration-logs/screen-\$(date +%Y%m%d-%H%M%S).log -S mig \\
         bash scripts/session-start.sh

See RUNBOOK.md for the per-window command sequence.
EOF
