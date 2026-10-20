# Slang-next handoff

Updated 2026-10-20. The mega project remains in progress. All implementation work
is on `slang-next`; the original checkout's unrelated edits were preserved.

## Checkout and build

Clone the aggregate repository's `slang-next` branch recursively, or check out that
branch and run `git submodule update --init --recursive`. Build the exact committed
gitlinks; submodules also publish `slang-next` branches for continued development.
See [build instructions](slang-next-build.md) and the
[approved scope](plans/2026-10-18-ethereal-nvrhi-slang-support.md).

```powershell
./build.ps1 -Preset slang-next -ConfigureOnly
cmake --build build --config Release --parallel 4
ctest --test-dir build -C Release --output-on-failure
```

Run GPU tests serially; do not overlap separate native, CUDA sanitizer or CTest
processes. Standalone Ninja/package builds need a Visual Studio developer shell.
The graphics-only preset disables CUDA discovery. Current local acceptance used
Slang 2026.10.2, CUDA12.9, OptiX9, NVIDIA RTX4050 Laptop and AMD Radeon780M graphics.

## Latest implementation

- CUDA Driver API / OptiX backend, offline Slang artifacts and unified NVRHI
  interfaces; Windows graphics/CUDA native interop and explicit unsupported routes.
- Public immutable GVDB ownership, point conversion/quantization, mutation/filter/
  gather/resampling/voxelization/deposition, and migrated owned sample consumers.
- Retained subcells expose stable ranges, signed cell locations and source ordinals,
  with actual GPU-expanded canonical position/velocity/color streams.
- Scalar-grid queries provide selected R32 reads and repaired Y-face diagnostics,
  including explicit nonfinite interpolation behavior across four APIs.
- Center/velocity-support insertion shares subcell expansion, preserving original
  attributes and stable ordering; pre-translation NOHIT handling is explicit.
- Coordinate splitting exposes raw X/Y/Z ranges, completed CPU planes and exact
  extrema from actual GPU results, with no hidden submission/wait.
- Leaf-marker workflow acceptance covers exact flags, dirty/finished/stale tickets,
  inactive/reactivated leaves and retained GPU snapshots through the existing API.

Latest committed samples implementation: `1c5dfa2`. Runtime dependencies: NVRHI `c17545a`,
Donut `c7ca1b2`, nested shader-tool `15b6ab0`. The aggregate gitlinks are authoritative.
An external handoff checkpoint also committed intermediate work during the session;
those commits were preserved without rewriting history.

## Validation evidence

The [status record](slang-next-status.md) and linked execution plans distinguish
historical full matrices from later focused validation. Latest completed full
matrices, at the subcell checkpoint, were **365/365 Windows** and **274/274
graphics-only**, without skips. Subsequent additions passed:

| Slice | Affected Windows tests | Graphics-only | Installed static/shared |
| --- | ---: | ---: | --- |
| Scalar-grid queries | 25/25 | 4/4 | 2/2 each |
| Point insertion | 30/30 | 8/8 | 2/2 each |
| Coordinate splitting | 25/25 | 4/4 | 2/2 each |
| Leaf markers | 16/16 | 4/4 | 3/3 each |
| Public ray records and spray | 24/24 | 19/19 | 2/2 each |
| Shared sections and compositing | 23/23 | 18/18 | No public ABI change |

Each slice passed native D3D11/D3D12/Vulkan validation on both graphics adapters
and CUDA Compute Sanitizer with zero errors. Logs are local build artifacts under
`build/m5-public-subcells`, `build/m5-grid-query`, `build/m5-point-insertion` and
`build/m5-point-split` and `build/m5-leaf-markers`; execution summaries and
reproducible tests are committed.
The later slices have not been represented as a new full-matrix run.

## Next work and open gates

1. Complete remaining exported section/compositing and individual shading
   contracts, consumer adoption and legacy control/visual comparisons. Shared
   mixed DXR/Vulkan/OptiX rendering exists but is not complete legacy parity.
2. Resolve remaining linking/GPU-key/algorithm integration roles and record broad
   timing/memory comparisons separately from correctness. Current point association
   deliberately uses checked host topology and Slang GPU attribute expansion.
   Leaf-marker acceptance covers host-owned markers; GPU-authored marker ingestion
   and incremental key/link/delink orchestration remain separate integration work.
3. Run Linux Vulkan/CUDA and supported real multi-GPU peer acceptance on suitable
   hardware. This Windows machine cannot establish those completion gates.
4. Rebuild/test the final aggregate matrix and installed packages from committed
   gitlinks before declaring completion or retiring the retained reference path.

The [kernel inventory](../ethereal-samples/docs/gvdb-cuda-entry-inventory.md) records
**49 owned-validated / 14 sample-validated / 17 portable-foundation / 20 partial /
0 pending** across 100 roles. These are not completion percentages. No reference
retirement is authorized; keep the legacy sources/build path for comparison.
Future ROCm/Metal/SYCL implementations remain outside the approved backend scope.

Latest execution record: [sections/compositing](plans/2026-10-20-gvdb-sections.md).
Spray uses the public ray query and shared section renderer. The corrected section
threshold changes 32 fixture pixels; all four APIs agree. Exhaustive integer
compositing differs from legacy CUDA by at most one byte. Remaining rendering
contracts and broad consumer/platform/performance gates are active.
