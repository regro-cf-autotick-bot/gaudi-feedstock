#!/bin/bash
# Falsifiable test of the derivation theory, on one machine.
#
# Theory: LLVM 18/19 derive avx10.1-256 from leaf 7.1 bit 19 alone, and
# avx10.1-512 additionally from leaf 0x24 bit 18. Leaf 0x24 is read with the
# two-arg getX86CpuIDAndInfo, which leaves ECX as whatever was live, so a bad
# subleaf returns zeros. That yields 256-without-512 - an invalid combination -
# and clang warns. LLVM 20 gates both on leaf 0x24, so both collapse to false
# together and it is silent while quietly losing AVX10.
#
# Predictions, all on the same host:
#   root_base 6.36.14 (clang 18)  -> warns, every single invocation
#   root_base 6.40.04 (clang 20)  -> silent
#   llvmdev 18 getHostCPUFeatures -> avx10.1-256=1  avx10.1-512=0
#   llvmdev 20 getHostCPUFeatures -> avx10.1-256=0  avx10.1-512=0
#
# The sharp one is intermittency: register allocation is fixed when libCling.so
# was compiled, so on a given build and CPU the outcome cannot vary. Any
# intermittency falsifies the mechanism.
set -uo pipefail

N="${N:-10}"
here="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-avx10-artifacts}"
mkdir -p "$OUT"

echo "FALSIFY cpu=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)"
echo "FALSIFY bit19=$(gcc -O2 -o /tmp/cp "$here/cpuid.c" 2>/dev/null && /tmp/cp | grep -oE 'bit19=[01]' | head -1)"

# --- prediction 1 and 2: does each ROOT warn, and is it deterministic? ---
for rb in 6.36.14 6.40.04; do
    hits=0
    for i in $(seq 1 "$N"); do
        if pixi exec --spec "root_base==${rb}" --spec "root_cxx_standard==20" \
             root -l -b -q -e 'return 0;' 2>&1 >/dev/null \
             | grep -q "invalid feature combination"; then
            hits=$((hits + 1))
        fi
    done
    echo "FALSIFY root_base=${rb} warned=${hits}/${N}"
done

# --- prediction 3 and 4: what does each LLVM actually derive? ---
for lv in 18.1.8 20.1.8; do
    res=$(pixi exec --spec "llvmdev==${lv}" --spec gxx --spec zlib --spec zstd bash -c '
        set -e
        CXX=$(ls "$CONDA_PREFIX"/bin/*-g++ 2>/dev/null | head -1)
        "$CXX" -std=c++17 -o /tmp/hf'"${lv//./}"' '"$here"'/hostfeatures.cpp \
            $(llvm-config --cxxflags --ldflags --libs TargetParser Support) -lz -lzstd
        /tmp/hf'"${lv//./}"'
    ' 2>&1 | grep -E 'avx10\.1-(256|512)=' | sed 's/AVX10PROBE llvm_feature //' | sort | paste -sd' ' -)
    echo "FALSIFY llvmdev=${lv} ${res:-BUILD_FAILED}"
done | tee -a "$OUT/falsify.txt"
