# MongoDB Community 5.0 → Percona Server for MongoDB 8.0

**A rolling, version-by-version migration with at-rest encryption and TLS, driven by Ansible.**

Community 5.0 went end-of-life in October 2024. This repository is the automation, and the reasoning, for
moving a 3-member production replica set off it — one major version at a time, one node at a time, without
taking the cluster down and **without a logical backup**.

It is published because the hard parts are not in the `dnf` commands. They are in the sequencing
(`FCV` gates, which node may be wiped when), in the two failure modes that look like success
(`preferTLS` blocking `w:"majority"` writes, and FCBIS silently falling back to a logical resync **after**
the disk is wiped), and in a handful of traps that cost us real debugging time — all documented here,
with the checks that make each one loud instead of silent.

> **This is not a copy-paste-to-production template.** It assumes you will read `EXECUTION-PROTOCOL.md`
> and adapt `inventory/` to your own estate. Every hostname, IP, database name and secret in this repo is
> a placeholder (see *Adapting this to your estate*).

---

## What it does

| Phase | Playbook(s) | What happens | Downtime |
|---|---|---|---|
| **1. Upgrade** | `00b-bootstrap`, `02-upgrade` | Community 5.0 → PSMDB 6.0 → 7.0 → 8.0, **rolling, secondaries first, primary last**. FCV raised only after every member reports the new binary. | none (a `stepDown`, i.e. one election per hop) |
| **2. Encryption** | `03-encryption-keys`, `04-encrypt-nodes` | Each node in turn: wipe its `dbPath`, resync from a healthy peer with **AES256-GCM at rest** enabled, verify fingerprint completeness before touching the next node | none (never more than one member down) |
| **3. Security baseline** | `05a-audit-log`, `05-tls` | Audit log config (JSON, least-privilege rotator, 1 GiB rotation, 7-day retention), then certificates + `net.tls.mode: preferTLS` with serial restarts. Ends with **TLS and plaintext both accepted** — no application change required. Order is enforced: `05a` writes config, `05-tls`'s single restart activates it | a few minutes of write stall (see W3 warning) |
| **4. Verify** | `00-preflight`, `06-verify` | Read-only baseline + post-change verification: versions, FCV, encryption, TLS, replication lag, per-database document fingerprints | none |

## The four things that will bite you

Read these before anything else. Each one is a real defect that survived code review and static analysis,
and each is now a hard gate in the playbooks.

1. **`preferTLS` takes two members out of replication at once.** The first two restarted members cannot
   find a TLS-speaking peer, so they stop replicating until the third is up. If your clients write with
   `w:"majority"` and **no `wtimeout`**, those writes **block** for 2–5 minutes — they do not fail, so
   `retryWrites` cannot rescue them. Get the app team's write concern in writing first;
   `EXECUTION-PROTOCOL.md` → Window 3 has three options.
2. **FCBIS can silently fall back to a logical initial sync**, after you have already wiped the node. The
   data still arrives, hours later, and your window is gone. The playbooks assert both the *positive* log
   marker and the *absence* of the fallback marker — and the marker is `File copy-based initial sync`
   (hyphenated). The unhyphenated string matches nothing on any build, so a naive grep reads `0` forever
   and looks like a pass.
3. **A skipped Ansible task still registers its variable.** `is defined` is true, `.stdout` is not, and
   the whole gate dies — or worse, silently evaluates against a stub. This bit the fingerprint gate, which
   is the *only* completeness proof in a no-backup migration.
4. **`ansible-core` 2.22 requires Python ≥ 3.13**, and Rocky 8 / RHEL 8 ship 3.12 at best. Pin the
   controller accordingly — the error surfaces as a generic "no matching distribution" at the worst time.
   The same Python 3.6-era trap makes `ansible.builtin.dnf` unusable on RHEL 8 targets; the playbooks drive
   `dnf` via `command:` and verify with `rpm -q`.

## Requirements

- **Control host:** Linux or macOS with Python ≥ 3.11 and `ansible-core` **2.21.x** (`2.22` needs Python
  3.13). One control host for the entire change — see `docs/CONTROL-NODE.md` for why.
- **Targets:** RHEL/Rocky 8, MongoDB **Community 5.0.x**, Python 3.9+ available for Ansible
  (`/usr/bin/python3.12` in our case), `mongosh` installed or installable.
- **Access:** root over SSH (key auth preferred — the vault fallback never works without `sshpass`).
- **Disk:** each member needs its current dataset size **free** on the data volume for the encryption
  phase (wipe + resync into the same volume).
- **A change window** for phases 1 and 2, and an app-team answer on write concern for phase 3.

## Quickstart

```bash
git clone <this-repo> && cd mongodb-community-to-psmdb

# 1. point the inventory at your cluster (three members, one PRIMARY)
$EDITOR inventory/prod-live.yml
$EDITOR inventory/group_vars/prod_live/main.yml     # allow-list IPs, replica set name, paths, package pins

# 2. secrets
cp inventory/group_vars/prod_live.vault.yml.example inventory/group_vars/prod_live/vault.yml
ansible-vault encrypt --vault-password-file ~/.ansible-vault-pass \
    inventory/group_vars/prod_live/vault.yml
chmod 600 inventory/group_vars/prod_live/vault.yml

# 3. prove the tree is internally consistent, then read the cluster (no changes)
./scripts/audit.sh
ansible-playbook playbooks/00-preflight.yml

# 4. only then, inside an approved window
ansible-playbook playbooks/00b-bootstrap.yml   -e change_ticket=CHG-0001 -e confirm_window=YES
ansible-playbook playbooks/02-upgrade.yml      -e change_ticket=CHG-0001 -e confirm_window=YES -e hop=6.0
# ... hop=7.0, hop=8.0 — never chained, always check rs.status() between hops
```

`RUNBOOK.md` has the full per-window command sequence, the operator checkpoints and the per-leg gate
table. `EXECUTION-PROTOCOL.md` has the abort thresholds.

## Repository layout

```
inventory/         inventory + group_vars (cluster identity, version pins, tolerances, paths)
playbooks/         00 preflight · 00b bootstrap · 01 backup (optional) · 02 upgrade
                   03 encryption keys · 04 encrypt nodes · 05 TLS · 06 verify · site.yml
tasks/             reusable steps: preflight-common, node-upgrade, merge-mongod-conf,
                   encrypt-leg, stepdown, tls-activate-one, wait-member-synced
scripts/           audit.py (13 static checks) · issue-certs.sh · leak-scan.sh
                   stage-control-node.sh / prepare-control-node.sh / session-start.sh
docs/              CONTROL-NODE.md (staging a cluster member as control host) · PITFALLS.md
README.md          the plan, the design decisions and the audit history (§12A)
EXECUTION-PROTOCOL.md   gates, abort thresholds, the no-backup decision record
RUNBOOK.md         day-of command sequences
```

A GitHub Actions workflow (`.github/workflows/static-checks.yml`) runs `--syntax-check`, then
`scripts/audit.sh`, then `scripts/leak-scan.sh` on every push. None of the three contacts a host or needs a
credential, which makes them the cheapest way to catch a gate that cannot fire. On a fresh clone
`audit.sh` **warns** (does not fail) that `inventory/group_vars/prod_live/vault.yml` is missing — that is the
correct state until you create it.

## Documents, in the order you should read them

| Read | Why |
|---|---|
| `docs/PITFALLS.md` | the condensed list of traps — 10 minutes, saves a window |
| `README.md` §1–§8 | the design: why version-by-version, why wipe+resync instead of dump/restore, the gates |
| `EXECUTION-PROTOCOL.md` | what stops the run: gates, abort thresholds, the no-backup acceptance |
| `RUNBOOK.md` | what to type, in what order, and what to check between steps |
| `README.md` §12A | the audit history — every defect found, and the check that now catches it |
| `docs/CONTROL-NODE.md` | if you will run this from one of the database nodes instead of a laptop |

## Adapting this to your estate

Everything environment-specific lives in two files, which is deliberate:

- `inventory/prod-live.yml` — the three members and their `ansible_host` addresses.
- `inventory/group_vars/prod_live/main.yml` — replica set name, `allowed_member_ips`,
  `forbidden_member_ips`, data/config paths, the package pins per hop, the fingerprint tolerances.

Values that are **placeholders you must change**: `rs0`, `example.internal`, `10.0.0.11/12/13`,
`10.0.0.21-23` (the "do not touch" look-alike cluster), `/DATA/mongo`, `/etc/mongodb/keyFiles/mongo-key`,
`/mnt/mongo-nfs`, and the six package NVRAs. The database names in the examples (`orders`,
`event_log`, …) are illustrative.

`scripts/leak-scan.sh` checks a checkout for private key material, real private-IP ranges outside the
example block, and an accidentally committed vault file — run it before you push your own fork.

## About this case study

The numbers in §12A are real measurements from the cluster this was written for: 3 members,
**~1.2 billion documents across 35 databases**, ~0.7 TB per member, 250 GB RAM, 128 GB WiredTiger cache,
on Rocky 8.7/8.8. They are here because they are *why* the tolerances and timings are what they are —
not because your cluster looks like this. Scale the timeouts (`resync_wait_retries`,
`fcbis_max_lag_sec`) to your data size and write rate.

**Status of this repository, stated precisely**, because the difference matters when you are deciding
whether to trust it:

- The **procedure** was executed end to end on a second replica set in the same estate — including the
  wipe+resync encryption phase and the TLS rollout. The order, the gates and the timings come from that
  run.
- The **three windows for the cluster described above were not run** at the time of publication. What was
  completed there: control-node staging, the full read-only `00-preflight.yml` baseline, and every static
  audit. The plan was armed and awaiting its change window.
- The PSMDB version pins, FCBIS parameter names and log markers were verified **against the 8.0.29 binary**
  on those hosts, not taken from documentation.

This public copy is a sanitized reconstruction: hostnames, IPs, domain, replica-set name, database names
and certificates are placeholders, and it has not been re-run after sanitization. Treat it as a reviewed
starting point — run `./scripts/audit.sh`, run `00-preflight.yml`, and rehearse in a lab first.

## License

MIT — see `LICENSE`.

---

## 1. Scope

Bring one production replica set (`db-node-1/2/3`) to a supported, encrypted, TLS-capable build, without
taking the cluster down and without a logical backup:

| | Before | After |
|---|---|---|
| Build | MongoDB **Community 5.0.8** (EOL, unpatched CVEs) | **Percona Server for MongoDB 8.0.29-13** |
| FCV | `5.0` | `8.0` |
| At-rest encryption | **none** | AES256-GCM, shared key, DR copy off-box |
| TLS | **none** | **enabled, `preferTLS`** — TLS accepted **and non-TLS accepted** (deliberate end state, no app change required) |
| Audit log | none | JSON audit + 1 GiB size-triggered rotation + 7-day/20 GiB retention — **automated** (`05a-audit-log.yml`) and asserted by `06-verify.yml` |
| bindIp | `0.0.0.0` | **unchanged — stays `0.0.0.0`** (decision 2026-11-24; accepted risk R3, §11). Recorded in every report, never managed by a play |
| Backup | none, and **none taken** (decision recorded in `EXECUTION-PROTOCOL.md` §2A) | unchanged; compensating controls replace it |

**In scope:** members `mongo1` (.11), `mongo2` (.12, PRIMARY), `mongo3` (.13); `/DATA/mongo` ~0.7 TB;
35 databases; oplog ~50 GB; ~350 writes/s.

**Out of scope (but must not be broken):** the second (standby) cluster — it shares the replica set name,
see below — the application workloads themselves, and any directory-service/LDAP integration.

### The single largest risk in this kind of migration

A second cluster in the same estate uses the **same replica set name** (`rs0`). A mistake that crosses the
two sets — a play against the wrong inventory group, `rs.add`-ing a member from the other set, or an app
pointing at the wrong host list — is close to unrecoverable (divergent oplogs, forced reconfig, possibly a
rolled-back write). Every playbook here therefore asserts its membership against a hard-coded allow-list
(§4 G1), refuses any host on `forbidden_member_ips`, and **no playbook ever calls `rs.add` / `rs.remove` /
`rs.reconfig`**.

If your estate does not have that shape, keep the allow-list anyway: it is what makes a wrong-inventory run
impossible instead of merely unlikely.

---

## 2. Why Ansible — and what stays manual

Ansible is the right tool for the 80 % that is deterministic, repetitive and identical-but-for-one-parameter:
repo switching, package pinning, config ≥ baseline enforcement, `rs.status()` polling, doc-count
fingerprints, and the wipe+resync legs (where a human typo in `rm -rf` is the classic disaster).

Ansible is **not** allowed to own these; they are explicit human go/no-go gates:

| Not automated | Why |
|---|---|
| Executing any `*-apply` play | Playbooks are gated on `confirm_*` extra-vars; a human passes them inside the window |
| `setFeatureCompatibilityVersion` beyond installed binaries | FCV is a one-way ratchet; the *decision* to burn it is a change-approval decision |
| App connection-string readiness | Only the app team can confirm `retryWrites=true` + all-host URI (§5 G2) |
| Which member syncs from which (FCBIS source) | Ansible asserts the constraint, the operator chooses the leg order at the gate |
| Declaring the window closed | Fingerprint + smoke test must be read by a human (§8) |

Everything else — including every restart — is playbook-driven so the same bytes run in the rehearsal
and in prod.

---

## 3. Strategy

Inherited from the two migrations we already completed (dev 5.0.8→8.0.28-12, prod-backup 5.0.8→8.0.29-13),
**not** re-invented. Three phases, three windows, one cluster. No rebuild path (Path A) is proposed:
0.8 TB of live traffic with 34 DBs and shared apps makes the in-place rolling path strictly cheaper, and it
is now a proven procedure on identical hardware.

Each window opens only when `EXECUTION-PROTOCOL.md` §2 is satisfied and the change owner gives an explicit
go. The Ansible commands below are *what would run*, not instructions to run them now.

### Phase 0 — Pre-flight and rehearsal (Window 1, first half, ~1–2 h)
1. `00-preflight.yml` — read-only: topology verification (G1), versions, FCV, disk, NFS, mongosh presence,
   config md5 baseline, **doc-count fingerprint**, `rs.status()` snapshot → `artifacts/`.
2. Rehearsal — re-run the FBIS validation on dev (already proven once, re-prove on the current build) so the
   Phase 2 timings hold. With no backup in play this rehearsal stops being a formality: it is the evidence
   that a wipe+resync on this build actually completes. Zero risk, ~1 h.
3. Confirm the 5.0 → 8.0 RPM sets are staged in `/root/rpm-stage-*/` on each prod node (Phase 1 binary rollback).

**No backup is taken (ops decision, same as the reference-cluster migration).** That is accepted, not ignored: the
controls in §2A of `EXECUTION-PROTOCOL.md` carry the risk instead, and the per-DB fingerprint becomes the
only proof that a resynced node is complete.

### Phase 1 — Version upgrade 5.0 → 6.0 → 7.0 → 8.0 (Window 1, second half, ~2–3 h)
`02-upgrade.yml` per hop, secondaries first, **`rs.stepDown(300)` before touching the primary**, FCV bumped
`confirm:true` at 7.0 and 8.0, verify version + FCV + SECONDARY + lag < 5 s before the next node.
FCV stays at the *source* major for the whole binary swap of each hop. Data is never touched.

**Community → Percona package transition (hop 6.0 only).** `mongodb-org-*` and
`percona-server-mongodb` own the same paths (`/usr/bin/mongod`, `/etc/mongod.conf`), so installing one
over the other is a dnf file-conflict failure — with mongod already stopped, that is an outage. The
play removes the community packages between *stop* and *install*, restores the saved config afterwards,
and re-asserts ownership of `/DATA` (removing `mongodb-org-server` can recreate the `mongod` user with a
different uid; the recursive `chown` only runs when the uid actually moved).

**Rollback staging is a hard gate, not a directory.** Before mongod stops, the play downloads the
*currently installed* RPM set to `/root/rpm-stage-<major>/` and a copy of the running binary is kept
alongside it. It then asserts that ≥ 4 RPMs are actually on disk **and** that nothing failed to download
(`download-warnings.txt` empty). A node that cannot be rolled back is not allowed to be upgraded —
override only with `-e allow_missing_rollback=YES` and a written acceptance.

### Phase 2 — At-rest encryption, wipe + resync (Window 2, ~3–4 h)
`03-encryption-keys.yml` then `04-encrypt-nodes.yml`, **serial, one node at a time**:
1. `mongo3` (secondary) — **logical** initial sync (unavoidable: first node has no encrypted source; it pays
   the one-time index-rebuild cost, ~1.5–2.5 h at 661 collections).
2. `mongo1` (secondary) — **FCBIS** (physical copy, no index rebuild, ~30–45 min at measured ~1.15 GB/s).
3. `mongo2` (primary) — `rs.stepDown(120)` → FCBIS → priority re-elects `mongo2`.
   The playbook verifies the named donor (`mongo3`); the server itself may pick either encrypted
   secondary as the sync source, which is safe because every member already carries the same key (G11).
   This is the only Phase-2 client-visible failover (~10–30 s, transparent with `retryWrites=true`).

**Config gate before every wipe** (the 25 Aug incident): `grep -c enableEncryption /etc/mongod.conf` must be `1`
on the target, and FCBIS targets must carry `initialSyncMethod: fileCopyBased` +
`initialSyncSourceReadPreference: secondary` + `fileBasedInitialSyncMaxLagSec: 1800` +
`fileBasedInitialSyncMaxCyclesWithoutProgress: 10`. Ansible asserts this and refuses to continue.

**After every leg** the run proves three separate things, because "the file says fileCopyBased" proves
only that a file was written: the **running server** carries the parameters (`getCmdLineOpts`); the leg's
own log window contains **no** logical-fallback marker; and it contains a **positive** file-copy marker.
The window is cut from a line offset taken *before* the restart and fetched into
`artifacts/fcbis-evidence/`, because the nodes keep only 7 days of log (see §5B for the marker table and
the one documented override).

### Phase 3 — Post-upgrade security baseline (Window 3, ~1 h, low risk)
`05-tls.yml` — write the `preferTLS` config + certs to **all three** members first, then restart them
**one at a time** (`mongo3` → `mongo1` → `mongo2`), waiting for each to be back in service and caught up
before the next one moves. All three end the run on the same `net.tls` config (G9), but the restarts are
serial: restarting them back-to-back would put two members down at once, cost the set its majority, and
turn a zero-downtime change into an outage. The primary is stepped down immediately before its own
restart — the only client-visible event in this phase.

The cluster is left in **`preferTLS` permanently** for this change: members replicate over TLS, while
clients may connect with or without TLS. Both paths are verified on every node at the end of the play and
again in `06-verify.yml`.

**Expect a replication stall during this rollout.** `preferTLS` uses TLS for *outbound* connections, so a
restarted member cannot open a replication link to a peer that has not been restarted yet. The first two
restarted members therefore sit idle (healthy, SECONDARY, not syncing) until the third is restarted — this
is normal and the play tolerates it, then asserts full catch-up on all three once the rollout is complete.
Do not "fix" it by restarting the remaining members at the same time: two members down costs the set its
majority and turns this into a real outage.

`requireTLS` is **not** part of this change — it is unreachable without `-e confirm_require_tls=YES`, and it
would break every application that has not yet moved to `tls=true`. See §11 for the risk this accepts.

**Order inside this window: `05a-audit-log.yml` → `05-tls.yml` → `06-verify.yml`.** mongod reads its
`auditLog` block **only at startup**, and `05-tls` performs this window's only restart — so the audit log
costs no extra rollout, and `05-tls` refuses to roll if `05a` has not already written the block (ordering
gate). Running them the other way round silently defers the audit log to "some later restart", which in
practice means never.

`05a-audit-log.yml` (config only — nothing is active until the restart):
- writes `auditLog` (JSON file destination, security-relevant event filter — the filter is the volume lever;
  see `audit_filter` in the group vars)
- creates the least-privilege `audit-rotator` user (privilege: `logRotate` **only**), because a cron that
  fires every 10 minutes must not hold admin
- installs size-triggered rotation (1 GiB, checked every 10 min) with 7-day age retention and a 20 GiB hard
  cap — via `logRotate: 1` (reopen), since PSMDB has no `rotateAuditLog`

`06-verify.yml` then answers three separate questions, because each fails differently: did the **running
process** parse the block (`getCmdLineOpts`), does the file contain valid JSON, and does a **forced rotation
actually produce** a new `audit.log.<stamp>` (the command returning `ok` is not evidence).

`bindIp` is **not** changed: it stays `0.0.0.0` by decision. No play merges `net.bindIp`; the baseline and
verify reports record the value so the exposure is documented rather than assumed. Rationale and
compensating controls: §11 R3.

`06-verify.yml` — final fingerprint equality, smoke test, per-node build/FCV/encryption report.

---

## 4. Hard guardrails (enforced in code, not just prose)

| # | Rule | Enforced by |
|---|---|---|
| G1 | Never assume topology; verify member/IP/hostname on every node | `00-preflight.yml`, and again at the top of `02`/`04` |
| G1b | **This set only.** Member IP must be in `allowed_member_ips`; membership must never contain a reference-cluster IP | `assert` in `tasks/preflight-common.yml` |
| G2 | Never restart the PRIMARY without `rs.stepDown` | primary runs only in the `prod_live_primary` play, after a stepDown+wait task |
| G3 | systemd PIDFile drop-in required (`Type=forking` vs `/var/run/mongodb/mongod.pid`) | `tasks/node-upgrade.yml` |
| G4 | Packages overwrite `/etc/mongod.conf` — save and restore | same |
| G5 | `mongosh` must exist on the target (legacy `mongo` shell is gone at 8.0) | preflight assert |
| G6 | Fingerprint (per-DB doc counts) before/after every phase | `00` writes, `06` compares |
| G7 | One node at a time; verify sync before the next | `serial: 1`, `max_fail_percentage: 0`, poll-until-synced |
| G9 | Never *finish* with mixed `net.tls` states; restarts are **serial**, one at a time, and replication lag is not gated mid-rollout (TLS uses TLS outbound) | `05-tls.yml` stages config everywhere, then `tasks/tls-activate-one.yml` per member, waiting in between |
| G10 | **No backup during an FCBIS leg**; no writes to the target's `local` DB | assert: no `mongodump`/`pbm` process on source/target |
| G11 | TDE keyfile must be **raw 32 bytes**, not hex text; identical sha256 on all members | `03-encryption-keys.yml` asserts length + hash equality |
| G12 | FCV ratchet: never set FCV above the installed binary major | computed from `buildInfo.version` |
| G13 | **No backup exists.** Every wipe requires 3/3 healthy + steady members, a healthy sync source, and every resync must beat the Phase-0 fingerprint | `tasks/encrypt-leg.yml` (state + source-health asserts, completeness check), `04-encrypt-nodes.yml` (baseline required) |
| G14 | Community `mongodb-org-*` must be removed before the Percona package is installed (file conflicts) | `tasks/node-upgrade.yml` (detect → stop → remove → install → restore config → uid check) |
| G15 | No node is upgraded unless its rollback RPM set is really on disk | `tasks/node-upgrade.yml` (RPM count + `download-warnings.txt` assert; `-e allow_missing_rollback=YES` to override in writing) |

---

## 5. Gate checklist (print this; ops sign each line)

**Automated pre-gate, run 10 minutes before the window:**

```bash
./scripts/audit.sh        # must print "clean" — static only, contacts nothing
```

**G-A: Start of Window 1**
- [ ] Change approved; window announced; app team confirmed `retryWrites=true` + full host list for **10.0.0.11/12/13** (not the reference cluster)
- [ ] `00-preflight.yml` PASS (all asserts green); baseline fingerprint archived
- [ ] **No-backup acceptance recorded** in the change: rollback = peer resync only, and a double-node failure is unrecoverable
- [ ] 5.0/6.0/7.0/8.0 RPM sets staged on each node; `mongosh` present on all 3
- [ ] Monitoring live: primary CPU/IO, repl lag, app error rate

**G-B: Before each hop's primary restart**
- [ ] Both secondaries on hop *N*, `health=1`, lag < 5 s
- [ ] `rs.stepDown(300)` executed; new primary is **not** the node about to be restarted
- [ ] No resync in progress anywhere

**G-C: Before Phase 2 (destructive, no backup)**
- [ ] Phase 1 verified: `8.0.29-13` + FCV `8.0` on all 3, fingerprint matches baseline, smoke test PASS
- [ ] ≥ 24 h burn-in completed with no anomalies
- [ ] Shared key installed on all 3, identical sha256, DR copy on NFS + off-box
- [ ] **Two senior engineers accept, in writing, that the only rollback is a resync from the two surviving members** — and that losing two members at once is unrecoverable
- [ ] FCBIS re-validated on dev for these timings (§2A.1)
- [ ] Both surviving members confirmed `health=1`, lag ≈ 0, and fingerprint-identical **immediately before the first wipe**

**G-D: Before each wipe leg**
- [ ] `grep -c enableEncryption /etc/mongod.conf` == 1 on target (repeat per node — this is the 25 Aug failure)
- [ ] Target is SECONDARY, source is encrypted + `health=1`, no backup running
- [ ] Other two members `health=1`, lag < 5 s (never wipe when the set is already degraded)

**G-E: Close-out**
- [ ] All 3 encrypted (`encryptionAtRest.encryptionEnabled == true`), key hash equal
- [ ] Fingerprint identical on all 3 and equal to baseline (± live app writes — explain every delta)
- [ ] Plaintext-leak scan: unique token not found in dbPath (`grep -a` → 0)
- [ ] `mongo2` PRIMARY (priority 2), lag ≤ 2 s, smoke write→replicate→read→delete PASS
- [ ] Audit log proven on all 3: running process parsed the block, file holds valid JSON, **a forced rotation produced a new `audit.log.<stamp>`**, cron + script installed (`06-verify.yml` asserts all four)
- [ ] `bindIp` recorded in the report as `0.0.0.0` — **unchanged by decision** (R3); no play was allowed to touch it
- [ ] Old RPMs retained ~1 week, then cleaned; report filed; change closed

---

## 5A. Prerequisites measured on the real nodes (run 00b before anything else)

The plan was written against the cluster as documented. On 2026-11-19 the read-only preflight was
run against the live members and four assumptions turned out to be wrong. They are now encoded in
the playbooks (and enforced by `scripts/audit.sh`), but they explain the two new prerequisites:

| Measured reality | Why it breaks the plan | Where it is handled |
|---|---|---|
| Default `/usr/bin/python3` is **3.6.8** | ansible-core 2.22 module payloads need >= 3.7; every module fails with `future feature annotations is not defined` | `ansible_python_interpreter: /usr/bin/python3.12` in `group_vars/all.yml` (3.12 is present on all three nodes) |
| `ansible.builtin.dnf` **cannot work** | the dnf python bindings exist only for platform-python 3.6, which ansible-core cannot use | packages driven via `command: dnf ...` + `rpm -q` verification (`tasks/node-upgrade.yml`) |
| **`mongosh` is not installed** (only legacy `mongo` 5.0.8, owned by `mongodb-org-shell`) | every read and every gate drives `mongosh`; the first hop removes the package that owns `mongo`, so the run dies right after the binaries are swapped | `playbooks/00b-bootstrap.yml`; `require_mongosh: true` on every mutating play; read-only preflight still falls back to `mongo` |
| **`percona-release` is not installed** | `tasks/node-upgrade.yml` uses it to enable exactly one PSMDB repo per hop | `playbooks/00b-bootstrap.yml` |
| keyFile is `/etc/mongodb/keyFiles/mongo-key`, **not** `/etc/mongod.key` | the rollback staging of the keyfile, and the keyfile checksum gate, hit a missing file | `key_file` in `group_vars/prod_live/main.yml`, asserted against the running config by `00-preflight.yml` |
| the set's members are named `mongo1` / `mongo2` / **`db-node-3`** | a hostname allow-list rejects the real cluster, and `rs.status()` lookups by inventory name match nothing (the FCBIS donor check) | cluster identity asserted on **resolved IPs**; `rs_member_by_ip` maps host -> set name |
| the cluster holds **1.17 billion documents** in 35 databases | `countDocuments({})` per collection turns one fingerprint into hours, and it runs 8+ times | `collStats.count` in `fingerprint_js` (~5 s per run) |
| `listDatabases` is **primary-only** | on a secondary it returns `{ok:0}` with no `.databases`, so the fingerprint JS threw and the gate could never pass | `setSecondaryOk()` before the first admin command |
| two healthy secondaries differ by **9,696 docs (8 ppm)** | exact-equality comparison fails on every live run, so the completeness gate proves nothing | tolerance gate: identical database set + totals within 250 k / 0.05% |
| **`/var/log/mongodb` keeps only 7 days** (9 files, oldest 2026-11-13 on the reference cluster) | the FCBIS evidence for a completed leg is gone by the time anyone audits the window — the reference-cluster migration therefore cannot be *proved* from its logs today | evidence is captured **during** the leg and fetched into `artifacts/fcbis-evidence/` (`tasks/encrypt-leg.yml`) |
| every FCBIS tunable is **registered in the 8.0.29 binary** (`strings /usr/bin/mongod` on the reference cluster) | an unregistered `setParameter` makes mongod refuse to start — and in a leg that happens *after* the dbPath is wiped | `initialSyncMethod`, `initialSyncSourceReadPreference`, `fileBasedInitialSyncMaxLagSec`, `fileBasedInitialSyncMaxCyclesWithoutProgress` confirmed present, then asserted again at runtime via `getCmdLineOpts` |

`00b-bootstrap.yml` is **additive only**: it installs `percona-release` and `percona-mongodb-mongosh`
and touches no config, no data and no service.

```bash
ansible-playbook playbooks/00b-bootstrap.yml -e change_ticket=CHG-xxxx -e confirm_window=YES
```

Order: `00-preflight` (safe any time, read-only) → `00b-bootstrap` → the window.

## 5B. File-copy-based initial sync (FCBIS) — verified, not assumed

Phase 2 is only 3–4 h because legs 2 and 3 copy data files physically instead of re-inserting documents
and rebuilding indexes. That depends on an Enterprise feature that Percona back-ports, so the whole
assumption was checked against primary sources on 2026-11-20 rather than inherited from the previous run.

**Version reality** (Percona's FCBIS page is the source of truth):

| Fact | Consequence for this plan |
|---|---|
| FCBIS added in **8.0.12-4**; **Pro packages only** until **8.0.16-5**, then **all packages** | our pin `8.0.29-13` is in the free-package range ✓ |
| **Absent on 6.0 and 7.0** | Phase 2 must run *after* the set is fully on 8.0 — which is the order (W1 then W2). If W2 had to roll back to 7.0, every leg becomes a **logical** sync: hours, not 30–45 min |
| Upstream `initialSyncMethod` is documented **"Available only in MongoDB Enterprise"** | irrelevant to PSMDB, which ships its own implementation and uses the same parameter names — but it is why the parameter is not in the Community docs |

**Percona's documented limitations, and where each one is enforced:**

| Limitation | Where it is handled |
|---|---|
| "You cannot use the same sync source for multiple target nodes simultaneously because **only one backup cursor can exist** at any moment" | the legs are **strictly serial** — a doc-mandated constraint, not just risk appetite (`encrypt_sequence`, one leg per play) |
| "**Don't run backups** on either sync source or syncing node" | `pgrep -af '[m]ongodump|[m]ongorestore|[p]bm backup|[p]bm agent'` gate before every FCBIS leg (bracketed so it cannot match itself) |
| "If you're using encrypted storage, PSMDB **applies the encryption key from the sync source** to secure the data on the syncing node" | one identical key on all three members is **load-bearing**: key-equality (sha256) is asserted and DR copies taken before any leg. A differing key would reproduce the 25 Aug hybrid failure |
| "Both **source and target must run the same** PSMDB version" | satisfied by construction: all three are on 8.0.29 before Phase 2 opens |
| `fileBasedInitialSyncMaxLagSec` default **300 s**, `fileBasedInitialSyncMaxCyclesWithoutProgress` default **3** | raised to **1800 s / 10 cycles** for this cluster (`fcbis_max_lag_sec`): 684 GB under sustained writes must also apply its oplog backlog, and exhausting 3 cycles aborts the leg after the wipe |

**Tuning knobs are written only on the two FCBIS legs** (never on `mongo3`'s logical leg), together with
`initialSyncSourceReadPreference: secondary`, and are then re-checked **on the running server** with
`getCmdLineOpts` — a config file alone proves only that a file was written.

**What the reference-cluster precedent does and does not prove** (checked 2026-11-20 over password SSH, read-only):

| Verified | Evidence |
|---|---|
| the exact build this plan pins is already in production on another cluster | `db version v8.0.29-13` on refnode1/refnode2/refnode3 |
| `initialSyncMethod` + `initialSyncSourceReadPreference` are **accepted** by that build | both present in `/etc/mongod.conf` on refnode1/refnode2, and **neither** on refnode3 — the mirrored leg design — with config written 22:31 and mongod started 22:34/22:38. An unknown `setParameter` would have prevented startup |
| the parameters **were actually parsed and applied** | the startup line `"Options set by command line" … "setParameter":{"initialSyncMethod":"fileCopyBased","initialSyncSourceReadPreference":"secondary"}` |
| ❌ **not** proved: that FCBIS *executed* | the sync ran 7 Sept; the log now starts 2026-11-13 (7-day retention). This is precisely the gap the new evidence capture closes for our own legs |

**Log markers used as evidence** are taken from the binary itself (`strings /usr/bin/mongod`, v8.0.29-13),
not guessed:

| Marker | Meaning |
|---|---|
| `File copy-based initial sync` | **positive** — the copy ran. Note the hyphen: an earlier draft grepped `File copy based initial sync` and could therefore never match on any build |
| `FCBIS` | positive (alternate) |
| `Falling back to logical initial sync` | **negative** — the build degraded to logical sync; the node is still correct but the window estimate is void |
| `Support for the file copy-based` | **negative** — this build does not provide FCBIS |
| `sync source does not support file copy-based initial sync` | **negative** — the chosen donor cannot donate |

A positive marker is required, with a documented escape hatch (`-e fcbis_evidence_override=YES`) because
Percona does not document the marker's log level — the first leg on any cluster tells us whether it is
logged at default verbosity.

---

## 6. Timeline (calendar)

| Window | Length | Content | Client impact |
|---|---|---|---|
| W1 | 3–4 h | Preflight + FBIS re-rehearsal + Phase 1 (3 hops) | 3–4 failovers, 10–30 s each, transparent with `retryWrites` |
| W2 | 3–4 h | Phase 2 encryption (1 logical + 2 FCBIS) | 1 failover (~10–30 s) |
| W3 | ~1 h | `05a-audit-log` → `05-tls` (TLS staging), final verify — `bindIp` **not** changed | none (one serial rolling restart, which also activates the audit log) |

Phase 2 must not start less than 24 h after Phase 1 close (burn-in), and must not overlap any work on
the reference cluster — the two sets share a name and app teams confuse them.

---

## 7. Playbook map

```
ansible-prod-live-mongo/
├── README.md                        # this plan
├── EXECUTION-PROTOCOL.md            # decision rights, day-of sheet, abort criteria, rollback tree
├── ansible.cfg
├── inventory/
│   ├── prod-live.yml                # 3 hosts, hard-pinned to 10.0.0.11/12/13
│   └── group_vars/
│       ├── all.yml                  # vault wiring, connection defaults
│       ├── prod_live/               # the group dir SHADOWS a sibling prod_live.yml — keep it here
│       │   ├── main.yml             # cluster facts, pins, encrypt sequence, fingerprint JS
│       │   └── vault.yml            # AES256 secrets (gitignored, 0600)
│       └── prod_live.vault.yml.example
├── tasks/
│   ├── preflight-common.yml         # G1/G1b asserts + fact gathering (shared)
│   ├── node-upgrade.yml             # one-node binary swap (G3/G4/G5)
│   ├── stepdown.yml                 # graceful stepDown + wait for a new primary (G2)
│   ├── wait-member-synced.yml       # poll state/health/lag, fail loudly (G7); budget is a variable
│   │                                #   (15 min for a restart, 4 h for a wipe+resync)
│   ├── tls-activate-one.yml         # one member: optional stepDown → restart → wait (G9, serial)
│   ├── merge-mongod-conf.yml        # YAML-aware config merge, backup + integrity gate
│   ├── audit-log.yml                # auditLog block + least-priv audit-rotator + rotation/retention cron
│   └── encrypt-leg.yml              # one wipe+resync leg with the config gate (G10/G11, G-D)
├── playbooks/
│   ├── 00-preflight.yml             # read-only baseline → artifacts/
│   ├── 00b-bootstrap.yml            # prerequisites only: percona-release + mongosh (no config, no data)
│   ├── 01-backup.yml                # OPTIONAL — not imported by site.yml, no backup in this change
│   ├── 02-upgrade.yml               # hops 6.0/7.0/8.0, rolling, stepDown, FCV
│   ├── 03-encryption-keys.yml       # shared key + DR copies (no restarts)
│   ├── 04-encrypt-nodes.yml         # logical → FCBIS → FCBIS, serial
│   ├── 05a-audit-log.yml            # audit config + rotation cron (NO restart — activated by 05)
│   ├── 05-tls.yml                   # preferTLS enable, serial restarts (G9), both transports verified
│   ├── 06-verify.yml                # fingerprint compare + smoke + audit/rotation proof + report
│   └── site.yml                     # ordered entry point with tag gates
├── scripts/
│   ├── issue-certs.sh               # PKI for this cluster (control host only, never on a DB node)
│   └── audit.sh → audit.py          # static audit: templates, vars, module args, fail-open gates.
│                                    #   Contacts no host. Run before every window and after any edit.
└── artifacts/                       # fingerprints, manifests, keys, reports (gitignored)
```

Usage (control host, after §9 prerequisites). Every applying play needs the change record:

```bash
# read-only, safe to run any time
ansible-playbook playbooks/00-preflight.yml

# window steps — each refuses to run without its confirmation vars
ansible-playbook playbooks/01-backup.yml    -e change_ticket=CHG-xxxx -e confirm_backup=YES
ansible-playbook playbooks/02-upgrade.yml   -e change_ticket=CHG-xxxx -e confirm_window=YES -e hop=6.0
ansible-playbook playbooks/02-upgrade.yml   -e change_ticket=CHG-xxxx -e confirm_window=YES -e hop=7.0
ansible-playbook playbooks/02-upgrade.yml   -e change_ticket=CHG-xxxx -e confirm_window=YES -e hop=8.0
#   ... Phase 1 verify, then >=24 h burn-in, then the signed no-backup acceptance (gate G-C) ...
ansible-playbook playbooks/03-encryption-keys.yml -e change_ticket=CHG-xxxx -e confirm_window=YES
ansible-playbook playbooks/04-encrypt-nodes.yml   -e change_ticket=CHG-xxxx -e confirm_window=YES -e confirm_wipe=WIPE
ansible-playbook playbooks/06-verify.yml          -e change_ticket=CHG-xxxx
#   Window 3 — ORDER MATTERS: 05a writes the audit config, 05's restart activates it, 06 proves it
ansible-playbook playbooks/05a-audit-log.yml      -e change_ticket=CHG-xxxx -e confirm_window=YES
ansible-playbook playbooks/05-tls.yml             -e change_ticket=CHG-xxxx -e confirm_window=YES
ansible-playbook playbooks/06-verify.yml          -e change_ticket=CHG-xxxx
```

`00` and `06` are read-only in effect and need no confirmation. `--check` is supported on `00`, `05`
and `06`; the destructive phases deliberately refuse check mode — a half-checked wipe is worse than
no check.

---

## 8. Verification (what "done" means)

```js
// per node
db.runCommand({buildInfo:1}).version                 // 8.0.29-13
db.runCommand({buildInfo:1}).psmdbVersion            // present = Percona build
db.adminCommand({getParameter:1, featureCompatibilityVersion:1})  // {fcv:"8.0"}
db.serverStatus().encryptionAtRest                   // {encryptionEnabled:true, encryptionCipherMode:"AES256-GCM"}
rs.status()                                          // 3 healthy, mongo2 primary, lag ~0
```

- **Fingerprint equality** across all 3 nodes and against the Phase-0 baseline. Any delta must be
  explained by live writes in the window (record write rate × seconds; prod-backup showed +25 docs).
- **Plaintext-leak negation** (the strongest evidence for the ISO 27001 file): insert a unique token,
  `grep -a -r <token> /DATA/mongo` → 0 hits on every node.
- **Smoke test** through the real app path: write → replicate to a secondary → read there → delete.
- `06-verify.yml` writes `artifacts/verify-<date>.json` + `.md` — this is the change record and the audit evidence.

---

## 9. Prerequisites on this control host

**Decision (2026-11-20): the control host is `db-node-1` (10.0.0.11 = `mongo1`), not the admin Mac.**
The window runs from a `screen` session on the node — see `RUNBOOK-db-node-1.md` (day-of sequences) and
**`docs/CONTROL-NODE.md`** (what was measured, what was changed, what was proven, how to unwind it).
Staging is one command from the Mac (`./scripts/stage-control-node.sh`), and it is additive only: a
private venv, an SSH key for root **on that node**, the project copy, the vault password file, and cert
material. It is **already executed and rehearsed** on db-node-1 — see §12A, sixth pass.

Why the control host must not move once the change starts: `04-encrypt-nodes.yml` reads the Phase-0
baseline with `lookup('file', artifacts/baseline-*.json)` — a **local file**. A baseline taken on another
machine is invisible there, and the per-leg completeness gate then fails closed *after* a wipe.

**Version pin, measured rather than chosen.** ansible-core **2.21.6** on the node, not the 2.22.0 used to
audit the plan from the Mac: 2.22.0 declares `Requires-Python >=3.13`, and 3.12.8 is the newest Python
the Rocky 8 repos provide (the Mac ran 3.15). `scripts/audit.sh` is therefore re-run **on db-node-1** after
install, because its module-argument check validates against the installed version's `ansible-doc`. The
tree uses `ansible.builtin` only, so nothing depends on 2.22 behaviour.

Two security consequences of hosting the control node on a database host, both accepted and both
time-boxed: the **vault password file** lives at `/root/.ansible-vault-pass` (delete it once the change
record is signed), and the **node certificates** (which contain private keys) are all in one place — but
the **CA private key never leaves the admin host**, as `scripts/issue-certs.sh` itself instructs.

Ansible was **not** installed on any node at plan time. A throwaway venv was created on the Mac purely to
syntax-check this project (`.venv-check/`, ansible-core 2.22, gitignored) — it was never used against a
remote host. For the staged node venv, or a manual install of your own:

```bash
python3 -m pip install --user ansible-core   # or: brew install ansible
ansible --version
ssh-copy-id root@10.0.0.11 && ssh root@10.0.0.11 true   # key auth preferred
# group_vars/prod_live/ already exists and holds main.yml + vault.yml
cp inventory/group_vars/prod_live.vault.yml.example inventory/group_vars/prod_live/vault.yml
ansible-vault encrypt --vault-password-file ~/.ansible-vault-pass inventory/group_vars/prod_live/vault.yml
chmod 600 inventory/group_vars/prod_live/vault.yml
# editing an existing vault needs the explicit id, because ansible.cfg also supplies one:
#   ansible-vault edit --encrypt-vault-id default inventory/group_vars/prod_live/vault.yml
```

**Layout rule (this bit us on 2026-11-19, twice).** Ansible loads group vars from
`group_vars/<group>.yml` **or** from every file inside `group_vars/<group>/` — but when the directory
exists it **shadows the sibling `.yml`**. So the group's vars all live in the directory:
`prod_live/main.yml` (cluster facts) + `prod_live/vault.yml` (secrets). Do not re-create
`group_vars/prod_live.yml`, and do not put the vault at `group_vars/prod_live.vault.yml` — in both cases
the file is silently ignored and you get an undefined-variable error (or, worse, a credential that
resolves to nothing) with no warning that a file was skipped. `ansible.cfg` already points
`vault_password_file` at `~/.ansible-vault-pass`, so no run needs `--ask-vault-pass`.

Then verify the tree itself before trusting it:

```bash
./scripts/audit.sh          # syntax + templates + variables + module args + fail-open gates + docs
```

`audit.sh` contacts **no** host and needs only `ansible-playbook`, `ansible-doc`, `pyyaml` and `jinja2`.
It must report `clean` before a window opens; every check maps to a defect that actually shipped in a
draft of this plan (README §12A).

No collection is required — the playbooks use `ansible.builtin` only. `ansible.posix` /
`community.general` are optional (only for the `yaml` stdout callback and `profile_tasks`; both are
commented out in `ansible.cfg`).

Secrets policy: `vault_ansible_password`, `vault_mongo_admin_password`, `vault_audit_rotator_password`
live **only** in the vault file. The admin password currently in `servers-and-credentials.md` is
considered compromised-by-documentation and must be rotated as part of W3 (it is shared across both prod sets).

---

## 10. Rollback

| Point | Rollback | Cost |
|---|---|---|
| Before any change | nothing to do | — |
| Mid Phase 1, same hop | reinstall previous RPM from `/root/rpm-stage-*`, restart, previous FCV still valid | ~10 min/node |
| After FCV bumped to *N* | **no binary downgrade** — FCV ratchet is one-way | forward-only |
| Phase 2, before a wipe | restore pre-change config `.bak`, restart | ~5 min |
| Phase 2, after a wipe, sync fails | re-wipe + retry (logical fallback), other 2 members intact | 1–2.5 h |
| Phase 2, after encryption | **no path back to plaintext.** The other two members are the rollback; the encrypted node is re-wiped from them | 1–2.5 h/leg |
| **Two members lost during Phase 2** | **no recovery path.** There is no backup for this cluster | unrecoverable |

This is why G-C requires a written no-backup acceptance: from the first wipe onward, "rollback" means
resyncing one node from the two survivors — there is no archive to fall back to.

---

## 11. Risk register

| Risk | L | I | Mitigation |
|---|---|---|---|
| Play runs against the reference cluster by mistake (same replSet name) | M | Critical | Hard-coded allow-list assert (G1b); separate inventory file; no `rs.add` anywhere |
| Missing `enableEncryption` block on a wipe target | M | Critical | Per-leg config gate `grep -c == 1` (G-D); this exact thing broke refnode1 on 25 Aug |
| Backup not taken (ops decision) | — | Critical | Accepted. Offset by: serial legs, survivor-health gates before every wipe, per-leg fingerprint completeness check, dev rehearsal, and RPM/config rollback for Phase 1 |
| Two members lost/wipe runs on a second node | L | Critical | Only one leg can run at a time (serial plays), pre-wipe assert that all 3 are `health=1`, no other change in the window, no concurrent reboots/patches |
| FCBIS lag/cycle exceeded under 337 w/s load | L | M | `fileBasedInitialSyncMaxLagSec` watch; documented fallback = logical |
| **dnf file conflict: PSMDB installed over `mongodb-org-*`** | H if unhandled | Critical | G14 — community packages are removed between stop and install; the config is restored from `.bak`, and the uid change is detected before the data dir is touched |
| **Rollback RPM set is empty/unobtainable when the hop starts** | M | Critical | G15 — hard assert on RPM count + download warnings *before* mongod stops; `allow_missing_rollback=YES` is the only bypass and it is recorded |
| App pinned to one host / no `retryWrites` | M | H | Gate G-A requires written app-team confirmation |
| 8.0 behaviour changes (`{f:null}`≠`undefined`, `mapReduce` gone) | L | M | Apps already on 8.0 elsewhere (the reference cluster, dev) — same app family |
| Disk: `/DATA` needs ≥ 2× headroom for wipe+resync | L | H | Preflight free-space assert (xfs, ~1.9 T on this hardware) |
| **A gate fails open** — a `| default(x)` inside an assertion, or a skipped task's register mistaken for a result | M | Critical | Systematic audit (README §12A) removed the completeness-gate default and both `is defined` tests; every `failed_when: false` register is re-asserted downstream |
| **A metadata change breaks outbound replication during the TLS rollout** | H (expected) | L | `preferTLS` uses TLS outbound, so restarted members idle until the last one restarts. Tolerated deliberately (`skip_lag_check`), full catch-up asserted at the end |
| **Nodes lack `mongosh` today**; first hop removes the legacy shell | H (certain) | Critical | `00b-bootstrap.yml` installs it *before* the window; every mutating play asserts `mongo_base_argv` shell == mongosh |
| Ansible itself cannot run on the node default python 3.6 | — (already hit) | Critical | interpreter pinned to `/usr/bin/python3.12`; audited by `scripts/audit.sh` check 10 |
| Destructive typo in `rm -rf` | L | Critical | Wipe only inside the playbook, gated on `confirm_wipe=WIPE`, path asserted to equal `/DATA/mongo` |
| A Phase-2 leg declared failed mid-sync because the wait budget was too short | — | M | `wait_retries` is a variable: 15 min for restarts, 4 h (`resync_wait_retries: 960`) for wipe+resync legs |
| Key loss (DR) | L | Critical | Identical key on 3 nodes + NFS + off-box; sha256 recorded in preflight artifacts |
| Operator fatigue across 3 windows | M | M | Phase 2 blocked < 24 h after Phase 1; one cluster per night |

### Accepted risks (signed, not mitigated away)

**R1 — No backup is taken.** Rollback is peer resync only; two members lost in the same change is
unrecoverable. Compensating: serial legs, survivor-health gates before every wipe, per-leg fingerprint
completeness check against the baseline, lab rehearsal, RPM/config rollback for Phase 1.

**R2 — TLS is `preferTLS`, not `requireTLS`.** Non-TLS client connections remain accepted, so the TLS
change does not actually prevent a plaintext connection. Compensating: `requireTLS` is unreachable from
the playbooks without `-e confirm_require_tls=YES`, the upgrade path to it is one config key change once
every app has moved to `tls=true`, and the end state is verified by `06-verify.yml` (both transports
proven available on every member).

**R3 — `bindIp` stays `0.0.0.0`.** MongoDB listens on every interface, so exposure is limited only by the
network path and by authentication. Reasons for not changing it in the same window: the real client subnet
list is usually not documented, and a wrong `bindIp` is a *silent* outage that only appears when the app
reconnects — which would land on top of a version change, a wipe+resync and a TLS rollout. Compensating
controls that are already true: `security.authorization: enabled` with SCRAM (every connection must
authenticate), per-role least privilege, TLS available (`preferTLS`), the value recorded in
`artifacts/baseline-*.json` and `artifacts/verify-*.json` so the exposure is documented rather than
assumed, and no play merges `net.bindIp` (`bind_ip_managed: false` in the group vars) so nothing can change
it by accident. **Follow-up (separate change, own window): bind to the member IPs + `127.0.0.1`, then add a
host firewall.** Do not fold it into this one.

---

## 12. Roles & comms

- **DBA/ops (2 people):** one drives Ansible, one reads `rs.status()`/monitoring independently and holds the gate list. Neither works alone in Phase 2.
- **App team:** confirms URIs before G-A; on standby during stepDowns; validates end-to-end after W3.
- **Change manager:** approves 3 windows; records the no-backup acceptance signature for G-C.
- **Comms:** notify the application owners (and anyone else running a change against these hosts) once the dates are fixed.

Full decision rights, no-go conditions, abort thresholds and the rollback tree are in
**`EXECUTION-PROTOCOL.md`** — that file, not this plan, is what the operator works from on the night.

---

## 12A. Automation status — verified vs. unverified (read before trusting the playbooks)

This project was authored as a plan. **Nothing that mutates the cluster has been executed against
production** — but `00-preflight.yml` (read-only, `check_mode: false`, no `changed` tasks on the nodes) has
been run end to end against 10.0.0.11/12/13, and it passes. Be precise about what that means:

**Verified locally (control host only, no DB node contacted):**
- `ansible-playbook --syntax-check` passes on all 8 playbooks (ansible-core 2.22, `ansible.builtin` only).
  Re-verified on db-node-1 with **ansible-core 2.21.6**, the newest release that runs on the node's Python
  3.12.8 (2.22 requires ≥ 3.13) — see §12A, sixth pass
- every template expression used in the gates renders: replica-set URI, FCV commands
  (`6.0` without `confirm`, `7.0`/`8.0` with `confirm: true`), TLS boolean, encrypt sequence
- the config-merge task was run against a **copy** of a representative `mongod.conf`: encryption and
  `setParameter` blocks are added while `storage`, `replication`, `net`, `systemLog`, existing
  `security.keyFile` and `processManagement.fork` are all preserved, and the result re-parses as YAML
- the exact strings the config gate greps for (`enableEncryption: true`,
  `initialSyncMethod: fileCopyBased`, `initialSyncSourceReadPreference: secondary`) were asserted
  against the rendered YAML, not assumed
- the state logic of `wait-member-synced.yml` (omitted / `2` / `''`), the `df --output=avail,size`
  parsing, the sync-source health selection, and the per-host TLS-block gate were exercised with
  fixture data, including a deliberate negative case for each

**Corrected in the 2026-11-19 review (all were run-breaking, none were cosmetic):**
ten defects were found and fixed — two `set_fact`/`copy` tasks that referenced `item` with no `loop`
(`00`, `06`, `node-upgrade`), the TLS activation play running on `localhost` where `replset_name` and
`mongosh` do not exist, a cluster-wide `mongod.conf` md5 gate that would always fail because Phase 2
legitimately leaves `setParameter.initialSyncMethod` on two of the three members, three members restarted
back-to-back (two down at once), the missing community→Percona package transition, a missing
`pgrep` self-match guard that made every FCBIS leg fail the "no backup running" gate, a 15-minute wait
budget applied to a 1–3 h resync, `expected_state: 2` applied to the member that re-elects itself, and a
toothless RPM staging gate. A **tenth-and-a-half** finding came out of wiring the credentials: the vault
file was named `group_vars/prod_live.vault.yml`, which Ansible **silently ignores** (group vars only load
from `prod_live.yml` or from inside `prod_live/`), leaving `ansible_password` unset with no warning; it now
lives at `group_vars/prod_live/vault.yml`, and `preflight-common.yml` additionally refuses a `REPLACE_ME`
placeholder instead of only `__UNSET__`.

**Second audit — 2026-11-19 (systematic sweep for "silent failure" defects).** Rather than re-reading,
this pass ran machine checks over the whole tree: Jinja AST analysis of every template and every
`when`/`until`/`failed_when` expression against the full variable set; module-argument validation of
all 13 modules against the installed `ansible-doc` specs; a register-usage audit (every
`failed_when: false` must be re-checked downstream); a `| default(...)` audit (a default inside an
assertion is a potential fail-open); and a doc↔code check that every documented command supplies the
confirmation variables its playbook gates on. Five defects were found and fixed:

1. **`00-preflight.yml` crashed on the primary.** A task that is *skipped* still registers its
   variable (`{"skipped": true}`), so `selectattr('fingerprint', 'defined')` picked up the primary,
   whose result has no `.stdout`, and `from_json` aborted the run. This is the gate for the whole
   change — nothing would have proceeded. Fixed by filtering on `fingerprint.stdout`.
2. **`06-verify.yml` used `else null`.** `null` is **not** a Jinja literal (only `none` is), so the
   expression yielded *Undefined* and silently defeated the `selectattr(..., 'ne', none)` filters that
   are supposed to exclude the primary from the fingerprint comparison.
3. **The Phase-2 completeness gate failed open.** `baseline_fp_total | default(0)` in
   `tasks/encrypt-leg.yml` made the comparison `total >= 0` — always true — if the baseline was ever
   missing. With no backup, that comparison is the *only* proof a wipe+resync produced a complete
   dataset. It now fails closed, and `04-encrypt-nodes.yml` asserts the baseline is a real positive
   count before any node is wiped.
4. **Two different defaults for one variable.** `01-backup.yml` gated NFS on
   `min_nfs_free_gb | default(2000)` while group_vars defined `min_nfs_free_gb: 10`, so the 2000 GB
   default never applied and the backup gate was 20× too lax. Split into `min_nfs_free_gb` (key DR
   copy) and `min_nfs_backup_free_gb` (a full dump).
5. **A failed stepDown was invisible.** `tls_stepdown` was registered with `failed_when: false` and
   never checked, so a failed `rs.stepDown(120)` surfaced later as a confusing "no new primary"
   timeout. It now has an explicit assertion with the real `rc`/`stderr`.

A sixth item was **introduced and caught by this same audit**: a YAML comment placed inside a `>-`
folded Jinja block is *template text*, not a comment, and breaks the expression. The template parser
flagged it immediately; the comment was moved above the key.

**Ansible/Jinja traps confirmed in this codebase — do not "tidy" these away:**

| Trap | Symptom | Guard now in place |
|---|---|---|
| A `group_vars/<group>/` **directory shadows** a sibling `<group>.yml` | the sibling's variables vanish; undefined-var errors or, worse, silently missing credentials | all vars live in `group_vars/prod_live/{main.yml,vault.yml}`; nothing beside the directory |
| a file named `<group>.vault.yml` is **not** group vars | treated as vars for a group `<group>.vault`; `ansible_password` silently unset | vault is `group_vars/prod_live/vault.yml`; `preflight-common.yml` rejects `__UNSET__` *and* `REPLACE_ME` |
| a **skipped** task still registers its variable | `is defined` is true, `.stdout` is not → `from_json` explodes | filter on `.stdout` (00, 06) |
| **`null` is not a Jinja literal**, `none` is | expression yields Undefined, filters silently mismatch | `none` in Jinja; `null` only in YAML |
| **YAML `none` is the string `"none"`**, not null | a "null" value compares as a string — `ne none` no longer filters it | use YAML `null` for null, `none` inside Jinja |
| a **`#` comment inside a `>-`/`|` block** is template text | `TemplateSyntaxError` at runtime, syntax-check still passes | comments live above the key, never inside the block |
| `failed_when: false` without a follow-up check | the failure disappears; a later gate reports something unrelated | every such register is re-asserted (`stepdown`, `tls_stepdown`, probes) |
| `| default(x)` inside an assertion | the gate passes when the variable is missing — fails *open* | removed from the completeness gate; audited across the tree |

**The audit is now a script, not a one-off.** `./scripts/audit.sh` re-runs every check above plus the
doc↔gate comparison, and contacts no host. It was itself negative-tested: six defect classes were
injected into a copy of the tree (`else null`, `default(0)` in a comparison, `not (x|default(false))`,
a keyword inside a module's args, a `#` comment inside a folded Jinja block, and a shadowing
`prod_live.yml` beside `prod_live/`) and each one was reported. **A clean run is a precondition for
opening a window.**

**Third audit — 2026-11-19, `00-preflight.yml` run against the live set.** This is the first pass
that was not static: it executed read-only against 10.0.0.11/12/13 and found defects that no
amount of re-reading would have caught. Each was a real run-stopper.

1. **Every module failed.** Default `python3` is 3.6.8; ansible-core 2.22 needs >= 3.7.
   `ansible -m ping` → `future feature annotations is not defined`. Fixed by pinning
   `/usr/bin/python3.12` (present on all three).
2. **`ansible.builtin.dnf` can never work here.** The bindings exist only for platform-python 3.6.
   Replaced with `command: dnf ...` plus an `rpm -q` assertion of the exact pinned NVR — which also
   closes a gap the dnf module had hidden: dnf will satisfy a request with a *different* build if the
   exact pin is missing, and the whole rollback plan is pinned to those builds.
3. **The cluster-identity gate rejected the real cluster.** Members are named `mongo1`, `mongo2`,
   `db-node-3` — not `mongo3`. A hostname allow-list both failed on the real set and was a weak
   discriminator against the look-alike second set (`mongo4/5/6`). Now asserted on **resolved IPv4
   addresses**, which is exact and naming-agnostic.
4. **`getent hosts` returned an IPv6 link-local address** for `db-node-3` on the node that owns that
   name, so even the IP check would have mis-fired. Uses `getent ahostsv4`.
5. **`/etc/mongod.key` does not exist.** The real keyFile is `/etc/mongodb/keyFiles/mongo-key`
   (0400, mongod:mongod). The rollback staging of that file would have failed mid-window.
6. **YAML flow-sequence comma splitting.** `argv: [..., -o, SOURCE,TARGET,FSTYPE]` parses as three
   elements, and `--output=avail,size` as two, so `findmnt`/`df` both fail. This is a YAML trap, not
   an Ansible one — and it is now check 9 of the audit.
7. **`stat` has no `.owner`** — the field is `pw_name`.
8. **The FCBIS donor check could never pass.** It matched `rs.status()` member names against the
   inventory name `mongo3`; the set calls that member `db-node-3`. Now resolved through
   `rs_member_by_ip`, and it fails closed if the name cannot be resolved.

**Fourth audit — 2026-11-20, first complete `00-preflight.yml` run.** The preflight now runs end to end
against 10.0.0.11/12/13 and writes `artifacts/baseline-<stamp>.json`. Getting there exposed three
defects in the *verification* path — which is the only completeness proof this change has, since there is
no backup:

1. **The fingerprint could never produce a number.** It called `listDatabases`, which is **primary-only**:
   on a secondary it returns `{ok: 0, errmsg: "not master and slaveOk=false"}` — a document with no
   `.databases` — and the JS then threw `TypeError: ...databases is undefined` (exit 252, seen as `rc=2`
   through `no_log`). The fingerprint deliberately runs on **secondaries**, so the gate was impossible to
   satisfy. Fixed with `setSecondaryOk()` before the first admin command.
2. **The fingerprint would have taken hours per run.** `countDocuments({})` per collection is a full
   aggregation scan, and this cluster holds **1,169,641,970 documents across 35 databases**
   (`orders` alone: 460 M, `event_log`: 438 M). The fingerprint is taken before *and* after
   every encryption leg — 8+ runs per window. Replaced with `collStats.count`, which reads the
   WiredTiger table count: the whole cluster now fingerprints in **~5 s**.
3. **Exact fingerprint equality is unachievable on a live cluster — and the gate enforced it.** Measured
   with both secondaries healthy and fully in sync: `1,169,656,301` vs `1,169,646,605`, i.e. **9,696
   documents apart (8 ppm)**, purely from writes landing between the two samples. The old gate
   (`unique | length == 1`) failed every run and therefore proved nothing. Now: the **database set must be
   identical** on every member (that catches a real missing database), and the totals must agree within
   `fingerprint_max_abs_delta` / `fingerprint_max_rel_pct` = **250 k documents or 0.05%, whichever is
   larger**. Optime lag remains the authoritative "is this member behind" check.
4. **The report plays could not see the cluster variables.** `check_templates` validates variable names
   against one global set, so `cluster_id`, `replset_name` and the tolerance knobs counted as "defined"
   even inside `hosts: localhost` plays — but implicit localhost is only in group `all`, so
   `group_vars/prod_live/` never arrives. The run died in the *report* task, after the expensive work, with
   `'fingerprint_max_rel_pct' is undefined`. Both localhost plays now load the group file explicitly with
   `vars_files`.
5. **`map('keys')` is not a filter.** `No filter named 'keys'` — `keys` is a Python method. Replaced with
   `dictsort | map('map', attribute=0)`, which is the portable way to extract a dict's key set.

Checks **11** (a `hosts: localhost` play may not read group-scoped vars it never loads) and **12** (no
`map('keys')`-style non-existent filters) were added to `scripts/audit.sh` and negative-tested: removing
`vars_files` produces exactly five `play-scope` failures naming the five variables, and re-introducing
`map('keys')` is reported at the offending line.

**Fifth audit — 2026-11-20, "the gate that could never fire".** Triggered by the question *"so you also
append `initialSyncMethod: fileCopyBased`?"* — checking the answer against the docs instead of memory
found that the plan was asserting FCBIS **was configured**, never that it **ran**:

1. **The FCBIS proof grepped the wrong string.** `tasks/encrypt-leg.yml` searched the mongod log for
   `File copy based initial sync`. The binary emits **`File copy-based initial sync`** (hyphenated;
   verified with `strings /usr/bin/mongod` on 10.0.0.21, v8.0.29-13). The count could therefore never
   be anything but `0`, on any build — and it was only *printed* in a debug line, never asserted, so the
   leg would have "passed" with a broken proof. Now the markers are taken from the binary, both
   *positive* and *negative* ones are asserted, and `scripts/audit.py` check 13 rejects the bad literal.
2. **Silent degradation had no detector.** PSMDB logs `Falling back to logical initial sync` (and
   `Support for the file copy-based …` when the build lacks FCBIS) and then completes *correctly* — just
   hours slower, after the wipe. That is a window-killer with no error, and it is now a hard failure.
3. **The configured parameters were never verified on the running process.** A `mongod.conf` grep passes
   even if the file was written after the process started, or if the block was ignored. The leg now reads
   `db.adminCommand({getCmdLineOpts:1})` and asserts all four parameters are live.
4. **The two FCBIS abort-prone defaults were left at Percona's settings.** `fileBasedInitialSyncMaxLagSec`
   (300 s) and `fileBasedInitialSyncMaxCyclesWithoutProgress` (3) are sized for a quiet 500 GB cluster;
   this one is 684 GB under sustained writes and must also apply its oplog backlog. Raised to 1800 s / 10
   cycles on the FCBIS legs only.
5. **The evidence would have expired before anyone read it.** `/var/log/mongodb` holds 7 days. A wipe +
   resync happens in a window; the post-mortem happens days later. The leg now cuts its own log window
   from a pre-restart line offset (handling mid-leg rotation) and fetches an excerpt to `artifacts/`.
6. **A parameter whose acceptance was only probable was made certain.** `initialSyncSourceReadPreference`
   is not in Percona's FCBIS parameter table, and an unregistered `setParameter` makes mongod refuse to
   start *after* the wipe. It was confirmed accepted on the precedent cluster: present in
   refnode1/refnode2 config (and deliberately absent on refnode3, the logical leg), written 22:31, mongod
   started 22:34/22:38, and echoed back in the running server's startup options.

Check **13** (bad literals: a gate's comparison string that cannot match real output) was added to
`scripts/audit.py` and negative-tested — re-introducing `File copy based initial sync` produces exactly
one `bad-literal` failure pointing at the line.

**Sixth pass — 2026-11-20, control-node staging on db-node-1.** Not an audit of the playbooks but of the
*platform they would run on*: the user decision was to execute the change **from db-node-1, inside a `screen`
session**, instead of from the admin Mac. Staging it before the window (rather than at 02:00) found six
defects, four of which would have stopped or corrupted the run. Full record: `docs/CONTROL-NODE.md`.

1. **ansible-core 2.22.0 cannot run on db-node-1.** It declares `Requires-Python >=3.13`; the node's newest
   Python is **3.12.8** and the Rocky 8 repos offer nothing newer. The Mac runs 3.15, which is why the
   plan had been audited with 2.22. `pip install` would simply have failed on the first command of the
   window. Pinned the node venv to **2.21.6**, then re-ran `scripts/audit.sh` **on the node** — because
   check 4 validates module arguments against the *installed* `ansible-doc`. Result: clean.
2. **db-node-1 had no SSH key of its own** (only `authorized_keys`), and there is no `sshpass` on the node,
   so the inventory's `ansible_password` fallback could never have worked — every task would have failed
   at authentication. The key is now generated **on the node** and only its public half travels to
   10.0.0.11/12/13; no private key moves between hosts.
3. **`rsync --delete` would have destroyed the node's own evidence.** `artifacts/baseline-*.json` taken
   *inside* a window is the reference every encryption leg compares against, and `artifacts/fcbis-evidence/`
   is the only proof a leg produced a complete dataset. A re-stage between W1 and W2 — the very moment
   someone would re-sync the project — would have deleted both, and the gate would then fail closed with
   nothing to compare to. Now `--filter='P artifacts/***'`, tested both ways: with the filter the node
   artifacts survive and local copies still land; plain `--delete` removes them.
4. **Re-staging during a live window was possible.** Ansible reads `tasks/*.yml` as it walks the play, so
   overwriting the tree underneath a running play changes the run mid-flight. Staging now refuses to
   start if a `mig` screen session exists.
5. **`scripts/issue-certs.sh` was mode 644** while the docs invoke `./scripts/issue-certs.sh` — W3
   preparation would have failed with "permission denied". Fixed.
6. **`rsync -a` preserved the Mac's uid 501 onto the node**, leaving the whole tree owned by `501:games`.
   Harmless today, but it makes real permission errors invisible later. `chown -R root:root` added to the
   script; node tree corrected and re-audited clean.

The read-only rehearsal was then run **through the session, from db-node-1**: `00-preflight.yml` →
`failed=0` on all three members, baseline written on the node, total **1,183,366,522** documents. That one
run proves inventory resolution, vault decryption, SSH key auth from the node, target-interpreter
selection, shell detection, the `setSecondaryOk`/`collStats` fingerprint path and artifact writing — the
whole chain, from the real control node. Session `mig` is armed and idle; **no window step has been run.**

**Measured baseline (2026-11-19/20, read-only):**

| | mongo1 / 10.0.0.11 | mongo2 / 10.0.0.12 | mongo3 / 10.0.0.13 |
|---|---|---|---|
| OS / kernel | Rocky 8.7 / 4.18.0-513 | Rocky 8.7 | Rocky 8.8 |
| MongoDB | 5.0.8 (mongodb-org), FCV 5.0 | 5.0.8 | 5.0.8 |
| Role | SECONDARY | **PRIMARY** | SECONDARY |
| `/DATA` free | 1003 GB of 1918 GB (48%) | 958 GB (50%) | 873 GB (45%) |
| Data on disk | 684 GB | 677 GB | 686 GB |
| RAM / WT cache | 250 GB / 128 GB | 250 GB / 128 GB | 250 GB / 128 GB |
| NFS | `10.0.0.31:/mongo-nfs` → 5.5 TB free | same | same |

**Document fingerprint (the completeness reference, guardrail G6):**

| | value |
|---|---|
| Total documents on the set | **1,169,677,587** (sampled 2026-11-20 09:56, from the Mac) |
| Re-measured from db-node-1 (rehearsal) | **1,183,366,522** (sampled 2026-11-20 11:04) — **+13.7 M/day**, which is why the gate is a tolerance and not an equality |
| Databases (excluding admin/local/config) | 35 |
| Largest databases | `orders` 460.3 M, `event_log` 438.7 M, `message_history` 101.3 M, `order_history` 73.3 M, `inbound_events` 30.2 M |
| Secondaries sampled | mongo1, mongo3 (mongo2 is PRIMARY and is never scanned) |
| Spread between the two secondaries | 9,696 documents (8 ppm) while both healthy — **this is why the gate is a tolerance, not an equality** |
| Runtime of one fingerprint | ~5 s (`collStats.count`), vs. hours with `countDocuments({})` |

The baseline artifact (`artifacts/baseline-*.json`, mode 0600) records the total **and the per-database
map**. It is regenerated in W1 rather than reused — every Phase-2 leg compares against the number taken
in the same window.

Disk note: the encryption legs are **initial syncs, not dump/restore** (the `logical` leg is a
logical initial sync, the others FCBIS), so no dump space is required. The tightest margin is
mongo3: 686 GB of data into 873 GB free — acceptable, and it is the first leg for exactly that reason.

**Unverified until the window (this is the honest list).** Everything the read-only preflight *can* check
has now been checked — hostnames, roles, free space, keyfile, NFS, fingerprints, python, shells. What
remains cannot be tested without changing the cluster:

- **FCBIS behaviour on 0.8 TB under this write load** — the timings assume the reference-cluster measurement (~1.15 GB/s,
  1–3 h per leg). The encryption legs are the only part of this plan with no rehearsal on this cluster.
  Also unproven until the first leg: **whether the positive file-copy marker is logged at default
  verbosity** (Percona does not document its level), which is why that one assertion has a documented
  override (`-e fcbis_evidence_override=YES`) rather than a silent pass.
- **the `grep -c enableEncryption` config gate has never run against a real node** in this project
- **the resync wait budget** (`960 × 15 s = 4 h`) is sized from the reference cluster, not measured here
- **the pinned NVRs install cleanly on these nodes** — all three are confirmed present on
  `repo.percona.com`, but `percona-release` is not installed yet, so no repo on the node has been enabled
  and read back (`00b-bootstrap.yml` fixes the first half; the first `dnf install` is the real proof)
- **the application connection strings** — the app team must confirm all hosts are listed with
  `replicaSet=rs0` and `retryWrites=true`, or the failovers are not transparent

**Deliberate deviations from the executed reference-cluster runbook** (each is a decision, not an accident):

| Deviation | Why |
|---|---|
| **No logical backup** (ops decision, 2026-11) | Same call as the reference-cluster migration. It removes 2–4 h and the dump load, and it is defensible for Phase 1 (rolling, data preserved, RPM rollback available). For Phase 2 it moves all the weight onto the serial-resync design: one node down at a time, survivors verified healthy and fingerprint-identical before each wipe, per-leg fingerprint completeness check after each resync |
| Encryption config is written **per leg** just before that node's wipe, not up front on all 3 | with the block present, an unplanned reboot of a not-yet-migrated node leaves mongod unable to start (encryption on, plaintext data). Per-leg + a mandatory gate removes that outage mode; the gate still protects against the 25 Aug hybrid mistake |
| `previous_major` is declared per hop instead of computed | the hop can't be skipped by arithmetic error, and it reads as documentation |
| Fingerprints run on **secondaries only** | never add scan load to the only writable node |
| Hard allow-list assert in every play | a second cluster in the estate shares the replica set name; a wrong-inventory run is the worst-case scenario here |
| `change_ticket` required by every applying play | the gates become auditable in the scrollback, and an ad-hoc run is impossible |
| Plaintext-leak scan is **sampled** (10 newest data files) | a full `grep` over 0.8 TB is hours of IO on a production node. It is also **indicative only** — WiredTiger block compression can hide a plaintext token, so `serverStatus().encryptionAtRest` remains the authoritative check |

**Seventh audit — 2026-11-24, "documented but not implemented" sweep.** This pass did not re-read the
prose: it compared the README's promises against the code, then ran every declared variable against every
reference to find the ones nothing consumes. Six defects, one of them a **run-stopper that would have
fired on the first hop**:

1. **The FCV is a document, not a string — every FCV gate was dead.** `getParameter` answers with
   `{version: "5.0"}`, confirmed on a live 5.0.8 cluster rather than inferred. Rendering that with
   `| string` gives `{'version': '5.0'}`, which never matches `^5\.0`. So the "never skip a hop" ratchet
   and the post-hop assert would have aborted the very first hop — safely, before anything changed, but
   the window would have died with no obvious cause. `tasks/preflight-common.yml` now normalises to
   `mongo_fcv` (plain version) and keeps `mongo_fcv_raw` for inspection; the shape is exercised against
   nine synthetic cases (doc/string shape, mid-hop, hop-done, wrong rung, skipped rung, off-ladder, FCV
   ahead of binary, end state).
2. **Nothing checked the cluster was on 5.0 before the first hop.** `expected_start_major` was declared and
   never read. It now feeds guardrail **G0**: binary major and FCV major must both be on the planned ladder
   (5.0 → 6.0 → 7.0 → 8.0), and the FCV may never be ahead of the binary. Written as membership, not
   equality, so an interrupted window resumes instead of refusing.
3. **The audit-log scope was configuration with no consumer.** Four variables and one vault secret were
   declared and read by nothing: no task wrote `auditLog`, nothing created the rotator identity, no cron
   existed, and `06-verify.yml` asserted nothing — while four places in the docs claimed it was covered.
   Now `playbooks/05a-audit-log.yml` + `tasks/audit-log.yml`, with three independent verify assertions
   (running-process config, JSON shape, **forced rotation actually produces a new file**).
4. **`05a` could be skipped and nobody would notice.** mongod reads `auditLog` only at startup, so a skipped
   `05a` silently defers the audit log to "the next restart", which in practice is never. `05-tls.yml` now
   refuses to roll unless the block is already present (`default(true)` on the gate, so an *undefined*
   `audit_enabled` refuses rather than passes).
5. **A resume could strand the change.** `node-upgrade.yml` required binary and FCV to be exactly at
   `previous_major`. If a window died after swapping one member's packages, re-running the hop — the safe
   recovery — was refused on that member, and the only remaining route was the unsafe one. Both now accept
   `previous_major` **or** the hop, and mongod is not stopped again on a member already on the target build.
6. **A wiped node could be left with no eligible donor.** `fcbis_source_read_pref: secondary` excludes the
   primary from its first selection pass; on leg 1 there is exactly one secondary, so a moment of
   ineligibility (lag > `maxSyncSourceLagSecs`, default 30 s) leaves no candidate and mongod can exit after
   10 attempts — with a wiped dbPath and no backup. Now `secondaryPreferred`, which degrades to the primary
   instead of failing. Each leg also records **which member actually donated the copy**.

Two smaller cleanups: a stale `allowed_member_names` list (naming members that do not exist) was removed
rather than wired up, and the baseline/verify reports now record `bindIp` and the `auditLog` block so the
exposure is documented without being managed. `./scripts/audit.sh` is clean, and it caught two defects
introduced *during* this pass — a `#` comment inside a `>-` block, and a `not (x | default(false))`
fail-open — which is the script doing its job.

---

## 13. Decisions you must make before you run this

These are the choices that are **not** technical defaults. Each one changes the plan.

1. **Window structure.** We used three: W1 upgrade, W2 encryption (≥ 24 h after W1, never the same night),
   W3 TLS. Compressing them is possible and is a bad idea — the point of the gap is that you learn whether
   the new binaries are stable under your workload *before* you wipe a member.
2. **`requireTLS` or `preferTLS`?** This plan ends at **`preferTLS`** deliberately: TLS and plaintext are
   both accepted, so no application change is needed on day one. `requireTLS` is a *separate* change —
   every client needs `tls=true` and the CA mounted, and it must be flipped only after that is true.
3. **`bindIp`.** `0.0.0.0` is the default that ships, and **this repo deliberately leaves it there** (accepted
   risk R3, §11): the playbooks only *record* it, they never manage it (`bind_ip_managed: false`). Tighten it
   to the member IPs plus `127.0.0.1` once you know the application subnets — as its own change, with its own
   window, and after a failed reconnect has been costed. Do not guess, and do not fold it into the migration
   window: a wrong `bindIp` only shows up when an app reconnects.
4. **Key management.** A local 32-byte keyfile (copied off-box for DR) is what this repo automates. That
   key is now as critical as the data: KMIP/Vault is the grown-up answer, a documented local key is the
   pragmatic one. Decide, and write down where the DR copy lives.
5. **Audit log retention and shipping.** JSON audit + 1 GiB rotation + 7 days is a starting point, not a
   policy — and `05a-audit-log.yml` now implements it (config, least-privilege `logRotate` user, size-triggered
   rotation, age retention, volume cap). The knob that matters most is `audit_filter`: an **empty** filter
   logs every authorization check, which at a few hundred writes/s is multi-GB per day on the system volume.
   The shipped default records security-relevant event types only. Decide your fidelity *and* where the
   rotated files actually go (a cron on the same box is rotation, not shipping).
6. **Certificate renewal.** Ours: CA 10 years, node certificates 2 years, **nothing renews them**. Put the
   expiry on a calendar or in monitoring. A silently expired member certificate stops replication under
   `preferTLS` exactly like a config error would — and it will happen at 03:00 on a Sunday.
7. **What replaces the backup.** See below.

Assumption used throughout: one keyfile approach and one set of package pins for every cluster in the
estate, so that a fix is applied once and a procedure works everywhere.

**A note on the no-backup decision.** This migration was run **without a logical backup** — an explicit,
recorded acceptance, not an oversight. Phase 1 is safe without one (rolling, data preserved, the old RPMs
staged on disk for rollback). Phase 2 is not, in the conventional sense: from the first wipe onward the
only rollback is *resync from a healthy peer*, and that is exactly why the encryption phase is serial, why
each survivor is verified healthy and fingerprint-identical before the next wipe, and why every leg has a
per-database completeness gate. That gate is the whole safety net — treat it as load-bearing, not as
reporting.

If you want a backup instead, `playbooks/01-backup.yml` is intact and runnable on its own (it is
deliberately **not** wired into `site.yml`). It needs an NFS mount with room for a full dump:

```bash
ansible-playbook playbooks/01-backup.yml -e change_ticket=CHG-xxxx -e confirm_backup=YES
```
