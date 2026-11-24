#!/usr/bin/env bash
# check-sops-files.sh: fail if a SOPS file isn't fully encrypted, or if a
# plaintext secret is about to be committed. Plain bash + git + grep, no other
# tools. It prints file names and line numbers only, never values.
#
#   scripts/check-sops-files.sh --staged   # what is staged (pre-commit hook)
#   scripts/check-sops-files.sh --all      # every tracked file (CI)
#
# For every *.sops.env it requires:
#   - the path is in ALLOWED below (the stacks named in infrastructure/README.md,
#     Guiding Principles section 5);
#   - every non-empty line is KEY=ENC[AES256_GCM,...], an encrypted comment
#     #ENC[AES256_GCM,...], or one of the metadata lines sops writes for an
#     age-only file (sops_version, sops_lastmodified, sops_mac,
#     sops_unencrypted_suffix=_unencrypted, sops_age__list_N__map_recipient,
#     sops_age__list_N__map_enc), each with a value of the expected shape;
#   - a sops_mac=ENC[AES256_GCM,...] line;
#   - no sops_unencrypted_*, sops_encrypted_* or sops_mac_only_encrypted key,
#     except sops' own default sops_unencrypted_suffix=_unencrypted (every data
#     line must still be ENC[...], so a *_unencrypted key fails anyway);
#   - its age recipients are exactly the two age1... keys in .sops.yaml, and
#     .sops.yaml has no <AGE_PUBKEY_...> placeholder left;
#   - no "tskey-" and no "AGE-SECRET-KEY-" anywhere in it.
# Any other file with "sops" in its name (secrets.sops.yaml, .env.sops,
# secrets.sops.env.bak, ...) fails, except .sops.yaml and this script.
# In every scanned file it rejects a Tailscale-key-shaped or age-private-key-
# shaped string.
set -uo pipefail

# Stacks allowed to carry an encrypted env file. Adding one is a reviewed change
# together with infrastructure/README.md (Guiding Principles, section 5).
ALLOWED=(
  compose/infrastructure/tailscale/secrets.sops.env
)

# Key-shaped patterns. They don't match their own text (a '[' follows the prefix).
TSKEY_RE='tskey-[A-Za-z0-9_-]{16,}'
AGEKEY_RE='AGE-SECRET-KEY-[0-9A-Z-]{20,}'
B64='[A-Za-z0-9+/=]'
ENC_RE="ENC\\[AES256_GCM,data:${B64}*,iv:${B64}+,tag:${B64}+,type:[a-z]+\\]"
DATA_LINE_RE="^[A-Za-z_][A-Za-z0-9_]*=${ENC_RE}\$"
COMMENT_LINE_RE="^#${ENC_RE}\$"
# Metadata keys sops writes for an age-only dotenv file: getsops/sops
# stores/stores.go (metadata struct: lastmodified, mac, unencrypted_suffix,
# version; agekey: recipient, enc; one key group is written as top-level age),
# stores/metadata.go (SopsPrefix "sops_"), stores/flatten.go (__list_/__map_),
# stores/dotenv/store.go (newlines in values written as a literal \n).
AGE_ENC_RE='-----BEGIN AGE ENCRYPTED FILE-----(\\n[A-Za-z0-9+/=]*)*\\n-----END AGE ENCRYPTED FILE-----(\\n)?'
META_LINE_RE="^(sops_version=[0-9][0-9A-Za-z.+-]*|sops_lastmodified=[0-9][0-9TZ:.+-]*|sops_mac=${ENC_RE}|sops_unencrypted_suffix=_unencrypted|sops_age__list_[0-9]+__map_recipient=age1[0-9a-z]+|sops_age__list_[0-9]+__map_enc=${AGE_ENC_RE})\$"

usage() { echo "usage: $0 --staged | --all" >&2; exit 2; }
[ "$#" -eq 1 ] || usage
case "$1" in
  --staged) mode=staged ;;
  --all) mode=all ;;
  *) usage ;;
esac

root=$(git rev-parse --show-toplevel) || exit 2
cd "$root" || exit 2

# Print a file's content as it will be committed (staged) or as checked out (all).
content() {
  if [ "$mode" = staged ]; then git show ":$1" 2>/dev/null; else cat -- "$1" 2>/dev/null; fi
}

files=()
if [ "$mode" = staged ]; then
  mapfile -d '' -t files < <(git diff --cached --name-only -z --diff-filter=ACMR)
else
  mapfile -d '' -t files < <(git ls-files -z)
fi

fail=0
err() { echo "check-sops-files: $*" >&2; fail=1; }
lines_of() { cut -d: -f1 | paste -sd, -; }

# Recipients from .sops.yaml as it will be committed.
sops_yaml=$(content .sops.yaml || true)

sops_files=()
scanned=0
for f in "${files[@]}"; do
  [ -n "$f" ] || continue
  if [ "$mode" = all ] && [ ! -f "$f" ]; then continue; fi
  scanned=$((scanned + 1))
  { body=$(content "$f"); } 2>/dev/null || continue

  # Repo-wide: key-shaped strings in any text file.
  if hits=$(printf '%s\n' "$body" | grep -naIE -- "$TSKEY_RE" | lines_of) && [ -n "$hits" ]; then
    err "$f: Tailscale-key-shaped string on line(s) $hits"
  fi
  if hits=$(printf '%s\n' "$body" | grep -naIE -- "$AGEKEY_RE" | lines_of) && [ -n "$hits" ]; then
    err "$f: age private key on line(s) $hits"
  fi

  case "$f" in
    *.sops.env) sops_files+=("$f") ;;
    *)
      # Misnamed SOPS-looking files: "sops" anywhere in the file name.
      base=${f##*/}
      case "${base,,}" in
        *sops*)
          if [ "$f" != .sops.yaml ] && [ "$f" != scripts/check-sops-files.sh ]; then
            err "$f: file name contains 'sops' but isn't an allowed SOPS file (only */secrets.sops.env at ALLOWED paths, and .sops.yaml)"
          fi ;;
      esac
      continue ;;
  esac

  allowed=0
  for a in "${ALLOWED[@]}"; do [ "$f" = "$a" ] && allowed=1; done
  [ "$allowed" = 1 ] || err "$f: not an allowed SOPS file path (see ALLOWED in scripts/check-sops-files.sh)"

  if hits=$(printf '%s\n' "$body" | grep -nvE -e '^[[:space:]]*$' -e "$META_LINE_RE" -e "$DATA_LINE_RE" -e "$COMMENT_LINE_RE" | lines_of) && [ -n "$hits" ]; then
    err "$f: unencrypted or malformed line(s) $hits"
  fi
  printf '%s\n' "$body" | grep -qE '^sops_mac=ENC\[AES256_GCM,' \
    || err "$f: no sops_mac=ENC[AES256_GCM,...] line (not a SOPS-encrypted file)"
  # sops writes sops_unencrypted_suffix=_unencrypted by default (no rule set);
  # that exact line is allowed. Any other partial-encryption setting is not.
  if hits=$(printf '%s\n' "$body" | grep -nE '^sops_(unencrypted_|encrypted_|mac_only_encrypted)' \
      | grep -vE '^[0-9]+:sops_unencrypted_suffix=_unencrypted[[:space:]]*$' | lines_of) && [ -n "$hits" ]; then
    err "$f: partial-encryption setting on line(s) $hits"
  fi
  if hits=$(printf '%s\n' "$body" | grep -n 'tskey-' | lines_of) && [ -n "$hits" ]; then
    err "$f: contains 'tskey-' on line(s) $hits"
  fi
  if hits=$(printf '%s\n' "$body" | grep -n 'AGE-SECRET-KEY-' | lines_of) && [ -n "$hits" ]; then
    err "$f: contains 'AGE-SECRET-KEY-' on line(s) $hits"
  fi

  # Recipients: exactly the set in .sops.yaml.
  want=$(printf '%s\n' "$sops_yaml" | grep -v '^[[:space:]]*#' | grep -oE 'age1[0-9a-z]+' | sort -u)
  got=$(printf '%s\n' "$body" | sed -nE 's/^sops_age__list_[0-9]+__map_recipient=(age1[0-9a-z]+)[[:space:]]*$/\1/p' | sort -u)
  if [ -z "$got" ]; then
    err "$f: no age recipients (sops_age__list_N__map_recipient)"
  elif [ "$got" != "$want" ]; then
    err "$f: age recipients differ from .sops.yaml"
  fi
done

# .sops.yaml itself: no placeholder may be left once a SOPS file exists, and
# once filled in it must list exactly two recipients.
if printf '%s\n' "$sops_yaml" | grep -q '<AGE_PUBKEY_'; then
  [ "${#sops_files[@]}" -eq 0 ] \
    || err ".sops.yaml: an <AGE_PUBKEY_...> placeholder is left; fill in both public keys first"
elif [ -n "$sops_yaml" ]; then
  n=$(printf '%s\n' "$sops_yaml" | grep -v '^[[:space:]]*#' | grep -oE 'age1[0-9a-z]+' | sort -u | wc -l)
  [ "$n" -eq 2 ] || err ".sops.yaml: expected exactly 2 age recipients, found $n"
elif [ "${#sops_files[@]}" -gt 0 ]; then
  err ".sops.yaml is missing"
fi

if [ "$fail" -ne 0 ]; then
  echo "check-sops-files: FAILED ($mode). Values are never printed; open the file(s) above." >&2
  exit 1
fi
echo "check-sops-files: OK ($mode: $scanned file(s) scanned, ${#sops_files[@]} SOPS file(s))"
