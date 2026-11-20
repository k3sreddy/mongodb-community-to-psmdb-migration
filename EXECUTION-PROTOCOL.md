# Execution Protocol — gates, abort thresholds, decision record

**This document governs whether anything runs. It is not the plan — the plan is `README.md`.**
Nothing in this repository should be executed against production until every line of §2 and §3 below is
satisfied and the change owner has given an explicit, written go.

This is the protocol we actually used. If you adopt it, keep its shape: the value is not the checklist
items, it is that **the person running the destructive step is not the person who authorised it**, and that
every gate is read aloud and recorded rather than remembered.

---

## 1. Decision rights

| Decision | Who | Cannot be delegated to |
|---|---|---|
| Open the window / say "go" | Change owner + ops lead (both) | Ansible, a cron, or the operator alone |
| `confirm_*` variables (the actual trigger) | Operator, inside the window, after the gate is read aloud | Pre-set in a file, shell alias, or CI job |
| Approve the FCV ratchet at each hop | Change owner | — |
| **No-backup acceptance before the first wipe** | Two senior engineers, in writing, in the change record | The operator who performs the wipe |
| Abort / roll back | Either ops engineer, unilaterally — "stop" needs no second opinion | — |
| Declare the change successful | Ops lead, only after `06-verify.yml` PASS is read by a human | — |

## 2. Pre-window prerequisites (must all be true, verified — not assumed)

- [ ] Change record raised with: scope (3 hosts), 3 phases, 3 windows, rollback statement, named engineers
- [ ] App team written confirmation, quoting the actual production URI: replica-set form, **all three**
      hosts `10.0.0.11/12/13`, `replicaSet=rs0`, `retryWrites=true`
      (and explicitly *not* the 10.0.0.21/22/23 host list)
- [ ] No other change in flight on the reference cluster or on the application stack during the same window
- [ ] **No-backup acceptance recorded in the change** (Phase 2): rollback is a resync from the two
      surviving members, and losing two members at once is unrecoverable. Two signatures, §2A reviewed.
- [ ] Monitoring live and watched by a second person: primary CPU/IO, repl lag, app 5xx rate, driver errors
- [ ] `./scripts/audit.sh` prints **clean** (static audit, contacts nothing). If it does not, the window
      does not open — the last audit of this tree found five defects that `--syntax-check` passed
- [ ] `00b-bootstrap.yml` PASS — `mongosh` and `percona-release` installed on all three (additive
      only: no config, no data, no service). Without it the first hop removes the binary that owns
      the legacy `mongo` shell and every later step fails
- [ ] `00-preflight.yml` PASS (this is the go/no-go for topology, disk, NFS, and the baseline fingerprint)
- [ ] `00b`/`00` order respected, and the report shows shell=`mongosh` on all three (the read-only
      preflight may legitimately run with the legacy shell; nothing that mutates may)
- [ ] Vault file created, encrypted, readable: `inventory/group_vars/prod_live/vault.yml` (inside the
      group directory — a sibling `prod_live.vault.yml` is silently ignored by Ansible), and
      `ansible-playbook 00-preflight.yml` reaches the topology checks rather than failing on credentials
- [ ] Ansible reachable from the control host to all three nodes, key-based, `mongosh` present everywhere
- [ ] NFS share mounted rw on all three, with the free space the preflight requires
- [ ] Rollback RPM sets staged per node (`/root/rpm-stage-*`) **and** verified present — this is the only
      binary rollback for Phase 1
- [ ] Previous 7 days of `mongod.log` retained (post-incident forensics), log retention policy unchanged
- [ ] NFS share still holds the **encryption key DR copy** — with no data backup, losing that key means the
      data is gone permanently, so this one is non-negotiable

If any box is unchecked, the window does not open. There is no partial go.

## 2A. Compensating controls — migrating with no backup

There is no dump of this cluster and none will be taken. Phase 1 is low-risk without one (rolling, data
untouched, RPM rollback available until an FCV bump). **Phase 2 is different**: once a node is wiped, the
only copy of its data is on the other two members. These controls are what replaces the backup, and each
one is enforced by the playbooks, not by memory:

1. **Rehearsal first.** FBIS wipe+resync proven on dev, on the same 8.0 build, before the first prod wipe.
   If it does not complete cleanly on dev, Phase 2 does not start on prod.
2. **Strictly serial legs.** One node wiped at a time; the play structures make concurrency impossible.
   Never start leg N+1 while leg N is syncing.
3. **Survivor verification before every wipe.** All three members must be `health: 1`, in state
   PRIMARY/SECONDARY only, lag ≈ 0, and the two survivors must expose the **same database set** with totals
   within the fingerprint tolerance — checked on the target node immediately before `mongod` is stopped.
   Tolerance is 250,000 documents or 0.05%, whichever is larger (`group_vars/prod_live/main.yml`), because
   two healthy secondaries on this cluster measurably differ by ~9,700 docs (8 ppm) from write traffic
   alone. **Lag, not the fingerprint, is what proves a member is caught up.**
4. **Completeness proof after every resync.** The resynced node's fingerprint must be ≥ the Phase-0
   baseline (≥, never "≈": a short resync is always *below*), with **zero** optime lag against the primary.
   A short or partial resync fails the leg and the node is re-wiped — this is the check that a backup would
   otherwise have provided. The baseline is the `artifacts/baseline-*.json` written at the start of *this*
   window, never an older file: the cluster gains ~35 k documents per hour.
5. **Nothing else in the window.** No reboots, no patching, no other cluster work, no network changes while
   Phase 2 is in progress.
6. **Key DR is now the single point of no return.** Identical key on 3 nodes + NFS + off-box, sha256 recorded
   in the change. With no data backup, a lost key is unrecoverable data.
7. **Stop-on-first-degradation.** Any second member becoming degraded stops all work immediately — the
   cluster is then at 1 healthy member with no archive behind it.

**Residual risk, explicitly accepted:** if two nodes are lost (hardware, human error, or a wipe that runs on
the wrong host) during Phase 2, this cluster's data is unrecoverable. The controls above reduce the
probability; they do not provide a recovery path. That sentence belongs in the change record, signed.

## 3. No-go conditions (checked at T-0 and re-checked before each step)

Any one of these = stop, do not start, or abandon and reschedule:

- Replica set not fully healthy (3/3 `health: 1`) or lag > 5 s anywhere
- Any member already resyncing **or in any state other than PRIMARY/SECONDARY**
- Disk free on `/DATA` below the preflight threshold
- NFS share not mounted or not writable (it holds the encryption key DR copy)
- Doc-count fingerprints disagree between the two secondaries
- App team has not confirmed the URI / `retryWrites` — **a stepDown with a pinned host is an outage**
- A backup or restore is running anywhere in this set (it would contend with a resync)
- **The rollback RPM set for the hop is not on disk** (`/root/rpm-stage-<major>/`, ≥ 4 RPMs, no download
  warnings) — the play refuses to stop mongod without it
- **The community `mongodb-org-*` packages cannot be removed cleanly**, or the Percona repo for the hop is
  unreachable/there is no such NEVRA — a file-conflict failure happens with mongod already stopped
- Nobody else is watching monitoring

## 4. Ordered execution sheet

Run from the control host, in the repo root. Each command prints its gate; do not bypass a failed gate.
`CHG` = the real change number. Read the expected result aloud before moving on.

### Window 1 — baseline and upgrade (3–4 h)

```bash
# 1. Read-only baseline. Expected: all asserts green, artifacts/baseline-*.json written.
#    No backup is taken (ops decision) — this baseline fingerprint is the safety net.
#    Run it in THIS window, not reused from an older one.
ansible-playbook playbooks/00-preflight.yml

# 2. Hops, one at a time. Expected per hop: 3 members on the new build, FCV = hop, lag < 10 s.
ansible-playbook playbooks/02-upgrade.yml -e change_ticket=CHG -e confirm_window=YES -e hop=6.0
ansible-playbook playbooks/02-upgrade.yml -e change_ticket=CHG -e confirm_window=YES -e hop=7.0
ansible-playbook playbooks/02-upgrade.yml -e change_ticket=CHG -e confirm_window=YES -e hop=8.0

# 3. Close window 1.
ansible-playbook playbooks/06-verify.yml -e change_ticket=CHG
```

**Hop 6.0 is the only hop that removes packages.** Expect, per node, in this order: mongod stopped →
`mongodb-org-*` removed → `percona-server-mongodb-6.0.29-23` installed → saved config restored → mongod
started. If the play stops between the removal and the install, the node has **no mongod binary** — recover
with the staged RPM set in `/root/rpm-stage-5.0/`, not by improvising.

**Stop after every hop** and let the operator read `rs.status()` on the *primary* themselves — do not
trust only the playbook's own assertion. Between hops, wait until lag is back to ~0 on both secondaries.

Expected client-visible events in W1: 3 primary failovers, 10–30 s each, transparent with `retryWrites`.

### Burn-in — ≥ 24 h, no exceptions

No encryption work in the same night as the version upgrade. Watch: replication lag, slow queries,
app error rate, driver reconnects, index-format warnings. Anything odd: diagnose before Phase 2 —
after a wipe, diagnosis gets much more expensive.

### Window 2 — at-rest encryption (3–4 h, destructive, **no backup exists**)

Gate G-C must be signed first (no-backup acceptance + §2A reviewed).

```bash
# 5. Keys on all three, identical sha256, DR copy on NFS. No restarts, no data touched.
ansible-playbook playbooks/03-encryption-keys.yml -e change_ticket=CHG -e confirm_window=YES

# 6. Legs, in this order and only this order: mongo3 (logical) → mongo1 (FCBIS) → mongo2 (primary, FCBIS)
ansible-playbook playbooks/04-encrypt-nodes.yml -e change_ticket=CHG -e confirm_window=YES -e confirm_wipe=WIPE
```

Per leg, before the wipe, the operator personally checks on the target:
`grep -c enableEncryption /etc/mongod.conf` → **1**. This is not optional; this exact check was missed
on 25 Aug on the sibling cluster and produced an invalid hybrid node.

After each leg: member SECONDARY, lag < 30 s, `encryptionAtRest.encryptionEnabled: true`, and both other
members healthy **before** the next leg starts. Never start leg N+1 while leg N is still syncing —
2 healthy members is your only failover headroom.

### Window 3 — TLS, audit, hardening (~1 h)

```bash
./scripts/issue-certs.sh                      # once, on the control host; PKI lands in artifacts/tls
ansible-playbook playbooks/05-tls.yml -e change_ticket=CHG -e confirm_window=YES
ansible-playbook playbooks/06-verify.yml -e change_ticket=CHG
```

The play stages the config on all three members, then restarts **mongo3 → mongo1 → mongo2**, waiting for
each to be back in service before the next. Watch it: if a member does not come back, the run stops with one
member down and two healthy — recoverable. Do **not** shortcut this into a simultaneous restart; two members
down in a 3-node set means no majority and a real outage.

**Expected during the rollout, not a fault:** the first two restarted members stop replicating until the
third is restarted, because `preferTLS` uses TLS for outbound connections and their peers are still
plaintext. Healthy + SECONDARY + lagging is the expected look. The final verification asserts full catch-up
on all three; only *that* failing is an abort condition.

**What this means for clients, stated plainly.** While only two of three members are on TLS, those two
cannot apply new writes, so **`w: "majority"` writes do not fail — they block.** A blocked write is not an
error, so `retryWrites` does *not* rescue it; application threads or pool slots simply wait until the third
member is restarted (~2–5 min). Reads and `w: 1` writes are unaffected. Three ways to handle it:

| Option | What happens | When to choose |
|---|---|---|
| **A — accept it** (what the play does now) | 2–5 min of writes waiting on majority | the app team confirms `w: 1`, or accepts the pause in the lowest-traffic hour |
| **B — planned 5-minute write pause** before the two restarts | nothing blocks; apps drain first | the app team confirms `w: "majority"` **without** `wtimeout` |
| **C — `allowTLS` instead of `preferTLS`** | no pause, but member-to-member traffic stays **plaintext** | rejected: it does not satisfy "TLS enabled" |

The deciding input is the app team's **write concern** (`w`, `wtimeout`) — a hard gate, not paperwork. If
`wtimeout` is set (e.g. 5 s), majority writes fail rather than hang and `retryWrites` may ride it out, at the
cost of error-log noise.

**End state of this change: `net.tls.mode: preferTLS` — TLS and non-TLS client connections are both
accepted, by decision.** Members replicate over TLS; clients may use `tls=true` or a plaintext URI. No client
certificate is required. Verify both paths on all three nodes (the play asserts it):

```js
// from each node
db.adminCommand({getParameter:1})                    // sanity
db.serverStatus().transportSecurity                  // TLS 1.3/1.2 handshake counters climbing
```
`requireTLS` is a separate change (app CA mount + `tls=true` in every URI first, then the flip). It cannot be
run from this project without `-e confirm_require_tls=YES`.

## 5. Abort criteria (numeric — no judgement call needed)

Abort the remaining work and stabilise if any of these occur:

| Signal | Threshold |
|---|---|
| **Any second member degrades during a leg** | **stop everything immediately** — no backup exists |
| Replication lag | > 60 s sustained for 5 min after a member returns |
| Member health | any member `health: 0` for > 2 min |
| Failover churn | > 2 primary changes in 10 min |
| Resync | no progress (bytes copied / oplog position) for 15 min |
| Resync completeness | fingerprint below the Phase-0 baseline → re-wipe that node, logical fallback |
| App errors | 5xx or driver errors materially above pre-window baseline |
| Disk | `/DATA` free falls below 15 % |
| Resync duration | still not SECONDARY after the 4 h budget (`resync_wait_retries: 960`) → stop, inspect, re-wipe |
| TLS rollout | a member not accepting connections 10 min after its restart → stop before restarting the next (lag alone is NOT an abort here) |
| FCBIS | `fileBasedInitialSyncMaxLagSec` exceeded for > 3 cycles → fall back to **logical** for that node |
| Config gate | any leg fails the `grep -c enableEncryption == 1` check |

Abort ≠ rollback. Abort = stop touching things, keep the set at 2+ healthy members, and decide from the
state you actually have. Rolling back is the §6 branch.

## 6. Rollback decision tree

```
Failure is in Phase 1 (version upgrade), before an FCV bump?
└── reinstall the staged RPM set on the affected node, restore its .bak config, restart.
    FCV is still the previous major → the old binary is compatible. Cost: ~10 min/node.

Failure is after an FCV bump (6.0/7.0/8.0 confirmed)?
└── NO binary downgrade exists. Forward-fix only, on 2 healthy members.

Failure in Phase 2 (encryption), before a wipe?
└── restore the .bak config on that node, restart, re-plan. Nothing was destroyed.

Failure in Phase 2, during or after a wipe of node N?
├── Node N is not yet resynced → wipe again and retry; if FCBIS keeps failing, remove the FCBIS
│   parameter, restart, let it sync logically. The other two members are intact throughout.
├── Node N resynced but the fingerprint is below baseline → same: re-wipe, retry, logical fallback.
└── A SECOND member becomes degraded at any point during this → STOP. Keep everything else up,
    do not touch another host, and escalate. There is no archive to restore from.

Failure in Phase 3 (TLS)?
└── Same all-members rule: restore the pre-TLS .bak (`/root/mongod.conf.tls-preferTLS.bak`) on ALL
    THREE, then restart them ONE AT A TIME, waiting for each to return. Never leave the set split
    between TLS-configured and TLS-less members, and never restart two at once — with one member
    already down that removes the majority.

There is no branch that reads "restore from backup". That is the accepted cost of not taking one.
```

The point of Phase 2's serial design is that **the other two members are always intact**. Every decision
above assumes you never take a second node down while one is degraded — that assumption is now load-bearing,
because it is the entire rollback plan.

## 7. Close-out (required before the change is closed)

- [ ] `06-verify.yml` PASS: 3/3 on `8.0.29-13`, FCV `8.0`, AES256-GCM, encryption enabled everywhere
- [ ] Fingerprint: current ≥ baseline, member spread within tolerance, delta explained by live writes
      (record the numbers and the artifact filename, not "looks fine")
- [ ] Plaintext-leak scan: token not found in dbPath
- [ ] Smoke test: write → replicated read on a secondary → cleanup
- [ ] Replica set: `mongo2` PRIMARY (priority 2), lag ≤ 2 s, all `health: 1`
- [ ] Report + manifests filed in `artifacts/` and attached to the change record
- [ ] Encryption key sha256 recorded in the change record; key DR copies verified readable
- [ ] Firewall/bindIp decision recorded (either implemented or explicitly deferred with an owner)
- [ ] App team end-to-end validation signed off
- [ ] Old RPMs retained ~1 week, then cleaned; logs retained for the audit window
- [ ] Update `tasks.md` status and notify stakeholders

## 8. Post-migration backlog (deliberately *not* in these windows)

1. `requireTLS` + `allowConnectionsWithoutCertificates: false` (only after every app URI carries `tls=true`)
2. `bindIp` restriction + firewalling 27017 to app subnets (needs the CIDR list)
3. Admin password rotation — the current prod admin credential is shared across both clusters and is
   written down in a file in this repo; after the migration it should be rotated and vaulted (and this
   project's vault file becomes the single reference)
4. AD/LDAP mapping for prod (separate plan, mirrors the dev implementation)
5. Percona Backup for MongoDB (PBM) + scheduled physical backups, so "backup" stops being a manual window
6. Key management upgrade: local keyfile → Vault/KMIP
7. First quarterly access review (ISO 27001 A.5)
