# Slang-next Linux acceptance return — 2026-10-20

Linux L0–L4 are complete on the RTX 5070 Ti host. W1 is complete. On 2026-10-21
the user explicitly waived multi-device CUDA validation and requested GPU0-only
coverage; H1 is therefore recorded as **waived, not passed**.
The legacy reference sources and `ETHEREAL_BUILD_GVDB_LEGACY` option were retired
by the final cleanup documented in the aggregate handoff.

**Subsequent Windows return:** W1 now passes at aggregate `57531c1` with the same
implementation gitlinks: 438/438 full, 330/330 graphics-only, native validation
and five CUDA memory checks. See [the Windows return](slang-next-windows-return.md).
The original H1 instructions below are retained as historical material; they are
not required under the revised GPU0-only scope.

## Revisions and host

The final implementation is aggregate `9230478f5aef1919531a4110544f6f2b89ba129b`:

| Component | Gitlink |
| --- | --- |
| NVRHI | `7c6a8944dfcaaba907906714292fd76511565d3f` |
| Samples | `d8acf1eddab61c7adb01e2fd5a74c0e6c6deaef6` |
| Donut | `c7ca1b2f451d1d1ec26525fedad32c7ccdfbf768` |
| Nested shader-tool | `15b6ab0875b88f41cd6c197f0b9c9bba7e5d0b53` |

Full-matrix and isolated-runtime reports record clean committed sources; isolated
runs also verify unchanged sources at completion. Later documentation commits do
not alter these implementation gitlinks. Earlier graphics/production evidence is
identified separately below.

Ubuntu 24.04.4, kernel 7.0.0-38, GCC 13.3, CMake 4.4.0-rc2, Ninja 1.13.2.
Slang 2026.10.2; CUDA 12.9 (nvcc 12.9.86, NVRTC 12.9.86); OptiX 9.0 headers at
NVIDIA/optix-dev `fff65c2a7c592f1ea5f1661ad7d2381cf965f9bd`;
Compute Sanitizer 2025.2.1. Khronos validation 1.4.313.0~rc2 was unpacked locally.

CUDA ordinal **0** and Vulkan ordinal **0** both identify NVIDIA RTX 5070 Ti,
UUID `GPU-76a81398-f023-b96f-ef07-b303ded77260`, driver **595.99.02**,
Vulkan device API 1.4.329. Vulkan ordinal 1 is llvmpipe, not a second CUDA GPU.
Native windows ran on `DISPLAY=:1`. GPU processes were serialized.

All paths below are relative to the aggregate root. Logs, JUnit, caches, runtime
packages and JSON evidence remain under ignored `build/acceptance/`, outside
tracked source. `linux-inventory-final/` contains full identity/version output and
SDK/compiler hashes. Local SDKs and tools are under `build/linux-tools/`.

## Results

| Gate | Result | Evidence under `build/acceptance/` |
| --- | --- | --- |
| L0 inventory | Recorded, clean final implementation | `linux-inventory-final/inventory.json` |
| L1 full Vulkan/CUDA/OptiX | **248/248**, no skips, 92.01 s | `linux-full-optix-final/{acceptance.json,ctest.xml,ctest.log}` |
| L2 Vulkan only, CUDA discovery disabled | **150/150**, no skips, 52.75 s, at `b942aa8` | `linux-graphics-final/{acceptance.json,ctest.xml,ctest.log}` |
| L2 tests-disabled production | Point-cloud volume verification and interactive self-test pass; PNG exactly matches equivalent graphics build | `linux-production-final/{results.json,*.log,*.png}` |
| L3 native validation | All four full-build diagnostics pass without validation errors/warnings | `linux-diagnostics-optix-final/acceptance.json` and logs |
| L3 CUDA memory checks | Topology/owner/atlas remap, scene RT and full point-cloud asset: **zero errors** | Same diagnostic directory |
| L4 ShaderTool artifact SDK | Compiler/tests disabled; build/install pass | `linux-build-logs/shadertool-linux-CMakeCache.txt`, install manifest |
| L4 full NVRHI installed consumers | Static **2/2**, shared **2/2**, CUDA toolkit discovery disabled | `nvrhi-consumer-full-*-optix-final.{log,xml}` |
| L4 GVDB portable wrapper | Static **5/5**, shared **5/5**, installed NVRHI | `gvdb-full-package-*-optix-final.{log,xml}` |
| L4 installed topology and ray consumers | **2/2 each**, both linkage variants; includes CUDA and ABI cases | `gvdb-full-{topology,ray}-consumer-*-optix-final.{log,xml}` |
| L4 isolated full runtime | **31/31** routes; clean sources unchanged | `linux-isolated-full-final/acceptance.json`, runtime, images and logs |
| L4 isolated graphics runtime | **17/17** routes at `b942aa8`; clean sources unchanged | `linux-isolated-graphics-final/acceptance.json`, runtime, images and logs |
| OptiX regression | Six focused tests pass; resource-array memory check has zero errors | `linux-optix-fix-focused.{log,xml}`, `linux-resource-arrays-memcheck.log` |
| Final graphics regression | Cached/uncached resource-array test passes at `9230478` | `linux-graphics-resource-arrays-final.{log,xml}` |
| GPU0-only final scope check | **4/4** CUDA/OptiX/resource-array/scene-RT tests with `CUDA_VISIBLE_DEVICES=0` | `gpu0-final-scope.{log,xml}` |
| H1 real supported peers | **Waived by user; not passed**; only one CUDA adapter | `linux-peer-current/{result.json,direct-rerun.log,host-inventory.txt}` |
| W1 affected Windows regression | **Complete**; 438/438 full and 330/330 graphics-only | [Windows return](slang-next-windows-return.md) |

The production capture SHA256 is
`b55ce3412a9b4e6ea39932f15b7b0c2a5d57a88f564824c04f8924d0415a32ad`
for both builds. Production was rebuilt and checked with the final implementation
gitlinks; its JSON records the exact aggregate revision including documentation.
This is an equivalent Vulkan-configuration comparison, not a cross-backend or
cross-platform claim. The final graphics regression covers the later test-only
change. Earlier
full-package checks at `f059702` were repeated after rebuilding/installing the
corrected backend at `9230478`.

The isolated-runtime runner now supports Linux: it stages application executables,
build-local shared libraries and offline shader blobs; removes ELF RPATHs;
checks imports and loader resolution; strips SDK/compiler environment variables;
and executes the existing fixture oracles from the staged directory. No
Slang/NVRTC/compiler library is staged or imported. The NVIDIA driver and OptiX
runtime are permitted. Source assets remain available, so this is compiler-free
shader deployment evidence, not an asset redistribution package.

## Fixes and investigated failures

- NVRHI `93491e5`: static Vulkan backend exports its common-library dependency in
  link order; fetched Vulkan-Headers no longer leaks a non-exported target;
  installed shared consumers use Linux loader paths.
- NVRHI `8e7b4bc`: installed Linux static CUDA consumers resolve the driver library
  directly and configure with CUDA toolkit discovery disabled.
- Samples `04cde82`: Windows-specific debug logging is guarded; shared installed
  topology/ray consumers use `LD_LIBRARY_PATH` on Linux.
- Aggregate `b942aa8`: Linux staging/auditing in the isolated-runtime runner.
- NVRHI `7c6a894`: the Linux driver rejected a ray-generation-only OptiX launch
  with `sbt->missSbtRecord is null`. The backend now links an internal no-op miss
  program group and uploads its record when the public table has no misses.
  Public table entry counts and ABI are unchanged. NVIDIA documents null-module
  miss program groups in the [OptiX type reference](https://raytracing-docs.nvidia.com/optix9/api/group__optix__types.html).
- Samples `d8acf1e`: the existing resource-array regression now exercises cached
  and uncached ray-generation-only tables with exactly one public entry.

Earlier failures are retained as investigation evidence, not counted as passes:

- Initial sandbox execution selected llvmpipe and passed 106/150; host execution
  exposed the NVIDIA device. Two subsequent native-window failures were missing
  validation-layer setup. `linux-graphics*` preserves these earlier reports.
- The full runner initially rejected a configuration missing `cuda_vulkan_interop`.
  Explicit Vulkan include/loader paths enabled it; external-memory/semaphore and
  native interop then passed without backend changes or CPU staging.
- `linux-full-final/` records **247/248**, with the empty-miss OptiX failure.
  `linux-full-optix-final/` supersedes it with **248/248**.
- The Ubuntu 1.3.275 validation layer did not understand driver cluster-RT
  structures. Diagnostics were repeated with 1.4.313.0~rc2 and are clean.
- Earlier package attempts exposed static link ordering, shared loader paths and
  toolkit-discovery dependencies. Final installed-consumer runs pass.
- Build logs retain Slang messages about missing optional `spirv-opt`/
  `slang-glslang-2026.10.2`. Compilation returned success and emitted artifacts;
  the runtime matrices and native validation passed. No optimization-quality
  claim is made.

## Reproduction and remaining work

The standard commands remain in [the Linux checklist](slang-next-linux-todos.md).
This host additionally required the following local tool paths:

```sh
export OPTIX_ROOT="$PWD/build/linux-tools/optix-9.0"
export CUDA_PATH="$PWD/build/linux-tools/cuda-12.9"
export VK_LAYER_PATH="$PWD/build/linux-tools/validation-modern/usr/share/vulkan/explicit_layer.d"
export LD_LIBRARY_PATH="$PWD/build/linux-tools/validation-modern/usr/lib/x86_64-linux-gnu:$CUDA_PATH/lib"
cmake --preset slang-next-linux -B build/linux-full \
  -DOPTIX_ROOT="$OPTIX_ROOT" -DCUDAToolkit_ROOT="$CUDA_PATH" \
  -DVulkan_INCLUDE_DIR="$PWD/build/vulkan-headers-prefix/include" \
  -DVulkan_LIBRARY=/lib/x86_64-linux-gnu/libvulkan.so.1
cmake --build build/linux-full --config Release --parallel 4
```

Standalone NVRHI configuration also used `CMAKE_POLICY_VERSION_MINIMUM=3.22`.
Full static/shared prefixes are `build/nvrhi-full-{static,shared}-prefix`;
artifact/Vulkan headers prefixes are `build/shadertool-prefix` and
`build/vulkan-headers-prefix`. GVDB prefixes are `build/gvdb-full-sdk-{static,shared}`.
Use the matching linkage prefix when building each package. Consumers set
`CMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE`. Isolation requires `patchelf` in the
invoker's PATH (`build/linux-tools/root/usr/bin` on this host); the staged process
gets only `/usr/bin:/bin` and its runtime library directory.

**H1 scope decision:** the user waived multi-device validation on 2026-10-21 and
requested GPU0-only coverage. The single-GPU negative peer diagnostic remains
evidence of the hardware boundary, not a peer pass.

**W1:** rebuild the Windows full configuration with these gitlinks. Rerun the
OptiX and resource-array regressions (including cached/uncached tables), scene RT,
and their CUDA sanitizer checks; then return a clean strict Windows matrix.
At minimum the focused CTest filter is
`cuda_slang_optix|cuda_optix|slang_resource_arrays|gvdb_scene_rt`.
Earlier Windows 438/438 results predate the OptiX change and cannot certify it.
Final reconciliation is complete under the revised GPU0-only scope; retained
references remain available for rollback and comparison.
