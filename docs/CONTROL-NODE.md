# Running the migration from a cluster member (control node on a database host)

Most Ansible work runs from a laptop. This migration is a case where running it **from one of the database
nodes** is the better choice — and where getting it wrong fails *after* a destructive step rather than
before it.

This document is the staging record: what to install, what it costs, what it proves, and the traps we hit
doing it. The day-of commands are in `../RUNBOOK.md`.

---

## 1. Why a cluster member is a defensible control host

| Reason | Detail |
|---|---|
| It survives your SSH session dropping | `screen` on the node; the window is independent of your workstation, and of `mongod` restarts (only a node **reboot** ends the session) |
| **Correctness, not convenience** | `playbooks/04-encrypt-nodes.yml` reads the Phase-0 baseline with `lookup('file', artifacts/baseline-*.json)` — a **local file on the control host**. A baseline taken elsewhere is invisible, and the per-leg completeness gate fails closed *after* a wipe |
| The node is always reachable | no VPN or laptop dependency during a 3–4 h window at 02:00 |

**The rule that follows:** every window must run from **one** control host. Re-staging from a workstation
mid-change invalidates the baseline path *and* overwrites task files under a running play.

If you would rather use a workstation, that is fine — just never move once the change has started.

---

## 2. What the node needs (measured, not assumed)

Verify these before you rely on them. On a stock Rocky/RHEL 8.7 node:

| Property | Typical value | Why it matters |
|---|---|---|
| `screen` | present (4.06.02) | must support `-L -Logfile` — that is how the run is monitored without attaching |
| `tmux` | often absent | use `screen` |
| `python3` | **3.6.8 — unusable** | see §3 |
| `python3.12` | 3.12.x, with `venv` + pip | the controller interpreter |
| PyPI reachable | `curl -s -o /dev/null -w %{http_code} https://pypi.org/simple/` → 200 | otherwise the venv cannot be built and you need a wheel bundle |
| Vendor repo reachable | e.g. `repo.percona.com` → 200 | the upgrade hops need it later |
| Free space on `/` | project ~400 KB, venv ~60 MB, logs | **not** on the data volume — the encryption legs wipe that |
| `sshd` independent of `mongod` | `systemctl is-active sshd mongod` | keeps the session alive across every restart in the change |
| `rsync`, `tar`, `openssl` | present | staging + PKI + `06-verify` |

Two things a stock node usually **lacks**, and both break the run in ways that are easy to misdiagnose:

- **`ansible`** — installed into a private venv by the staging script below.
- **An SSH keypair for root, and `sshpass`.** The inventory's `ansible_password` fallback is then dead: every
  task fails at authentication. Generate a key **on the node** and install only its public half on the
  members. Never copy a private key between hosts.

---

## 3. The version trap: ansible-core 2.22 needs Python ≥ 3.13

Measured on a Rocky 8.7 node, 2026-11-20:

```
$ /usr/bin/python3.12 -m pip install --dry-run "ansible-core==2.22.0"
ERROR: Ignored the following versions that require a different python version:
       2.22.0 Requires-Python >=3.13
ERROR: No matching distribution found for ansible-core==2.22.0
```

RHEL/Rocky 8 provide nothing newer than Python 3.12, so on these nodes:

| ansible-core | Requires-Python | Runs on 3.12 |
|---|---|---|
| 2.22.x | ≥ 3.13 | ✗ |
| **2.21.x** | ≥ 3.12 | ✓ |
| 2.20.x / 2.19.x | ≥ 3.12 | ✓ (fallbacks) |

The trap is that this is invisible on a modern workstation: a Mac with Python 3.13+ installs 2.22 happily, so
a tree authored and audited there will fail on the first `pip install` **inside the window**. Pin the node
venv to 2.21.x and re-run `./scripts/audit.sh` **on the node** afterwards, because its module-argument check
validates against the `ansible-doc` that is actually installed there.

This tree uses `ansible.builtin` only (assert, command, shell, copy, file, stat, slurp, fetch, set_fact,
include_tasks, add_host, pause, systemd, debug, dnf), so no behaviour depends on 2.22. `ansible.builtin.dnf`
is deliberately **not** used: on RHEL 8 its bindings exist only for platform-python 3.6, so packages are
driven through `command: dnf …` and verified with `rpm -q`.

---

## 4. What staging adds (all additive)

`scripts/stage-control-node.sh` (workstation) → `scripts/prepare-control-node.sh` (node).

| Path | What | Perms |
|---|---|---|
| `/root/ansible-venv` | venv + pinned `ansible-core` (~60 MB) | 755 |
| `/root/ansible-prod-live-mongo` | project mirror, `chown root:root` | 755 |
| `…/artifacts` | baselines and `tls/` | 700 |
| `…/artifacts/tls/{ca.crt,<member>.pem}` | certificates only | 644 / 600 |
| `/root/migration-logs` | screen + ansible logs | 700 |
| `/root/.ansible-vault-pass` | vault password, copied from the workstation | 600 |
| `/root/.ssh/id_ed25519{,pub}` | **generated on the node**, comment `ansible-control` | 600 / 644 |
| `authorized_keys` on every member | that public key appended (idempotent grep) | 600 |

Nothing else changes: `mongod.conf` mtime, the data directory, and every service stay untouched. The only
cluster-side change is control-plane files under `/root` plus one public SSH key per member.

---

## 5. PKI: issue on the workstation, copy certificates only

`scripts/issue-certs.sh` writes `artifacts/tls/{ca.crt,ca.key,<member>.pem}`. Stage **only** `ca.crt` and the
`.pem` files:

- each `.pem` is certificate **+** key concatenated — that is what `net.tls.certificateKeyFile` takes;
- the SAN must cover both the hostname **and** the IP, because members replicate by name and clients often
  connect by address;
- verify with the exact check `05-tls.yml` runs before installing the file:
  `openssl x509 -in artifacts/tls/mongo1.pem -noout -checkhost mongo1`;
- the **CA private key stays off the database hosts**. It is the trust root — back it up like the encryption
  key, and put the member-certificate expiry on a calendar (an expired member cert stops replication under
  `preferTLS` exactly like a config error).

---

## 6. Prove the staging with a read-only rehearsal

Before any window, run the read-only playbook from the session:

```bash
ansible-playbook playbooks/00-preflight.yml
```

Expect `failed=0` on every member and a fresh `artifacts/baseline-<stamp>.json`. That single run proves the
whole chain: inventory resolution, vault decryption, SSH key auth from the node, target-interpreter
selection, shell detection (`mongosh` vs `mongo`), the `setSecondaryOk()`/`collStats` fingerprint path, and
artifact writing — everything except the mutations.

It also produces the number the encryption legs will compare against, so in W2 the baseline must be taken
**in that window**, not reused from an older run.

---

## 7. The session model

| Thing | Value |
|---|---|
| Start | `screen -L -Logfile /root/migration-logs/screen-<stamp>.log -S mig bash scripts/session-start.sh` |
| What the startup script sets | venv activation, `ANSIBLE_VAULT_PASSWORD_FILE`, per-session `ANSIBLE_LOG_PATH`, a `[MIG]` prompt marker |
| Attach / detach | `screen -r mig` · `Ctrl-a d` |
| Raw log (readable while detached) | `/root/migration-logs/screen-<stamp>.log` |
| Structured log | `/root/migration-logs/ansible-<stamp>.log` |
| Inject a command | `screen -S mig -p 0 -X stuff "cmd\n"` |
| "Is it still running?" | last `[MIG] … # ` line in the log means idle at a prompt |

**Single writer.** Never open a second session and run the same playbook — two concurrent runs on one cluster
is the failure mode this whole design exists to prevent. The staging script refuses to run while a `mig`
session is alive, because Ansible reads `tasks/*.yml` as it walks the play.

**Not survivable:** a **reboot** of the control node ends the session. The change never reboots a node — it
restarts `mongod`, which is independent of `sshd`.

---

## 8. Defects this staging caught (each would have cost the window)

| # | Defect | Consequence if it had shipped | Fix |
|---|---|---|---|
| 1 | `ansible-core` 2.22 requires Python ≥ 3.13 on a node with 3.12 | the first `pip install` fails; no controller inside the window | pin 2.21.x, verify it *starts*, re-run the audit on the node |
| 2 | node had no SSH key, and no `sshpass` exists | the vault password fallback is dead; every task fails at auth | key generated on the node, public half installed on all members, verified per member |
| 3 | **`rsync --delete` deleted the node's own evidence** — the in-window `baseline-*.json` and `artifacts/fcbis-evidence/` | a re-stage between W1 and W2 destroys the reference every encryption leg compares against, plus the only FCBIS proof | `--filter='P artifacts/***'`; tested both ways |
| 4 | re-staging was possible while a window was running | overwrites `tasks/*.yml` underneath a live play — the run changes mid-flight | abort if a `mig` screen session exists |
| 5 | `scripts/issue-certs.sh` shipped mode 644 | W3 preparation fails with "permission denied" | `chmod +x` (and it is checked in executable) |
| 6 | `rsync -a` preserved the source uid/gid (Mac `501:games`) onto the node tree | harmless today; hides real permission errors, breaks if a task runs as another user | `chown -R root:root` in the staging script |

---

## 9. Accepted risks, and their mitigation

| Risk | Why accepted | Mitigation |
|---|---|---|
| **Vault password on a database host** (600) | the run must start unattended inside the window | delete it once the change record is signed |
| **All member certificates in one place** | `05-tls.yml` distributes them from the control host | the CA private key is not there, and the certs already live on those hosts |
| **Controller runs on a cluster member** | required by the baseline-lookup constraint | tiny footprint (~60 MB); fingerprints run on secondaries only, never the primary |
| **Command injection via `screen -X stuff`** | that is how the run is driven without attaching | check the prompt marker first; never inject while a task is running |
| **Member certificates expire (2 y)** | nothing renews them | put the expiry in monitoring/calendar — README §13 item 6 |

---

## 10. How to unwind the staging

Control-plane only — this does **not** touch `mongod`, its config or the data volume:

```bash
# on the control node
screen -S mig -X quit
rm -f  /root/.ansible-vault-pass
rm -rf /root/ansible-venv /root/ansible-prod-live-mongo /root/migration-logs

# only if the whole migration is abandoned:
#   rm -f /root/.ssh/id_ed25519 /root/.ssh/id_ed25519.pub
#   and remove the 'ansible-control' line from /root/.ssh/authorized_keys on every member
```

Archive `artifacts/` and `/root/migration-logs/` first — they are the change evidence.

---

## 11. Pre-window checklist

- [ ] `screen -ls` shows exactly one `mig` session, idle at a `[MIG]` prompt
- [ ] `./scripts/audit.sh` prints **clean** on the control node
- [ ] `ansible-playbook --version` is the version you audited with
- [ ] `00-preflight.yml` passes **in this window**, and `artifacts/baseline-*.json` is fresh
- [ ] the vault decrypts without a prompt (`ANSIBLE_VAULT_PASSWORD_FILE` is set)
- [ ] key auth works from the control node to **every** member — not just some
- [ ] for W3: `artifacts/tls/ca.crt` + one `.pem` per member, each passing `openssl x509 -checkhost`
- [ ] a second person is watching replication lag and application error rate
