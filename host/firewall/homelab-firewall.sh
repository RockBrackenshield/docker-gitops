#!/usr/bin/env bash
# homelab-firewall.sh: host firewall for the docker-gitops nodes.
#
# Reads and validates /etc/homelab/firewall.env (private values, written by
# host/bootstrap.sh; never committed), then applies the node's rules in its
# own chains:
#
#   --early    raw PREROUTING (HOMELAB-RAW) and, on core, filter INPUT
#              (HOMELAB-INPUT), IPv4 and IPv6. Run by
#              homelab-firewall-early.service before the network and Docker.
#   --docker   the DOCKER-USER second layer (HOMELAB-DOCKER), IPv4 and IPv6.
#              Run by homelab-firewall-docker.service after Docker.
#   --check    validate the env file only.
#   --remove   delete the jumps and chains (rollback).
#   --env FILE use another env file (for --check).
#
# Validation runs before any rule is touched, so a broken env file fails the
# early unit and, through RequiredBy=docker.service, keeps Docker down
# (fails closed). Each table is committed atomically with
# iptables-restore --noflush; the jump into a chain is added only when
# `-C` says it is missing, so re-runs never duplicate rules.
#
# Never `systemctl restart homelab-firewall-early`: Requires= would restart
# Docker too. To re-apply, run `homelab-firewall.sh --early` directly.

set -euo pipefail
umask 077

ENV_FILE=/etc/homelab/firewall.env

# Ports. Infrastructure: ntfy 2586 (bound to the LAN IP), Dockhand 3000,
# Zoraxy UI 8000, Backrest 9898, AdGuard admin 8102. Core: Paperless 8000,
# Samba 445, NFS 2049 (host nfsd).
INFRA_ZORAXY_ONLY_PORTS="9898 8102"

die() { echo "homelab-firewall: $*" >&2; exit 1; }

is_ipv4() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    [[ $o =~ ^(0|[1-9][0-9]*)$ ]] && (( o <= 255 )) || return 1
  done
}
is_cidr4() {
  local c=$1 addr len
  [[ $c =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
  addr=${BASH_REMATCH[1]} len=${BASH_REMATCH[2]}
  is_ipv4 "$addr" && (( 10#$len <= 32 ))
}
ipv4_to_int() {   # caller has checked is_ipv4
  local o v=0 IFS=.
  for o in $1; do v=$(( v * 256 + 10#$o )); done
  echo "$v"
}
# cidr4_within INNER OUTER: INNER is no wider than OUTER and inside it.
cidr4_within() {
  local il=${1##*/} ol=${2##*/} ia oa mask
  is_cidr4 "$1" && is_cidr4 "$2" || return 1
  il=$((10#$il)) ol=$((10#$ol))
  (( il >= ol )) || return 1
  ia=$(ipv4_to_int "${1%/*}") oa=$(ipv4_to_int "${2%/*}")
  mask=$(( ol == 0 ? 0 : (0xFFFFFFFF << (32 - ol)) & 0xFFFFFFFF ))
  (( (ia & mask) == (oa & mask) ))
}
is_ipv6() {
  local ip=$1
  [[ $ip =~ ^[0-9A-Fa-f:]+$ && $ip == *:*:* && ${#ip} -le 39 ]]
}

# load_env FILE: parse KEY=VALUE lines without executing anything, accept
# only known keys, validate them, and set them as shell variables.
load_env() {
  local file=$1 line key val n=0
  [ -r "$file" ] || die "cannot read $file"
  ROLE='' INFRA_LAN_IP='' ZORAXY_SOURCE_CIDR='' INFRA_EDGE_SUBNET='' DOCKHAND_3000=''
  PRINTER_IP='' LAPTOP_IP='' PRINTER_IPV6='' LAPTOP_IPV6=''
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]] || die "$file:$n: not KEY=VALUE"
    key=${BASH_REMATCH[1]} val=${BASH_REMATCH[2]}
    case $key in
      ROLE|INFRA_LAN_IP|ZORAXY_SOURCE_CIDR|INFRA_EDGE_SUBNET|DOCKHAND_3000|PRINTER_IP|LAPTOP_IP|PRINTER_IPV6|LAPTOP_IPV6)
        printf -v "$key" '%s' "$val" ;;
      *) die "$file:$n: unknown key $key" ;;
    esac
  done < "$file"

  case $ROLE in
    infrastructure)
      is_ipv4 "$INFRA_LAN_IP"        || die "INFRA_LAN_IP missing or not an IPv4 address"
      is_cidr4 "$ZORAXY_SOURCE_CIDR" || die "ZORAXY_SOURCE_CIDR missing or not an IPv4 CIDR"
      # One typo must not open :2586/:3000/:9898/:8102 (e.g. /0): /16 or longer.
      (( 10#${ZORAXY_SOURCE_CIDR##*/} >= 16 )) || die "ZORAXY_SOURCE_CIDR must be /16 or longer"
      [ -n "$INFRA_EDGE_SUBNET" ] \
        || die "INFRA_EDGE_SUBNET missing (firewall.env is older than this script): re-run host/bootstrap.sh"
      is_cidr4 "$INFRA_EDGE_SUBNET"  || die "INFRA_EDGE_SUBNET is not an IPv4 CIDR"
      cidr4_within "$ZORAXY_SOURCE_CIDR" "$INFRA_EDGE_SUBNET" \
        || die "ZORAXY_SOURCE_CIDR must sit inside INFRA_EDGE_SUBNET"
      [[ $DOCKHAND_3000 == lock || $DOCKHAND_3000 == allowlist ]] \
        || die "DOCKHAND_3000 must be lock or allowlist"
      [ -z "$PRINTER_IP$LAPTOP_IP$PRINTER_IPV6$LAPTOP_IPV6" ] || die "core-only keys set on infrastructure"
      ;;
    core)
      is_ipv4 "$INFRA_LAN_IP" || die "INFRA_LAN_IP missing or not an IPv4 address"
      is_ipv4 "$PRINTER_IP"   || die "PRINTER_IP missing or not an IPv4 address"
      is_ipv4 "$LAPTOP_IP"    || die "LAPTOP_IP missing or not an IPv4 address"
      [ -z "$PRINTER_IPV6" ] || is_ipv6 "$PRINTER_IPV6" || die "PRINTER_IPV6 is not an IPv6 address"
      [ -z "$LAPTOP_IPV6" ]  || is_ipv6 "$LAPTOP_IPV6"  || die "LAPTOP_IPV6 is not an IPv6 address"
      [ -z "$ZORAXY_SOURCE_CIDR$INFRA_EDGE_SUBNET$DOCKHAND_3000" ] || die "infrastructure-only keys set on core"
      ;;
    *) die "ROLE must be infrastructure or core" ;;
  esac
}

# --- rule rendering (pure; prints iptables-restore input) -------------------

# chain_header TABLE CHAIN
chain_header() { printf '*%s\n:%s - [0:0]\n-F %s\n' "$1" "$2" "$2"; }

render_raw4() {
  load_env "$1"
  chain_header raw HOMELAB-RAW
  echo '-A HOMELAB-RAW -i lo -j RETURN'
  if [ "$ROLE" = infrastructure ]; then
    echo "-A HOMELAB-RAW -p tcp -d $INFRA_LAN_IP --dport 2586 ! -s $ZORAXY_SOURCE_CIDR -j DROP"
    if [ "$DOCKHAND_3000" = lock ]; then
      echo '-A HOMELAB-RAW -p tcp --dport 3000 -m addrtype --dst-type LOCAL -j DROP'
    else
      echo "-A HOMELAB-RAW -p tcp --dport 3000 -m addrtype --dst-type LOCAL ! -s $ZORAXY_SOURCE_CIDR -j DROP"
    fi
    echo '-A HOMELAB-RAW -p tcp --dport 8000 -m addrtype --dst-type LOCAL -j DROP'
    local p
    for p in $INFRA_ZORAXY_ONLY_PORTS; do
      echo "-A HOMELAB-RAW -p tcp --dport $p -m addrtype --dst-type LOCAL ! -s $ZORAXY_SOURCE_CIDR -j DROP"
    done
  else
    echo "-A HOMELAB-RAW -p tcp --dport 8000 -m addrtype --dst-type LOCAL ! -s $INFRA_LAN_IP -j DROP"
    echo "-A HOMELAB-RAW -p tcp --dport 445 -m addrtype --dst-type LOCAL ! -s $PRINTER_IP -j DROP"
  fi
  echo COMMIT
}

render_raw6() {
  load_env "$1"
  chain_header raw HOMELAB-RAW
  echo '-A HOMELAB-RAW -i lo -j RETURN'
  local p
  if [ "$ROLE" = infrastructure ]; then
    # The Docker networks are IPv4-only: no IPv6 source is ever allowed.
    for p in 2586 3000 8000 $INFRA_ZORAXY_ONLY_PORTS; do
      echo "-A HOMELAB-RAW -p tcp --dport $p -m addrtype --dst-type LOCAL -j DROP"
    done
  else
    echo '-A HOMELAB-RAW -p tcp --dport 8000 -m addrtype --dst-type LOCAL -j DROP'
    if [ -n "$PRINTER_IPV6" ]; then
      echo "-A HOMELAB-RAW -p tcp --dport 445 -m addrtype --dst-type LOCAL ! -s $PRINTER_IPV6 -j DROP"
    else
      echo '-A HOMELAB-RAW -p tcp --dport 445 -m addrtype --dst-type LOCAL -j DROP'
    fi
  fi
  echo COMMIT
}

# INPUT rules exist on core only (NFS is served by the host, not Docker).
render_input4() {
  load_env "$1"
  [ "$ROLE" = core ] || return 0
  chain_header filter HOMELAB-INPUT
  echo '-A HOMELAB-INPUT -i lo -j RETURN'
  echo "-A HOMELAB-INPUT -p tcp --dport 2049 ! -s $LAPTOP_IP -j DROP"
  echo COMMIT
}
render_input6() {
  load_env "$1"
  [ "$ROLE" = core ] || return 0
  chain_header filter HOMELAB-INPUT
  echo '-A HOMELAB-INPUT -i lo -j RETURN'
  if [ -n "$LAPTOP_IPV6" ]; then
    echo "-A HOMELAB-INPUT -p tcp --dport 2049 ! -s $LAPTOP_IPV6 -j DROP"
  else
    echo '-A HOMELAB-INPUT -p tcp --dport 2049 -j DROP'
  fi
  echo COMMIT
}

# DOCKER-USER second layer. `--ctstate DNAT` limits it to traffic Docker
# DNATed to a published port, so traffic the Tailscale subnet router forwards
# to other LAN hosts is never matched.
dk() { echo "-A HOMELAB-DOCKER -p tcp -m conntrack --ctstate DNAT --ctdir ORIGINAL --ctorigdstport $1${2:+ ! -s $2} -j DROP"; }
render_docker4() {
  load_env "$1"
  chain_header filter HOMELAB-DOCKER
  local p
  if [ "$ROLE" = infrastructure ]; then
    for p in 2586 3000 $INFRA_ZORAXY_ONLY_PORTS; do dk "$p" "$ZORAXY_SOURCE_CIDR"; done
    dk 8000
  else
    dk 8000 "$INFRA_LAN_IP"
    dk 445 "$PRINTER_IP"
  fi
  echo COMMIT
}
render_docker6() {
  load_env "$1"
  chain_header filter HOMELAB-DOCKER
  local p
  if [ "$ROLE" = infrastructure ]; then
    for p in 2586 3000 8000 $INFRA_ZORAXY_ONLY_PORTS; do dk "$p"; done
  else
    dk 8000
    dk 445 "$PRINTER_IPV6"
  fi
  echo COMMIT
}

render_all() {
  render_raw4 "$1"; render_raw6 "$1"; render_input4 "$1"; render_input6 "$1"
  render_docker4 "$1"; render_docker6 "$1"
}

# --- applying -----------------------------------------------------------------

# ensure_jump CMD TABLE FROM CHAIN: insert `-j CHAIN` at position 1 of FROM
# unless it is already there.
ensure_jump() {
  local cmd=$1 table=$2 from=$3 chain=$4
  "$cmd" -w -t "$table" -C "$from" -j "$chain" 2>/dev/null \
    || "$cmd" -w -t "$table" -I "$from" 1 -j "$chain"
}

apply_early() {
  local env=$1 rules
  load_env "$env"                       # validate before touching anything
  rules=$(render_raw4 "$env")  && iptables-restore  -w --noflush <<<"$rules"
  rules=$(render_raw6 "$env")  && ip6tables-restore -w --noflush <<<"$rules"
  ensure_jump iptables  raw PREROUTING HOMELAB-RAW
  ensure_jump ip6tables raw PREROUTING HOMELAB-RAW
  if [ "$ROLE" = core ]; then
    rules=$(render_input4 "$env") && iptables-restore  -w --noflush <<<"$rules"
    rules=$(render_input6 "$env") && ip6tables-restore -w --noflush <<<"$rules"
    ensure_jump iptables  filter INPUT HOMELAB-INPUT
    ensure_jump ip6tables filter INPUT HOMELAB-INPUT
  fi
  echo "homelab-firewall: early rules applied (role $ROLE${DOCKHAND_3000:+, dockhand $DOCKHAND_3000})"
}

apply_docker() {
  local env=$1 rules
  load_env "$env"
  iptables -w -n -L DOCKER-USER >/dev/null 2>&1 || die "DOCKER-USER chain missing; is Docker running?"
  rules=$(render_docker4 "$env") && iptables-restore -w --noflush <<<"$rules"
  ensure_jump iptables filter DOCKER-USER HOMELAB-DOCKER
  if ip6tables -w -n -L DOCKER-USER >/dev/null 2>&1; then
    rules=$(render_docker6 "$env") && ip6tables-restore -w --noflush <<<"$rules"
    ensure_jump ip6tables filter DOCKER-USER HOMELAB-DOCKER
  else
    echo "homelab-firewall: no IPv6 DOCKER-USER chain; the IPv6 raw rules still apply" >&2
  fi
  echo "homelab-firewall: DOCKER-USER layer applied (role $ROLE)"
}

# remove_chain CMD TABLE FROM CHAIN
remove_chain() {
  local cmd=$1 table=$2 from=$3 chain=$4
  while "$cmd" -w -t "$table" -D "$from" -j "$chain" 2>/dev/null; do :; done
  "$cmd" -w -t "$table" -F "$chain" 2>/dev/null || true
  "$cmd" -w -t "$table" -X "$chain" 2>/dev/null || true
}

remove_all() {
  local cmd
  for cmd in iptables ip6tables; do
    remove_chain "$cmd" raw PREROUTING HOMELAB-RAW
    remove_chain "$cmd" filter INPUT HOMELAB-INPUT
    remove_chain "$cmd" filter DOCKER-USER HOMELAB-DOCKER
  done
  echo "homelab-firewall: all homelab chains removed"
}

main() {
  local mode='' env=$ENV_FILE
  while [ $# -gt 0 ]; do
    case $1 in
      --early|--docker|--check|--remove) [ -z "$mode" ] || die "one mode at a time"; mode=$1 ;;
      --env) [ $# -ge 2 ] || die "--env needs a file"; env=$2; shift ;;
      *) die "unknown argument: $1 (use --early, --docker, --check, --remove)" ;;
    esac
    shift
  done
  case $mode in
    --check)  load_env "$env"; echo "homelab-firewall: $env OK (role $ROLE)" ;;
    --early)  [ "$EUID" -eq 0 ] || die "must run as root"; apply_early "$env" ;;
    --docker) [ "$EUID" -eq 0 ] || die "must run as root"; apply_docker "$env" ;;
    --remove) [ "$EUID" -eq 0 ] || die "must run as root"; remove_all ;;
    *) die "no mode given (use --early, --docker, --check, --remove)" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
