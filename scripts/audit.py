#!/usr/bin/env python3
"""Static audit for the LIVE migration playbooks. Contacts NO host.

Run it before every window, and after any edit to playbooks/ or tasks/:

    ./scripts/audit.sh

It exists because this project's failure mode is not "the playbook errors" — it is "the gate
silently passes" or "the variable was never loaded". Every check below corresponds to a defect
that actually shipped in a draft of this plan (see README §12A):

  1  syntax          --syntax-check on every playbook
  2  templates       every {{ }} / {% %} and every when/until/failed_when expression must PARSE
  3  variables       every name used in a template must be defined somewhere
  4  modules         every module argument must exist in ansible-doc for the installed version
  5  fail-closed     no `| default(...)` inside an assert (a missing var would pass the gate)
  6  registers       every `failed_when: false` register must be re-checked downstream
  7  group_vars      the group directory must not be shadowed, and the vault must be loadable
  8  docs            every documented command supplies the confirmation vars it gates on
  9  yaml commas     no unquoted "A,B" inside a flow sequence (YAML splits it into 2 elements)
 10  host env        the measured node reality: python>=3.8 interpreter, no dnf module,
                    require_mongosh on every mutating play
 11  play scope      a `hosts: localhost` play may not read vars that exist only inside a
                    group's group_vars/ directory — implicit localhost is only in group 'all'
 12  jinja filters   filters Ansible does not actually have (e.g. `map('keys')`)
 13  bad literals    string literals a gate compares against that CANNOT match the real output
                    (e.g. a log grep on "File copy based initial sync" when PSMDB logs it with a
                    hyphen — the check then reads zero forever and silently passes)
"""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

import yaml

try:
    import jinja2
    from jinja2 import nodes as jnodes
except ImportError:
    sys.exit("jinja2 missing — run this with the same interpreter as ansible-playbook")

ROOT = pathlib.Path(__file__).resolve().parent.parent
FAIL = []
WARN = []


def fail(check, msg):
    FAIL.append((check, msg))


def warn(check, msg):
    WARN.append((check, msg))


def load(p):
    try:
        return yaml.safe_load(p.read_text())
    except Exception as e:  # noqa: BLE001
        fail("yaml", f"{p.name}: {e}")
        return None


PLAYBOOKS = sorted((ROOT / "playbooks").glob("*.yml"))
TASKS = sorted((ROOT / "tasks").glob("*.yml"))
ALL = PLAYBOOKS + TASKS

KEYWORDS = {
    "name", "when", "loop", "register", "ignore_errors", "no_log", "quiet", "vars", "run_once",
    "delegate_to", "failed_when", "until", "retries", "delay", "changed_when", "check_mode",
    "loop_control", "tags", "become", "become_user", "environment", "notify", "listen", "args",
    "block", "rescue", "always", "any_errors_fatal", "ignore_unreachable", "throttle", "diff",
}
# module args that collide with keyword names but are legitimate
ARG_EXCEPTIONS = {"assert": {"quiet"}, "file": {"state", "mode", "owner", "group"},
                  "copy": {"mode", "owner", "group", "dest", "src", "content"},
                  "dnf": {"name", "state"}, "systemd": {"name", "state", "enabled", "daemon_reload"}}


def walk_tasks(node, out):
    if isinstance(node, dict):
        if "name" in node or any(k.startswith("ansible.builtin.") for k in node):
            out.append(node)
        for v in node.values():
            walk_tasks(v, out)
    elif isinstance(node, list):
        for v in node:
            walk_tasks(v, out)


def all_tasks():
    out = []
    for f in ALL:
        doc = load(f)
        if isinstance(doc, list):
            walk_tasks(doc, out)
    return out


# ── 1. syntax ────────────────────────────────────────────────────────────────────
def check_syntax():
    exe = os.environ.get("AUDIT_ANSIBLE_PLAYBOOK") or "ansible-playbook"
    for p in PLAYBOOKS:
        r = subprocess.run([exe, "--syntax-check", str(p)], capture_output=True, text=True)
        if r.returncode != 0:
            fail("syntax", f"{p.name}: {r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr[:120]}")


# ── 2+3. templates and variables ──────────────────────────────────────────────────
MAGIC = set("""item inventory_hostname inventory_hostname_short hostvars groups group_names playbook_dir
omit ansible_facts ansible_host ansible_user ansible_password ansible_become ansible_version
ansible_check_mode ansible_diff_mode ansible_play_hosts ansible_play_batch ansible_run_tags
ansible_skip_tags ansible_verbosity ansible_loop ansible_loop_var ansible_index_var
ansible_python_version ansible_config_file ansible_forks ansible_inventory_sources ansible_limit
ansible_search_path role_path role_name now query q lookup range dict zip lipsum undef vars
namespace""".split())

VAULT_KEYS = {"vault_ansible_password", "vault_mongo_admin_password",
              "vault_audit_rotator_password", "vault_mongo_backup_password"}
EXTRA_VARS = {"hop", "change_ticket", "allow_missing_rollback", "backup_source_host",
              "confirm_window", "confirm_wipe", "confirm_backup", "confirm_require_tls",
              "tls_mode", "tls_restart_order", "expected_state", "skip_lag_check", "max_lag_sec",
              "wait_retries", "wait_delay", "leg_method", "leg_source", "leg_expected_state",
              "conf_merge", "conf_label", "stepdown_seconds", "r", "x"}


def defined_names():
    names = set(MAGIC) | set(EXTRA_VARS)
    for gv in (ROOT / "inventory/group_vars").rglob("*.yml"):
        if gv.name == "vault.yml" or gv.name.endswith((".vault.yml",)):
            names |= VAULT_KEYS
            continue
        d = load(gv)
        if isinstance(d, dict):
            names |= set(d)
    for f in ALL:
        doc = load(f)
        if not isinstance(doc, list):
            continue
        stack = [doc]
        while stack:
            n = stack.pop()
            if isinstance(n, dict):
                if "register" in n and isinstance(n["register"], str):
                    names.add(n["register"])
                if n.get("set_fact") or n.get("ansible.builtin.set_fact"):
                    v = n.get("set_fact") or n.get("ansible.builtin.set_fact")
                    if isinstance(v, dict):
                        names |= set(v)
                if isinstance(n.get("vars"), dict):
                    names |= set(n["vars"])
                if isinstance(n.get("loop_var"), str):
                    names.add(n["loop_var"])
                if "loop" in n:
                    names.add("item")
                stack.extend(n.values())
            elif isinstance(n, list):
                stack.extend(n)
    return names


def names_in(ast):
    out, stack = set(), [ast]
    while stack:
        n = stack.pop()
        if isinstance(n, jnodes.Name) and n.ctx == "load":
            out.add(n.name)
        for field in getattr(n, "fields", ()):
            v = getattr(n, field, None)
            if isinstance(v, jnodes.Node):
                stack.append(v)
            elif isinstance(v, list):
                stack.extend(x for x in v if isinstance(x, jnodes.Node))
    return out


def check_templates():
    env = jinja2.Environment()
    known = defined_names()

    def chk(s, where, implicit=False):
        if not isinstance(s, str):
            return
        if not implicit and "{{" not in s and "{%" not in s:
            return
        src = "{{ " + s + " }}" if implicit else s
        try:
            ast = env.parse(src)
        except Exception as e:  # noqa: BLE001
            fail("template", f"{where}: cannot parse -> {str(e)[:90]}")
            return
        for nm in names_in(ast):
            if nm not in known:
                fail("variable", f"{where}: '{nm}' is not defined anywhere")

    def walk(n, where):
        if isinstance(n, dict):
            for k, v in n.items():
                if k in ("when", "until", "failed_when", "changed_when"):
                    for x in (v if isinstance(v, list) else [v]):
                        if isinstance(x, str):
                            chk(x, where, implicit=True)
                    continue
                walk(v, where)
        elif isinstance(n, list):
            for v in n:
                walk(v, where)
        elif isinstance(n, str):
            chk(n, where)

    for f in ALL:
        doc = load(f)
        if isinstance(doc, list):
            walk(doc, f.name)


# ── 4. module arguments ──────────────────────────────────────────────────────────
def check_module_args():
    exe = os.environ.get("AUDIT_ANSIBLE_DOC") or "ansible-doc"
    tasks = all_tasks()
    mods = set()
    for t in tasks:
        for k in t:
            if k.startswith("ansible.builtin."):
                mods.add(k)
    for mod in sorted(mods):
        try:
            r = subprocess.run([exe, "--json", mod], capture_output=True, text=True, timeout=90)
            if r.returncode != 0:
                fail("module", f"{mod}: ansible-doc failed")
                continue
            doc = json.loads(r.stdout)
            doc = doc.get(mod, doc)
            params = set((doc.get("doc") or {}).get("options") or {})
        except Exception as e:  # noqa: BLE001
            fail("module", f"{mod}: {e}")
            continue
        if not params:
            continue
        short = mod.split(".")[-1]
        # set_fact / add_host accept ARBITRARY keys as variables — validating them is meaningless
        if short in ("set_fact", "add_host"):
            continue
        # deliberately NOT `| KEYWORDS`: a task keyword placed INSIDE a module's argument
        # dict is exactly the defect this check exists to find (e.g. no_log under assert).
        allowed = params | ARG_EXCEPTIONS.get(short, set())
        for t in tasks:
            args = t.get(mod)
            if isinstance(args, dict):
                for a in args:
                    if a not in allowed:
                        fail("module", f"{t.get('name')}: {short} got invalid parameter '{a}'")


# ── 5. fail-closed assertions ────────────────────────────────────────────────────
# Two distinct hazards, and only the first is fatal:
#   (a) a COMPARISON BOUND defaulted to 0/empty -> `x >= 0` is always true -> gate passes.
#       This is the defect that made the Phase-2 completeness check toothless.
#   (b) a boolean defaulted to False in a "must not be" test -> `not (x|default(false))` is
#       true when x is unknown, i.e. "unknown" reads as "safe".
# a default of 0 / [] / {} inside a gate makes comparisons trivially satisfiable, on whichever
# side of the operator it appears. default('') is left alone: the ubiquitous
# `confirm_x | default('') == 'YES'` pattern is fail-CLOSED ('' != 'YES').
TRIVIAL_BOUND = re.compile(r"\|\s*default\(\s*(0|\[\]|\{\})\s*\)")
FAIL_OPEN_NOT = re.compile(r"not\s*\(?\s*[\w.\[\]']+\s*\|\s*default\(\s*(false|False)\s*\)")


def check_fail_closed():
    for t in all_tasks():
        for mod in ("assert", "ansible.builtin.assert"):
            a = t.get(mod)
            if not isinstance(a, dict):
                continue
            for cond in a.get("that") or []:
                if not isinstance(cond, str):
                    continue
                if TRIVIAL_BOUND.search(cond):
                    fail("fail-open", f"{t.get('name')}: comparison bound defaults to 0/empty, "
                                      f"so this gate always passes: {cond.strip()[:80]}")
                if FAIL_OPEN_NOT.search(cond):
                    fail("fail-open", f"{t.get('name')}: `not (x | default(false))` passes when x "
                                      f"is unknown — use default(true) so unknown refuses: "
                                      f"{cond.strip()[:80]}")


# ── 6. register re-checks (per file: the check must look at the SAME file) ────────
def check_registers():
    for f in ALL:
        doc = load(f)
        if not isinstance(doc, list):
            continue
        per_file = []
        walk_tasks(doc, per_file)
        text = f.read_text()
        for t in per_file:
            if t.get("failed_when") is False and isinstance(t.get("register"), str):
                var = t["register"]
                if not (re.search(rf"\b{var}\.(rc|stdout|stderr|stat|results)\b", text)
                        or re.search(rf"\b{var}\b\s*\|\s*(failed|changed)", text)):
                    fail("register", f"{f.name}: '{var}' has failed_when:false and is never "
                                     f"re-checked in that file — the failure disappears")


# ── 7. group_vars layout ─────────────────────────────────────────────────────────
def check_group_vars():
    gv = ROOT / "inventory/group_vars"
    for entry in sorted(gv.iterdir()):
        if entry.is_dir() and (gv / f"{entry.name}.yml").exists():
            fail("group_vars", f"{entry.name}/ SHADOWS {entry.name}.yml — move the file into the dir")
        if entry.is_file() and entry.name.count(".") >= 2 and entry.suffix == ".yml":
            warn("group_vars", f"{entry.name} is not group vars unless the group is named "
                               f"'{entry.name[:-4]}' — Ansible loads it only inside <group>/")
    if not (gv / "prod_live" / "vault.yml").exists():
        warn("group_vars", "inventory/group_vars/prod_live/vault.yml missing — credentials unset")


# ── 8. docs vs gates ─────────────────────────────────────────────────────────────
def check_docs():
    req = {}
    for p in PLAYBOOKS:
        t = p.read_text()
        req[p.name] = set(re.findall(r"confirm_[a-z_]+", t)) - {"confirm_require_tls", "confirm_backup"}
    for d in (ROOT / "README.md", ROOT / "EXECUTION-PROTOCOL.md"):
        if not d.exists():
            continue
        for line in d.read_text().splitlines():
            if "ansible-playbook" not in line:
                continue
            m = re.search(r"playbooks/([0-9a-z-]+\.yml)", line)
            if not m:
                continue
            miss = req.get(m.group(1), set()) - set(re.findall(r"(confirm_[a-z_]+)=", line))
            if miss:
                warn("docs", f"{m.group(1)} command omits {sorted(miss)}")


# ── 9. host-environment assumptions ──────────────────────────────────────────────
# These are not style points: each one was measured against the real nodes on 2026-11-19 and
# each one silently breaks the whole run if it is "tidied" back.
def check_host_environment():
    all_yml = pathlib.Path(ROOT / "inventory/group_vars/all.yml")
    cfg = load(all_yml) if all_yml.exists() else {}
    interp = str((cfg or {}).get("ansible_python_interpreter", ""))
    if not interp:
        fail("env", "group_vars/all.yml sets no ansible_python_interpreter; the node default is "
                    "python3.6 and every module payload fails with "
                    "'future feature annotations is not defined'")
    elif interp.endswith("/python3") and "3." not in pathlib.Path(interp).name[6:]:
        fail("env", f"ansible_python_interpreter={interp} is python3.6 on these nodes: "
                    f"ansible-core 2.22 modules cannot run on it")
    elif not any(v in interp for v in ("3.8", "3.9", "3.10", "3.11", "3.12", "3.13")):
        fail("env", f"ansible_python_interpreter={interp} is older than 3.8 — the module payload "
                    f"will not execute")

    # The dnf python bindings exist only for platform-python 3.6 on Rocky 8, so the dnf module
    # can never run alongside a modern interpreter. Packages must go through the CLI.
    for f in ALL:
        text = f.read_text()
        for mod in ("ansible.builtin.dnf", "ansible.builtin.yum", "dnf:", "yum:"):
            if re.search(rf"^\s+{re.escape(mod)}\s*:", text, re.M):
                fail("env", f"{f.name}: uses the '{mod}' module — its python bindings exist only "
                            f"for python3.6 here, which ansible-core cannot use. Use the dnf CLI.")

    # Anything that mutates a node runs after the community packages are removed, and the
    # legacy mongo binary belongs to them. Every non-localhost play must refuse without mongosh.
    for f in PLAYBOOKS:
        if f.name in ("00-preflight.yml", "00b-bootstrap.yml", "01-backup.yml", "site.yml"):
            continue
        doc = load(f)
        if not isinstance(doc, list):
            continue
        for i, play in enumerate(doc, 1):
            if not isinstance(play, dict) or "import_playbook" in play:
                continue
            if play.get("hosts") == "localhost":
                continue
            if not (play.get("vars") or {}).get("require_mongosh"):
                fail("env", f"{f.name} play#{i} (hosts={play.get('hosts')}) does not set "
                            f"require_mongosh: true — it would run without a usable shell")


# ── 10. YAML flow-sequence comma trap ────────────────────────────────────────────
# In an UNQUOTED flow sequence, a comma is YAML's item separator, not part of the value:
#     argv: [findmnt, -n, -T, "{{ nfs_backup_dir }}", -o, SOURCE,TARGET,FSTYPE]
# parses as SEVEN argv elements (..., '-o', 'SOURCE', 'TARGET', 'FSTYPE'), and findmnt then
# exits 1 with "options --target and --source can't be used together with command line element
# that is not an option". Same for `--output=avail,size`. Legal separators are written ", "
# (comma + space); a comma with no space after it, outside quotes and outside Jinja, is the bug.
def check_flow_commas():
    quoted_or_jinja = re.compile(r"""\{\{.*?\}\}|\{%.*?%\}|"[^"]*"|'[^']*'""")
    suspicious = re.compile(r"[A-Za-z0-9_.=/-]+,[A-Za-z0-9_.=/-]+")
    for f in ALL:
        for lineno, line in enumerate(f.read_text().splitlines(), 1):
            if "[" not in line or "]" not in line:
                continue
            if line.lstrip().startswith("#"):
                continue
            stripped = quoted_or_jinja.sub("", line)
            for m in suspicious.finditer(stripped):
                fail("yaml-comma", f"{f.name}:{lineno}: '{m.group(0)}' sits in an unquoted flow "
                                   f"sequence, so YAML splits it into separate elements — quote it "
                                   f"or avoid the comma")


# ── 11. play variable scope ──────────────────────────────────────────────────────
# check_templates() builds ONE global set of defined names, so a name that exists in
# inventory/group_vars/prod_live/ counts as "defined" even inside a play that never loads it.
# That is exactly how `fingerprint_max_rel_pct` and `cluster_id` reached a `hosts: localhost`
# play: implicit localhost is only a member of group 'all', so prod_live group vars never
# arrive, and the run dies mid-report with "'fingerprint_max_rel_pct' is undefined" — after the
# expensive fingerprint work has already been done. A localhost play must either read only
# group_vars/all.yml (+ -e extra vars, registers, set_fact), or load the group file explicitly
# with vars_files.
def _defined_in_play(play):
    out = set()
    stack = [play]
    while stack:
        n = stack.pop()
        if isinstance(n, dict):
            if isinstance(n.get("register"), str):
                out.add(n["register"])
            for k in ("set_fact", "ansible.builtin.set_fact", "vars"):
                v = n.get(k)
                if isinstance(v, dict):
                    out |= set(v)
            if isinstance(n.get("loop_var"), str):
                out.add(n["loop_var"])
            if "loop" in n:
                out.add("item")
            stack.extend(n.values())
        elif isinstance(n, list):
            stack.extend(n)
    return out


def _vars_loaded_by(play, playbook):
    out = set()
    for entry in play.get("vars_files") or []:
        if not isinstance(entry, str):
            continue
        raw = entry.replace("{{ playbook_dir }}", str(playbook.parent))
        raw = raw.replace("{{playbook_dir}}", str(playbook.parent))
        if "{{" in raw:
            continue  # computed path: cannot resolve statically, assume it works
        p = pathlib.Path(raw)
        p = p if p.is_absolute() else (playbook.parent / p)
        try:
            p = p.resolve()
        except OSError:
            continue
        if p.exists():
            d = load(p)
            if isinstance(d, dict):
                out |= set(d)
    return out


def check_play_scope():
    gv = ROOT / "inventory/group_vars"
    scoped, unscoped = {}, set()
    for entry in sorted(gv.iterdir()):
        if entry.is_dir():
            for f in entry.glob("*.yml"):
                if f.name == "vault.yml" or f.name.endswith(".vault.yml"):
                    continue
                d = load(f)
                if isinstance(d, dict):
                    for k in d:
                        scoped.setdefault(k, set()).add(entry.name)
        elif entry.suffix == ".yml":
            d = load(entry)
            if isinstance(d, dict):
                unscoped |= set(d)
    only_scoped = {k: v for k, v in scoped.items() if k not in unscoped}
    if not only_scoped:
        return

    env = jinja2.Environment()

    def names_in_text(s):
        if not isinstance(s, str) or ("{{" not in s and "{%" not in s):
            return set()
        try:
            return names_in(env.parse(s))
        except Exception:  # noqa: BLE001
            return set()  # unparseable is check_templates' problem, not this one

    def strings_in(n):
        stack = [n]
        while stack:
            x = stack.pop()
            if isinstance(x, dict):
                stack.extend(x.values())
            elif isinstance(x, list):
                stack.extend(x)
            elif isinstance(x, str):
                yield x

    for f in PLAYBOOKS:
        doc = load(f)
        if not isinstance(doc, list):
            continue
        for i, play in enumerate(doc, 1):
            if not isinstance(play, dict) or play.get("hosts") != "localhost":
                continue
            available = set(MAGIC) | set(EXTRA_VARS) | unscoped | _defined_in_play(play) \
                | _vars_loaded_by(play, f)
            used = set()
            for s in strings_in(play):
                used |= names_in_text(s)
            for nm in sorted(used & set(only_scoped) - available):
                fail("play-scope",
                     f"{f.name} play#{i} ({play.get('name', 'unnamed')}): reads '{nm}', which is "
                     f"defined only in group_vars/{sorted(only_scoped[nm])[0]}/ — implicit localhost "
                     f"is in group 'all' only. Add vars_files or move the var to group_vars/all.yml")


# ── 12. jinja filters that do not exist ─────────────────────────────────────────
# `map('keys')` looks reasonable and fails at RUN time with "No filter named 'keys'". The same
# class of mistake: map/dict2items etc. asked for a Python method that is not a filter.
NO_SUCH_FILTER = {"keys", "values", "items", "get", "append", "extend"}
FILTER_CALL = re.compile(r"\b(?:map|select|reject|selectattr|rejectattr)\(\s*['\"]([a-z_.0-9]+)['\"]")


def check_jinja_filters():
    for f in ALL:
        for lineno, line in enumerate(f.read_text().splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for m in FILTER_CALL.finditer(line):
                name = m.group(1)
                if name in NO_SUCH_FILTER:
                    fail("jinja-filter",
                         f"{f.name}:{lineno}: no filter named '{name}' — `{name}` is a python "
                         f"method, not a Jinja filter (use dictsort + map(attribute=0) for keys)")


# ── 13. literals that a gate compares against but that cannot match real output ────────────────
# Each entry is a string that shipped in a draft and made a gate read zero forever. The real
# output is in the comment so the correct form is obvious.
BAD_LITERALS = {
    "File copy based initial sync":
        "PSMDB logs 'File copy-based initial sync' (WITH a hyphen; verified via `strings "
        "/usr/bin/mongod` on v8.0.29-13). Without the hyphen the FCBIS proof reads 0 on every "
        "build and the gate silently passes.",
}


def check_bad_literals():
    for f in ALL:
        for lineno, line in enumerate(f.read_text().splitlines(), 1):
            for lit, why in BAD_LITERALS.items():
                if lit in line:
                    fail("bad-literal", f"{f.name}:{lineno}: '{lit}' — {why}")


def main():
    for fn in (check_syntax, check_templates, check_module_args, check_fail_closed,
               check_registers, check_group_vars, check_docs, check_host_environment,
               check_flow_commas, check_play_scope, check_jinja_filters, check_bad_literals):
        try:
            fn()
        except Exception as e:  # noqa: BLE001
            fail(fn.__name__, f"check crashed: {e}")

    print(f"audited {len(PLAYBOOKS)} playbooks, {len(TASKS)} task files\n")
    for c, m in FAIL:
        print(f"  FAIL [{c}] {m}")
    for c, m in WARN:
        print(f"  WARN [{c}] {m}")
    if not FAIL and not WARN:
        print("  clean")
    print(f"\n{len(FAIL)} failure(s), {len(WARN)} warning(s)")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
