#!/usr/bin/env bash
# Leak scan — run this before pushing a fork of this repo (or before you open-source your own copy).
#
#   ./scripts/leak-scan.sh          # scan this checkout
#   ./scripts/leak-scan.sh --staged # scan only what git has staged
#
# It looks for the things that actually leak in infrastructure repositories:
#   * private key material and certificates committed by accident
#   * an encrypted (or worse, plaintext) vault file that should have been ignored
#   * real private-network addresses outside the documentation example range (10.0.0.0/24)
#   * absolute paths from someone's laptop
#   * credentials in plain sight
#
# Exit code 1 = something to look at. It is a net, not a proof: read the diff too.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 2
MODE="${1:-all}"
FAIL=0
hit() { echo "  FAIL: $*"; FAIL=1; }
note() { echo "  ok:   $*"; }

if [[ "$MODE" == "--staged" ]] && command -v git >/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
  FILES="$(git diff --cached --name-only --diff-filter=ACMR)"
  SCAN() { printf '%s\n' "$FILES" | while read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done; }
else
  SCAN() { find . -type f \
             -not -path './.git/*' -not -path './.venv*' \
             -not -path './artifacts/*' -not -path './collections/*' -print; }
fi

echo "== 1. private key material / certificates in the tree =="
BAD_EXT="$(SCAN | grep -E '\.(pem|key|p12|pfx|jks|srl)$|(^|/)ca\.crt$' || true)"
if [[ -n "$BAD_EXT" ]]; then
  printf '%s\n' "$BAD_EXT" | sed 's/^/    /'
  hit "key/certificate files are present — they must not be committed (artifacts/tls/ is gitignored)"
else
  note "no .pem / .key / ca.crt files"
fi

echo "== 2. PEM blocks pasted into text files =="
PEM="$(SCAN | xargs grep -lE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' 2>/dev/null || true)"
if [[ -n "$PEM" ]]; then
  printf '%s\n' "$PEM" | sed 's/^/    /'
  hit "a private key body is embedded in one of these files"
else
  note "no embedded private keys"
fi

echo "== 3. vault files that are not the documented example =="
VLT="$(SCAN | grep -E 'vault\.ya?ml$' | grep -v '\.example$' || true)"
if [[ -n "$VLT" ]]; then
  printf '%s\n' "$VLT" | sed 's/^/    /'
  hit "a real vault file is in the tree (it should be listed in .gitignore)"
else
  note "only the .example vault file is present (or none)"
fi

echo "== 4. private IPs outside the example range 10.0.0.0/24 =="
IPPAT='\b(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})\b'
IPS="$(SCAN | grep -vE 'scripts/leak-scan\.sh$' | xargs grep -HoE "$IPPAT" 2>/dev/null \
        | grep -vE '(^|[^0-9])10\.0\.0\.[0-9]+' || true)"
if [[ -n "$IPS" ]]; then
  printf '%s\n' "$IPS" | sort -u | sed 's/^/    /'
  hit "real-looking addresses outside 10.0.0.x — confirm each one is intentional"
else
  note "all private addresses are in the example block"
fi

echo "== 5. laptop paths and hostnames =="
PATHS="$(SCAN | xargs grep -HoE '/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+' 2>/dev/null | sort -u || true)"
if [[ -n "$PATHS" ]]; then
  printf '%s\n' "$PATHS" | sed 's/^/    /'
  hit "absolute home-directory paths"
else
  note "no absolute home-directory paths"
fi

echo "== 6. credentials in plain sight =="
CRED="$(SCAN | xargs grep -nEi '(password|passwd|pwd|secret|token|api[_-]?key)[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9!@#$%^&*._-]{8,}' 2>/dev/null \
        | grep -viE 'REPLACE_ME|__UNSET__|placeholder|example|vault_|mongo_admin_password: "\{\{|x{8}|<.*>|\{\{|smoke' || true)"
if [[ -n "$CRED" ]]; then
  printf '%s\n' "$CRED" | sed 's/^/    /'
  hit "possible hard-coded credential"
else
  note "no hard-coded credentials found"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "clean — nothing obvious to strip before publishing"
  exit 0
fi
echo "REVIEW the items above before publishing."
exit 1
