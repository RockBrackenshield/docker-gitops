#!/usr/bin/env bash
# host/bootstrap.sh: one-time (and safely re-runnable) node bootstrap for the
# docker-gitops nodes `infrastructure` and `core`.
#
# Run it on the node, after the repo check in host/README.md:
#   sudo /srv/homelab/docker-gitops/host/bootstrap.sh
# or remotely (needs a terminal for the prompts):
#   ssh -t <admin-user>@<node> 'sudo /srv/homelab/docker-gitops/host/bootstrap.sh'
#
# Flags: none for the normal run; --unlock-dockhand (infrastructure, after
# Dockhand authentication is on); --restore-prep is reserved for the
# restore-runbook PR.
#
# The bws access token is read once from /dev/tty, never from argv, a file or
# the environment, is passed only to the one bws process, and is unset right
# after. Secrets come from `bws secret list -o env` on a pipe and are parsed
# here against the node's name allowlist; no secret name ever becomes an
# environment variable. Values only ever go to files in a tmpfs directory
# under /run that is deleted on every exit. Nothing secret is printed or logged.
# Never add `set -x` to this file.

set -euo pipefail
shopt -s inherit_errexit
refuse_xtrace() { case $- in *x*) echo "refusing to run with xtrace" >&2; exit 1 ;; esac; }
refuse_xtrace
# Fixed PATH in every mode, whatever the caller's environment holds.
SAFE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH=$SAFE_PATH
umask 077
ulimit -c 0                # no core dumps holding the token

REPO=/srv/homelab/docker-gitops
BWS=/usr/local/bin/bws
BWS_VERSION='bws 2.1.0'
# Release zip pin (checked by Rock at install time, host/README.md):
#   bws-aarch64-unknown-linux-gnu-2.1.0.zip
#   sha256 18253757286e119d450133a87eb463bf8c1ce418ce24c834f4f250d60cba6f9e
#   (GitHub asset digest and bws-sha256-checksums-2.1.0.txt)
# sha256 of the extracted /usr/local/bin/bws. Bitwarden publishes digests for
# the zip only, so this value comes from Rock's verified install.
# Recorded from Rock's installed bws 2.1.0 (Nov 12, 2026).
BWS_BIN_SHA256=3633cb277faf94fb446fa8eff492d447ed4b1b1fbc2bbf59528e034c06bdc167
BWS_SERVER_BASE=https://vault.bitwarden.com   # US cloud
DOCKHAND_SERVER_URL=''                         # empty for the US cloud

LOG=/var/log/homelab-bootstrap.log
FW_ENV=/etc/homelab/firewall.env
FW_SCRIPT=/usr/local/sbin/homelab-firewall.sh
UNIT_DIR=/etc/systemd/system
FW_UNITS=(homelab-firewall-early.service homelab-firewall-docker.service)      # enabled
FW_UNIT_FILES=("${FW_UNITS[@]}" homelab-firewall-alert.service)               # installed (alert: OnFailure= only)
DOCKHAND_URL=http://127.0.0.1:3000
TS_STATE=/srv/homelab/tailscale/state/tailscaled.state

ROLE=''
RUNDIR=''
BWS_TOKEN=''
TOKEN_ENTERED=0            # 1 once a bws token was typed: cleanup reminds to revoke it
LOG_READY=0

# --- output -----------------------------------------------------------------

log() {   # log STEP RESULT: step names and results only, never values
  printf '[%s] %s\n' "$1" "$2" >&2
  if [ "$LOG_READY" = 1 ]; then
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >> "$LOG"
  fi
}
die() { log "${STEP:-bootstrap}" "FAIL: $*"; exit 1; }

# --- pure helpers (box-tested) -------------------------------------------------

expected_names() {
  case $1 in
    infrastructure)
      printf '%s\n' TS_AUTHKEY_INFRASTRUCTURE DOCKHAND_BWS_ACCESS_TOKEN TS_ROUTES INFRA_LAN_IP \
        ZORAXY_SOURCE_CIDR INFRA_EDGE_SUBNET INFRA_INTERNAL_SUBNET NTFY_UID NTFY_GID ;;
    core)
      printf '%s\n' INFRA_LAN_IP PRINTER_IP LAPTOP_IP PAPERLESS_UID PAPERLESS_GID ;;
    *) return 1 ;;
  esac
}
optional_names() {
  case $1 in
    core) printf '%s\n' PRINTER_IPV6 LAPTOP_IPV6 ;;
    *) : ;;
  esac
}

# check_names ROLE NAME...: the names bws handed over must be exactly the
# node's set (plus optional ones). Extra names mean the machine account can
# read more than its one project. Prints names only, never values.
check_names() {
  local role=$1 n; shift
  local -A got=()
  for n in "$@"; do got[$n]=1; done
  local missing=()
  for n in $(expected_names "$role"); do
    [[ -n ${got[$n]+x} ]] || missing+=("$n")
    unset 'got[$n]'
  done
  for n in $(optional_names "$role"); do unset 'got[$n]'; done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "missing secret names for $role: ${missing[*]}" >&2; return 1
  fi
  if [ "${#got[@]}" -gt 0 ]; then
    echo "unexpected secret names (machine account reads too much): ${!got[*]}" >&2; return 1
  fi
}

# stage_secrets ROLE DIR: reads `bws secret list -o env` output on stdin.
# bws 2.1.0 prints NAME="VALUE" per line and escapes nothing, so only lines
# matching ^[A-Z0-9_]+="[^"\\]*"$ are accepted. Anything else fails closed:
# the comment bws prints for a non-POSIX name, a quote, backslash or newline
# inside a value, a blank line. The names must be exactly the node's set (no
# duplicates, no extras such as LD_PRELOAD or PATH) before any value is
# written. Values stay in this function and go only to files in DIR; names
# never become variables. Prints names and line numbers only, never values.
stage_secrets() {
  local role=$1 dir=$2 line name n=0
  local re='^([A-Z0-9_]+)="([^"\\]*)"$'
  local -A vals=()
  local names=()
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    [[ $line =~ $re ]] || { echo "bws output line $n is not NAME=\"VALUE\" (line not shown)" >&2; return 1; }
    name=${BASH_REMATCH[1]}
    [[ -z ${vals[$name]+x} ]] || { echo "duplicate secret name: $name" >&2; return 1; }
    vals[$name]=${BASH_REMATCH[2]}
    names+=("$name")
  done
  check_names "$role" "${names[@]}" || return 1
  for name in $(expected_names "$role"); do
    [ -n "${vals[$name]}" ] || { echo "secret $name is empty" >&2; return 1; }
  done
  for name in $(expected_names "$role"); do
    printf '%s' "${vals[$name]}" > "$dir/$name" || return 1
  done
  for name in $(optional_names "$role"); do
    if [ -n "${vals[$name]-}" ]; then printf '%s' "${vals[$name]}" > "$dir/$name" || return 1; fi
  done
}

# root_owned_not_writable "UID MODE" (stat -c '%u %a'): owner root, no
# group/world write bit.
root_owned_not_writable() {
  local uid mode
  read -r uid mode <<<"$1" || return 1
  [ "$uid" = 0 ] && [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 8#022) == 0 ))
}

# bws_pin_ok PIN: fails closed unless PIN is a sha256 and matches the binary.
bws_pin_ok() {
  local pin=$1 actual
  [[ $pin =~ ^[0-9a-f]{64}$ ]] || return 1
  actual=$(sha256sum "$BWS")
  [ "${actual%% *}" = "$pin" ]
}

valid_id() { [[ $1 =~ ^[1-9][0-9]{0,9}$ ]]; }
valid_ipv4() { [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
valid_cidr4() { [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; }

# ipv4_int IP: strict dotted quad (0-255, no leading zeros) -> 32-bit integer.
ipv4_int() {
  local o v=0
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    [[ $o =~ ^(0|[1-9][0-9]*)$ ]] && (( o <= 255 )) || return 1
    v=$(( v * 256 + o ))
  done
  printf '%s' "$v"
}

# cidr4_within INNER OUTER: both strict IPv4 CIDRs, INNER no wider than OUTER
# and inside it. Used to keep ZORAXY_SOURCE_CIDR inside INFRA_EDGE_SUBNET.
cidr4_within() {
  local ia il oa ol mask
  [[ $1 =~ ^([^/]+)/(0|[1-9][0-9]?)$ ]] || return 1
  il=${BASH_REMATCH[2]}; ia=$(ipv4_int "${BASH_REMATCH[1]}") || return 1
  [[ $2 =~ ^([^/]+)/(0|[1-9][0-9]?)$ ]] || return 1
  ol=${BASH_REMATCH[2]}; oa=$(ipv4_int "${BASH_REMATCH[1]}") || return 1
  (( il <= 32 && ol <= 32 && il >= ol )) || return 1
  mask=$(( ol == 0 ? 0 : (0xFFFFFFFF << (32 - ol)) & 0xFFFFFFFF ))
  (( (ia & mask) == (oa & mask) ))
}

# read_marker FILE: the Dockhand :3000 marker in an existing firewall.env.
read_marker() {
  local f=$1 m=''
  if [ -n "$f" ] && [ -r "$f" ]; then
    m=$(sed -n 's/^DOCKHAND_3000=//p' "$f" | tail -n 1)
  fi
  case $m in lock|allowlist) printf '%s' "$m" ;; *) printf lock ;; esac
}

# render_firewall_env ROLE STAGEDIR OLDFILE: new firewall.env content. The
# Dockhand marker is preserved (a new install starts locked; allowlist is
# never turned back into lock or removed).
render_firewall_env() {
  local role=$1 dir=$2 old=$3 n zcidr edge
  if [ "$role" = infrastructure ]; then
    # Zoraxy's source range must sit inside its Docker network (fails closed;
    # homelab-firewall.sh checks this again at every boot and requires /16 or
    # longer).
    zcidr=$(<"$dir/ZORAXY_SOURCE_CIDR") && edge=$(<"$dir/INFRA_EDGE_SUBNET") \
      && cidr4_within "$zcidr" "$edge" \
      || { echo "ZORAXY_SOURCE_CIDR must be an IPv4 CIDR inside INFRA_EDGE_SUBNET" >&2; return 1; }
  fi
  echo '# Written by host/bootstrap.sh. Private values: never commit this file.'
  echo "ROLE=$role"
  if [ "$role" = infrastructure ]; then
    echo "INFRA_LAN_IP=$(<"$dir/INFRA_LAN_IP")"
    echo "ZORAXY_SOURCE_CIDR=$(<"$dir/ZORAXY_SOURCE_CIDR")"
    echo "INFRA_EDGE_SUBNET=$(<"$dir/INFRA_EDGE_SUBNET")"
    echo "DOCKHAND_3000=$(read_marker "$old")"
  else
    for n in INFRA_LAN_IP PRINTER_IP LAPTOP_IP; do echo "$n=$(<"$dir/$n")"; done
    for n in PRINTER_IPV6 LAPTOP_IPV6; do
      if [ -s "$dir/$n" ]; then echo "$n=$(<"$dir/$n")"; fi
    done
  fi
}

# dockhand_action HTTP_CODE MARKER HAS_PROVIDER -> skip | create | fail
dockhand_action() {
  case $1 in
    403) echo skip ;;                         # auth is on: never POST
    200)
      if [ "$2" = allowlist ]; then echo fail  # auth off after unlock
      elif [ "$3" = yes ]; then echo skip
      else echo create
      fi ;;
    *) echo fail ;;
  esac
}

# render_provider_json TOKENFILE SERVERURL: body for POST /api/secret-providers
# (Dockhand v1.0.57: {name, type, config:{token, serverUrl?}}).
render_provider_json() {
  local token
  token=$(<"$1")
  [[ $token =~ ^[0-9A-Za-z.:+/=_-]+$ ]] || { echo "Dockhand token has unexpected characters" >&2; return 1; }
  if [ -n "$2" ]; then
    printf '{"name":"bitwarden","type":"bitwarden","config":{"token":"%s","serverUrl":"%s"}}' "$token" "$2"
  else
    printf '{"name":"bitwarden","type":"bitwarden","config":{"token":"%s"}}' "$token"
  fi
}

# render_ts_override RUNDIR: run-time Compose override (tmpfs, never in Git).
# The key reaches the container only as a file; env, argv and docker inspect
# show the path, never the key.
render_ts_override() {
  cat <<YAML
services:
  tailscale:
    environment:
      TS_AUTHKEY: file:/run/secrets/ts_authkey
    secrets:
      - source: ts_authkey
        target: ts_authkey
secrets:
  ts_authkey:
    file: $1/TS_AUTHKEY_INFRASTRUCTURE
YAML
}

render_exports() {   # README section 6 export line
  printf '/srv/homelab/paperless/consume/nfs %s(rw,sync,sec=sys,secure,no_subtree_check,root_squash,all_squash,anonuid=%s,anongid=%s)\n' "$1" "$2" "$3"
}

# port53_ok "SS_OUTPUT": nothing on :53, or only Docker's proxy (AdGuard).
port53_ok() {
  local line
  if [ -z "$1" ]; then return 0; fi
  while IFS= read -r line; do
    if [ -z "$line" ]; then continue; fi
    [[ $line == *'"docker-proxy"'* || $line == *'"AdGuardHome"'* ]] || return 1
  done <<<"$1"
}

# --- system helpers -----------------------------------------------------------

init_log() {
  [ -e "$LOG" ] || install -m 0600 -o root -g root /dev/null "$LOG"
  chmod 0600 "$LOG"
  LOG_READY=1
}

# cleanup: runs from the EXIT trap and at the end of a normal run, so the
# revocation reminder shows on failures too (printed once).
cleanup() {
  if [ -n "$RUNDIR" ] && [ -d "$RUNDIR" ]; then rm -rf -- "$RUNDIR"; fi
  unset -v BWS_TOKEN
  if [ "$TOKEN_ENTERED" = 1 ]; then
    TOKEN_ENTERED=0
    cat >&2 <<'MSG'

Revoke the bootstrap access token now (Bitwarden > Machine accounts > bootstrap-<node> > Access tokens).
MSG
  fi
}

have_tty() { { : </dev/tty; } 2>/dev/null; }

# install_file SRC DST MODE: copy only when different; prints "changed".
install_file() {
  if ! cmp -s "$1" "$2"; then
    install -m "$3" -o root -g root "$1" "$2"
    echo changed
  fi
}

ts_running() {
  local st
  st=$(docker exec tailscale tailscale status --json 2>/dev/null || true)
  [[ $st =~ \"BackendState\":[[:space:]]*\"Running\" ]]
}
# ts_logs_clean: no 'tskey-' in the current tailscale container's log.
ts_logs_clean() {
  local n
  n=$(docker logs tailscale 2>&1 | grep -c 'tskey-' || true)
  [ "$n" = 0 ] || { echo "docker logs tailscale contain 'tskey-' ($n lines)" >&2; return 1; }
}
wait_ts_running() {
  local _
  for _ in $(seq 1 60); do ts_running && return 0; sleep 2; done
  return 1
}

dockhand_probe() {   # dockhand_probe OUTFILE -> HTTP code (000 if down)
  curl --noproxy '*' -s -o "$1" -w '%{http_code}' "$DOCKHAND_URL/api/secret-providers" 2>/dev/null || true
}

# --- preflight (step 0) ---------------------------------------------------------

preflight() {
  STEP=0-preflight
  [ "$EUID" -eq 0 ] || die "run with sudo"
  ROLE=$(hostname -s)
  case $ROLE in infrastructure|core) ;; *) die "hostname must be infrastructure or core" ;; esac
  [ "$(uname -m)" = aarch64 ] || die "not aarch64"
  have_tty || die "no terminal: run on the node or with ssh -t"
  local cis
  cis=$(cloud-init status --wait 2>/dev/null || true)
  [[ $cis == *"status: done"* ]] || die "cloud-init has not finished cleanly (cloud-init status --long)"
  command -v docker >/dev/null || die "docker missing"
  docker version >/dev/null 2>&1 || die "docker not running"
  docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
  local fb
  fb=$(docker info --format '{{json .FirewallBackend}}' 2>/dev/null || true)
  [[ $fb == *'"Driver":"iptables"'* ]] || die "Docker firewall backend is not iptables"
  log 0-preflight "iptables: $(iptables -V)"
  [ -d "$REPO/.git" ] || die "$REPO is not a git clone"
  local bad
  bad=$(find "$REPO" ! -type l \( ! -user root -o -perm /022 \) -print -quit)
  [ -z "$bad" ] || die "repo must be root-owned and not group/world-writable: $bad"
  # Information only: Rock verifies HEAD with the OS's git BEFORE running.
  log 0-preflight "repo HEAD (info only): $(git -C "$REPO" log -1 --format='%H %cd %s')"
  [ -f "$BWS" ] && [ -x "$BWS" ] || die "$BWS missing (install bws first, host/README.md)"
  root_owned_not_writable "$(stat -L -c '%u %a' "$BWS")" \
    || die "$BWS must be owned by root and not group/world-writable"
  bws_pin_ok "$BWS_BIN_SHA256" \
    || die "sha256 of $BWS does not match BWS_BIN_SHA256 (pinned bws 2.1.0, host/README.md)"
  [ "$("$BWS" --version)" = "$BWS_VERSION" ] || die "bws version is not $BWS_VERSION"
  log 0-preflight ok
}

# --- secrets (step 1) -------------------------------------------------------------

need_secrets() {
  STEP=1-secrets
  install -d -m 0700 "$RUNDIR/bws-state"
  printf '[profiles.default]\nserver_base = "%s"\nstate_opt_out = "true"\nstate_dir = "%s"\n' \
    "$BWS_SERVER_BASE" "$RUNDIR/bws-state" > "$RUNDIR/bws.toml"
  IFS= read -rs -p 'bws access token (input hidden): ' BWS_TOKEN < /dev/tty
  echo > /dev/tty
  [ -n "$BWS_TOKEN" ] || die "empty token"
  TOKEN_ENTERED=1
  # Values arrive on the pipe and are parsed in this script (stage_secrets);
  # the token is only in bws's own environment.
  if ! BWS_ACCESS_TOKEN=$BWS_TOKEN BWS_CONFIG_FILE=$RUNDIR/bws.toml \
      "$BWS" -p default secret list -o env --color no | stage_secrets "$ROLE" "$RUNDIR"; then
    unset -v BWS_TOKEN
    die "bws login or secret staging failed (nothing that needs secrets was changed)"
  fi
  unset -v BWS_TOKEN
  log 1-secrets ok
}

# --- steps: done_<step> needs no secrets; step_<step> uses staged files ---------

done_accounts() {
  if [ "$ROLE" = infrastructure ]; then
    id -u ntfy >/dev/null 2>&1 && [ "$(stat -c '%U %a' /srv/homelab/ntfy 2>/dev/null)" = 'ntfy 700' ]
  else
    [ "$(stat -c %u /srv/homelab/paperless 2>/dev/null)" != 0 ] \
      && [ "$(stat -c %a /srv/homelab/paperless/consume 2>/dev/null)" = 2770 ]
  fi
}
step_accounts() {
  STEP=2-accounts
  if [ "$ROLE" = infrastructure ]; then
    local uid gid
    uid=$(<"$RUNDIR/NTFY_UID") gid=$(<"$RUNDIR/NTFY_GID")
    if ! valid_id "$uid" || ! valid_id "$gid"; then die "NTFY_UID/NTFY_GID must be positive integers"; fi
    if getent group ntfy >/dev/null; then
      [ "$(getent group ntfy | cut -d: -f3)" = "$gid" ] || die "group ntfy exists with a different GID"
    else
      groupadd --system --gid "$gid" ntfy
    fi
    if id -u ntfy >/dev/null 2>&1; then
      [ "$(id -u ntfy)" = "$uid" ] && [ "$(id -g ntfy)" = "$gid" ] || die "user ntfy exists with a different UID/GID"
    else
      useradd --system --uid "$uid" --gid ntfy --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin ntfy
    fi
    install -d -m 0700 -o ntfy -g ntfy /srv/homelab/ntfy /srv/homelab/ntfy/attachments
  else
    local uid gid p=/srv/homelab/paperless
    uid=$(<"$RUNDIR/PAPERLESS_UID") gid=$(<"$RUNDIR/PAPERLESS_GID")
    if ! valid_id "$uid" || ! valid_id "$gid"; then die "PAPERLESS_UID/PAPERLESS_GID must be positive integers"; fi
    mkdir -p "$p"/{data,media,export,dump,consume/smb,consume/nfs} /srv/paperless/{db,broker}
    if [ "$(stat -c %u:%g "$p")" != "$uid:$gid" ]; then chown -R "$uid:$gid" "$p"; fi
    chmod 0750 "$p"/{data,media,export,dump}
    chmod 2770 "$p"/consume "$p"/consume/smb "$p"/consume/nfs
  fi
  log 2-accounts ok
}

done_networks() {
  docker network inspect infra_edge >/dev/null 2>&1 && docker network inspect infra_internal >/dev/null 2>&1
}
step_networks() {
  STEP=3-networks
  local name subnet have
  for name in infra_edge infra_internal; do
    if [ "$name" = infra_edge ]; then subnet=$(<"$RUNDIR/INFRA_EDGE_SUBNET"); else subnet=$(<"$RUNDIR/INFRA_INTERNAL_SUBNET"); fi
    valid_cidr4 "$subnet" || die "subnet for $name is not an IPv4 CIDR"
    if docker network inspect "$name" >/dev/null 2>&1; then
      have=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$name")
      [[ " $have " == *" $subnet "* ]] || die "network $name exists with a different subnet (not recreated; Rock decides)"
    else
      docker network create --driver bridge --subnet "$subnet" "$name" >/dev/null
    fi
  done
  log 3-networks ok
}

done_firewall() {
  [ -f "$FW_ENV" ] && [ -x "$FW_SCRIPT" ] || return 1
  cmp -s "$REPO/host/firewall/homelab-firewall.sh" "$FW_SCRIPT" || return 1
  local u
  for u in "${FW_UNIT_FILES[@]}"; do
    cmp -s "$REPO/host/firewall/$u" "$UNIT_DIR/$u" || return 1
  done
  for u in "${FW_UNITS[@]}"; do
    systemctl is-enabled --quiet "$u" || return 1
  done
  "$FW_SCRIPT" --check >/dev/null 2>&1 || return 1
  iptables -w -t raw -C PREROUTING -j HOMELAB-RAW 2>/dev/null || return 1
  ip6tables -w -t raw -C PREROUTING -j HOMELAB-RAW 2>/dev/null || return 1
  iptables -w -C DOCKER-USER -j HOMELAB-DOCKER 2>/dev/null || return 1
  if [ "$ROLE" = core ]; then iptables -w -C INPUT -j HOMELAB-INPUT 2>/dev/null || return 1; fi
}
step_firewall() {
  STEP=4-firewall
  local new=$RUNDIR/firewall.env units_changed='' u
  render_firewall_env "$ROLE" "$RUNDIR" "$FW_ENV" > "$new" \
    || die "firewall values from bws do not validate (nothing changed)"
  bash "$REPO/host/firewall/homelab-firewall.sh" --check --env "$new" >/dev/null \
    || die "firewall values from bws do not validate (nothing changed)"
  install -d -m 0700 -o root -g root /etc/homelab
  install_file "$new" "$FW_ENV" 0600 >/dev/null
  install_file "$REPO/host/firewall/homelab-firewall.sh" "$FW_SCRIPT" 0755 >/dev/null
  for u in "${FW_UNIT_FILES[@]}"; do
    units_changed+=$(install_file "$REPO/host/firewall/$u" "$UNIT_DIR/$u" 0644)
  done
  if [ -n "$units_changed" ]; then systemctl daemon-reload; fi
  systemctl enable --quiet "${FW_UNITS[@]}"
  # Never `systemctl restart` the early unit (Requires= would restart Docker).
  if systemctl is-active --quiet homelab-firewall-early.service; then
    "$FW_SCRIPT" --early >/dev/null
  else
    systemctl start homelab-firewall-early.service
  fi
  if systemctl is-active --quiet homelab-firewall-docker.service; then
    "$FW_SCRIPT" --docker >/dev/null
  else
    systemctl start homelab-firewall-docker.service
  fi
  done_firewall || die "firewall rules not all present after apply"
  log 4-firewall ok
}

step_port53() {   # verify only; the fix is cloud-init (stub listener off)
  STEP=5-port53
  local out
  out=$(ss -Hlntup 'sport = :53' 2>/dev/null || true)
  port53_ok "$out" || die "something other than AdGuard (Docker) listens on :53: check 'ss -lntup sport = :53'"
  log 5-port53 ok
}

done_nfs() {
  local v
  [ -f /etc/exports.d/paperless.exports ] || return 1
  v=$(exportfs -v 2>/dev/null || true)
  [[ $v == *"/srv/homelab/paperless/consume/nfs"* ]]
}
step_nfs() {
  STEP=6-nfs
  local ip uid gid new=$RUNDIR/paperless.exports
  ip=$(<"$RUNDIR/LAPTOP_IP") uid=$(<"$RUNDIR/PAPERLESS_UID") gid=$(<"$RUNDIR/PAPERLESS_GID")
  valid_ipv4 "$ip" || die "LAPTOP_IP is not an IPv4 address"
  if ! valid_id "$uid" || ! valid_id "$gid"; then die "PAPERLESS_UID/GID must be positive integers"; fi
  render_exports "$ip" "$uid" "$gid" > "$new"
  install -d -m 0755 /etc/exports.d
  install_file "$new" /etc/exports.d/paperless.exports 0644 >/dev/null
  exportfs -ra
  done_nfs || die "exportfs does not list the Paperless export"
  log 6-nfs ok
}

done_tailscale() { [ -s "$TS_STATE" ] && ts_running; }
step_tailscale() {
  STEP=7-tailscale
  local compose=$REPO/compose/infrastructure/tailscale/compose.yaml cfg cenv mounts routes
  routes=$(<"$RUNDIR/TS_ROUTES")
  render_ts_override "$RUNDIR" > "$RUNDIR/ts-override.yaml"
  # Fail closed unless Compose resolves TS_AUTHKEY to the file path.
  cfg=$(TS_ROUTES=$routes TS_AUTHKEY='' docker compose -p tailscale -f "$compose" \
        -f "$RUNDIR/ts-override.yaml" config 2>/dev/null || true)
  [[ $cfg =~ (^|$'\n')[[:space:]]+TS_AUTHKEY:\ file:/run/secrets/ts_authkey($'\n'|$) ]] \
    || die "Compose did not resolve TS_AUTHKEY to the file path; not starting"
  TS_ROUTES=$routes TS_AUTHKEY='' docker compose -p tailscale -f "$compose" \
    -f "$RUNDIR/ts-override.yaml" up -d >/dev/null
  wait_ts_running || die "tailscale did not reach Running within 120 s"
  # Check the first container's log now: the recreate below replaces it.
  ts_logs_clean || die "docker logs tailscale contain 'tskey-' before the recreate: rotate the key"
  # Recreate without the override: the node logs in from its state file.
  TS_ROUTES=$routes TS_AUTHKEY='' docker compose -p tailscale -f "$compose" \
    up -d --force-recreate >/dev/null
  wait_ts_running || die "tailscale did not come back from its state file"
  cenv=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' tailscale)
  if [[ $cenv =~ (^|$'\n')TS_AUTHKEY=[^$'\n']+ ]]; then
    die "TS_AUTHKEY is still set in the container after the recreate"
  fi
  mounts=$(docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' tailscale)
  if [[ $mounts == *"/run/homelab-bootstrap"* ]]; then die "container still mounts the tmpfs directory"; fi
  ts_logs_clean || die "docker logs tailscale contain 'tskey-' after the recreate: rotate the key"
  log 7-tailscale ok
}

done_dockhand() {
  local code marker
  [ "$(docker inspect -f '{{.State.Running}}' dockhand 2>/dev/null)" = true ] || return 1
  marker=$(read_marker "$FW_ENV")
  code=$(dockhand_probe "$RUNDIR/providers-probe.json")
  if [ "$code" = 403 ]; then return 0; fi
  [ "$code" = 200 ] && [ "$marker" = lock ] && grep -Eq '"type":[[:space:]]*"bitwarden"' "$RUNDIR/providers-probe.json"
}
step_dockhand() {
  STEP=8-dockhand
  local marker code has=no action _ cidr
  [ -f "$BWS" ] || die "$BWS missing (Docker would create a directory there)"
  marker=$(read_marker "$FW_ENV")
  if [ "$marker" = lock ]; then
    iptables -w -t raw -C HOMELAB-RAW -p tcp --dport 3000 -m addrtype --dst-type LOCAL -j DROP 2>/dev/null \
      || die "the :3000 lock is not active; not starting Dockhand"
  else
    cidr=$(sed -n 's/^ZORAXY_SOURCE_CIDR=//p' "$FW_ENV")
    iptables -w -t raw -C HOMELAB-RAW -p tcp --dport 3000 -m addrtype --dst-type LOCAL ! -s "$cidr" -j DROP 2>/dev/null \
      || die "the :3000 allowlist is not active; not starting Dockhand"
  fi
  docker compose -p dockhand -f "$REPO/compose/infrastructure/dockhand/compose.yaml" up -d >/dev/null
  code=000
  for _ in $(seq 1 60); do
    code=$(dockhand_probe "$RUNDIR/providers.json")
    if [ "$code" != 000 ]; then break; fi
    sleep 2
  done
  if [ "$code" = 200 ] && grep -Eq '"type":[[:space:]]*"bitwarden"' "$RUNDIR/providers.json"; then has=yes; fi
  action=$(dockhand_action "$code" "$marker" "$has")
  case $action in
    skip) log 8-dockhand "skipped (auth on or provider already present, HTTP $code)" ; return 0 ;;
    fail)
      if [ "$code" = 200 ]; then die "Dockhand answers without login after unlock: turn authentication back on"; fi
      die "unexpected HTTP $code from Dockhand" ;;
    create)
      render_provider_json "$RUNDIR/DOCKHAND_BWS_ACCESS_TOKEN" "$DOCKHAND_SERVER_URL" > "$RUNDIR/provider.json" \
        || die "could not build the provider request"
      curl --noproxy '*' -fsS -o /dev/null -H 'Content-Type: application/json' \
        --data-binary @"$RUNDIR/provider.json" "$DOCKHAND_URL/api/secret-providers" \
        || die "creating the Bitwarden provider failed"
      rm -f -- "$RUNDIR/provider.json"
      log 8-dockhand ok ;;
  esac
}

next_steps() {
  if [ "$ROLE" = infrastructure ]; then
    cat >&2 <<'MSG'

Next (infrastructure):
  1. ssh -L 3000:127.0.0.1:3000 <admin-user>@infrastructure, open http://127.0.0.1:3000,
     turn on authentication, and bind each stack to its Bitwarden project.
  2. sudo /srv/homelab/docker-gitops/host/bootstrap.sh --unlock-dockhand
MSG
  fi
}

# --- modes --------------------------------------------------------------------------

run_bootstrap() {
  preflight
  RUNDIR=$(mktemp -d /run/homelab-bootstrap.XXXXXX)
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  local steps s pending=()
  if [ "$ROLE" = infrastructure ]; then
    steps=(accounts networks firewall port53 tailscale dockhand)
  else
    steps=(accounts firewall nfs)
  fi
  for s in "${steps[@]}"; do
    if [ "$s" = port53 ]; then continue; fi
    "done_$s" || pending+=("$s")
  done
  if [ "${#pending[@]}" -gt 0 ]; then need_secrets; fi
  for s in "${steps[@]}"; do
    if [ "$s" = port53 ]; then step_port53; continue; fi
    if [[ " ${pending[*]} " == *" $s "* ]]; then
      "step_$s"
    else
      log "$s" "skipped (already done)"
    fi
  done
  STEP=9-cleanup
  cleanup
  log 9-cleanup ok
  if [ "${#pending[@]}" -gt 0 ]; then next_steps; else log bootstrap "nothing to do; no token needed"; fi
}

unlock_dockhand() {
  STEP=unlock-dockhand
  [ "$EUID" -eq 0 ] || die "run with sudo"
  ROLE=$(hostname -s)
  [ "$ROLE" = infrastructure ] || die "only on infrastructure"
  have_tty || die "no terminal"
  [ -f "$FW_ENV" ] && [ -x "$FW_SCRIPT" ] || die "firewall not installed; run bootstrap first"
  local code tmp ans cidr
  tmp=$(mktemp)
  code=$(dockhand_probe "$tmp"); rm -f -- "$tmp"
  [ "$code" = 403 ] || die "anonymous GET /api/secret-providers returned $code, not 403: turn on authentication first (staying locked)"
  cat >&2 <<'MSG'
Audit in Dockhand's UI before unlocking (W-031: anything created while auth was off persists):
  - exactly one user (yours);
  - no API tokens, no OIDC providers, no webhooks;
  - Hawser tokens: none yet. Core's agent token is created only AFTER this unlock (D16).
    If Dockhand's data was restored from Backrest, only core's existing agent token.
MSG
  read -r -p 'Type yes if all of the above is true: ' ans < /dev/tty
  [ "$ans" = yes ] || die "audit not confirmed (staying locked)"
  if [ "$(read_marker "$FW_ENV")" = lock ]; then
    tmp=$(mktemp)
    sed 's/^DOCKHAND_3000=lock$/DOCKHAND_3000=allowlist/' "$FW_ENV" > "$tmp"
    "$FW_SCRIPT" --check --env "$tmp" >/dev/null || { rm -f -- "$tmp"; die "new firewall.env does not validate"; }
    install -m 0600 -o root -g root "$tmp" "$FW_ENV"; rm -f -- "$tmp"
  fi
  "$FW_SCRIPT" --early >/dev/null
  "$FW_SCRIPT" --docker >/dev/null
  cidr=$(sed -n 's/^ZORAXY_SOURCE_CIDR=//p' "$FW_ENV")
  iptables -w -t raw -C HOMELAB-RAW -p tcp --dport 3000 -m addrtype --dst-type LOCAL ! -s "$cidr" -j DROP \
    || die "allowlist rule not active"
  log unlock-dockhand "ok: :3000 now allows only loopback and Zoraxy (permanent)"
}

main() {
  case ${1:-} in
    '')
      [ $# -eq 0 ] || die "unexpected arguments"
      [ "$EUID" -eq 0 ] || die "run with sudo"
      init_log; run_bootstrap ;;
    --unlock-dockhand)
      [ $# -eq 1 ] || die "unexpected arguments"
      [ "$EUID" -eq 0 ] || die "run with sudo"
      init_log; unlock_dockhand ;;
    --restore-prep)
      echo "--restore-prep is reserved for the restore-runbook PR" >&2; exit 2 ;;
    *) die "unknown argument: $1 (use no argument, --unlock-dockhand or --restore-prep)" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
