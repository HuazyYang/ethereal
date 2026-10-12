# ethereal

An aggregate of sub-projects, laid out like DiligentEngine:

| Directory | Content |
|---|---|
| `ethereal-donut/` | Graphics framework (git submodule, branch `ethereal-dev`); brings nvrhi, ShaderTool, glfw, imgui, ... |
| `ethereal-samples/` | Samples and benchmarks built on Donut (git submodule): DDGI, VXGI, GVDB, the Donut examples, `benchmark/Asteroids` |
| `cmake/` | Shared CMake helpers: `ethereal_compile_shaders()`, `copy_assets()`, `FindOptiX` |
| `CMakeLists.txt`, `CMakePresets.json`, `build.ps1` | The aggregate build |

## Clone

```
git clone --recursive git@github.com:HuazyYang/ethereal.git
# or, in an existing clone:
git submodule update --init --recursive
```

## Build (Windows, Visual Studio 2022)

```powershell
.\build.ps1                                         # Release, everything -> build\bin
.\build.ps1 -Config Debug -Target VXGISample
.\build.ps1 -Test                                   # also runs ctest
```

`build.ps1` sources the Visual Studio environment when `cl.exe` is not on `PATH`, then runs
`cmake --preset default` (Ninja Multi-Config) and `cmake --build --preset <config>`. Without that environment the
compiler cannot find the standard headers.

## Build (Linux, Vulkan)

Linux is a secondary target: only the Vulkan backend exists there, and the D3D-only parts are skipped.

```bash
sudo apt install build-essential cmake ninja-build python3 libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev
sudo apt install libgtest-dev                       # optional: the nvrhi::core unit tests
cmake --preset linux                                # Ninja Multi-Config -> build/
cmake --build build --config Release
ctest --test-dir build -C Release                   # unit tests, nvrhi tests, benchmark analysis tests
cd build/bin && ./basic_triangle                    # any sample; DDGISample needs --config <ethereal-samples/assets/config/*.cfg.json>
```

No vcpkg is involved: GLFW, imgui, stb, cgltf and the Vulkan headers are fetched at configure time. A GTest that
is not in a system location is found with `-DCMAKE_PREFIX_PATH=<prefix>`. GLFW builds its X11 backend only when
`wayland-scanner` is missing. Not built on Linux: `benchmark/Asteroids` (D3D11/D3D12 baselines; only its Python
analysis tests run), `demos/nv_asteroids`, `rt_reflections` and `work_graphs` (D3D12), and the GVDB samples (CUDA, opt-in).

| CMake option | Default | |
|---|---|---|
| `ETHEREAL_BUILD_SAMPLES` | ON | `ethereal-samples/src` |
| `ETHEREAL_BUILD_BENCHMARKS` | ON | `ethereal-samples/benchmark` (needs `fxc.exe` from the Windows SDK) |
| `ETHEREAL_BUILD_GVDB` | OFF | GVDB samples; enables the CUDA language |
| `ETHEREAL_WITH_OPTIX` | OFF | locate the OptiX SDK |
| `ASTEROIDS_MATCH_CODEGEN` | ON | apply the benchmark's Release code generation (`/GL /arch:AVX2 ...`) to all of Donut |
| `DONUT_WITH_KTX` | OFF | Donut's KTX2 support; turning it on fetches zstd from GitHub at configure time |
| `ETHEREAL_AGILITY_SDK_VERSION` | 1.619.6 | D3D12 Agility SDK NuGet version loaded by the ray tracing samples; a `-preview` version needs Windows Developer Mode |

Configure downloads Vulkan-Headers, DirectX-Headers and the D3D12 Agility SDK (and unpacks ShaderTool's compiler
packages). On a machine with a flaky connection reuse existing copies, e.g.
`-DEPM_VULKAN_HEADERS_SOURCE=<path> -DEPM_DIRECTX_HEADERS_SOURCE=<path>` (see [docs/epm.md](docs/epm.md); `-DEPM_SOURCE_CACHE=<dir>` shares downloads between build trees)
(`build.ps1 -CMakeArgs ...`).
