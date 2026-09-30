#!/bin/bash
# Stage 1 detector. Collects everything about this runner, then asks a real
# Cling process whether it warns. Writes an artifact tree under $OUT and sets
# hit=yes|no on $GITHUB_OUTPUT.
#
# Deliberately does not exit early or non-zero on a hit: stage 2 needs the same
# job to go on and build Gaudi. Pairing a CPUID dump with a real warning on one
# machine is the whole deliverable, so a hit whose job stopped here is wasted.
set -uo pipefail

OUT="${OUT:-avx10-artifacts}"
mkdir -p "$OUT"
here="$(cd "$(dirname "$0")" && pwd)"

echo "=== machine ==="
{ uname -a; echo; systemd-detect-virt 2>/dev/null || echo "detect-virt: n/a"; } | tee "$OUT/uname.txt"
lscpu > "$OUT/lscpu.txt" 2>&1 || true
cp /proc/cpuinfo "$OUT/cpuinfo.txt" 2>/dev/null || true
grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs | tee "$OUT/model.txt"
# archspec is what conda reports as __archspec. The 2026-09-29 failing job said
# sapphirerapids, but archspec has no Granite Rapids entry, so a GNR host is
# labelled sapphirerapids - this does not identify the microarchitecture.
pixi exec --spec archspec archspec cpu 2>/dev/null | tee "$OUT/archspec.txt" || true

echo
echo "=== CPUID (both -O0 and -O2: the uninitialised-ECX read depends on register allocation) ==="
for opt in O0 O2; do
    if gcc "-$opt" -o "$OUT/cpuid-$opt" "$here/cpuid.c" 2>"$OUT/cpuid-$opt.build.log"; then
        "$OUT/cpuid-$opt" | sed "s/^AVX10PROBE /AVX10PROBE opt=$opt /" | tee -a "$OUT/cpuid.txt"
    else
        echo "AVX10PROBE opt=$opt BUILD_FAILED" | tee -a "$OUT/cpuid.txt"
    fi
done

echo
echo "=== LLVM 20 getHostCPUFeatures (ground truth - the code Cling runs) ==="
pixi exec --spec "llvmdev==20.1.8" --spec gxx --spec zlib --spec zstd bash -c '
    set -e
    CXX=$(ls "$CONDA_PREFIX"/bin/*-g++ 2>/dev/null | head -1)
    "$CXX" -std=c++17 -o /tmp/hostfeatures '"$here"'/hostfeatures.cpp \
        $(llvm-config --cxxflags --ldflags --libs TargetParser Support) -lz -lzstd
    /tmp/hostfeatures
' > "$OUT/llvm-hostfeatures.txt" 2>&1 || echo "AVX10PROBE llvm_probe FAILED" >> "$OUT/llvm-hostfeatures.txt"
cat "$OUT/llvm-hostfeatures.txt"

echo
echo "=== the real detector: a Cling process ==="
# `root` alone bundles the same Cling/LLVM 20 as a Gaudi build, so this is
# enough and far cheaper than building Gaudi to find out.
pixi exec --spec root bash -c 'root-config --version; root -l -b -q -e "return 0;"' \
    > "$OUT/root-stdout.txt" 2> "$OUT/root-stderr.txt" || true
echo "--- root stderr ($(wc -c < "$OUT/root-stderr.txt") bytes) ---"
cat "$OUT/root-stderr.txt"

# Fail loudly if the probe never ran, rather than letting a missing tag read as
# a clean result.
if ! grep -q AVX10PROBE "$OUT/cpuid.txt" 2>/dev/null; then
    echo "AVX10PROBE MISSING - the cpuid probe did not run; treat this job as no data"
    echo "hit=error" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
fi

hit=no
grep -q "invalid feature combination" "$OUT/root-stderr.txt" && hit=yes
echo "AVX10RESULT hit=$hit model=$(cat "$OUT/model.txt") archspec=$(cat "$OUT/archspec.txt" 2>/dev/null)"
grep -h "warn_pre=" "$OUT/cpuid.txt" | tail -2
echo "hit=$hit" >> "${GITHUB_OUTPUT:-/dev/null}"
exit 0
