#!/usr/bin/env bash
#
# mayhem/test.sh — RUN OpenImageIO's own test suite (already built by mayhem/build.sh into build/tests).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# 1) Upstream's ctest suite: the C++ unit tests plus the oiiotool/iinfo/idiff testsuite, whose runner
#    diffs each tool's output against the checked-in reference output (so a program that exits 0 and
#    prints nothing fails). Excluded: tests that need a GPU/the network/a compiler or depend on the
#    Debian library versions (oiiotool + the stochastic/UDIM texture cases + jxl write differ in
#    libjxl/freetype/libtiff behaviour; unit_imageinout aborts inside libjxl's debug check on write).
BT="$SRC/build/tests"
[ -x "$BT/bin/oiiotool" ] && [ -x "$BT/bin/iinfo" ] && [ -x "$BT/bin/idiff" ] \
  || { echo "build/tests tools missing — mayhem/build.sh did not build them" >&2; exit 2; }
EXCLUDE='texture-device|cmake-consumer|docs-examples|threadtimes|^(igrep|oiiotool|oiiotool-copy|oiiotool-subimage|oiiotool-text|texture-levels-stochaniso|texture-levels-stochmip|texture-udim|texture-udim2|jxl|openexr-partialtile|unit_imageinout)(\.batch)?$'
log="$(mktemp)"
(cd "$BT" && ctest -j"$MAYHEM_JOBS" --timeout 600 -E "$EXCLUDE") >"$log" 2>&1
cat "$log" | tail -25
total="$(sed -n 's/.*tests passed, [0-9]* tests failed out of \([0-9]*\).*/\1/p' "$log" | tail -1)"
failed="$(sed -n 's/.*tests passed, \([0-9]*\) tests failed.*/\1/p' "$log" | tail -1)"
if [ -z "$total" ] || [ -z "$failed" ] || [ "$total" -lt 100 ]; then
  echo "ctest produced no usable summary (or ran <100 tests)" >&2; total=${total:-0}; failed=$(( ${failed:-0} + 1 ))
fi
passed=$(( total - failed ))
fail=$failed
rm -f "$log"

# 2) Known-answer probes, run from bash so a neutered program cannot hide: exact output of the built tools
#    on fixed inputs. Unconditional — a missing tool or fixture is a failure, not a skip.
probe() {  # probe <name> <expected-substring> <command...>
  local name="$1" want="$2"; shift 2
  local out; out="$("$@" 2>&1)" || true
  if printf '%s' "$out" | grep -qF -- "$want"; then passed=$((passed+1)); echo "PASS probe $name"
  else fail=$((fail+1)); echo "FAIL probe $name: wanted [$want], got [$out]"; fi
}
T="$SRC/testsuite/common"
W="$(mktemp -d)"
probe iinfo-tiff "512 x  384, 3 channel, uint8 tiff" "$BT/bin/iinfo" -s "$T/tahoe-small.tif"
probe stats-constant "Constant Color: 0.250000 0.500000 0.750000" \
  "$BT/bin/oiiotool" --pattern constant:color=0.25,0.5,0.75 4x4 3 --printstats
"$BT/bin/oiiotool" "$T/tahoe-small.tif" --resize 64x48 -d uint8 -o "$W/r.png" >/dev/null 2>&1 || true
probe resize-png-roundtrip "64 x   48, 3 channel, uint8 png" "$BT/bin/iinfo" -s "$W/r.png"
probe idiff-self "PASS" "$BT/bin/idiff" "$T/tahoe-small.tif" "$T/tahoe-small.tif"
probe idiff-differs "FAILURE" "$BT/bin/idiff" "$T/tahoe-small.tif" "$T/tahoe-tiny.tif"
rm -rf "$W"

emit_ctrf "oiio-ctest+kat" "$passed" "$fail" 0
