#!/usr/bin/env bash
#
# mayhem/build.sh — build OpenImageIO's libFuzzer harness (one binary, one symlink per image
# format) with ASan+UBSan, a run-once standalone reproducer, and an un-sanitized tree for test.sh.
# Runs inside the commit image as `mayhem` in /mayhem. Everything it needs is baked into the image
# (apt -dev packages + /opt/deps), so it is re-runnable offline.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Formats the harness is run against (the names `fuzz_image --list-formats` prints, minus the
# pseudo-formats). The harness picks its format from argv[0] (fuzz_<format>) or $OIIO_FUZZ_FORMAT.
FORMATS="bmp cineon dds dicom dpx ffmpeg fits gif hdr heif ico iff jpeg jpeg2000 jpegxl openexr openvdb png pnm psd ptex raw rla sgi softimage targa tiff webp zfile"

# The compiler comes from $CC/$CXX in the environment, NOT -DCMAKE_*_COMPILER: a changed -D compiler
# makes cmake wipe its cache on a re-run under a different PATH, and the re-run then fails to configure.
# Shared by both configures: every optional reader on, nothing that needs python/Qt/network.
COMMON_CMAKE=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_PREFIX_PATH=/opt/deps
  -DUSE_PYTHON=OFF -DUSE_QT=OFF -DUSE_OPENCV=OFF -DUSE_NUKE=OFF
  -DBUILD_DOCS=OFF -DINSTALL_DOCS=OFF -DSTOP_ON_WARNING=OFF
  -DOIIO_BUILD_FUZZ_TARGETS=OFF -DVERBOSE=OFF
)

# 1) Sanitized + coverage-instrumented library, so the readers (not just the harness) are fuzzed.
# stb_sprintf's intentional unaligned store is exempted from UBSan's alignment check (that file only).
UBSAN_IGNORE="-fsanitize-ignorelist=$SRC/mayhem/ubsan_ignorelist.txt"
FUZZ_FLAGS="$SANITIZER_FLAGS $UBSAN_IGNORE -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
cmake -S . -B build/fuzz "${COMMON_CMAKE[@]}" \
  -DOIIO_BUILD_TOOLS=OFF -DOIIO_BUILD_TESTS=OFF -DBUILD_TESTING=OFF \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS"
cmake --build build/fuzz -j"$MAYHEM_JOBS"

# 2) The harness, once against libFuzzer and once against the run-once standalone driver.
#    LSan is turned off at build time (mayhem/lsan_off.cc) — leaks are not what we fuzz for.
INC=(-I"$SRC/src/include" -I"$SRC/build/fuzz/include" -I"$SRC/src/libOpenImageIO"
     -I/usr/include/OpenEXR -I/usr/include/Imath)
LIBS=(-L"$SRC/build/fuzz/lib" -lOpenImageIO -lOpenImageIO_Util -Wl,-rpath,"$SRC/build/fuzz/lib")
HARNESS_FLAGS=($SANITIZER_FLAGS $UBSAN_IGNORE $DEBUG_FLAGS -O1 -std=c++17)

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

$CXX "${HARNESS_FLAGS[@]}" "${INC[@]}" -c "$SRC/src/fuzz/fuzz_image.cpp" -o /tmp/fuzz_image.o
$CXX "${HARNESS_FLAGS[@]}" /tmp/fuzz_image.o /tmp/lsan_off.o $LIB_FUZZING_ENGINE "${LIBS[@]}" \
     -o "$SRC/fuzz_image"
$CXX "${HARNESS_FLAGS[@]}" /tmp/fuzz_image.o /tmp/lsan_off.o /tmp/standalone_main.o "${LIBS[@]}" \
     -o "$SRC/fuzz_image-standalone"

# One real binary per format (Mayhem does not preserve a symlink's argv[0]): each links a tiny
# constructor (mayhem/fuzz_format.cc) that sets OIIO_FUZZ_FORMAT=<format> before the harness reads it.
# The standalone reproducer takes the format from the environment: OIIO_FUZZ_FORMAT=<fmt>.
for f in $FORMATS; do
  rm -f "$SRC/fuzz_$f"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -DOIIO_FUZZ_FORMAT_NAME="\"$f\"" -c "$SRC/mayhem/fuzz_format.cc" \
       -o "/tmp/fuzz_format_$f.o"
  $CXX "${HARNESS_FLAGS[@]}" /tmp/fuzz_image.o "/tmp/fuzz_format_$f.o" /tmp/lsan_off.o \
       $LIB_FUZZING_ENGINE "${LIBS[@]}" -o "$SRC/fuzz_$f"
done

# 3) Normal-flags tree with the tools and the unit tests, for mayhem/test.sh.
cmake -S . -B build/tests "${COMMON_CMAKE[@]}" \
  -DOIIO_BUILD_TOOLS=ON -DOIIO_BUILD_TESTS=ON -DBUILD_TESTING=ON \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build/tests -j"$MAYHEM_JOBS"
