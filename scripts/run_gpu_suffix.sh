#!/usr/bin/env bash
# GPU 后台：按模板规则文件匹配（默认 examples/matching_888888.txt，后缀 6 位 888888）
#   ./scripts/run_gpu_suffix.sh start
#   MATCHING=examples/matching.txt SUFFIX_COUNT=6 ./scripts/run_gpu_suffix.sh start
#   ./scripts/run_gpu_suffix.sh stop|status
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$root/build/tron_vanity_generator"
matching="${MATCHING:-$root/examples/matching_888888.txt}"
prefix_count="${PREFIX_COUNT:-0}"
suffix_count="${SUFFIX_COUNT:-6}"
run_dir="$root/run"
log_dir="$run_dir/logs"
out_dir="$run_dir/results"
pidfile="$run_dir/gpu_suffix.pid"
stamp="$(date +%Y%m%d_%H%M%S)"
log="${LOG:-$log_dir/gpu_matching_${stamp}.log}"
output="${OUTPUT:-$out_dir/tron_matching_${stamp}.txt}"

cmd="${1:-start}"

ensure_bin() {
  if [[ ! -x "$bin" ]]; then
    echo "Building ..."
    "$root/build.sh"
  fi
}

stop_job() {
  if [[ ! -f "$pidfile" ]]; then
    echo "No pidfile ($pidfile)"
    return 0
  fi
  local pid
  pid="$(cat "$pidfile")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    echo "Sent SIGTERM to pid $pid"
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
      echo "Force killed pid $pid"
    fi
  else
    echo "Pid $pid not running"
  fi
  rm -f "$pidfile"
}

status_job() {
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "Running pid $(cat "$pidfile")"
    echo "Latest log: $(ls -t "$log_dir"/gpu_matching_*.log 2>/dev/null | head -1 || echo none)"
    return 0
  fi
  echo "Not running"
  return 1
}

start_job() {
  ensure_bin
  mkdir -p "$log_dir" "$out_dir"
  if [[ ! -f "$matching" ]]; then
    echo "Matching file not found: $matching"
    exit 1
  fi
  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "Already running pid $(cat "$pidfile"). Use: $0 stop"
    exit 1
  fi

  nohup "$bin" \
    --backend gpu \
    --matching "$matching" \
    --prefix-count "$prefix_count" \
    --suffix-count "$suffix_count" \
    --once \
    --output "$output" \
    >> "$log" 2>&1 &
  echo $! > "$pidfile"

  echo "GPU template hunt started"
  echo "  Matching: $matching"
  echo "  Prefix:   $prefix_count  Suffix: $suffix_count"
  echo "  PID:      $(cat "$pidfile")"
  echo "  Log:      $log"
  echo "  Output:   $output"
  echo "  Follow:   tail -f $log"
}

case "$cmd" in
  start) start_job ;;
  stop) stop_job ;;
  status) status_job ;;
  *)
    echo "Usage: $0 {start|stop|status}"
    exit 1
    ;;
esac
