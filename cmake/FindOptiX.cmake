#
# SPDX-FileCopyrightText: Copyright (c) 2010 - 2024 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: BSD-3-Clause
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its
# contributors may be used to endorse or promote products derived from
# this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Locate the OptiX distribution.  Search relative to the SDK first, then look in the system.

# Our initial guess will be within the SDK.
# Default: the environment variable set by the SDK installer, else the newest default install.
set(_optix_default "$ENV{OptiX_INSTALL_DIR}")
if(NOT _optix_default AND WIN32)
  file(GLOB _optix_candidates "$ENV{ProgramFiles}/NVIDIA GPU Computing Toolkit/OptiX SDK*")
  if(_optix_candidates)
    list(SORT _optix_candidates)
    list(GET _optix_candidates -1 _optix_default)
  endif()
endif()
if(NOT _optix_default)
  set(_optix_default "${CMAKE_SOURCE_DIR}/../")
endif()
set(OptiX_INSTALL_DIR "${_optix_default}" CACHE PATH "Path to OptiX installed location.")

# The distribution contains only 64 bit libraries.  Error when we have been mis-configured.
if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
  if(WIN32)
    message(SEND_ERROR "Make sure when selecting the generator, you select one with Win64 or x64.")
  endif()
  message(FATAL_ERROR "OptiX only supports builds configured for 64 bits.")
endif()

# search path based on the bit-ness of the build.  (i.e. 64: bin64, lib64; 32:
# bin, lib).  Note that on Mac, the OptiX library is a universal binary, so we
# only need to look in lib and not lib64 for 64 bit builds.
if(NOT APPLE)
  set(bit_dest "64")
else()
  set(bit_dest "")
endif()

# Include
find_path(OptiX_INCLUDE
  NAMES optix.h
  PATHS "${OptiX_INSTALL_DIR}/include"
  NO_DEFAULT_PATH
  )
find_path(OptiX_INCLUDE
  NAMES optix.h
  )

# Check to make sure we found what we were looking for
function(OptiX_report_error error_message required component )
  if(DEFINED OptiX_FIND_REQUIRED_${component} AND NOT OptiX_FIND_REQUIRED_${component})
    set(required FALSE)
  endif()
  if(OptiX_FIND_REQUIRED AND required)
    message(FATAL_ERROR "${error_message}  Please locate before proceeding.")
  else()
    if(NOT OptiX_FIND_QUIETLY)
      message(STATUS "${error_message}")
    endif(NOT OptiX_FIND_QUIETLY)
  endif()
endfunction()

if(NOT OptiX_INCLUDE)
  OptiX_report_error("OptiX headers (optix.h and friends) not found." TRUE headers )
endif()

