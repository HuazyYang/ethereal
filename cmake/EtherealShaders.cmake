# EtherealShaders.cmake
#
# ethereal_compile_shaders() -- the replacement for Donut's removed
# donut_compile_shaders() / donut_compile_shaders_all_platforms() (ShaderMake).
# It forwards to ShaderTool's shadertool_add_shader_objects() with the same
# defaults Donut uses for its own shaders (shader model 6_5, TARGET_* defines,
# one output sub-directory per backend).
#
#   ethereal_compile_shaders(
#       TARGET            <target>                   # custom target to create
#       CONFIG            <shaders.cfg>              # ShaderMake-style config
#       [OUTPUT_DIRECTORY <dir>]                     # default: <bin>/shaders/<target without _shaders>
#       [INCLUDE_DIRECTORIES <dir>...]               # Donut's include dir is always added
#       [SOURCES <file>...]                          # listed in the IDE only
#       [FOLDER <ide folder>]
#       [BACKENDS <DXBC|DXIL|SPIRV>...]              # explicit backend list (overrides the default)
#       [ALL_PLATFORMS]                              # default backends plus DXBC (D3D11, SM 5_0)
#       [SHADER_MODEL <major_minor>]                 # default 6_5
#       [DEFINES <name>...]                          # extra global defines
#       [EMBED_PDB]                                  # embed shader PDBs (required for Aftermath)
#       [EXTRA_FLAGS <flag>...]                      # extra ShaderTool flags, all backends
#       [EXTRA_FLAGS_SPIRV <flag>...])               # extra ShaderTool flags, SPIR-V only
#
# Backends: DXIL (D3D12) and SPIRV (Vulkan) by default, DXBC added by
# ALL_PLATFORMS; each is dropped if Donut was configured without that API
# (DONUT_WITH_DX11 / DONUT_WITH_DX12 / DONUT_WITH_VULKAN).
#
# Must be called after add_subdirectory(donut) so that ShaderTool::ShaderTool and
# DONUT_SHADER_INCLUDE_DIR exist.

# shadertool_add_shader_objects() reads _SHADERTOOL_ALL_BACKENDS, a plain variable
# set by the module in the directory scope that first includes it. The module has
# include_guard(GLOBAL), so including it from the root scope *before* Donut's
# subdirectories do makes the variable visible to every directory below the root.
include("${ETHEREAL_DONUT_DIR}/thirdparty/shader-tool/cmake/ShaderToolFunctions.cmake")

function(ethereal_compile_shaders)
    cmake_parse_arguments(arg
        "ALL_PLATFORMS;EMBED_PDB"
        "TARGET;CONFIG;OUTPUT_DIRECTORY;FOLDER;SHADER_MODEL"
        "BACKENDS;INCLUDE_DIRECTORIES;SOURCES;DEFINES;EXTRA_FLAGS;EXTRA_FLAGS_SPIRV"
        ${ARGN})

    if(NOT arg_TARGET OR NOT arg_CONFIG)
        message(FATAL_ERROR "ethereal_compile_shaders requires TARGET and CONFIG")
    endif()
    if(arg_UNPARSED_ARGUMENTS)
        message(FATAL_ERROR "ethereal_compile_shaders: unknown arguments ${arg_UNPARSED_ARGUMENTS}")
    endif()

    if(NOT arg_OUTPUT_DIRECTORY)
        string(REGEX REPLACE "_shaders$" "" project_name "${arg_TARGET}")
        set(arg_OUTPUT_DIRECTORY "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/shaders/${project_name}")
    endif()
    if(NOT arg_SHADER_MODEL)
        set(arg_SHADER_MODEL 6_5)
    endif()

    if(NOT arg_BACKENDS)
        set(arg_BACKENDS DXIL SPIRV)
        if(arg_ALL_PLATFORMS)
            list(PREPEND arg_BACKENDS DXBC)
        endif()
    endif()
    set(backends)
    foreach(backend IN LISTS arg_BACKENDS)
        if((backend STREQUAL "DXBC" AND DONUT_WITH_DX11) OR
           (backend STREQUAL "DXIL" AND DONUT_WITH_DX12) OR
           (backend STREQUAL "SPIRV" AND DONUT_WITH_VULKAN))
            list(APPEND backends ${backend})
        endif()
    endforeach()
    set(pdb_option)
    if(arg_EMBED_PDB)
        set(pdb_option EMBED_PDB)
    endif()
    if(NOT backends)
        # Keep the target so add_dependencies() on it still works.
        add_custom_target(${arg_TARGET} SOURCES ${arg_SOURCES})
        return()
    endif()

    shadertool_add_shader_objects(
        TARGET ${arg_TARGET}
        CONFIG_FILE ${arg_CONFIG}
        BACKENDS ${backends}
        OUTPUT_MODE BINARY_BLOB
        OUTPUT_DIRECTORY ${arg_OUTPUT_DIRECTORY}
        SHADER_MODEL ${arg_SHADER_MODEL}
        INCLUDE_DIRECTORIES ${DONUT_SHADER_INCLUDE_DIR} ${arg_INCLUDE_DIRECTORIES}
        DEFINES ${arg_DEFINES}
        DEFINES_DXBC TARGET_D3D11
        DEFINES_DXIL TARGET_D3D12
        DEFINES_SPIRV SPIRV TARGET_VULKAN
        EXTRA_FLAGS ${arg_EXTRA_FLAGS}
        EXTRA_FLAGS_SPIRV ${arg_EXTRA_FLAGS_SPIRV}
        SOURCES ${arg_SOURCES}
        ${pdb_option})

    if(arg_FOLDER)
        set_target_properties(${arg_TARGET} PROPERTIES FOLDER "${arg_FOLDER}")
    endif()

    ethereal_disable_vs_hlsl_rule(${arg_TARGET})
endfunction()

# The Visual Studio generators hand every .hlsl listed as a target source to
# their built-in FXC rule ("error X4502: invalid vs_2_0 output semantic"). Mark
# them as not-to-be-built. Harmless with Ninja.
function(ethereal_disable_vs_hlsl_rule target)
    get_target_property(sources ${target} SOURCES)
    if(NOT sources)
        return()
    endif()
    foreach(source IN LISTS sources)
        if(source MATCHES "\\.(hlsl|hlsli)$")
            set_source_files_properties("${source}" TARGET_DIRECTORY ${target}
                PROPERTIES VS_TOOL_OVERRIDE "None")
        endif()
    endforeach()
endfunction()
