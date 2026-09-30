#!/bin/bash
# TEMPORARY DEBUG - remove before merging.
#
# Identifies the runner CPU and checks whether Cling emits the AVX10 feature
# warning, once against conda-forge's root_base and once against an LCG view
# over CVMFS, on the same machine. conda-forge's CI reproduces the warning where
# a personal repository's runners never did (86 samples, no CPU even advertising
# avx10), so the point of running here is to find out which CPU it actually is.
#
# See root-project/root#23542.
#
# Nothing is injected: no EXTRA_CLING_ARGS, no -march, no -m flags. Any warning
# reported below comes from Cling's own host CPU detection.
set -uo pipefail

LCG_VIEW="${LCG_VIEW:-/cvmfs/sft.cern.ch/lcg/views/LCG_110a/x86_64-el9-gcc15-opt/setup.sh}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)
avx10=$(grep -oE 'avx10[^ ]*' /proc/cpuinfo | sort -u | paste -sd, -)
avx512=$(grep -m1 -oE 'avx512f' /proc/cpuinfo || true)
arch=$(pixi exec --spec archspec archspec cpu 2>/dev/null || echo unknown)

echo "### CPU"
echo "model:    ${model}"
echo "archspec: ${arch}"
echo "avx10:    ${avx10:-none}"
echo "avx512f:  ${avx512:-none}"
echo
echo "### full flags"
grep -m1 '^flags' /proc/cpuinfo | cut -d: -f2- | tr ' ' '\n' | grep -E '^avx' | paste -sd, -

# Prints a RESULT marker for every outcome, so a probe whose environment is
# broken is visible as such rather than counting as evidence the CPU is clean.
run_probe() {
    local label="$1" err
    err=$(mktemp)
    echo "### ${label}"
    echo "root:             $(command -v root || echo '<not found>')"
    echo "ROOT version:     $(root-config --version 2>/dev/null || echo '?')"
    echo "EXTRA_CLING_ARGS: ${EXTRA_CLING_ARGS-<unset>}"
    root -l -b -q -e 'return 0;' 2>"$err" >/dev/null
    local rc=$?
    echo "exit code:        ${rc}"
    echo "stderr bytes:     $(wc -c <"$err")"
    echo "--- begin stderr ---"
    cat "$err"
    echo "--- end stderr ---"
    if grep -q "invalid feature combination" "$err"; then
        echo "RESULT ${label} hit"
    elif [[ $rc -ne 0 ]]; then
        echo "RESULT ${label} error"
    elif [[ -s "$err" ]]; then
        echo "RESULT ${label} other-stderr"
    else
        echo "RESULT ${label} clean"
    fi
}

if [[ "${1:-}" == "--in-container" ]]; then
    run_probe lcg
    exit 0
fi

# --- conda-forge -----------------------------------------------------------
conda_res=$(pixi exec --spec root_base bash -c "
    $(declare -f run_probe)
    run_probe conda-forge
" 2>&1 | tee /dev/stderr | sed -n 's/^RESULT conda-forge //p' | tail -1)

# --- LCG view over CVMFS ---------------------------------------------------
# The view is built for EL9 so it cannot run on the Ubuntu runner directly.
# /cvmfs is an autofs mount and the automounter does not follow into a
# container's namespace, so the already-mounted repository is bind mounted
# rather than /cvmfs itself. LCG views also need HEP_OSlibs, whose -devel
# dependencies live in CRB, which AlmaLinux ships disabled.
lcg_res=did-not-run
if [[ -e "$LCG_VIEW" ]]; then
    lcg_res=$(docker run --rm \
        -v /cvmfs/sft.cern.ch:/cvmfs/sft.cern.ch:ro \
        -v "$PWD:/work:ro" \
        -e LCG_VIEW="$LCG_VIEW" \
        almalinux:9 bash -c '
            set -e
            dnf install -y -q epel-release
            dnf install -y -q https://linuxsoft.cern.ch/wlcg/el9/x86_64/wlcg-repo-1.0.0-1.el9.noarch.rpm
            dnf install -y -q --enablerepo=crb HEP_OSlibs
            source "$LCG_VIEW"
            bash /work/debug-probe.sh --in-container
        ' 2>&1 | tee /dev/stderr | sed -n 's/^RESULT lcg //p' | tail -1)
else
    echo "LCG view not visible on host: $LCG_VIEW"
fi

{
    echo "| \`${CONFIG:-?}\` | \`${arch}\` | ${model} | ${avx10:-none} | ${avx512:-none} | **${conda_res:-did-not-run}** | **${lcg_res:-did-not-run}** |"
} >> "$summary"

echo "SUMMARY conda-forge=${conda_res:-did-not-run} lcg=${lcg_res:-did-not-run} arch=${arch} cpu=${model}"
