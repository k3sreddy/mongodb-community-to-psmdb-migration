# RUNBOOK — the day-of sequences

**In this example the control host is `db-node-1` (10.0.0.11, inventory name `mongo1`).** Every window runs
from there, from one long-lived `screen` session. A workstation works equally well — what matters is that it
never changes mid-migration.

Why that constraint: `playbooks/04-encrypt-nodes.yml` reads the Phase-0 baseline with
`lookup('file', artifacts/baseline-*.json)`. That is a **local file** — a baseline taken on another machine is
invisible, and the per-leg completeness gate then fails closed *after* a wipe. One control host for the whole
change, or the gate cannot do its job.

---

## 0. What "ready" means (staged once, before the window)

Stage it once, **from your workstation**:

```bash
cd mongodb-community-to-psmdb
./scripts/stage-control-node.sh --dry-run     # preview, changes nothing
./scripts/stage-control-node.sh               # do it
```

That performs, in order: a dedicated ed25519 key for root **on db-node-1** (generated there, only the public
half travels) → that key authorised on every member → project rsynced to
`/root/ansible-prod-live-mongo` → vault password at `/root/.ansible-vault-pass` (0600) → TLS material if it
exists locally (**ca.crt + node .pem only; the CA private key never leaves the admin workstation**) → venv +
`ansible-core 2.21.6` + readiness checks + `scripts/audit.sh`.

Two security notes that come with this choice:

- the **vault password now lives on a database host** — delete `/root/.ansible-vault-pass` once the change
  record is signed;
- the node certificates (private keys) are on db-node-1 — that was already true per-node, but they are now all
  in one place. The **CA key** is not, and must not be.

## 1. Open the session (once, then leave it alone)

```bash
ssh root@10.0.0.11
screen -L -Logfile /root/migration-logs/screen-$(date +%Y%m%d-%H%M%S).log -S mig
export ANSIBLE_VAULT_PASSWORD_FILE=/root/.ansible-vault-pass
export ANSIBLE_LOG_PATH=/root/migration-logs/ansible-$(date +%Y%m%d-%H%M%S).log
export PS1='[MIG] \u@\h:\w\$ '          # the marker used to detect "session is idle"
cd /root/ansible-prod-live-mongo
. /root/ansible-venv/bin/activate
./scripts/audit.sh                       # must print "clean" — hard gate
```

`-L -Logfile` writes everything the session displays to a file, so progress can be checked **without
attaching** — that is how the run is monitored, and it is also the change evidence.

Detach: `Ctrl-a d` · Reattach: `screen -r mig` · List: `screen -ls`

**Do not** open a second session and run the same playbook: two concurrent runs on one cluster is the
failure mode this whole plan is built to avoid.

## 2. Readiness check, every time before a window

```bash
screen -r mig                                        # if not attached
cd /root/ansible-prod-live-mongo && . /root/ansible-venv/bin/activate
./scripts/audit.sh                                   # "clean" or do not proceed
ansible-playbook playbooks/00-preflight.yml          # read-only; also proves inventory, vault, shell
ls -l artifacts/baseline-*.json                      # the completeness reference for W2
```

`00-preflight.yml` is read-only and safe to run any time. In **W1** it must be run *inside the window* (not
reused from an older run) because every Phase-2 leg compares against the baseline from its own window.

## 3. Window 1 — upgrade 5.0 → 6.0 → 7.0 → 8.0

```bash
# prerequisites first (additive: mongosh + percona-release). Without mongosh the first hop deletes the
# only shell on the boxes and the run dies with mongod stopped.
ansible-playbook playbooks/00b-bootstrap.yml -e change_ticket=CHG-XXXX -e confirm_window=YES

# baseline IN this window
ansible-playbook playbooks/00-preflight.yml

# one hop at a time — NEVER chain them. Between hops, look at rs.status() yourself.
ansible-playbook playbooks/02-upgrade.yml -e change_ticket=CHG-XXXX -e confirm_window=YES -e hop=6.0
#   expect: 3 members on 6.0.29, FCV 6.0, both secondaries at lag ~0
ansible-playbook playbooks/02-upgrade.yml -e change_ticket=CHG-XXXX -e confirm_window=YES -e hop=7.0
ansible-playbook playbooks/02-upgrade.yml -e change_ticket=CHG-XXXX -e confirm_window=YES -e hop=8.0

ansible-playbook playbooks/06-verify.yml -e change_ticket=CHG-XXXX
```

Hop 6.0 is the only one that removes packages (`mongodb-org-*` → `percona-server-mongodb-6.0.29-23`). If it
stops between removal and install, the node has **no mongod binary** — restore from `/root/rpm-stage-5.0/`,
do not improvise.

Then **≥ 24 h burn-in**. No Phase 2 in the same night.

## 4. Window 2 — at-rest encryption (destructive, no backup exists)

Gate G-C (signed no-backup acceptance, `EXECUTION-PROTOCOL.md` §2A) must be signed **before** this.

```bash
ansible-playbook playbooks/03-encryption-keys.yml -e change_ticket=CHG-XXXX -e confirm_window=YES

# baseline for THIS window — the per-leg fingerprint gate compares against it
ansible-playbook playbooks/00-preflight.yml

# one run, three serial legs: mongo3 (logical) -> mongo1 (FCBIS) -> mongo2 (FCBIS, stepDown)
ansible-playbook playbooks/04-encrypt-nodes.yml -e change_ticket=CHG-XXXX \
    -e confirm_window=YES -e confirm_wipe=WIPE

ansible-playbook playbooks/06-verify.yml -e change_ticket=CHG-XXXX
```

Note this runs **on db-node-1**, which is `mongo1` — the node that leg 2 wipes. That is safe: the wipe touches
`/DATA/mongo` only, and the project, venv and logs live on `/` (285 GB free). The session survives because
`sshd` is independent of `mongod`.

Per leg, the run must show all of these before the next leg starts (it stops by itself otherwise):

| Gate | Expected |
|---|---|
| `getCmdLineOpts` on the running server | `initialSyncMethod: fileCopyBased`, `initialSyncSourceReadPreference: secondary`, `fileBasedInitialSyncMaxLagSec: 1800`, `…MaxCyclesWithoutProgress: 10` (FCBIS legs only) |
| log window markers | **no** `Falling back to logical initial sync`; **at least one** `File copy-based initial sync` / `FCBIS` |
| member state | `SECONDARY`, `health: 1`, lag 0 |
| encryption | `serverStatus().encryptionAtRest` → `AES256-GCM` |
| completeness | fingerprint ≥ the baseline from this window, per-database gate included |
| evidence file | `artifacts/fcbis-evidence/<node>-<method>-<stamp>.log` written |

If the only failure is the positive marker, read `/tmp/initial-sync-<node>.log` **on the node** before
deciding: the node is already correct and encrypted, and re-running with `-e fcbis_evidence_override=YES` is
the documented escape hatch.

## 5. Window 3 — TLS (`preferTLS`), then restarts

```bash
ansible-playbook playbooks/05-tls.yml -e change_ticket=CHG-XXXX -e confirm_window=YES
ansible-playbook playbooks/06-verify.yml -e change_ticket=CHG-XXXX
```

Before this: the PKI must be on db-node-1 (`artifacts/tls/ca.crt` + `mongo1/2/3.pem`). Issue it on the **admin
Mac** (`./scripts/issue-certs.sh`) and re-run `stage-control-node.sh` to copy — the CA **private key** must
stay off the database hosts, as `issue-certs.sh` itself says.

**Expected, not a fault:** the first two restarted members stop replicating until the third is up. **Also
expected if the apps write `w:"majority"` without `wtimeout`: those writes BLOCK for ~2–5 min** (they do not
fail, so `retryWrites` cannot help). Options A/B/C are in `EXECUTION-PROTOCOL.md` → Window 3. This is decided
by the app team's write concern, which is why that answer is a hard gate.

## 6. Collect the evidence back to your workstation (after every window)

```bash
# from your workstation
rsync -av root@10.0.0.11:/root/ansible-prod-live-mongo/artifacts/ \
      ./ansible-prod-live-mongo/artifacts-db-node-1/
rsync -av root@10.0.0.11:/root/migration-logs/ /tmp/db-node-1-migration-logs/
```

This is not housekeeping: the node keeps **7 days** of mongod log, and the artifacts (`baseline-*.json`,
`verify-*.json/.md`, `fcbis-evidence/`) are the only proof that each leg produced a complete dataset.

## 7. End of change

```bash
# in the session
exit                                     # leaves the shell; screen session ends
# then, on the node
rm -f /root/.ansible-vault-pass          # secret should not stay on a DB host
```

Keep `/root/ansible-venv` and the project until the change record is signed and the post-implementation
review is done — they are how you reproduce what ran. To remove: `rm -rf /root/ansible-venv /root/ansible-prod-live-mongo`.

---

## Appendix — how the run is driven programmatically

The session survives disconnects, so commands can be injected and progress read without attaching:

```bash
# send a command into the running session
ssh root@10.0.0.11 'screen -S mig -X stuff "ansible-playbook playbooks/00-preflight.yml\n"'

# is the session idle (at a prompt) or still working?
ssh root@10.0.0.11 'tail -c 400 /root/migration-logs/screen-*.log | grep -c "\[MIG\]"'

# read progress
ssh root@10.0.0.11 'tail -40 /root/migration-logs/screen-*.log'
```

The `[MIG] ` prompt marker (set in step 1) is what makes "is it still running" answerable without guessing.
Never inject a command while the previous one is running — check the prompt first.
