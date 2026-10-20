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

Latest committed samples implementation: `3864daf`. Runtime dependencies: NVRHI `2c06d77`,
Donut `c7ca1b2`, nested shader-tool `15b6ab0`. The aggregate gitlinks are authoritative.
An external handoff checkpoint also committed intermediate work during the session;
those commits were preserved without rewriting history.

## Validation evidence

The [status record](slang-next-status.md) and linked execution plans distinguish
historical full matrices from later focused validation. Latest completed full
matrices at aggregate `5d22ac4` are **433/433 Windows** (239.42 seconds) and
**326/326 graphics-only** (221.51 seconds), without CTest skips. Both used clean
sources at committed parent gitlinks. Installed NVRHI consumers pass static 2/2
and shared 1/1; installed GVDB ray consumers pass static/shared 2/2 each. Focused
slice history:

| Slice | Affected Windows tests | Graphics-only | Installed static/shared |
| --- | ---: | ---: | --- |
| Scalar-grid queries | 25/25 | 4/4 | 2/2 each |
| Point insertion | 30/30 | 8/8 | 2/2 each |
| Coordinate splitting | 25/25 | 4/4 | 2/2 each |
| Leaf markers | 16/16 | 4/4 | 3/3 each |
| Public ray records and spray | 24/24 | 19/19 | 2/2 each |
| Shared sections and compositing | 23/23 | 18/18 | No public ABI change |
| Shared modes and matched scene | 23/23 plus 36/36 | 18/18 | No public ABI change |

Each slice passed native D3D11/D3D12/Vulkan validation on both graphics adapters
and CUDA Compute Sanitizer with zero errors. Logs are local build artifacts under
`build/m5-public-subcells`, `build/m5-grid-query`, `build/m5-point-insertion` and
`build/m5-point-split` and `build/m5-leaf-markers`; execution summaries and
reproducible tests are committed.
The latest full runs include all slices above. Machine-readable reports and logs
are under `build/acceptance/windows-layers-final` and `build/acceptance/graphics-layers-final`. The local
matrix does not require a real CUDA peer pair; that external gate remains open.

## Next work and open gates

1. Complete broader legacy scene comparisons. Ordered multi-volume composition
   is now adopted by render-to-file, with matched two-instance captures.
   Shared sections and individual shading modes now have explicit
   controls, analytic checks and matched explosion captures. Shared
   mixed DXR/Vulkan/OptiX rendering exists but is not complete legacy parity.
2. Resolve remaining linking/GPU-key/algorithm integration roles and record broad
   timing/memory comparisons separately from correctness. Current point association
   deliberately uses checked host topology and Slang GPU attribute expansion.
   GPU-authored markers now pass through private fixed-pool editing, validated
   fetch and transactional publication. Fixed-pool marker/delink/relink
   orchestration is also validated. GPU key-driven new-node allocation and
   compaction remain separate integration work.
3. Run Linux Vulkan/CUDA and supported real multi-GPU peer acceptance on suitable
   hardware. This Windows machine cannot establish those completion gates.
4. Rebuild/test the final aggregate matrix and installed packages from committed
   gitlinks before declaring completion or retiring the retained reference path.

The [kernel inventory](../ethereal-samples/docs/gvdb-cuda-entry-inventory.md) records
**49 owned-validated / 23 sample-validated / 17 portable-foundation / 11 partial /
0 pending** across 100 roles. These are not completion percentages. No reference
retirement is authorized; keep the legacy sources/build path for comparison.
Future ROCm/Metal/SYCL implementations remain outside the approved backend scope.

Latest execution record: [shared rendering modes](plans/2026-10-20-gvdb-render-modes.md).
Matched 1024x768 explosion captures pass documented tolerances on all four APIs;
three-run process timings and logical storage are separate from correctness.
`tools/run-slang-acceptance.py` checks coverage and fails on skipped tests.
The NVRHI required-peer mode now fails on missing/unsupported pairs; its local
single-adapter negative check passes, while actual peer success remains unproved.

Fresh mixed-RT comparisons found and corrected level-set sampling phase and
hierarchy-entry bias. Expanded three-backend tests, both native RT graphics
adapters and CUDA memory checking pass. The [mixed RT investigation](plans/2026-10-20-gvdb-mixed-rt-reference.md)
distinguishes the legacy zero-gradient NaN failure from the remaining empty-skip
image difference. Those visual gates remain open. The latest matrices include
this correction and the updated interactive application distance expectations.

[Ordered volume layers](plans/2026-10-20-gvdb-volume-layers.md) now cover scene-order
rendering, first/later background and Off behavior, per-mode alpha, GPU packing
and diagnostics. Focused Windows 40/40, graphics-only plus RT 32/32, six native
graphics runs and CUDA memory checks pass. All 32 single-volume images are
unchanged; all eight translated two-explosion modes pass documented comparison
limits on four APIs. Section/compositing roles are sample-validated. The strict
runner now requires the new layer algorithm and production-application tests.

[Private GPU topology fetch](plans/2026-10-20-gvdb-device-topology-fetch.md) now
exposes an additive installed factory. Actual GPU markers, retained source bytes,
graph validation, stale host/channel/publication rejection and explicit caller
completion pass four APIs. Focused owner/point tests 14/14, adoption/accumulation
8/8, graphics-only 11/11, native adapters 6/6 and CUDA memory checks pass;
installed static/shared consumers pass 2/2 each. The 433/326 full matrices predate
this API. Linking remains foundation until incremental orchestration is integrated.

[Fixed-pool topology activity](plans/2026-10-20-gvdb-topology-activity.md) now
orchestrates all five topology kernels through an additive installed factory.
Inactive nodes are reconnected after bottom-up activity derivation. Exact CPU
oracles cover ten levels, 257-leaf tail dispatches, repeated deactivate/reactivate
cycles, signed geometry, empty/root-leaf cases, budgets and stale revisions.
Focused topology/compute **9/9**, native graphics **6/6**, CUDA memory **zero
errors**, graphics-only **11/11**, installed static/shared **2/2 each** pass.
Distinct immutable constant ranges fix an observed NVIDIA D3D12 update failure;
shader marker offsets avoid Vulkan storage-view alignment restrictions. GPU
key-driven growth and compaction are still open. Full 433/326 matrices predate this.
