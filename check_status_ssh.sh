#!/usr/bin/env bash
# check_ssh_status.sh
# Usage: ./check_ssh_status.sh -f hosts.txt -u myuser -o output.csv -t 8 -c 10
# -f : fichier contenant les hosts (une entrée par ligne, format [user@]host[:port] ou host)
# -u : user par défaut (optionnel si vos lignes contiennent user@host)
# -o : fichier de sortie CSV (défaut: ssh_status.csv)
# -t : timeout connexion SSH en secondes (défaut: 10)
# -c : nb max de connexions parallèles (défaut: 8)

set -u
SCRIPT_NAME="$(basename "$0")"

# valeurs par défaut
HOSTFILE=""
DEFAULT_USER=""
OUTFILE="ssh_status.csv"
CONNECT_TIMEOUT=10
MAX_JOBS=8
TMPDIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

print_usage() {
  cat <<EOF
$SCRIPT_NAME - Vérifie accès SSH et exporte un CSV
Usage: $SCRIPT_NAME -f hosts.txt [-u default_user] [-o output.csv] [-t timeout] [-c concurrency]
EOF
}

# parse args
while getopts "f:u:o:t:c:h" opt; do
  case "$opt" in
    f) HOSTFILE="$OPTARG" ;;
    u) DEFAULT_USER="$OPTARG" ;;
    o) OUTFILE="$OPTARG" ;;
    t) CONNECT_TIMEOUT="$OPTARG" ;;
    c) MAX_JOBS="$OPTARG" ;;
    h) print_usage; exit 0 ;;
    *) print_usage; exit 1 ;;
  esac
done

if [[ -z "$HOSTFILE" ]]; then
  echo "ERREUR: fichier hosts requis (-f)." >&2
  print_usage
  exit 1
fi

if [[ ! -r "$HOSTFILE" ]]; then
  echo "ERREUR: impossible de lire '$HOSTFILE'." >&2
  exit 1
fi

# Entête CSV
echo "timestamp,host,user,port,status,message" > "$OUTFILE"

# function pour tester un host
# arg1: host_line (could be user@host:port or host or host:port)
check_one_host() {
  local raw="$1"
  local timestamp
  timestamp="$(date --iso-8601=seconds)"
  # parse user/host/port
  local user host port
  user="$DEFAULT_USER"
  host="$raw"
  port="22"

  # if raw contains '@'
  if [[ "$raw" == *@* ]]; then
    user="${raw%@*}"
    host="${raw#*@}"
  fi
  # if host contains ':port'
  if [[ "$host" == *:* ]]; then
    port="${host##*:}"
    host="${host%%:*}"
  fi
  # if still no user, set to empty (ssh will use current user)
  if [[ -z "$user" ]]; then user=""; fi

  # build ssh target
  local target
  if [[ -n "$user" ]]; then
    target="${user}@${host}"
  else
    target="${host}"
  fi

  # temp files
  local outf errf
  outf="$TMPDIR/out_$(echo "$raw" | md5sum | cut -d' ' -f1).txt"
  errf="$TMPDIR/err_$(echo "$raw" | md5sum | cut -d' ' -f1).txt"

  # Command:
  # -o BatchMode=yes  => fail instead of prompting for password
  # -o ConnectTimeout => TCP connect timeout
  # -o StrictHostKeyChecking=no + -o UserKnownHostsFile=/dev/null => avoid interactive hostkey prompt (accept temporarily)
  # NOTE: accepting host keys automatically is convenient for checks; if you don't want that, remove those options.
  ssh -o BatchMode=yes \
      -o ConnectTimeout="$CONNECT_TIMEOUT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -p "$port" \
      "$target" 'echo SSH_OK' >"$outf" 2>"$errf"
  local rc=$?

  local status message
  if [[ $rc -eq 0 ]]; then
    # success
    status="OK"
    message="$(tr -d '\n' < "$outf" | sed -e 's/,/ /g')"
    if [[ -z "$message" ]]; then message="SSH_OK"; fi
  else
    # read stderr
    local err
    err="$(tr '\n' ' ' < "$errf" | sed -e 's/^[ \t]*//;s/[ \t]*$//')"
    # classify common cases
    if echo "$err" | grep -qi "Permission denied"; then
      status="AUTH_FAILED"
      message="Permission denied (authentication required)"
    elif echo "$err" | grep -qi "Authentication failure"; then
      status="AUTH_FAILED"
      message="Authentication failure"
    elif echo "$err" | grep -qi "No route to host"; then
      status="NETWORK"
      message="No route to host"
    elif echo "$err" | grep -qi "Connection timed out"; then
      status="TIMEOUT"
      message="Connection timed out"
    elif echo "$err" | grep -qi "Connection refused"; then
      status="REFUSED"
      message="Connection refused"
    elif echo "$err" | grep -qi "Host key verification failed"; then
      status="HOSTKEY"
      message="Host key verification failed"
    elif echo "$err" | grep -qi "Name or service not known"; then
      status="DNS"
      message="DNS resolution failed"
    elif echo "$err" | grep -qi "Connection reset by peer"; then
      status="RESET"
      message="Connection reset by peer"
    else
      status="UNKNOWN"
      # include short stderr (max 200 chars)
      message="$(echo "$err" | cut -c1-200)"
      if [[ -z "$message" ]]; then message="rc=$rc"; fi
    fi
  fi

  # print CSV line (escape commas in message)
  local esc_msg
  esc_msg="$(echo "$message" | sed 's/"/""/g')"
  printf '%s,"%s","%s","%s","%s"\n' "$timestamp" "$host" "$user" "$port" "$esc_msg" >> "$OUTFILE"
}

# job control for parallelism
jobs_in_flight=0
pids=()

# loop hosts
while IFS= read -r line || [[ -n "$line" ]]; do
  # skip empty / comment lines
  line="$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')"
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^# ]] && continue

  # launch job in background
  check_one_host "$line" &
  pids+=($!)
  ((jobs_in_flight++))

  # wait if reached max
  if (( jobs_in_flight >= MAX_JOBS )); then
    wait -n 2>/dev/null || wait "${pids[0]}" 2>/dev/null
    # recompute jobs_in_flight by checking running pids
    new_pids=()
    jobs_in_flight=0
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        new_pids+=("$pid")
        ((jobs_in_flight++))
      fi
    done
    pids=("${new_pids[@]}")
  fi
done < "$HOSTFILE"

# wait remaining
wait

echo "Terminé. Résultats écrits dans: $OUTFILE"