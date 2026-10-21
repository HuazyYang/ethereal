# Slang-next handoff

Updated 2026-10-21 after explicit scope direction from the user. **Linux L0-L4
and Windows W1 are complete; the user waived multi-device CUDA validation and
accepted GPU0-only coverage for this plan.** H1 is recorded as waived, not
passed. The legacy GVDB CUDA/gp implementation has since been retired from
`gvdb_samples`; the portable NVRHI/Slang path is now the only production path.
The
[Windows return](slang-next-windows-return.md) records the fresh Windows results
and worktree relocation; the [Linux results](slang-next-linux-results.md) record
L0-L4. The remote Linux H1 handoff is retained as historical scope; it is no
longer blocking under the user's revised GPU0-only requirement.

## Checkout and build

The Windows checkout is now `.worktrees/ethereal-slang-next` inside the main
aggregate checkout (`D:/ps/repo/ethereal` on this host). Git worktree and nested
submodule links have been repaired. Work is on aggregate branch `slang-next`.
Use the committed parent gitlinks, including nested shader-tool. See [build instructions](slang-next-build.md)
and the [approved plan](plans/2026-10-18-ethereal-nvrhi-slang-support.md).

The returned implementation is aggregate `9230478`, NVRHI `7c6a894`, samples
`d8acf1e`, Donut `c7ca1b2`, and shader-tool `15b6ab0`. Later aggregate commits update
documentation only. On a clean continuation checkout, fetch `origin/slang-next`,
fast-forward the aggregate branch, then run `git submodule update --init --recursive`.
Do not replace the recorded gitlinks with moving submodule branch tips. Confirm
`git status --short` is empty and `git submodule status --recursive` has no `+`,
`-`, or `U` entries before acceptance runs.

W1 passes at aggregate `57531c1` with the implementation gitlinks above. Fresh
builds are `build/relocated` and `build/relocated-graphics`; historical CMake caches
moved from the old location retain absolute paths and must not be reused.
To reproduce the full Windows job (choose a fresh evidence directory):

```powershell
./build.ps1 -Preset slang-next -ConfigureOnly -CMakeArgs '-Bbuild/relocated','-DOPTIX_ROOT=C:/Program Files/NVIDIA GPU Computing Toolkit/OptiX SDK 9.0.0'
cmake --build build/relocated --config Release --parallel 4
ctest --test-dir build/relocated -C Release --parallel 1 --output-on-failure -R "cuda_slang_optix|cuda_optix|slang_resource_arrays|gvdb_scene_rt"
python tools/run-slang-acceptance.py --build build/relocated --profile windows-full --require-clean --output build/acceptance/windows-followup
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

The post-Linux Windows return at clean aggregate `57531c1` passes **438/438 full**
(288.62 s), **330/330 graphics-only** (234.37 s), and isolated runtime **61/61 full**
plus **45/45 graphics-only**, without skips. The affected filters pass **10/10 full**
and **4/4 graphics-only**; six native checks pass and five CUDA memory checks report
zero errors. See the [Windows evidence index](slang-next-windows-return.md).
The following earlier checkpoints remain historical evidence.

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

## Linux return and final scope decision

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

The user's final scope decision on 2026-10-21 is:

1. **H1 is waived.** The current native Linux host exposes one RTX 5070 Ti and
   the user explicitly requested GPU0-only CUDA validation. The required-peer
   negative diagnostic remains recorded and is not relabeled as a pass.
2. **Final reconciliation is complete under the revised scope.** W1 is complete:
   the private no-op OptiX miss record passes the affected tests, native checks,
   sanitizer and strict Windows matrices.

## Legacy CUDA and affine-host cleanup

The final M6 cleanup is complete in samples revision `bdb8905` (the
submodule commit is recorded with this handoff). The retired surface included:

- `gvdb/GPDevice*`, `gvdb/GVDB.h`, `GVDBVolume.cpp`, `GVDBScene.*`, the old
  affine/gp operation adapters, and the `GVDBOperators.cu`/`GVDBParticles.cu`
  PTX sources;
- the CUDA raycast/OptiX and fluid PTX trees, legacy sample launchers, and the
  gp-only sample framework; and
- the legacy CMake entry points, CUDA language enablement, and
  `ETHEREAL_BUILD_GVDB_LEGACY` option.

Portable `GVDBHostVolume`, `GVDBNvrhi*`, Slang shader manifests, migrated sample
applications, and their tests remain. The cleanup acceptance is source-level:
`rg` finds no `GPDevice`, `donut::gp`, legacy `.cu/.cuh` GVDB kernels, or legacy
CMake target in the production tree; a fresh graphics-only configure/build
must also succeed without CUDA toolkit or NVCC discovery.

The portable `tools/gvdb-acceptance-package` continues to use installed NVRHI,
without workstation-specific paths. `tools/run-slang-isolated-runtime.py` now
supports Windows DLL and Linux ELF deployment checks, including import auditing,
Linux RPATH removal and runtime loader resolution. Source assets remain available;
this is shader/compiler deployment validation, not asset redistribution.
The current Windows isolated-runtime **61/61 full** and **45/45 graphics-only**
runs at `57531c1` are under `build/acceptance/windows-relocated-isolated` and
`build/acceptance/graphics-relocated-isolated`. The runs at `bb0eb36` remain
historical evidence under `build/acceptance/isolated-{full,graphics}-final`;
Linux evidence is under the paths listed in its return. Future ROCm/Metal/SYCL backends remain out of scope.

Linux evidence is retained on host `fysics` at
`/home/wyh/repo/ethereal/build/acceptance/`. These logs, JUnit reports, SDKs and staged
runtime packages are ignored build artifacts and are not included in Git pushes.
The committed result document indexes them. Preserve the original reports when
collecting H1 or follow-up evidence and return the tested revisions, recursive gitlinks,
hardware identities, failed/skipped jobs and new evidence paths.
