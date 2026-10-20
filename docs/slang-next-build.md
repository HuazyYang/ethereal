# Building and running Slang-next

[Implementation status](slang-next-status.md) records verified behavior and outstanding acceptance gates. Work belongs in the `ethereal-slang-next` worktree, on the `slang-next` branches.

## Windows build

Use Visual Studio 2022 with the C++ workload, CMake, Ninja, and the existing vcpkg setup. The full preset additionally needs CUDA Toolkit 12.9 and OptiX SDK 9.0. Slang 2026.10.2 comes from shader-tool's dependency setup.

```powershell
.\build.ps1 -Preset slang-next -CMakeArgs '-DOPTIX_ROOT=C:/Program Files/NVIDIA GPU Computing Toolkit/OptiX SDK 9.0.0' -Target basic_triangle,headless,rt_triangle,shader_specializations,render-to-file,render-kernel,sph_fluid_pool,resample,3d-print,depth-map,point-fusion,point-cloud,interactive-optix,fluid-surface,gvdb_scene_rt_tests,gvdb_slang_tests,gvdb_rt_tests,slang_rt_shared,gvdb_volume_view_tests,gvdb_volume_surface_tests
```

For graphics-only execution use `-Preset slang-next-graphics`. It disables the NVRHI CUDA and OptiX backends. Portable GVDB requires neither the CUDA language nor NVCC. An isolated build with `CMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE` has compiled the complete graphics configuration and passed 330 CTests locally at aggregate `f2eae3e`.

The current presets share the default `build` directory. Use a separate binary directory to retain different configurations side by side:

```powershell
.\build.ps1 -Preset slang-next-graphics -ConfigureOnly -CMakeArgs '-Bbuild/graphics-only','-DCMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE'
cmake --build build/graphics-only --config Release
ctest --test-dir build/graphics-only -C Release --output-on-failure
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
build/bin/resample.exe -vk --sparse --halo
build/bin/resample.exe -cuda --verify --sparse --output head.png
build/bin/3d-print.exe -dx12 --voxel-size .3 --shading section
build/bin/3d-print.exe -cuda --verify --output lucy.png
build/bin/depth-map.exe -dx12 --compute-api cuda
build/bin/depth-map.exe -vk --compute-api graphics --headless --output depth.png
build/bin/point-fusion.exe -dx12 --color
build/bin/point-fusion.exe -cuda --frames 2 --color --speed 1 --output city.png
build/bin/point-cloud.exe -vk --samples 8 --screenshot points.png
build/bin/point-cloud.exe -dx11 --renderer compute --headless --frames 2 --output points-compute.png
build/bin/interactive-optix.exe -dx12 --samples 8 --screenshot mixed.png
build/bin/fluid-surface.exe -cuda --headless --frames 1 --samples 8 --output fluid.png
```

Backend options are `-dx11`, `-dx12`, `-vk`, and `-cuda`. `--adapter N` selects an adapter within that API. `--validation` requests the native debug runtime in addition to NVRHI validation.

The fluid viewer supports Space to pause, R to reset, arrow keys to orbit, and the mouse wheel to zoom. CUDA currently runs headless. Graphics modes draw directly from simulation buffers. Presets are regression (0), tower (1), wave pool (2), and dam break (3). The older scene/ImGui integration remains in the legacy implementation.

`render-to-file` defaults to framing index-space bounds. `--shade 0..7 --reference-scene`
selects the retained explosion camera, light, VBX transform and transfer table for
matched reference comparisons. See the [render-mode record](plans/2026-10-20-gvdb-render-modes.md)
for fixture tolerances and separate end-to-end timing/storage measurements.

Resample uses keys 1/2/3 for topology/sparse/halo. 3d-print uses 1/2/3 for topology/shading/voxel size. Their shared viewer supports left-drag orbit, middle-drag pan, right-drag or wheel zoom, Shift-left-drag light rotation, V shading and I section inset. CUDA produces headless images. See the application READMEs for exact legacy behavior and presentation differences.

Depth-map supports graphics computation on all three graphics APIs and a separate CUDA device. Default legacy projection preserves the reference image; `--depth-mode exact --bias N` uses off-axis perspective correction. Normal CUDA-mode frames use GPU-only shared-texture ordering. `--frames N --screenshot image.png` captures a bounded window run.

Point-fusion retains the procedural city, scanner and persistent scalar/color fusion. Keys 1/2 toggle points/topology, Space scanning, F FPV/orbit, O city, C color/reset and R reset. CUDA runs headlessly; graphics support the same bounded screenshot option. The scanner fixes the original shared RNG race, so its deterministic scan sequence differs intentionally from the old CUDA kernel.

Point-cloud, interactive-optix and fluid-surface use native mixed ray tracing on D3D12, Vulkan and CUDA/OptiX. Point-cloud and fluid-surface also expose an explicit compute preview on D3D11 and the other APIs. Their Inspector controls, original scene parameters and numerical compatibility differences are documented in their sample READMEs. CUDA remains headless. Fluid captures simulate `--frames N` steps and then accumulate `--samples M` views of the last state; the default full preset contains 1.5 million SPH particles.

For public CUDA/graphics resource sharing, link nvrhi::interop and nvrhi::cuda. The [interop guide](../ethereal-nvrhi/docs/graphics-interop.md) describes shared allocation flags, ownership release/acquire and GPU timeline ordering. The SDK-free application test is src/slang_compute/InteropTests.cpp in ethereal-samples.

## Artifacts and runtime dependencies

Ship the generated `shaders` directory with applications, preserving its `dxbc`, `dxil`, `spirv`, `ptx` and `optix` target subdirectories. ShaderTool is an offline build tool. Runtime artifact loading uses NVRHI and the compiler-independent artifact library, without Slang or NVRTC.

CUDA compute storage currently requires structured or raw buffers. Shader-tool rejects unsupported typed CUDA buffer lowering explicitly. Declare distinct texture/sampler pairings when using multiple samplers with one texture.

The installed static NVRHI package resolves its link dependencies. A shared NVRHI consumer does not require compiler or CUDA SDK discovery. Both installed-package paths have external consumer tests.

## Legacy references and platform coverage

`ETHEREAL_BUILD_GVDB_LEGACY=ON` enables old CUDA reference implementations and their dependencies. Set `ETHEREAL_BUILD_GVDB=OFF` when building legacy versions of migrated target names. The retained render-to-file, depth-map, point-fusion, point-cloud, interactive-optix and fluid-surface targets have been freshly rebuilt under `build/legacy-reference`; retain `ETHEREAL_WITH_SLANG=ON` when representative graphics samples are enabled.

Linux presets (`slang-next-linux` and `slang-next-linux-graphics`) have not been executed on this workstation. Linux Vulkan/CUDA interop and actual multi-GPU transfers remain required acceptance runs. Single-GPU rejection tests do not establish peer-transfer success.

The user deferred Linux execution to another developer. Use the
[Linux TODO handoff](slang-next-linux-todos.md) for the assigned jobs, package
commands and evidence to return; the peer job remains a separate hardware gate.

Run the serial matrix with `python tools/run-slang-acceptance.py --build build
--profile windows-full --require-clean --output build/acceptance/windows`. Use
`windows-graphics`, `linux-full` or `linux-graphics` for the matching configuration.
The runner checks coverage, records source revisions, and fails on skipped tests.

On a supported CUDA pair configure `-DNVRHI_TEST_REQUIRE_CUDA_PEER=ON` and run the
acceptance tool with `--require-peer`. Select destination/source ordinals with
`NVRHI_TEST_CUDA_LOCAL_ADAPTER` and `NVRHI_TEST_CUDA_PEER_ADAPTER`; their defaults are
0 and 1. The required test fails when the pair is absent or unsupported. A direct
diagnostic invocation is `nvrhi_cuda_interop --require-peer --peer-only --adapter 0
--peer-adapter 1`. This option prepares the external acceptance job; it does not
establish peer-transfer success on the local single-CUDA-adapter machine.

The pending Linux jobs can use the following commands from a clean recursive
checkout of the committed checkpoint. Install the Linux compiler/CMake/Ninja,
X11 development packages listed in the `linux` preset, Vulkan driver/validation
layers and the pinned CUDA/OptiX toolchains first. Set `OPTIX_ROOT` to the SDK.
The full graphics matrix includes window tests and needs a working display.
These commands are prepared for the external host; they have not run locally.

```sh
cmake --preset slang-next-linux -B build/linux-full -DOPTIX_ROOT="$OPTIX_ROOT"
cmake --build build/linux-full --config Release --parallel 4
python3 tools/run-slang-acceptance.py --build build/linux-full --profile linux-full --require-clean --output build/acceptance/linux-full

cmake --preset slang-next-linux-graphics -B build/linux-graphics -DCMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE
cmake --build build/linux-graphics --config Release --parallel 4
python3 tools/run-slang-acceptance.py --build build/linux-graphics --profile linux-graphics --require-clean --output build/acceptance/linux-graphics
```

For the required peer job, add `-DNVRHI_TEST_REQUIRE_CUDA_PEER=ON` and the actual
adapter ordinals to the full configure command, then add `--require-peer` to its
acceptance command. Run native Vulkan validation, CUDA memory checks and installed
static/shared consumer jobs on that platform too. Archive the revision-stamped
reports and diagnostics; do not replace an unavailable required route with a skip.

## Isolated Windows production runtime

Use a fresh output directory and run serially with other GPU work:

```powershell
python tools/run-slang-isolated-runtime.py --build build --require-clean --output build/acceptance/isolated-full
python tools/run-slang-isolated-runtime.py --build build/graphics-only --graphics-only --require-clean --output build/acceptance/isolated-graphics
```

This requires Ninja and MSVC `dumpbin` (discovered through `vswhere`). It checks
the selected production targets' transitive compile/link commands, inspects PE
imports, and copies only the applications, `nvrhi_core.dll`, D3D12 runtime and
compiled shader blobs. No compiler executable, Slang/NVRTC/cudart DLL, source
shader or developer SDK path is copied into the runtime directory. Every fixture
runs from the copy with a system-only `PATH`; errors and developer skip codes fail
the job. The report records source revisions, file hashes, imports and results.
Reference asset paths remain available and are not an asset-packaging claim.
Drivers, including CUDA PTX JIT and OptiX, remain runtime requirements.
