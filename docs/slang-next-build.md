# Building and running Slang-next

[Implementation status](slang-next-status.md) records verified behavior and outstanding acceptance gates. Work belongs in the `ethereal-slang-next` worktree, on the `slang-next` branches.

## Windows build

Use Visual Studio 2022 with the C++ workload, CMake, Ninja, and the existing vcpkg setup. The full preset additionally needs CUDA Toolkit 12.9 and OptiX SDK 9.0. Slang 2026.10.2 comes from shader-tool's dependency setup.

```powershell
.\build.ps1 -Preset slang-next -CMakeArgs '-DOPTIX_ROOT=C:/Program Files/NVIDIA GPU Computing Toolkit/OptiX SDK 9.0.0' -Target basic_triangle,headless,rt_triangle,shader_specializations,render-to-file,render-kernel,sph_fluid_pool,gvdb_slang_tests,gvdb_rt_tests,slang_rt_shared
```

For graphics-only execution use `-Preset slang-next-graphics`. It disables the NVRHI CUDA and OptiX backends. Portable GVDB requires neither the CUDA language nor NVCC. An isolated build with `CMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE` has compiled and passed 18 graphics sample tests locally.

The current presets share the default `build` directory. Use a separate binary directory to retain different configurations side by side:

```powershell
.\build.ps1 -Preset slang-next-graphics -ConfigureOnly -CMakeArgs '-Bbuild/graphics-only','-DCMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE'
cmake --build build/graphics-only --config Release --target gvdb_slang_tests render-to-file sph_fluid_pool
ctest --test-dir build/graphics-only -C Release -R '^(gvdb_|slang_)' --output-on-failure
```

`build.ps1` initializes Visual Studio and sets console output to UTF-8. Localized MSVC diagnostic encoding must match CMake's detected `/showIncludes` prefix for Ninja to track header dependencies. Old trees created with mismatched encodings need a fresh configure and clean rebuild. `VSLANG=1033` alone does not work when English compiler resources are absent.

## Portable samples

```powershell
build/bin/headless.exe -cuda
build/bin/render-to-file.exe -vk --input path/to/volume.vbx --output volume.png
build/bin/render-to-file.exe -dx11 --surface --width 640 --height 480
build/bin/sph_fluid_pool.exe -dx12 --particles 65536 --example 2
build/bin/sph_fluid_pool.exe -vk --headless --particles 8192 --example 3 --frames 20 --screenshot pool.png
build/bin/sph_fluid_pool.exe -cuda --particles 8192 --example 3 --frames 20 --output particles.csv
```

Backend options are `-dx11`, `-dx12`, `-vk`, and `-cuda`. `--adapter N` selects an adapter within that API. `--validation` requests the native debug runtime in addition to NVRHI validation.

The fluid viewer supports Space to pause, R to reset, arrow keys to orbit, and the mouse wheel to zoom. CUDA currently runs headless. Graphics modes draw directly from simulation buffers. Presets are regression (0), tower (1), wave pool (2), and dam break (3). The older scene/ImGui integration remains in the legacy implementation.

`render-to-file` frames index-space volume bounds. Its camera and timing interval differ from the legacy renderer; analytic tests and cross-backend images establish correctness, not a direct speed comparison.

## Artifacts and runtime dependencies

Ship the generated `shaders` directory with applications, preserving its `dxbc`, `dxil`, `spirv`, `ptx` and `optix` target subdirectories. ShaderTool is an offline build tool. Runtime artifact loading uses NVRHI and the compiler-independent artifact library, without Slang or NVRTC.

CUDA compute storage currently requires structured or raw buffers. Shader-tool rejects unsupported typed CUDA buffer lowering explicitly. Declare distinct texture/sampler pairings when using multiple samplers with one texture.

The installed static NVRHI package resolves its link dependencies. A shared NVRHI consumer does not require compiler or CUDA SDK discovery. Both installed-package paths have external consumer tests.

## Legacy references and platform coverage

`ETHEREAL_BUILD_GVDB_LEGACY=ON` enables old CUDA reference implementations and their dependencies. Set `ETHEREAL_BUILD_GVDB=OFF` when building legacy versions of migrated target names.

Linux presets (`slang-next-linux` and `slang-next-linux-graphics`) have not been executed on this workstation. Linux Vulkan/CUDA interop and actual multi-GPU transfers remain required acceptance runs. Single-GPU rejection tests do not establish peer-transfer success.
