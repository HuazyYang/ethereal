# Slang-next Windows return - 2026-10-20

**W1 is complete.** The shared OptiX fix passes the affected Windows regressions,
native validation, CUDA memory checking and clean strict matrices. Linux L0-L4
are already complete. Final plan acceptance and reference retirement still need
**H1, real transfers on a supported CUDA peer pair**, followed by reconciliation.
No runtime source changes were needed for this Windows return.

## Revisions and host

All runs below used clean aggregate `57531c140eef8d3f882ad95036d6bf3a4b8c08d0`:

| Component | Gitlink |
| --- | --- |
| NVRHI | `7c6a8944dfcaaba907906714292fd76511565d3f` |
| Samples | `d8acf1eddab61c7adb01e2fd5a74c0e6c6deaef6` |
| Donut | `c7ca1b2f451d1d1ec26525fedad32c7ccdfbf768` |
| Nested shader-tool | `15b6ab0875b88f41cd6c197f0b9c9bba7e5d0b53` |

Windows 10 build 19045, VS 2022 / MSVC 19.44.35228, CMake 4.4.4,
Slang 2026.10.2, CUDA 12.9.86 and OptiX SDK 9.0.0. NVIDIA RTX 4050 Laptop GPU,
UUID `GPU-c86c40c1-38ca-a512-495e-aa3c7c245da6`, driver 617.42, plus AMD Radeon
780M graphics. Scene-RT native validation exercised both adapters through D3D12
and Vulkan; resource-array native validation used each API's default adapter.
Only the NVIDIA GPU is a CUDA adapter. This machine cannot satisfy H1.

## Relocated checkout

The active worktree is now
`D:/ps/repo/ethereal/.worktrees/ethereal-slang-next`, on branch `slang-next`.
Aggregate and nested submodule worktree records were repaired. The main checkout
and all submodules remained clean. The old sibling path contains no files;
Windows-held empty directory shells may persist until their handles are released.

Historical build artifacts moved with the checkout. Their recorded absolute paths
remain historical evidence, and their CMake caches must not be reused. Fresh
builds at `build/relocated` and `build/relocated-graphics` regenerated binaries,
shaders and asset paths for the new location. Use explicit build directories;
the default build presets still point to `build`.

## Results and evidence

Paths below are relative to `build/acceptance/` in the relocated checkout.
Ignored reports and runtime packages remain on this workstation; the Git commit
contains this evidence index, not those artifacts. All GPU jobs ran serially.

| Check | Result | Evidence |
| --- | --- | --- |
| Inventory | Clean aggregate and recursive gitlinks; hardware/tool versions recorded | `windows-relocated/inventory.json` |
| Affected full filter | **10/10** | `windows-relocated/focused.log`, `focused.xml` |
| Affected graphics-only filter | **4/4** | `windows-relocated/graphics-focused.log` |
| Native resource arrays and scene RT | **6/6**, no validation warnings/errors | `windows-relocated/*native*.log`, `diagnostics.json` |
| CUDA memory checks | **5/5**, each reports zero errors | `windows-relocated/memcheck-*.log`, `diagnostics.json` |
| Strict Windows full matrix | **438/438**, no skips, 288.62 s | `windows-relocated-full/{acceptance.json,ctest.xml,ctest.log}` |
| Strict graphics-only matrix | **330/330**, no skips, 234.37 s | `windows-relocated-graphics/{acceptance.json,ctest.xml,ctest.log}` |
| Full isolated runtime | **61/61**, sources unchanged | `windows-relocated-isolated/acceptance.json`, `logs/` |
| Graphics-only isolated runtime | **45/45**, sources unchanged | `graphics-relocated-isolated/acceptance.json`, `logs/` |

The focused filter is `cuda_slang_optix|cuda_optix|slang_resource_arrays|gvdb_scene_rt`.
It includes cached and uncached resource-array tables and the private no-op OptiX
miss record introduced by the Linux fix. Memcheck covers `cuda_slang_optix`,
`cuda_optix_local`, `cuda_optix_validation`, `slang_resource_arrays_CUDA` and
`gvdb_scene_rt_CUDA`, using `--tool memcheck --error-exitcode 99`.

Both isolated reports verify clean committed sources before staging and unchanged
sources afterward. They audit selected production build commands and PE imports,
copy runtime executables/libraries and offline shaders, and run with a system-only
PATH. Source assets remain accessible; this is shader/compiler deployment evidence,
not an asset redistribution claim. Installed SDK and tests-disabled production
results remain the separately recorded Windows/Linux evidence; they were not
rerun as part of this W1 return.

## Reproduction

From the relocated checkout, configure/build each variant in a Visual Studio
developer environment, or use `build.ps1` to initialize it:

```powershell
./build.ps1 -Preset slang-next -ConfigureOnly -CMakeArgs '-Bbuild/relocated','-DOPTIX_ROOT=C:/Program Files/NVIDIA GPU Computing Toolkit/OptiX SDK 9.0.0'
cmake --build build/relocated --config Release --parallel 4
./build.ps1 -Preset slang-next-graphics -ConfigureOnly -CMakeArgs '-Bbuild/relocated-graphics','-DCMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE'
cmake --build build/relocated-graphics --config Release --parallel 4
```

Use new evidence directories on subsequent runs; preserve the result paths above.
Run these jobs serially, together with native validation and sanitizer checks:

```powershell
ctest --test-dir build/relocated -C Release --parallel 1 --output-on-failure -R "cuda_slang_optix|cuda_optix|slang_resource_arrays|gvdb_scene_rt"
python tools/run-slang-acceptance.py --build build/relocated --profile windows-full --require-clean --output build/acceptance/windows-followup-full
python tools/run-slang-acceptance.py --build build/relocated-graphics --profile windows-graphics --require-clean --output build/acceptance/windows-followup-graphics
python tools/run-slang-isolated-runtime.py --build build/relocated --require-clean --output build/acceptance/windows-followup-isolated
python tools/run-slang-isolated-runtime.py --build build/relocated-graphics --graphics-only --require-clean --output build/acceptance/graphics-followup-isolated
```

`windows-relocated/diagnostics.json` records exact commands and process times for
all executed diagnostic jobs. Configure/build logs are `build/relocated-*.log`.

## Preserved failures and remaining work

Before relocation, the interrupted full-matrix attempt passed its first 192 cases,
then reported DLL-initialization failure `0xc0000142` for the remaining cases,
including CPU tests. Its root cause was not established. Preserve
`windows-linux-fixes/` and `windows-linux-return/`; this failed attempt is not
acceptance. The fresh complete run above passes the same 438 cases.

The first graphics build hit a Windows file lock while linking
`nvrhi_spirv_float_controls.exe`; a retry later hit the same error at
`fluid-surface.exe`. Rebuilding remaining targets with parallelism one succeeded,
without source changes. Logs remain in `build/relocated-graphics-build.log`,
`build/relocated-graphics-build-retry.log` and
`build/relocated-graphics-build-retry-2.log`.

Transfer these committed gitlinks to a supported CUDA peer host and execute
[H1](slang-next-linux-todos.md#h1-supported-real-cuda-peers-separate-hardware-prerequisite).
Return adapter identities/capabilities, actual directional transfer evidence and
the strict required-peer report. Keep retained sources and
`ETHEREAL_BUILD_GVDB_LEGACY` until H1 and final reconciliation pass.
