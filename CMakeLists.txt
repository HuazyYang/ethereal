#
# Copyright (c) 2014-2021, NVIDIA CORPORATION. All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
cmake_minimum_required(VERSION 3.10)

project(ethereal)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

set_property( GLOBAL PROPERTY USE_FOLDERS ON)

if (MSVC)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /W3 /MP")
endif()

string(APPEND CMAKE_CXX_FLAGS_DEBUG " -D_DEBUG")

include(CMakeDependentOption)

option(ETHEREAL_WITH_NVRHI "Enable NVRHI and related projects" ON)

cmake_dependent_option(ETHEREAL_WITH_DX11 "Enable the DX11 version of Ethereal" ON "WIN32" OFF)
cmake_dependent_option(ETHEREAL_WITH_DX12 "Enable the DX12 version of Ethereal" ON "WIN32" OFF)
option(ETHEREAL_WITH_VULKAN "Enable the Vulkan version of Ethereal" ON)

option(ETHEREAL_WITH_STATIC_SHADERS "Build Ethereal with statically linked shaders" OFF)

option(ETHEREAL_WITH_AUDIO "Include Audio features (XAudio2)" OFF)
option(ETHEREAL_WITH_LZ4 "Include LZ4" ON)
option(ETHEREAL_WITH_MINIZ "Include miniz (support for zip archives)" ON)
option(ETHEREAL_WITH_TASKFLOW "Include TaskFlow" ON)
option(ETHEREAL_WITH_TINYEXR "Include TinyEXR" ON)
option(ETHEREAL_WITH_UNIT_TESTS "Ethereal unit-tests (see CMake/CTest documentation)" OFF)

# DXC
if(NOT DEFINED ENV{DXC_PATH})
    message(FATAL_ERROR "DirectXCompiler release must be installed")
else()
    add_library(dxcompiler SHARED IMPORTED)
    set_target_properties(dxcompiler PROPERTIES
        IMPORTED_LOCATION "$ENV{DXC_PATH}/bin/x64/dxcompiler.dll"
        IMPORTED_IMPLIB "$ENV{DXC_PATH}/lib/x64/dxcompiler.lib"
        INTERFACE_INCLUDE_DIRECTORIES "$ENV{DXC_PATH}/inc"
    )

    # For shader maker
    find_program(DXC_PATH "$ENV{DXC_PATH}/bin/x64/dxc" REQUIRED)
    message("Setting 'DXC_PATH' to: '${DXC_PATH}'")
    set(DXC_SPIRV_PATH "${DXC_PATH}")
    set(SHADERMAKE_FIND_DXC OFF CACHE BOOL "" FORCE)
    set(SHADERMAKE_FIND_DXC_SPIRV OFF CACHE BOOL "" FORCE)
endif()

add_subdirectory(thirdparty)

if (ETHEREAL_WITH_NVRHI)
    set(NVRHI_WITH_DX11 "${ETHEREAL_WITH_DX11}" CACHE BOOL "" FORCE)
    set(NVRHI_WITH_DX12 "${ETHEREAL_WITH_DX12}" CACHE BOOL "" FORCE)
    set(NVRHI_WITH_VULKAN "${ETHEREAL_WITH_VULKAN}" CACHE BOOL "" FORCE)

    add_subdirectory(nvrhi)

    set(ETHEREAL_SHADER_INCLUDE_DIR ${CMAKE_CURRENT_LIST_DIR}/include CACHE PATH "" FORCE)
    
    add_subdirectory(shaders)
endif()

include(ethereal-core.cmake)
if (ETHEREAL_WITH_NVRHI)
    include(ethereal-engine.cmake)
    include(ethereal-render.cmake)
    include(ethereal-app.cmake)
endif()

if (ETHEREAL_WITH_UNIT_TESTS)
    include(CTest)
    add_subdirectory(tests)
endif()
