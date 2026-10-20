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

## Deferred external acceptance and current local work

1. Linux developer: execute [L0-L4](slang-next-linux-todos.md), covering the full
   and graphics-only matrices, native validation, sanitizer, installed consumers
   and isolated runtime deployment. Return fixes and revision-stamped evidence.
2. On a supported CUDA pair, configure `NVRHI_TEST_REQUIRE_CUDA_PEER=ON`, select
   actual local/peer ordinals and run the strict runner with `--require-peer`.
   Missing/unsupported hardware must fail; a local negative test is not acceptance.
3. Only after the required external jobs pass, reconcile the final acceptance
   record and reference disposition. Keep `ETHEREAL_BUILD_GVDB_LEGACY` and retained
   sources available until then. Future ROCm/Metal/SYCL backends remain out of scope.

Linux availability is no longer a request for this session: that work is deferred
to the other host/developer. Local production dependency and isolated runtime
checks now pass at aggregate `bb0eb36`: **61/61 full-runtime** routes and **45/45
graphics-only** routes, with clean sources unchanged throughout each run.
The committed `tools/gvdb-acceptance-package` replaces absolute
workstation paths in the topology/ray package setup. The Windows deployment tool
`tools/run-slang-isolated-runtime.py` copies only selected executables, the runtime
DLLs and offline shader artifacts, removes developer SDK paths, and runs the
production fixtures from that separate directory. Source assets remain available;
this is shader/compiler deployment validation, not asset redistribution.

The 15 selected production targets' transitive build commands contain no
GPDevice, Thrust, cudart, NVCC or `.cu/.cuh` compilation. Audited PE imports contain
no Slang/NVRTC/cudart/GPDevice/compiler-library dependency. The portable topology/
ray package wrapper passes static/shared CPU/ABI **5/5 each**, and its independently
installed topology and ray consumers each pass **2/2 per linkage variant**, with
CUDA/compiler SDK discovery disabled. Logs and hashed runtime manifests are in
`build/acceptance/isolated-{full,graphics}-final` and
`build/acceptance/portable-package`. Runtime gitlinks remain unchanged.
Next integration work is to consume the Linux developer's L0-L4 results and the
separate H1 peer evidence; final global acceptance remains pending those jobs.
