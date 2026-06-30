# CMakeLists.txt — build libmmforge_occt_shim.a
#
# Prerequisites:
#   - OpenCASCADE >= 7.5 installed
#   - CMake >= 3.16
#
# Usage:
#   mkdir build && cd build
#   cmake .. -DOpenCASCADE_DIR=/path/to/occt/cmake
#   cmake --build .
#   cmake --install . --prefix /usr/local   # optional
#
# The resulting libmmforge_occt_shim.a is used by the mmforge-geometry
# Rust crate's build.rs (via MMFORGE_SHIM_DIR or auto-detect).

cmake_minimum_required(VERSION 3.16)
project(mmforge_occt_shim LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --- Find OpenCASCADE ---
# Users may need to set -DOpenCASCADE_DIR or -DCMAKE_PREFIX_PATH.
find_package(OpenCASCADE REQUIRED)

# --- Static library target ---
add_library(mmforge_occt_shim STATIC
    mmforge_occt_shim.cpp
)

target_include_directories(mmforge_occt_shim PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}          # mmforge_occt_shim.h
    ${OpenCASCADE_INCLUDE_DIR}
)

# Link the OCCT modules required by the shim.
# OCCT 7.9 renamed STEP libs (TKSTEPBase/TKSTEP/TKSTEP209/TKSTEPAttr/
# TKXDESTEP → TKDESTEP) and we need TKLCAF/TKStd/TKStdL/TKXmlXCAF
# for TDocStd_Document ("XmlXCAF") and TDataStd_Name.
target_link_libraries(mmforge_occt_shim PRIVATE
    TKernel
    TKMath
    TKG3d
    TKBRep
    TKTopAlgo
    TKGeomAlgo
    TKGeomBase
    TKShHealing
    TKMesh
    TKBO
    TKBool
    TKXSBase
    TKDESTEP
    TKXCAF
    TKCAF
    TKCDF
    TKLCAF
    TKStd
    TKStdL
    TKXmlXCAF
    TKService
)

# Ensure position-independent code (required for static libs linked
# into shared libraries on some platforms).
set_target_properties(mmforge_occt_shim PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# --- Install ---
install(TARGETS mmforge_occt_shim
    ARCHIVE DESTINATION lib
)
install(FILES mmforge_occt_shim.h
    DESTINATION include
)
