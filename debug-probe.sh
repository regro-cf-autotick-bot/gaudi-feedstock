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

# Also proceed on any CPU that merely *has* leaf 0x24, not only on a hit.
# The probe runs `root -l -b -q -e 'return 0;'`, which JITs almost nothing,
# whereas the 201 warnings came from a full Gaudi suite exercising Cling hard.
# So a Granite Rapids runner could be clean here and still warn under real
# load - the only way to know is to run the build and the whole test suite on
# one of these machines.
leaf24=0
grep -aq 'leaf24=1' avx10-artifacts/cpuid.txt 2>/dev/null && leaf24=1

# Gate on the CPU class the specimen reported, not only on leaf 0x24 being
# present. The 09-29 log contains exactly one piece of CPU identification -
# __archspec=1=sapphirerapids - and nothing else, so we cannot tell which part
# it was. Two candidates carry that label here, the Xeon 8573C and the 6973P-C,
# and only the latter exposes leaf 0x24 in the instances we sampled.
#
# Gating on leaf24=1 alone would assume away the variability we measured: the
# same silicon gets different archspec labels on different runners (an 8573C
# appears as both sapphirerapids and icelake, an EPYC 9V74 as both zen2 and
# x86_64_v4), which means the hypervisor masks features per instance. An 8573C
# on some other host could therefore expose leaf 0x24 differently from the 21
# we happened to see.
interesting=no
[ "$cling_hit" = yes ] && interesting=yes
[ "$would_warn" = 1 ] && interesting=yes
[ "$leaf24" = 1 ] && interesting=yes
[ "$arch" = sapphirerapids ] && interesting=yes

if [ "$interesting" = yes ]; then
    echo "PROCEEDING on ${model} (arch=${arch} cling_hit=${cling_hit} would_warn=${would_warn} leaf24=${leaf24})"
    # Force the variant the original failure used. The three full builds that
    # have run on Granite Rapids so far were all 6.38/6.40, i.e. clang 20.1.8 -
    # the 6.36.14 (clang 18.1.8) pairing that actually failed has never once
    # coincided with one of these runners in ~300 samples, so overriding beats
    # waiting for the matrix to pair them.
    echo "config=linux_64_clhep2.4.4.0python3.13.____cp313root_base6.36.14root_cxx_standard20" >> "${GITHUB_OUTPUT:-/dev/null}"
    # Falsifiable test of the derivation theory, before the build. Predicts
    # 6.36 warns on every invocation and 6.40 on none, and that llvmdev 18
    # derives 256=1/512=0 where llvmdev 20 derives 0/0. Any intermittency on a
    # fixed build and CPU would falsify the register-allocation mechanism.
    N=10 OUT=avx10-artifacts bash avx10/falsify.sh || echo "falsify returned non-zero"
    echo "  -> building Gaudi with root_base 6.36.14 and running the full suite here"
    exit 0
fi
echo "Not an interesting machine (${model}, arch=${arch}, leaf24=${leaf24}) - failing so a rerun re-rolls it."
exit 1
