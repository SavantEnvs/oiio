# Loaded through CMAKE_PROJECT_INCLUDE by mayhem/build.sh: drops UBSan's `alignment` check for the
# single TU that includes stb_sprintf.h (its deliberate unaligned store), without editing upstream.
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL set_source_files_properties
  "${CMAKE_SOURCE_DIR}/src/libutil/strutil.cpp" DIRECTORY "${CMAKE_SOURCE_DIR}/src/libutil"
  PROPERTIES COMPILE_OPTIONS -fno-sanitize=alignment)
