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

# The decisive measurement. A Granite Rapids runner swept clang 18.1.8, 20.1.8
# and 20.1.8 clean, so the CPU model is not the discriminator: real GNR reports
# leaf 0x24 EBX bit 18 set, which makes both avx10 features come out true even
# pre-fix. The warning needs version >= 1 with bit 18 clear, which real silicon
# does not do - so this dumps the raw registers to test whether the affected
# runners are virtualised behind an incomplete leaf 0x24. Unlike a reproduction
# attempt this is informative on every runner, warning or not.
echo
echo "### CPUID (what LLVM getHostCPUFeatures reads)"
would_warn=0
if gcc -O0 -o /tmp/cpuid-probe cpuid-probe.c 2>/dev/null; then
    /tmp/cpuid-probe | tee /tmp/cpuid.txt
    would_warn=$(sed -n 's/.*would_warn=\([01]\).*/\1/p' /tmp/cpuid.txt | tail -1)
    would_warn=${would_warn:-0}
else
    echo "  (failed to compile cpuid-probe.c)"
fi
echo "CPUIDVERDICT cpu=${model} arch=${arch} $(grep -h '^VERDICT' /tmp/cpuid.txt 2>/dev/null | sed 's/^VERDICT //')"

# NB the dash goes last in the tr set, otherwise it reads as a character range
cxx=$(grep -A1 '^root_cxx_standard:' ".ci_support/${CONFIG}.yaml" | tail -1 | tr -d " '\"-")

# every root_base this feedstock builds against, normalised to the package's
# zero padded patch (the variant files write 6.40.4 where the package is 6.40.04)
mapfile -t versions < <(
  for f in .ci_support/linux_64*.yaml; do
    grep -A1 '^root_base:' "$f" | tail -1 | tr -d " '\"-"
  done | sort -u | while read -r v; do
    python3 -c 'import sys;a=sys.argv[1].split(".");print("%s.%s.%02d"%(a[0],a[1],int(a[2])))' "$v"
  done
)

probe_body='
  err=$(mktemp)
  echo "  ROOT:  $(root-config --version 2>/dev/null || echo ?)"
  echo "  clang: $(root -l -b -q -e "std::cout << __clang_version__ << std::endl;" 2>/dev/null | tail -1 | cut -d" " -f1)"
  root -l -b -q -e "return 0;" 2>"$err" >/dev/null
  rc=$?
  echo "  stderr bytes: $(wc -c <"$err")"
  [ -s "$err" ] && { echo "  --- stderr ---"; sed "s/^/  /" "$err"; }
  if grep -q "invalid feature combination" "$err"; then echo "RESULT hit"
  elif [ $rc -ne 0 ]; then echo "RESULT error"
  elif [ -s "$err" ]; then echo "RESULT other-stderr"
  else echo "RESULT clean"; fi
'

reproduced=no
row="| \`${arch}\` | ${model} |"
for v in "${versions[@]}"; do
    echo
    echo "### root_base ${v} (cxx${cxx})"
    # capture to a file rather than `tee /dev/stderr`: command substitution
    # reads stdout through a pipe while stderr writes to the log with its own
    # offset, and the two clobber each other with NUL padding
    out=$(mktemp)
    pixi exec --spec "root_base==${v}" --spec "root_cxx_standard==${cxx}" \
        bash -c "$probe_body" >"$out" 2>&1
    cat "$out"
    res=$(sed -n 's/^RESULT //p' "$out" | tail -1)
    res=${res:-did-not-run}
    echo "  => ${v}: ${res}"
    row+=" **${res}** |"
    [ "$res" = "hit" ] && reproduced=yes
    echo "SWEEP cpu=${model} arch=${arch} root_base=${v} cxx=${cxx} result=${res}"
done

echo "$row" >> "$summary"

if [ "$reproduced" = yes ] || [ "$would_warn" = 1 ]; then
    echo "FOUND IT on ${model} (root_base hit=${reproduced}, cpuid would_warn=${would_warn})"
    exit 0
fi
echo "Nothing interesting on ${model} - failing so a rerun re-rolls the runner."
exit 1
