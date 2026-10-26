// Pins the image format of one fuzz_<format> binary. The harness (src/fuzz/fuzz_image.cpp) reads it
// from $OIIO_FUZZ_FORMAT before argv[0], and Mayhem does not keep the fuzz_<format> symlink name, so
// each target is a real binary that sets the variable before LLVMFuzzerInitialize runs.
// Built once per format with -DOIIO_FUZZ_FORMAT_NAME="\"<format>\""; an explicit env value still wins.
#include <cstdlib>

__attribute__((constructor)) static void oiio_fuzz_pin_format() {
  setenv("OIIO_FUZZ_FORMAT", OIIO_FUZZ_FORMAT_NAME, 0);
}
