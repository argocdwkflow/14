#!/usr/bin/env bash
# Vérifie l'accès SSH à une liste de serveurs
# Usage: ./check_ssh_status.sh -f hosts.txt -t 8 -c 10
# -f : fichier contenant la liste des serveurs (un par ligne)
# -t : timeout SSH en secondes (défaut: 10)
# -c : nombre de connexions parallèles (défaut: 8)

set -u

HOSTFILE=""
CONNECT_TIMEOUT=10
MAX_JOBS=8
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

print_usage() {
  echo "Usage: $0 -f hosts.txt [-t timeout] [-c concurrency]"
}

while getopts "f:t:c:h" opt; do
  case "$opt" in
    f) HOSTFILE="$OPTARG" ;;
    t) CONNECT_TIMEOUT="$OPTARG" ;;
    c) MAX_JOBS="$OPTARG" ;;
    h) print_usage; exit 0 ;;
    *) print_usage; exit 1 ;;
  esac
done

[[ -z "$HOSTFILE" || ! -r "$HOSTFILE" ]] && { echo "ERREUR: fichier hosts invalide."; exit 1; }

# Compteurs
declare -A CNT=([OK]=0 [TIMEOUT]=0 [AUTH_FAILED]=0 [NETWORK]=0 [REFUSED]=0 [HOSTKEY]=0 [DNS]=0 [RESET]=0 [UNKNOWN]=0)

printf "\n%-25s %-8s %-12s %s\n" "HOST" "PORT" "STATUS" "MESSAGE"
printf "%0.s-" {1..80}; echo

check_one_host() {
  local host_line="$1"
  local host port status message
  host="$host_line"; port="22"

  # gérer host:port
  [[ "$host" == *:* ]] && { port="${host##*:}"; host="${host%%:*}"; }

  local outf errf rc
  outf="$TMPDIR/out_$RANDOM.txt"
  errf="$TMPDIR/err_$RANDOM.txt"

  ssh -o BatchMode=yes \
      -o ConnectTimeout="$CONNECT_TIMEOUT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -p "$port" "$host" 'echo SSH_OK' >"$outf" 2>"$errf"
  rc=$?

  if [[ $rc -eq 0 ]]; then
    status="OK"; message="$(tr -d '\n' < "$outf")"
  else
    err="$(tr '\n' ' ' < "$errf")"
    if   echo "$err" | grep -qi "Permission denied"; then status="AUTH_FAILED"; message="Permission denied"
    elif echo "$err" | grep -qi "No route to host"; then status="NETWORK"; message="No route to host"
    elif echo "$err" | grep -qi "Connection timed out"; then status="TIMEOUT"; message="Connection timed out"
    elif echo "$err" | grep -qi "Connection refused"; then status="REFUSED"; message="Connection refused"
    elif echo "$err" | grep -qi "Host key verification failed"; then status="HOSTKEY"; message="Host key verification failed"
    elif echo "$err" | grep -qi "Name or service not known"; then status="DNS"; message="DNS failed"
    elif echo "$err" | grep -qi "Connection reset by peer"; then status="RESET"; message="Connection reset"
    else status="UNKNOWN"; message="${err:0:120}"; fi
  fi

  (( CNT["$status"]+=1 ))
  printf "%-25s %-8s %-12s %s\n" "$host" "$port" "$status" "$message"
}

# parallélisation
jobs_in_flight=0; pids=()

while IFS= read -r line || [[ -n "$line" ]]; do
  line="$(echo "$line" | sed 's/^[ \t]*//;s/[ \t]*$//')"
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  check_one_host "$line" &
  pids+=($!); ((jobs_in_flight++))
  if (( jobs_in_flight >= MAX_JOBS )); then
    wait -n 2>/dev/null || true
    new=(); jobs_in_flight=0
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then new+=("$pid"); ((jobs_in_flight++)); fi
    done
    pids=("${new[@]}")
  fi
done < "$HOSTFILE"
wait

printf "%0.s-" {1..80}; echo
echo "Résumé :"
for k in OK TIMEOUT AUTH_FAILED NETWORK REFUSED HOSTKEY DNS RESET UNKNOWN; do
  printf "  %-12s : %d\n" "$k" "${CNT[$k]}"
done

exit 0