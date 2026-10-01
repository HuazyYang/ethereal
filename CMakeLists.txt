cmake_minimum_required(VERSION 3.22)

# ethereal is an aggregate of sub-projects, in the manner of DiligentEngine:
#
#   donut/             the graphics framework (git submodule; brings nvrhi, ShaderTool, glfw, imgui, ...)
#   etherealsamples/   samples and benchmarks built on Donut (git submodule)
#
# This file configures the shared build environment and adds the sub-projects.

set(ETHEREAL_LANGUAGES C CXX)   # C: Donut's thirdparty modules (glfw, stb, ...) contain C sources.

# GVDBSamples needs CUDA; it is opt-in so that configuring does not require the CUDA Toolkit.
option(ETHEREAL_BUILD_GVDB "Build the GVDB samples (requires the CUDA Toolkit)" OFF)
if (ETHEREAL_BUILD_GVDB)
	list(APPEND ETHEREAL_LANGUAGES CUDA)
endif()

project(ethereal VERSION 1.0 LANGUAGES ${ETHEREAL_LANGUAGES})

option(ETHEREAL_BUILD_SAMPLES    "Build etherealsamples (src/)" ON)
option(ETHEREAL_BUILD_BENCHMARKS "Build etherealsamples benchmarks (benchmark/)" ON)

# NOTE(migration): lithereal's root CMakeLists had an unconditional
# `find_package(OptiX REQUIRED)`, but no migrated source file includes optix.h.
# It is kept behind an option (default OFF) so that configuring this project does
# not hard-require the OptiX SDK. Set -DETHEREAL_WITH_OPTIX=ON (plus
# -DOptiX_INSTALL_DIR=<path>) once OptiX is actually used.
option(ETHEREAL_WITH_OPTIX "Locate the OptiX SDK (cmake/FindOptiX.cmake)" OFF)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS ON)
set_property(GLOBAL PROPERTY USE_FOLDERS ON)

# ctest only sees tests registered below a directory that called enable_testing() at the root.
enable_testing()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

if (ETHEREAL_WITH_OPTIX)
	find_package(OptiX REQUIRED)
endif()

if (MSVC)
	set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# Every executable and runtime asset lands in <build>/bin, for every configuration:
# Donut looks for its shaders in <exe dir>/shaders/framework/<dxbc|dxil|spirv>.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_DEBUG "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}")
set(DONUT_SHADERS_OUTPUT_DIR "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/shaders/framework")

# Helpers shared by every sub-project: copy_assets() and ethereal_compile_shaders().
# EtherealShaders.cmake includes ShaderTool's function module here, in the root scope,
# which is what makes shadertool_add_shader_objects() usable from any sub-directory.
set(ETHEREAL_DONUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/donut")
include(CopyAssets)
include(EtherealShaders)

# Donut defaults for this aggregate (overridable with -D on the command line). KTX2 loading makes
# Donut fetch zstd from GitHub at configure time, and no sample uses it.
set(DONUT_WITH_KTX OFF CACHE BOOL "Build KTX2 (BCn + Zstandard) texture loading support")

if (NOT EXISTS "${ETHEREAL_DONUT_DIR}/CMakeLists.txt")
	message(FATAL_ERROR "donut is missing. Run: git submodule update --init --recursive")
endif()
add_subdirectory(donut)

if (ETHEREAL_BUILD_SAMPLES OR ETHEREAL_BUILD_BENCHMARKS)
	if (NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/etherealsamples/CMakeLists.txt")
		message(FATAL_ERROR "etherealsamples is missing. Run: git submodule update --init --recursive")
	endif()
	add_subdirectory(etherealsamples)
endif()
