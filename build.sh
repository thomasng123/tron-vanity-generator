#!/usr/bin/env bash
# Ubuntu / Debian / 其它 Linux：CMake + Ninja/Make 构建
#   ./build.sh
# 依赖（示例 Ubuntu 24.04）:
#   sudo apt install build-essential cmake git
#   sudo apt install ocl-icd-opencl-dev    # OpenCL 加载器（GPU 可选）
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"

if [[ ! -f third_party/secp256k1/CMakeLists.txt ]]; then
  echo "Fetching libsecp256k1 ..."
  if [[ -d .git ]]; then
    git submodule update --init --recursive
  else
    git clone --depth 1 https://github.com/bitcoin-core/secp256k1.git third_party/secp256k1
  fi
fi

gen=()
if command -v ninja >/dev/null 2>&1; then
  gen=(-G Ninja)
fi

cmake -B build "${gen[@]}" -DCMAKE_BUILD_TYPE=Release
cmake --build build -j"$(nproc)"

echo ""
echo "Done: $root/build/tron_vanity_generator"
"$root/build/tron_vanity_generator" --selftest
"$root/build/tron_vanity_generator" --list
