cmake_minimum_required(VERSION 3.22)

# ethereal is an aggregate of sub-projects, in the manner of DiligentEngine:
#
#   ethereal-donut/             the graphics framework (git submodule; brings nvrhi, ShaderTool, glfw, imgui, ...)
#   ethereal-samples/  samples and benchmarks built on Donut (git submodule)
#
# This file configures the shared build environment and adds the sub-projects.

set(ETHEREAL_LANGUAGES C CXX)   # C: Donut's thirdparty modules (glfw, stb, ...) contain C sources.

# GVDBSamples needs CUDA; it is opt-in so that configuring does not require the CUDA Toolkit.
option(ETHEREAL_BUILD_GVDB "Build the GVDB samples (requires the CUDA Toolkit)" OFF)
if (ETHEREAL_BUILD_GVDB)
	list(APPEND ETHEREAL_LANGUAGES CUDA)
endif()

project(ethereal VERSION 1.0 LANGUAGES ${ETHEREAL_LANGUAGES})

option(ETHEREAL_BUILD_SAMPLES    "Build ethereal-samples (src/)" OFF)
option(ETHEREAL_BUILD_BENCHMARKS "Build ethereal-samples benchmarks (benchmark/)" OFF)

# nv_asteroids (ethereal-samples/demos/nv_asteroids) reconstructs the 2018 NVIDIA
# Asteroids demo. It is opt-in because it only configures with the original
# installed: it reads the original's media.db and links the DLLs it shipped.
# Point NV_ASTEROIDS_ORIGINAL_DIR at that installation.
option(ETHEREAL_BUILD_NV_ASTEROIDS "Build the nv_asteroids demo (needs NV_ASTEROIDS_ORIGINAL_DIR)" OFF)

# OptiX (header-only SDK) backs the ray tracing path of the GVDB samples. ON by default
# because it is optional at configure time: when the SDK is not found the OptiX backend and
# the OptiX samples are skipped. cmake/FindOptiX.cmake looks at OptiX_INSTALL_DIR (cache or
# environment) and the default install location.
option(ETHEREAL_WITH_OPTIX "Build the OptiX ray tracing backend of the GVDB samples when the SDK is found" ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS ON)
set_property(GLOBAL PROPERTY USE_FOLDERS ON)

# ctest only sees tests registered below a directory that called enable_testing() at the root.
enable_testing()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
# The package manager lives in nvrhi, the deepest project that needs it; everything includes that copy.
include("${CMAKE_CURRENT_SOURCE_DIR}/ethereal-nvrhi/cmake/EPM.cmake")

set(ETHEREAL_OPTIX_FOUND OFF)
if (ETHEREAL_WITH_OPTIX AND ETHEREAL_BUILD_GVDB)
	find_package(OptiX)
	if (OptiX_INCLUDE)
		set(ETHEREAL_OPTIX_FOUND ON)
		message(STATUS "OptiX headers: ${OptiX_INCLUDE}")
	else()
		message(STATUS "OptiX SDK not found; the OptiX backend of the GVDB samples is disabled "
			"(set OptiX_INSTALL_DIR to enable it)")
	endif()
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
set(ETHEREAL_DONUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/ethereal-donut")
include(CopyAssets)
include(EtherealShaders)

# Donut defaults for this aggregate (overridable with -D on the command line). KTX2 loading makes
# Donut fetch zstd from GitHub at configure time, and no sample uses it.
set(DONUT_WITH_KTX OFF CACHE BOOL "Build KTX2 (BCn + Zstandard) texture loading support")

# nv_asteroids needs NVAPI: the 2018 demo built its Turing mesh-shader PSOs
# through NvAPI_D3D12_CreateGraphicsPipelineState, and the demo reproduces that
# path (it is the default when the 2018 NVAPI check passes; -meshShaders d3d12
# selects SM 6.5 amplification/mesh shaders instead). nvrhi finds the SDK, or fetches
# NVIDIA's public repository; it is configured below, before ethereal-samples is reached.
if (ETHEREAL_BUILD_NV_ASTEROIDS)
	set(NVRHI_WITH_NVAPI ON CACHE BOOL "" FORCE)
endif()

epm_add_package(
	NAME ethereal_donut
	PACKAGE EtherealDonut
	VERSION 1.0
	SOURCE_DIR "${ETHEREAL_DONUT_DIR}")

if (ETHEREAL_BUILD_SAMPLES OR ETHEREAL_BUILD_BENCHMARKS)
	epm_add_package(
		NAME ethereal_samples
		PACKAGE EtherealSamples
		VERSION 1.0
		SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/ethereal-samples")
endif()
