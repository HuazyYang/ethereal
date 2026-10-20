cmake_minimum_required(VERSION 3.24)
project(GvdbAcceptancePackage LANGUAGES CXX)

# A relocatable counterpart of the original workstation-local package drivers.
# Build against installed NVRHI; no Donut, shader compiler or CUDA SDK is needed.
include(CTest)
set(GVDB_NVRHI_BUILD_OWNER_TESTS OFF CACHE BOOL "Build owner device fixtures")
set(GVDB_NVRHI_BUILD_API_TESTS ON CACHE BOOL "Build SDK ABI fixtures")
set(GVDB_NVRHI_INSTALL ON CACHE BOOL "Install the public SDK")
find_package(nvrhi CONFIG REQUIRED)
get_filename_component(gvdb_source
    "${CMAKE_CURRENT_LIST_DIR}/../../ethereal-samples/src/gvdb_samples/gvdb" ABSOLUTE)
include("${gvdb_source}/GVDBNvrhiTopologyEditApi.cmake")
include("${gvdb_source}/GVDBNvrhiRayQueryApi.cmake")
foreach(compiler_target ShaderTool::ShaderTool ShaderTool::slang ShaderTool::dxcompiler)
    if(TARGET ${compiler_target})
        message(FATAL_ERROR "Runtime package imported compiler dependency ${compiler_target}")
    endif()
endforeach()
