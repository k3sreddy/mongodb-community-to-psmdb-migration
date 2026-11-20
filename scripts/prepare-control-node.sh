#!/usr/bin/env bash
# Make THIS node the Ansible CONTROL HOST for the migration — run as root on the node.
#
#   scp scripts/prepare-control-node.sh root@10.0.0.11:/root/
#   ssh root@10.0.0.11 'MEMBERS="10.0.0.11 10.0.0.12 10.0.0.13" bash /root/prepare-control-node.sh'
#
# ADDITIVE ONLY. It installs ansible-core into a private venv, creates two directories and runs readiness
# checks. It never touches mongod, its config, the data volume, or any service.
#
# Why a venv instead of a system package: the controller needs Python >= 3.11, and the default python3 on
# RHEL/Rocky 8 is 3.6.8 — the same trap that makes ansible-core unusable against these hosts. Pinning
# ansible-core to one version also keeps `scripts/audit.sh` meaningful, because its module-argument check
# validates against whichever ansible-doc is installed HERE.
#
# Version choice, measured on a Rocky 8.7 node (2026-11-20): ansible-core 2.22.x declares
# "Requires-Python >=3.13" and the newest python the RHEL 8 repos provide is 3.12.x, so 2.22 CANNOT be
# installed. 2.21.x is the newest release that installs and starts on 3.12. The tree uses ansible.builtin
# only, so nothing depends on 2.22 behaviour — but re-run scripts/audit.sh after changing this pin.
set -euo pipefail

VENV="${VENV:-/root/ansible-venv}"
PROJECT="${PROJECT:-/root/ansible-prod-live-mongo}"
LOGS="${LOGS:-/root/migration-logs}"
ANSIBLE_CORE_VERSION="${ANSIBLE_CORE_VERSION:-2.21.6}"
CONTROLLER_PY="${CONTROLLER_PY:-/usr/bin/python3.12}"
MEMBERS="${MEMBERS:-10.0.0.11 10.0.0.12 10.0.0.13}"
CONTROL="${CONTROL:-10.0.0.11}"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok:   $*"; }
info() { echo "  ..    $*"; }

[[ "${EUID}" -eq 0 ]] || fail "run this as root"

echo "== 1. is this a host that is allowed to be the control node? =="
IPS="$(hostname -I 2>/dev/null || true)"
MEMBER=""
for ip in $MEMBERS; do
  case " $IPS " in *" $ip "*) MEMBER="$ip" ;; esac
done
[[ -n "$MEMBER" ]] || fail "this host ($(hostname): $IPS) is not one of the migration members ($MEMBERS) — refusing"
ok "member $MEMBER on $(hostname)"
if [[ -n "$CONTROL" && "$MEMBER" != "$CONTROL" ]]; then
  echo "  WARN: this plan nominates $CONTROL as the control host. Running from $MEMBER works, but only if"
  echo "        EVERY window runs from the same host (see below)."
fi
echo "  NOTE: every window must run from ONE control host. playbooks/04-encrypt-nodes.yml reads"
echo "        artifacts/baseline-*.json with lookup('file') — a baseline taken on another machine is"
echo "        invisible here, and the per-leg completeness gate then fails closed."

echo "== 2. screen (the window must survive an SSH drop) =="
if command -v screen >/dev/null 2>&1; then
  ok "screen $(screen --version 2>/dev/null | awk '{print $2}')"
else
  info "installing screen"
  dnf install -y screen >/dev/null || fail "could not install screen"
  ok "screen installed"
fi

echo "== 3. controller python =="
[[ -x "$CONTROLLER_PY" ]] || fail "$CONTROLLER_PY is missing — the controller needs >= 3.11"
ok "$("$CONTROLLER_PY" -V 2>&1)"

echo "== 4. ansible-core in a private venv ($ANSIBLE_CORE_VERSION) =="
if [[ -x "$VENV/bin/ansible-playbook" ]] && \
   "$VENV/bin/ansible-playbook" --version 2>/dev/null | head -1 | grep -q "core $ANSIBLE_CORE_VERSION"; then
  ok "already installed: $("$VENV/bin/ansible-playbook" --version | head -1)"
else
  info "creating venv at $VENV"
  "$CONTROLLER_PY" -m venv "$VENV" || fail "venv creation failed (is python3.12-venv installed?)"
  "$VENV/bin/pip" install --quiet --upgrade pip >/dev/null
  info "installing ansible-core==$ANSIBLE_CORE_VERSION from PyPI"
  "$VENV/bin/pip" install --quiet "ansible-core==$ANSIBLE_CORE_VERSION" || \
    fail "pip install failed — check https://pypi.org reachability from this node"
  # A version that resolves but cannot import is worse than one that does not resolve.
  "$VENV/bin/ansible-playbook" --version >/dev/null 2>&1 || \
    fail "ansible-core $ANSIBLE_CORE_VERSION installed but does not start on $("$CONTROLLER_PY" -V 2>&1)"
  ok "installed: $("$VENV/bin/ansible-playbook" --version | head -1)"
fi
"$VENV/bin/python" -c "import yaml, jinja2, cryptography" \
  || fail "controller deps missing (yaml/jinja2/cryptography) — vault and audit.sh will not run"
ok "yaml + jinja2 + cryptography importable (vault + audit.sh)"

echo "== 5. directories =="
mkdir -p "$PROJECT" "$LOGS"
chmod 700 "$LOGS"
ok "$PROJECT"
ok "$LOGS"

echo "== 6. ssh key auth from this node to every member =="
KEY="${SSH_KEY:-/root/.ssh/id_ed25519}"
if [[ ! -f "$KEY" ]]; then
  echo "  WARN: no $KEY yet — scripts/stage-control-node.sh (run from your workstation) creates it"
fi
MISSING=0
for h in $MEMBERS; do
  if ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        root@"$h" true 2>/dev/null; then
    ok "key auth to $h"
  else
    echo "  MISS: key auth to $h"
    MISSING=1
  fi
done
[[ "$MISSING" -eq 0 ]] || echo "  (fix with scripts/stage-control-node.sh from your workstation)"

echo "== 7. does the ansible tree work here? =="
if [[ -f "$PROJECT/scripts/audit.sh" ]]; then
  AUDIT_ANSIBLE_PLAYBOOK="$VENV/bin/ansible-playbook" bash "$PROJECT/scripts/audit.sh" || \
    fail "scripts/audit.sh is not clean on this host — do not start a window"
else
  echo "  WARN: project not copied yet ($PROJECT/scripts/audit.sh missing)"
fi

echo
echo "READY (pending any MISS/WARN above). Start the session with:"
echo "  screen -L -Logfile $LOGS/screen-\$(date +%Y%m%d-%H%M%S).log -S mig \\"
echo "         bash $PROJECT/scripts/session-start.sh"
