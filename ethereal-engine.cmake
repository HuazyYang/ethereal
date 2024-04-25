#
# Copyright (c) 2014-2020, NVIDIA CORPORATION. All rights reserved.
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


file(GLOB ethereal_engine_src
    include/ethereal/engine/*.h
    src/engine/*.cpp
    src/engine/*.c
    src/engine/*.h
)

if (MSVC)
    list (APPEND ethereal_engine_src ethereal.natvis)
endif()

add_library(ethereal_engine STATIC EXCLUDE_FROM_ALL ${ethereal_engine_src})
target_include_directories(ethereal_engine PUBLIC include)

target_link_libraries(ethereal_engine ethereal_core nvrhi nlohmann_json stb tinyexr cgltf ShaderMakeBlob)

add_dependencies(ethereal_engine ethereal_shaders)

if (ETHEREAL_WITH_TASKFLOW)
    target_link_libraries(ethereal_engine taskflow)
    target_compile_definitions(ethereal_engine PUBLIC ETHEREAL_WITH_TASKFLOW)
endif()

if(WIN32)
    target_compile_definitions(ethereal_engine PUBLIC NOMINMAX)
endif()

if (ETHEREAL_WITH_AUDIO)
    target_link_libraries(ethereal_engine Xaudio2)
    target_compile_definitions(ethereal_engine PUBLIC ETHEREAL_WITH_AUDIO)
endif()

if (ETHEREAL_WITH_TINYEXR)
    target_link_libraries(ethereal_engine tinyexr)
    target_compile_definitions(ethereal_engine PUBLIC ETHEREAL_WITH_TINYEXR)
endif()

set_target_properties(ethereal_engine PROPERTIES FOLDER Ethereal)

target_compile_definitions(ethereal_engine PUBLIC ETHEREAL_WITH_DX11=$<BOOL:${ETHEREAL_WITH_DX11}>)
target_compile_definitions(ethereal_engine PUBLIC ETHEREAL_WITH_DX12=$<BOOL:${ETHEREAL_WITH_DX12}>)
target_compile_definitions(ethereal_engine PUBLIC ETHEREAL_WITH_VULKAN=$<BOOL:${ETHEREAL_WITH_VULKAN}>)
target_compile_definitions(ethereal_engine PUBLIC ETHEREAL_WITH_STATIC_SHADERS=$<BOOL:${ETHEREAL_WITH_STATIC_SHADERS}>)

if (ETHEREAL_WITH_STATIC_SHADERS)
target_include_directories(ethereal_engine PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/shaders")
endif()