# M5 ordinary gather and owned depth-map checkpoint

Status: implemented and validated on Windows, 2026-10-19. The mega project remains in progress.

Samples `dab1666` adds public ordinary density/level-set gathers with optional RGBA8 color. Private PointSet authentication proves device and dataset ownership. Stable CPU bins use actual completed conversion bytes; prepared bindings retain canonical GPU streams. Preparation records no commands and performs no readback. The existing generation ticket replaces selected channels atomically per operation, retains old snapshots, and rejects stale/foreign publication. See the [gather contract](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBNvrhiGatherApi.md).

Support coverage uses signed, phase-relative subcells, including shifted roots and root-only leaves. `supportRadius=-1` follows the distance radius; an explicit nonnegative support radius permits the existing point-fusion support2/distance1 behavior. Color includes every cell member, preserves input association/order, and retains the old initial-alpha wrapping. Empty fresh cells reset to scalar0/3 and color0; accumulation preserves exact empty-cell seeds. Active aprons preserve previous bits and unused slots become zero. These explicit corrections do not claim legacy identity for undefined/omitted cases. Normalized-ushort inverse-distance weighted color remains separate and unsupported.

The color oracle derives an interval for normalized binary32 summation/division/quantization. Its tested cases allow at most two adjacent truncation results near an integer threshold. One graphics byte differs from the CPU expression at such a boundary; CUDA matches that expression. Exact dyadic/alpha-wrap cases, preserved seeds/aprons and unused bytes remain strict. Scalar differences permit only the fixture's distance-arithmetic tolerance; NaN seed and tie preservation is exact.

Samples `ea973c9` migrates depth-map to one retained public raw snapshot, with optional explicit apron refresh recorded after import on the same command list. Graphics/CUDA texture interop, queue/timeline ordering, raster depth, composition, resize and presentation remain unchanged. A test-only structured renderer checks the original equations and imported/refreshed aprons. Strict artifact validation checks resources, constant layout, thread shape and absence of entry uniforms before rendering.

## Verification

- Final gather plus point-factory ABI/GPU regression: **10/10**, 4.84 seconds. Logs/JUnit: `build/m5-gather-final-tests.log/xml`.
- Graphics-only with CUDA Toolkit discovery disabled: **8/8**, 3.56 seconds. Log: `build/m5-gather-final-graphics-tests.log`; JUnit: `build/graphics-only/m5-gather-final-tests.xml`. Final builds are `build/m5-gather-final-{configure,build}.log` and `m5-gather-final-graphics-{configure,build}.log`.
- Independent gather support-radius four-backend/native checks pass; CUDA Compute Sanitizer reports zero errors. Logs: `build/m5-gather-api/*-support-tests.log`, `*-support-native.log`, `cuda-support-memcheck.log`. Fixtures cover signed/reversed sparse slots, inactive gaps, shifted roots, widths1/2/4/8, Float3/4, stable257-point association, separate support/distance, exact preparation budgets, scalar IEEE seeds, stale/foreign rejection and resource lifetimes.
- Gather static/shared SDK ABI tests pass **3/3** per variant; installed ABI passes **1/1** each, with compiler/toolkit discovery disabled. Installed CUDA consumers pass separately in **2.81/0.19 seconds**, including support2/distance1 farther-cell color. Logs: `build/m5-contract/gather-api-{shared,static}-*.log` and `gather-installed-{shared,static}-*.log`.
- Depth-map production/reference suite: **24/24**, 16.81 seconds; graphics-only: **12/12**, 7.81 seconds. Six native routes are clean, and three graphics/CUDA routes report zero memory errors. Logs: `build/m5-owned-depth/{aggregate-tests,graphics-tests,native-*,memcheck-*}.log`.
- Preserved previous-portable-executable and migrated depth-map Lucy/explosion PNG files are byte-identical on all six routes at160x120. Hash evidence: `build/m5-owned-depth/reference-comparison.json`. This does not replace the separately recorded tolerant legacy CUDA comparison.
- Tests-disabled/CUDA-disabled production build and DX11 analytic plus asset runs pass (`build/m5-owned-depth/production-*.log`). Shared-loader regressions in render-to-file/custom/owned raycasting pass **20/20**, 10.94 seconds, and graphics-only **15/15**, 7.50 seconds (`build/m5-owned-depth/shared-loader*-tests.log`).
- Inventory remains exactly100 retained CUDA entries with valid replacement paths:27 owned-validated,12 sample-validated,31 portable-foundation,24 partial,6 pending. Counts describe roles, not a completion percentage or retirement authorization.

These are affected-slice runs. The last full project matrix remains274/274 and graphics-only208/208.

## Next integration

Point-fusion migration requires two additional explicit options: float-based topology support and an apron boundary override independent of new-interior initialization. Existing descriptors/vtables retain compatibility; topology accepts the original32-byte prefix and defaults its new tail to legacy coverage. A separate apron factory leaves the existing voxel interface unchanged. App-only raw colored surface rendering and viewer metadata hooks will remove the sample's duplicate volume representation.

The sample retains its existing explicit scan CPU staging and validates malformed input before publication. Topology, gather and apron remain separate atomic operations; no full-frame rollback is claimed. An application may display its retained previous snapshot until the complete sequence is ready, but a later allocation failure can leave a valid intermediate owner publication.

Regional downsampling is a dense-source query, not sparse-world sampling: transform two inclusive box endpoints, preserve truncation/clamping order, Float32 sample sums and explicit CPU final division. Its public explicit-completion adapter remains future work, along with scatter, voxelization, weighted ushort color and remaining consumers. Linux, real multi-GPU routes, broader interactive/legacy visual/performance acceptance and reference retirement remain open.
