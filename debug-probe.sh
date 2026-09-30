#!/bin/bash
# TEMPORARY DEBUG - remove before merging. See root-project/root#23542.
#
# One confirmed failure exists: root_base 6.36.14 on a runner archspec labelled
# sapphirerapids, 201 warnings. A sibling job with the same pin and the same
# label was clean, so the label does not discriminate - archspec calls both
# Emerald Rapids (8573C) and Granite Rapids (6973P-C) sapphirerapids. 6.36
# bundles clang 18.1.8 where 6.38/6.40 bundle 20.1.8, which is the mechanistic
# difference the conjunction hypothesis rests on. It is not yet reproduced.
#
# Earlier versions of this probe tested one root_base per job, inherited from
# CONFIG. Across ~300 samples the pairing that matters - 6.36 on a 6973P-C -
# never occurred once, which suggests GitHub hands out a batch of similar
# runners per rerun, so a round of 30 jobs is closer to one CPU sample than
# thirty. So sweep every root_base in one job instead: whatever CPU the job
# draws, all three ROOT versions are tested on it.
#
# Exits non-zero unless some version reproduces, so an uninteresting machine
# fails in a couple of minutes and `gh run rerun --failed` re-rolls it.
#
# Nothing is injected: no EXTRA_CLING_ARGS, no -march, no -m flags.
set -uo pipefail

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
CONFIG="${CONFIG:?CONFIG must be set}"

model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)
arch=$(pixi exec --spec archspec archspec cpu 2>/dev/null || echo unknown)

echo "### CPU"
echo "model:    ${model}"
echo "archspec: ${arch}"

# Run the full avx10 collector: CPUID at -O0 and -O2, LLVM 20's own
# getHostCPUFeatures() as ground truth rather than a reimplementation, and a
# real Cling process. Reuses the jobs this PR already runs so it costs
# conda-forge no extra CI beyond what was running anyway.
#
# Why here as well as on the fork: the original 201-warning job was on
# conda-forge's runners, and conda-forge may draw from a different pool than a
# personal repository does.
echo
echo "### avx10 collector"
OUT=avx10-artifacts bash avx10/collect.sh || echo "collector returned non-zero"
would_warn=0
if grep -aq 'warn_pre=1' avx10-artifacts/cpuid.txt 2>/dev/null; then would_warn=1; fi
cling_hit=no
if grep -aq "invalid feature combination" avx10-artifacts/root-stderr.txt 2>/dev/null; then cling_hit=yes; fi
echo "AVX10SUMMARY cpu=${model} arch=${arch} would_warn=${would_warn} cling_hit=${cling_hit}"

if [ "$cling_hit" = yes ] || [ "$would_warn" = 1 ]; then
    # exit 0 so the job goes on to build Gaudi and run its full suite on this
    # same machine - a hit whose job stopped here would be wasted
    echo "FOUND IT on ${model} (cling_hit=${cling_hit}, cpuid would_warn=${would_warn})"
    exit 0
fi
echo "Nothing interesting on ${model} - failing so a rerun re-rolls the runner."
exit 1
