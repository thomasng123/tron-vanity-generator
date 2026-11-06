#!/usr/bin/env bash
# GPU 模式完整自检 + 压测 + 短跑 smoke（需 OpenCL GPU + ICD）
#   ./scripts/test_gpu.sh
#   BENCH_SECS=2 PROFILE_SECS=2 ./scripts/test_gpu.sh
#   SKIP_BENCH=1 SKIP_PROFILE=1 ./scripts/test_gpu.sh   # 仅 gputest + smoke
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$root/build/tron_vanity_generator"
bench_secs="${BENCH_SECS:-1}"
profile_secs="${PROFILE_SECS:-1}"
smoke_max="${SMOKE_MAX:-500000}"

if [[ ! -x "$bin" ]]; then
  echo "Binary missing, running build.sh ..."
  "$root/build.sh"
fi

# 避免 C++ stdout 全缓冲导致长时间无输出（尤其 --profile 多轮编译）
run_bin() {
  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL "$bin" "$@"
  else
    "$bin" "$@"
  fi
}

section() { echo; echo "======== $* ========"; }

section "OpenCL / GPU 检测 (--list)"
if ! run_bin --list 2>&1 | tee /tmp/tron_vanity_gpu_list.txt; then
  echo "ERROR: --list failed"
  exit 1
fi
if grep -q "无 GPU\|OpenCL 可用，但未枚举到 GPU" /tmp/tron_vanity_gpu_list.txt 2>/dev/null; then
  echo "ERROR: 未检测到 OpenCL GPU，请安装 ocl-icd-opencl-dev 与厂商 ICD（如 nvidia-opencl-icd）"
  exit 1
fi

section "matchruletest (模板 prefix/suffix 规则)"
run_bin --matchruletest

section "gputest (GPU 内核 vs CPU，含 Montgomery N=2..32)"
run_bin --gputest

if [[ "${SKIP_BENCH:-0}" != "1" ]]; then
  section "bench (${bench_secs}s 每档，ECW / MONT / KPI / 尾号规则)"
  run_bin --bench "$bench_secs"
fi

if [[ "${SKIP_PROFILE:-0}" != "1" ]]; then
  section "profile (${profile_secs}s，内核阶段占比)"
  # profile 会编译 6 个消融内核，慢机器可 SKIP_PROFILE=1
  run_bin --profile "$profile_secs"
fi

section "smoke run (--backend gpu --max ${smoke_max}, --min 5)"
run_bin --backend gpu --max "$smoke_max" --min 5 --output /tmp/tron_vanity_gpu_smoke.txt

section "smoke matching file (--backend gpu --max ${smoke_max})"
run_bin --backend gpu --max "$smoke_max" --matching "$root/examples/matching_888888.txt" \
  --suffix-count 6 --output /tmp/tron_vanity_gpu_smoke_matching.txt

echo
echo "All GPU tests passed."
