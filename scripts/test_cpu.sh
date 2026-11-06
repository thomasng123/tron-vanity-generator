#!/usr/bin/env bash
# CPU 模式完整自检 + 压测（无 GPU 依赖）
#   ./scripts/test_cpu.sh
#   BENCH_SECS=8 ./scripts/test_cpu.sh
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$root/build/tron_vanity_generator"
bench_secs="${BENCH_SECS:-5}"
smoke_max="${SMOKE_MAX:-200000}"

if [[ ! -x "$bin" ]]; then
  echo "Binary missing, running build.sh ..."
  "$root/build.sh"
fi

section() { echo; echo "======== $* ========"; }

section "selftest (已知私钥 → TRON 地址)"
"$bin" --selftest

section "hashtest (SHA-256 / Keccak-256 向量)"
"$bin" --hashtest

section "matchtest (尾号规则)"
"$bin" --matchtest

section "hardware (--list)"
"$bin" --list

section "cpubench (${bench_secs}s, 默认线程数)"
"$bin" --cpubench "$bench_secs"

hw_threads="$(nproc 2>/dev/null || echo 4)"
if [[ "$hw_threads" -gt 4 ]]; then
  section "cpubench (${bench_secs}s, --threads 4)"
  "$bin" --cpubench "$bench_secs" --threads 4
fi

section "smoke run (--backend cpu --max ${smoke_max})"
"$bin" --backend cpu --max "$smoke_max" --min 5 --output /tmp/tron_vanity_smoke.txt

echo
echo "All CPU tests passed."
