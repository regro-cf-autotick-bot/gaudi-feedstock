#!/bin/bash
# TEMPORARY DEBUG - remove before merging. See root-project/root#23542.
#
# The warning needs two things in the same job: root_base 6.36.x, which bundles
# clang 18.1.8, and a particular CPU. 6.38/6.40 bundle clang 20.1.8 and have
# never warned. archspec cannot tell the CPUs apart - it labels both Emerald
# Rapids (8573C, clean) and Granite Rapids (6973P-C, warns) as sapphirerapids.
#
# So this pins ROOT to the variant the job actually builds, which an earlier
# version of this script did not: it took whatever `pixi exec --spec root_base`
# resolved to, i.e. 6.40.04 in every job, and therefore could not reproduce the
# warning on any hardware.
#
# Exits non-zero unless it reproduces, so a job on uninteresting hardware fails
# in a minute or two instead of building for twenty. `gh run rerun --failed`
# then re-rolls those jobs onto different runners.
#
# Nothing is injected: no EXTRA_CLING_ARGS, no -march, no -m flags.
set -uo pipefail

summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
CONFIG="${CONFIG:?CONFIG must be set}"
variant=".ci_support/${CONFIG}.yaml"

model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)
arch=$(pixi exec --spec archspec archspec cpu 2>/dev/null || echo unknown)
avx10=$(grep -oE 'avx10[^ ]*' /proc/cpuinfo | sort -u | paste -sd, -)

echo "### CPU"
echo "model:    ${model}"
echo "archspec: ${arch}"
echo "avx10:    ${avx10:-none}   (absent is expected: the LLVM bug mis-reads CPUID)"

# Take the pins from the variant file rather than parsing CONFIG. The variant
# writes the patch unpadded (6.40.4) where the package is zero padded (6.40.04),
# so normalise before handing it to the solver.
# NB the dash goes last in the tr set, otherwise it reads as a character range
rb_raw=$(grep -A1 '^root_base:' "$variant" | tail -1 | tr -d " '\"-")
cxx=$(grep -A1 '^root_cxx_standard:' "$variant" | tail -1 | tr -d " '\"-")
rb=$(python3 -c 'import sys;a=sys.argv[1].split(".");print("%s.%s.%02d"%(a[0],a[1],int(a[2])))' "$rb_raw" 2>/dev/null || echo "$rb_raw")

echo
echo "### variant"
echo "root_base:         ${rb_raw} -> ${rb}"
echo "root_cxx_standard: ${cxx}"

probe_body='
  err=$(mktemp)
  echo "root:             $(command -v root || echo none)"
  echo "ROOT version:     $(root-config --version 2>/dev/null || echo ?)"
  echo "clang:            $(root -l -b -q -e "std::cout << __clang_version__ << std::endl;" 2>/dev/null | tail -1)"
  echo "EXTRA_CLING_ARGS: ${EXTRA_CLING_ARGS-<unset>}"
  root -l -b -q -e "return 0;" 2>"$err" >/dev/null
  rc=$?
  echo "exit code:        $rc"
  echo "stderr bytes:     $(wc -c <"$err")"
  echo "--- begin stderr ---"; cat "$err"; echo "--- end stderr ---"
  if grep -q "invalid feature combination" "$err"; then echo "RESULT hit"
  elif [ $rc -ne 0 ]; then echo "RESULT error"
  elif [ -s "$err" ]; then echo "RESULT other-stderr"
  else echo "RESULT clean"; fi
'

echo
echo "### conda-forge (pinned to this job's variant)"
res=$(pixi exec --spec "root_base==${rb}" --spec "root_cxx_standard==${cxx}" \
        bash -c "$probe_body" 2>&1 | tee /dev/stderr | sed -n 's/^RESULT //p' | tail -1)

echo "| \`${CONFIG}\` | \`${arch}\` | ${model} | ${rb} | **${res:-did-not-run}** |" >> "$summary"
echo "SUMMARY config=${CONFIG} arch=${arch} cpu=${model} root_base=${rb} result=${res:-did-not-run}"

if [[ "$res" == "hit" ]]; then
    echo "REPRODUCED on ${model} with root_base ${rb}"
    exit 0
fi
echo "Not reproduced on ${model} with root_base ${rb} - failing so a rerun re-rolls the runner."
exit 1
