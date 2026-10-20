# Slang-next handoff

Updated 2026-10-20. Windows implementation and fixture validation have advanced;
**the complete plan is not accepted yet**. The user deferred Linux Vulkan/CUDA
validation to another developer on 2026-10-20. The actionable
[Linux host TODOs](slang-next-linux-todos.md) are staged separately so local work
can continue. A supported real CUDA peer pair is a separate required hardware
job; it has not been waived. Retained references remain.

## Checkout and build

Work is on `slang-next` in the aggregate and its submodules. Use the committed
parent gitlinks, including nested shader-tool. See [build instructions](slang-next-build.md)
and the [approved plan](plans/2026-10-18-ethereal-nvrhi-slang-support.md).

```powershell
./build.ps1 -Preset slang-next -ConfigureOnly
cmake --build build --config Release --parallel 4
python tools/run-slang-acceptance.py --build build --profile windows-full --require-clean --output build/acceptance/windows
```

Run all GPU tests, native checks, captures and sanitizer processes serially.
Standalone Ninja/package builds need the Visual Studio developer environment.
Current local hardware is NVIDIA RTX4050 Laptop plus AMD Radeon780M graphics;
the AMD adapter cannot provide the required CUDA peer pair. Toolchains are
Slang 2026.10.2, CUDA 12.9 and OptiX 9. The graphics-only build disables CUDA discovery.

## Current implementation

Samples `40174a9` integrates GPU key generation, stable sorting, scans and
compaction into production point-cloud reconstruction. Authoritative host
allocation is followed by public GPU marker/delink/relink, actual fetched graph
validation and atlas publication. This matches the retained allocation division:
`allocateUniqueNodes` also allocates on the CPU after GPU discovery. Fresh frames
compact candidates and replace the owner; arbitrary disconnected pools are rejected.
See the [integration and measurement record](plans/2026-10-20-gvdb-point-topology-integration.md).

The same checkpoint reuses recursive radix scan storage and fixes actual AMD
Vulkan standalone voxelization by sharing the public geometric implementation.
The general compute test now honors adapter/native-validation options.

Mixed RT has a [documented secondary-ray diagnosis and matched fixture](plans/2026-10-20-gvdb-mixed-rt-reference.md).
Both interactive applications expose an explicit secondary bias, defaulting to
zero. All twelve matched 0.01-bias original-asset comparisons pass fixed limits.
The original level-set NaN defect remains separately measured; finite shading is
an explicit correction, not an unchanged-reference pass. The committed diagnostic
capture script reproduces that evidence without changing retained sources.

Earlier completed slices include public ownership and operator factories,
retained subcells/attributes, point insertion/quantization/deposition, grid/ray
queries, voxelization, all sample ownership migrations, shared shading/sections,
ordered multi-volume composition, and installed topology-edit/activity factories.
The [status history](slang-next-status.md) links their individual execution records.

The [100-role inventory](../ethereal-samples/docs/gvdb-cuda-entry-inventory.md) is now
**52 owned-validated / 48 sample-validated / 0 foundation / 0 partial / 0 pending**.
These are Windows role-validation classifications with explicit corrections and
fixture limits, not platform completion percentages or authority to retire code.
Dependencies remain NVRHI `2c06d77`, Donut `c7ca1b2`, shader-tool `15b6ab0`.

## Validation

Latest completed full matrices: aggregate `f2eae3e`, samples `40174a9`,
**438/438 Windows** (239.90 s), **330/330 graphics-only** (188.44 s), clean
committed gitlinks throughout and no skips. Reports are under
`build/acceptance/{windows,graphics}-integrated-final`.

Current focused integration checks: Windows algorithms/point-cloud **22/22**,
graphics-only affected applications **30/30**, native general-compute and point
reconstruction **12/12**, full-asset CUDA memory checking **zero errors**, installed
topology consumers static/shared **2/2 each**. Seven point-cloud images are
byte-identical to the preceding portable checkpoint. The mixed-RT fresh capture
passes all documented per-mode and cross-API checks. Logs are under
`build/acceptance/point-keys` and `build/acceptance/mixed-biased-holdout`.

The tests-disabled graphics-only production build passes point-cloud D3D11
compute, D3D12 RT/contribution checks and interactive controls. Both production
captures exactly match the corresponding graphics-only test build. Against the
CUDA-enabled build, compute differs by one byte in three pixels; RT differs in
78 pixels with maximum byte difference seven. Cross-configuration identity is
not claimed. All seven captures within the CUDA-enabled checkpoint remain exact.
Installed NVRHI consumers also pass static **2/2**, shared **1/1**; installed ray
consumers pass static/shared **2/2 each** at the final source checkpoint.

Timing and memory are recorded separately from correctness. GPU key integration
regresses D3D12/Vulkan process time, and portable full-scene reconstruction/render
processes remain slower than retained CUDA/OptiX on this fixture. Reused logical
scan scratch is smaller; CPU peak working set is not GPU peak memory.

## Linux return and remaining external acceptance

Linux L0–L4 have been executed and reviewed on the Linux host. See the
[full return and evidence index](slang-next-linux-results.md) and
[updated checklist](slang-next-linux-todos.md). Implementation aggregate
`9230478` pins NVRHI `7c6a894`, samples `d8acf1e`, Donut `c7ca1b2` and nested
shader-tool `15b6ab0`.

The full Linux matrix passes **248/248**, graphics-only **150/150**, with no skips.
Tests-disabled production passes and exactly matches the equivalent Vulkan
capture. Native validation and CUDA memory checks are clean. Static/shared
installed SDKs, actual CUDA topology/ray consumers, and compiler-free deployment
pass; isolated runtime routes are **31/31 full** and **17/17 graphics-only**.
The result document distinguishes final implementation evidence from earlier
graphics/production runs and preserves investigated failures.

The remaining work is:

1. **H1: supported CUDA peers.** Transfer these gitlinks to a supported two-GPU
   host and execute the strict required-peer job. This host has only one CUDA GPU;
   its explicit required-peer failure is not acceptance.
2. **W1: affected Windows regression.** The Linux run exposed an OptiX driver
   rejection of a raygen-only table without a miss record. The shared backend now
   supplies a private no-op miss record. Rebuild Windows and rerun OptiX, cached/
   uncached resource-array and scene-RT tests plus sanitizer, then return a clean
   strict full matrix. Earlier Windows 438/438 does not certify the new fix.
3. Reconcile final acceptance and reference disposition after H1 and W1 pass.
   Keep `ETHEREAL_BUILD_GVDB_LEGACY` and retained sources available until then.

The portable `tools/gvdb-acceptance-package` continues to use installed NVRHI,
without workstation-specific paths. `tools/run-slang-isolated-runtime.py` now
supports Windows DLL and Linux ELF deployment checks, including import auditing,
Linux RPATH removal and runtime loader resolution. Source assets remain available;
this is shader/compiler deployment validation, not asset redistribution.
The previous Windows isolated-runtime **61/61 full** and **45/45 graphics-only**
runs at `bb0eb36` remain historical evidence under
`build/acceptance/isolated-{full,graphics}-final`; Linux evidence is under the
paths listed in the return. Future ROCm/Metal/SYCL backends remain out of scope.
