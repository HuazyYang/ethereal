# M5 voxel filters and dense rebuild checkpoint

Status: implemented and validated on Windows, 2026-10-19. The [ownership project](2026-10-18-gvdb-unified-volume-ownership.md) remains in progress.

Samples `e86757f` adds private transactional dense topology replacement. A complete candidate determines the new leaf set, including subset-only removal and an empty result. Signed spatial origins preserve surviving channel interiors across reordered pools and changed atlas pitches/aprons. New regions use channel defaults; full-channel uploads override preservation. Preparation deep-copies the candidate, and publication swaps within the stable host object after command recording. Full rebuild advances the host epoch and invalidates cached node IDs. Append-preserving accumulation is a separate follow-up. Metadata retention is explicit.

Samples `aad8fff` adds Smooth, Grow, Noise, Cut, ExpandByte and ExpandColor, plus the additive `IGVDBVoxelFilters` factory in the existing static/shared API package. Existing volume and voxel-operator vtables remain unchanged. Each iteration reads a stable source, filters interiors, then optionally updates aprons. There is no initial apron update. Both retained skip settings effectively filter interiors. Only the selected channel receives a new allocation/revision; old snapshots and prepared resources remain usable after owner release. See the [core equations and restrictions](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBNvrhiVoxelFilters.md) and [public usage](../../ethereal-samples/src/gvdb_samples/gvdb/GVDBNvrhiVoxelFilterApi.md).

Deliberate corrections/extensions include deterministic separate source/destination filter passes instead of legacy in-place races, vector float Smooth, full-vector boundary values and checked integer conversion bounds. Preparation currently accepts at most 4096 iterations. Unsupported stencil work without aprons fails explicitly. Zero iterations return an authenticated one-use no-op without GPU allocation. No operation submits or waits internally.

## Validation

- Integrated affected suite: **47/47**, 16.98 seconds, D3D11/D3D12/Vulkan/CUDA. Full build passed. Logs: `build/m5-filter-dense-{configure,build,tests}.log`, JUnit `build/m5-filter-dense-tests.xml`.
- Graphics-only affected suite: **37/37**, 15.07 seconds, with CUDA Toolkit discovery disabled. Full graphics build passed. Logs: `build/m5-filter-dense-graphics-{configure,build,tests}.log`, JUnit in `build/graphics-only/`.
- Private core/public filter fixtures passed all four backends, native graphics validation on all three graphics APIs, and CUDA Compute Sanitizer with zero errors. Logs: `build/m5-filters/` and `build/m5-contract/filter-api-*-{smoke,validation}.log`, `filter-api-memcheck.log`.
- Static/shared package ABI tests each passed 2/2; installed public/concrete link consumers each passed 2/2 with SDK/compiler discovery disabled; installed CUDA consumers each passed 1/1. Evidence: `build/m5-contract/filter-api-{shared,static}-*.log` and `filter-installed-{shared,static}-*.log`.
- Dense adoption fixtures passed all four backends, native graphics validation and CUDA memcheck with zero errors: `build/m5-dense-adoption/{dx11,dx12,vk}-native.log`, `cuda-memcheck.log`.

Independent oracles cover all five channel formats, imported non-dense slots and poison bytes, rebuilt interiors/aprons/unused slots, subset/empty replacement, full upload overrides, leaf-width compatibility, stale host/base tickets, allocation failure, metadata retention/drop and deferred readbacks after owner destruction. Filter tests include isolated byte-seed propagation, immutable NaN/signed-zero apron bytes, explicit iteration/bias equations, deterministic Noise values, Cut thresholds, expansion normalization/byte wrapping/alpha, channel31 isolation and public ABI failures.

Remaining work includes authenticated append-preserving topology candidates, public point/gather/scatter and voxelizer factories, resample/reduction/custom-program adapters, consumer ownership migration, Linux execution, real multi-GPU validation and performance/reference-retirement gates. This checkpoint is not a complete mega-project result.
