# Slang-next handoff

Updated 2026-10-20 after Linux acceptance. **Linux L0–L4 are complete; the complete
plan is not accepted yet.** The next developer should run **W1**, the affected
Windows regression after the shared OptiX fix, and **H1**, real CUDA transfers on
a supported peer pair. Neither job has been waived. Retained references remain.
The [Linux results](slang-next-linux-results.md) record the completed jobs and
evidence; the [Linux checklist](slang-next-linux-todos.md) retains the H1 commands.

## Checkout and build

Work is on `slang-next` in the aggregate and its submodules. Use the committed
parent gitlinks, including nested shader-tool. See [build instructions](slang-next-build.md)
and the [approved plan](plans/2026-10-18-ethereal-nvrhi-slang-support.md).

The returned implementation is aggregate `9230478`, NVRHI `7c6a894`, samples
`d8acf1e`, Donut `c7ca1b2`, and shader-tool `15b6ab0`. Later aggregate commits update
documentation only. On a clean continuation checkout, fetch `origin/slang-next`,
fast-forward the aggregate branch, then run `git submodule update --init --recursive`.
Do not replace the recorded gitlinks with moving submodule branch tips. Confirm
`git status --short` is empty and `git submodule status --recursive` has no `+`,
`-`, or `U` entries before acceptance runs.

For W1, rebuild on Windows and first run the affected cases, then the full runner:

```powershell
./build.ps1 -Preset slang-next -ConfigureOnly
cmake --build build --config Release --parallel 4
ctest --test-dir build -C Release --parallel 1 --output-on-failure -R "cuda_slang_optix|cuda_optix|slang_resource_arrays|gvdb_scene_rt"
python tools/run-slang-acceptance.py --build build --profile windows-full --require-clean --output build/acceptance/windows-linux-fixes
```

Run all GPU tests, native checks, captures and sanitizer processes serially.
Standalone Ninja/package builds need the Visual Studio developer environment.
The earlier Windows host has NVIDIA RTX4050 Laptop plus AMD Radeon780M graphics;
the Linux acceptance host has one RTX5070 Ti. Neither provides a CUDA peer pair.
Toolchains are Slang 2026.10.2, CUDA 12.9 and OptiX 9. The graphics-only build
disables CUDA discovery.

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
That Windows checkpoint used NVRHI `2c06d77`, Donut `c7ca1b2`, shader-tool `15b6ab0`.
The returned Linux fixes advance NVRHI and samples to the gitlinks above.

## Validation

Last Windows full matrices before the Linux fixes: aggregate `f2eae3e`, samples `40174a9`,
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

Linux evidence is retained on host `fysics` at
`/home/wyh/repo/ethereal/build/acceptance/`. These logs, JUnit reports, SDKs and staged
runtime packages are ignored build artifacts and are not included in Git pushes.
The committed result document indexes them. Preserve the original reports when
collecting W1/H1 evidence and return the tested revisions, recursive gitlinks,
hardware identities, failed/skipped jobs and new evidence paths.
