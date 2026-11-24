# Pitfalls

Every item below is a defect that survived code review, `--syntax-check`, and in several cases a *successful*
read-only run. They are ordered by how expensive they were, not by elegance. Each one names the symptom you
would actually see, and the guard now in place.

If you read one document in this repository, read this one.

---

## 1. `preferTLS` stalls `w:"majority"` writes for minutes (and it looks like a hang, not an error)

**Symptom.** You restart members one at a time into `net.tls.mode: preferTLS`. The first two come up healthy
but report `STARTUP2`/no sync source: they cannot talk TLS to each other yet, because a `preferTLS` member
uses TLS *between members*. The cluster still has a primary, so the app does not crash — instead writes with
`w:"majority"` (and no `wtimeout`) **block** until the third member is up, typically **2–5 minutes**.

**Why `retryWrites` does not save you.** The writes do not fail, so there is nothing to retry. Your
`writeConcernError` handlers never fire. Request threads just sit there, and timeouts surface as 5xx from the
application pool, not as MongoDB errors.

**Guard.** Get the app team's actual write concern (`w`, `wtimeout`, `maxPoolSize`) in writing before the TLS
window, then choose deliberately:
- **A** — accept a 2–5 min block (fine if writes tolerate it or the pool is large);
- **B** — announce a planned 5-minute write pause;
- **C** — `allowTLS` instead (accepts TLS *and* plaintext inbound, but does **not** use TLS member-to-member —
  only do this if you know you are trading away the thing you wanted).

Also: `preferTLS` and `allowTLS` both accept plaintext inbound. Neither replaces network-level access control.

---

## 2. The FCBIS log marker is hyphenated — an unhyphenated grep reads `0` forever

**Symptom.** Your "did the resync use file-copy-based initial sync?" check reports zero matches on a run that
definitely used it. A zero-match grep looks like a *failed* gate, or worse, if you only print it, like nothing
at all.

**Cause.** Percona's binary logs `File copy-based initial sync` (with a hyphen), not `File copy based initial
sync`. Verified with `strings /usr/bin/mongod` on v8.0.29-13.

**Guard.** Take gate strings from the binary, not from memory or the docs, and assert both directions:
- positive: `File copy-based initial sync`, `FCBIS`
- negative: `Falling back to logical initial sync`, `Support for the file copy-based`,
  `sync source does not support file copy-based initial sync`

`scripts/audit.py` (check 13) rejects the unhyphenated literal, because a comparison string that can never
match real output is worse than no check.

---

## 3. FCBIS silently falls back to a logical resync — after you wiped the node

**Symptom.** Nothing. The resync completes correctly, hours later than planned, and your window is gone. The
log says `Falling back to logical initial sync` and carries on.

**Why it bites.** You have already deleted the data directory at this point. There is no going back to "just
restart it". The fallback is correct behaviour, not a bug — which is exactly why it must be a hard failure in
your run.

**Additional requirements that are easy to miss:**
- the syncing node and its source must be on the **same** PSMDB version;
- **no backup cursor** may be running on source or target (the backup cursor is single — hence one leg at a
  time, and a `pgrep` check that excludes your own Ansible process);
- FCBIS exists in 8.0 only; it is not available in 6.0/7.0, and early 8.0 builds gated it behind Percona's
  Pro build. Check `strings /usr/bin/mongod | grep -i "file copy"` **on your build** before designing around it.

---

## 4. An unregistered `setParameter` makes mongod refuse to start — after the wipe

**Symptom.** The leg writes its tuning into `mongod.conf`, the old data is gone, and `mongod` exits at startup
with an unknown-parameter error. The node is now empty *and* down.

**Guard.** Every parameter you write must be confirmed **registered in that exact binary**
(`strings /usr/bin/mongod | grep <name>`), and re-asserted at runtime against the running process:

```javascript
db.adminCommand({ getCmdLineOpts: 1 })
```

A `mongod.conf` grep proves you wrote the file. It does not prove the server accepted it — the file could have
been written after the process started, or the block could be ignored.

---

## 5. A skipped Ansible task still registers its variable

**Symptom.** A gate that works in testing crashes on the primary, or silently compares against a stub.
`when:` skipped the task, but `register:` still created the variable — with `{"skipped": true}` and no
`.stdout`. `from_json` then throws, or a filter quietly matches nothing and the gate "passes".

**Guard.** Filter on `result.stdout is defined`, never on `result is defined`. Audit every
`register` + `is defined` pair.

This one is load-bearing in a no-backup migration: the fingerprint gate is the *only* proof that a wipe+resync
produced a complete dataset.

---

## 6. `null` is not a Jinja literal (and YAML `none` is the string `"none"`)

**Symptom.** A `selectattr(…, 'ne', none)` filter silently stops filtering, so the primary gets included in a
comparison it was meant to be excluded from — or an expression yields *Undefined* and defeats the gate.

**Guard.** In Jinja use `none`. In YAML use `null` (not `none`). Never `else null` inside a template.

---

## 7. A `#` comment inside a `>-` or `|` block is template text

**Symptom.** `--syntax-check` passes. The play dies at runtime with `TemplateSyntaxError`, or the expression
renders garbage including your comment.

**Guard.** Comments go above the key, never inside the folded block.

---

## 8. `group_vars/<group>/` shadows `<group>.yml`, and `<group>.vault.yml` is not group vars

**Symptom.** `ansible_password` is undefined with **no warning at all**, or variables vanish when you add a
directory next to the file.

**Cause.** Ansible loads `group_vars/<group>.yml` **or** every file inside `group_vars/<group>/`. When the
directory exists it wins. And a file named `prod_live.vault.yml` is treated as vars for a group called
`prod_live.vault` — which does not exist — so it is silently ignored.

**Guard.** Keep the vault at `group_vars/<group>/vault.yml`, and have the first play assert the credential is
not a placeholder (`REPLACE_ME` / `__UNSET__`) so a missing vault fails loudly.

---

## 9. The controller's Python and the target's Python are two different problems

**Symptom A (controller).** `pip install ansible-core==2.22` fails on RHEL/Rocky 8: it declares
`Requires-Python >=3.13`, and 3.12 is the newest available. Invisible on a modern workstation running 3.13+.

**Symptom B (target).** `ansible -m ping` fails with `future feature annotations is not defined`: the default
`python3` on RHEL 8 is 3.6.8, and modern module payloads are not 3.6-compatible.

**Symptom C (the sequel).** Because the target's dnf bindings exist only for platform-python 3.6,
`ansible.builtin.dnf` cannot work there at all. Drive packages with `command: dnf …` and verify with `rpm -q`
— which also gives you the exact NVR check the `dnf` module would not.

**Guard.** Pin the controller (`2.21.x`) *and* the target interpreter (`/usr/bin/python3.12`), and re-run the
static audit **on the control host**, because module-argument validation uses the installed `ansible-doc`.

---

## 10. YAML flow sequences split on commas — silently

**Symptom.** `argv: [findmnt, -o, SOURCE,TARGET,FSTYPE]` becomes three arguments; `--output=avail,size`
becomes two. The command fails, or worse, means something different.

**Guard.** Quote comma-bearing values, and prefer block lists for `argv`. This is a YAML trap, not an Ansible
one, and it is check 9 of `scripts/audit.py`.

---

## 11. Fingerprints: `listDatabases` is primary-only, and `countDocuments` is a full scan

**Symptom A.** On a secondary, `db.adminCommand({listDatabases:1})` returns
`{ok: 0, errmsg: "not master and slaveOk=false"}` — a document with **no** `.databases` — and the JS throws
`TypeError: …databases is undefined` (exit 252).

**Symptom B.** The fingerprint takes hours, because `countDocuments({})` is an aggregation scan per collection.

**Guard.** Call `db.getMongo().setSecondaryOk()` before any admin command, and use `collStats.count` (the
WiredTiger table count) instead. On a ~1.2 billion-document cluster that turned hours into ~5 seconds. And
fingerprint **secondaries only** — never add a scan load to the only writable node.

---

## 12. Exact fingerprint equality is unachievable — so it is not a gate

**Symptom.** Your completeness gate fails on a healthy cluster. Two secondaries sampled seconds apart differ
by thousands of documents because writes are landing between samples. Measured: ~9,700 documents apart
(8 ppm) while both fully in sync.

**Guard.** Compare a **tolerance** (we use 250 k documents or 0.05%, whichever is larger) *and* assert the
**database set is identical** — that catches a genuinely missing database. Then add a **per-database** gate,
because 0.05% of a billion documents is 500 k: a whole 300 k-document collection could vanish and still pass
the total. Replication lag remains the authoritative "is this member behind" signal.

Be honest about the detection floor: ours is roughly 100 k documents in one database, 250 k in total. Write
that number down so nobody later believes the gate is more precise than it is.

---

## 13. `rsync --delete` from your workstation deletes the evidence the gate needs

**Symptom.** You re-sync the project before W2. The `baseline-*.json` that the encryption legs compare against
was produced **on the node**, is not in your workstation copy, and is now gone. The next leg fails closed
*after* a wipe, with nothing to compare to.

**Guard.** Protect node-produced paths: `--filter='P artifacts/***'`. Test it both ways — with the filter the
node artifacts survive and local copies still land; plain `--delete` removes them.

Same family: **never re-stage while a play is running.** Ansible reads task files as it walks the play, so
overwriting `tasks/*.yml` changes the run mid-flight. Have the staging script refuse when a session exists.

---

## 14. `map('keys')` does not exist, and other expression shapes that look right

**Symptom.** `No filter named 'keys'`. `keys` is a Python method, not an Ansible filter.

**Guard.** Use `dictsort | map('map', attribute=0)` for a dict's keys, and add a static check for the
non-existent-filter family — this class of typo only appears when the branch finally executes.

---

## 15. `hosts: localhost` plays do not see your group vars

**Symptom.** The run dies at the very end, in the *report* task, with `'<some_var>' is undefined` — after the
expensive work is done. Implicit `localhost` is only a member of group `all`, so `group_vars/<group>/` never
loads.

**Guard.** Give report plays an explicit `vars_files:` for the group file, or run them with `-i` plus
`hosts: all`. Add a static check that a localhost play cannot reference group-scoped variables it never loads.

---

## 16. The version-1 mistake: assuming the upgrade is the risky part

The upgrade (Community → Percona 6.0 → 7.0 → 8.0) is reversible: the data is untouched, the previous RPMs can
be staged on disk, and the failure mode is "start the old binary". The **encryption** phase is not. From the
first wipe onward, rollback means *resync from a surviving peer* — which is why it is serial, why survivors are
verified healthy and fingerprint-identical before each wipe, and why "we'll take a backup if we need one" is not
a plan you want to invent at 03:00.

Decide that before the window, record it, and have someone other than the operator sign it.

---

## 17. `featureCompatibilityVersion` is a **document**, not a string — so `| string` never matches

**Symptom.** A gate that has always worked suddenly reports "hop not complete" on a member that upgraded
perfectly — or, worse, an FCV comparison silently never matches and the gate reads as `false` forever.

**Cause.** `db.adminCommand({getParameter: 1, featureCompatibilityVersion: 1})` answers with
`{ featureCompatibilityVersion: { version: "5.0" }, ok: 1 }` on current builds — confirmed against a live
5.0.8 server, not inferred from the docs. Render that value in Jinja or templating and `| string` gives you
`{'version': '5.0'}`, which no `^5\.0` pattern will ever match. It is also easy to miss in a rehearsal,
because read-only preflight does not usually compare the FCV: the failure lands on the **first upgrade hop**,
after the packages have already been swapped.

**Guard.** Normalise once, keep the raw value for evidence, and assert the shape:

```yaml
mongo_fcv_raw: "{{ (build_raw.stdout | from_json).fcv }}"
mongo_fcv: "{{ mongo_fcv_raw.version if (mongo_fcv_raw is mapping) else mongo_fcv_raw }}"
```

Then every comparison uses `mongo_fcv`. Two related traps while you are there:
- a **resume** must be allowed to re-run the hop it is half-way through, so compare with set membership
  (`in [previous_major, hop]`), not equality — otherwise an interrupted window can only be recovered by
  doing the unsafe thing (skipping ahead);
- an FCV can never legitimately be **ahead** of the running binary, so `fcv_major | float <= binary_major |
  float` is a cheap, high-value assertion.
