# Slang-next implementation status

The agreed scope and acceptance gates are in [the archived plan](plans/2026-10-18-ethereal-nvrhi-slang-support.md). This is an implementation checkpoint, not a completion claim. See [build and run instructions](slang-next-build.md).

## Workspace and references

Root, NVRHI, Donut, samples, and nested shader-tool have linked worktrees on `slang-next` in `D:/ps/repo/ethereal-slang-next`. The original checkout's local edits are preserved. Commit `431a68a` archives the plan and exact starting revisions.

The first implementation checkpoint records shader-tool `15b6ab0`, Donut `8e922b4`, NVRHI `0cb60f1`, and samples `2f7057b`. All **77 configured Release CTests passed** on Windows, in 35.50 seconds. Results are in `build/checkpoint-tests.log` and `build/checkpoint-tests.xml`. The expanded GVDB CUDA suite also passed Compute Sanitizer with zero errors (`build/gvdb-extended-memcheck.log`).

The original checkout's existing test suite passed 26/26. Its legacy render-to-file executable rendered explosion.vbx at 1024 x 768 in 7.121 ms, reporting 40.04 MiB atlas and 1.75 MiB topology. Logs, CTest XML and the image are under build/baseline. This is an existing executable reference, not a fresh rebuild of the selected source revision. New renderer timings include readback and use different camera framing, so they are not a performance comparison.

The second local checkpoint passed **102/102 Release CTests** in 46.44 seconds. The complete matrix was rebuilt before the run; logs and JUnit are in build/checkpoint-2-tests.log and build/checkpoint-2-tests.xml. The public graphics export implementation is committed as NVRHI a3b261b, Donut e5cdf7d enables the supported Vulkan DrawParameters feature required by Slang vertex-ID shaders, and samples fd5fb55 records the viewer/resample/3d-print migration. After precision-bound and test-oracle review fixes, all 25 affected tests passed again in 13.75 seconds (build/review-regressions-tests.log).

The third checkpoint passed **130/130 Release CTests** in 59.55 seconds after a complete rebuild. NVRHI `3d8711a` fixes odd-sized D3D11/CUDA sharing with unkeyed NT handles, Donut `c7ca1b2` enables requested Vulkan depth clipping, and samples `a310bb5` migrates depth-map and persistent point-fusion. Results are in `build/checkpoint-3-tests.log` and `build/checkpoint-3-tests.xml`. The complete graphics-only build, with `CMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE`, passed **98/98 CTests** in 53.64 seconds (`build/checkpoint-3-graphics-tests.log/xml`). Separate static/shared native-handle lifetime regressions passed 4/4.

The retained source was freshly built in `build/legacy-reference` for render-to-file, depth-map and point-fusion. The default 1024 x 768 DX12/CUDA depth-map capture matches the migrated image to a mean RGB difference of 0.005712 on the 0-255 scale; 0.157% of pixels differ by more than one level, with a maximum channel difference of 57. Captures are `build/depth-map-legacy.png` and `build/depth-map-new.png`. This establishes a tolerant depth-map comparison, not performance or complete GVDB image parity.

## Implemented and exercised

- Shader-tool uses Slang sessions/components to produce DXBC, DXIL, SPIR-V, CUDA PTX and OptiX PTX artifacts. A separate artifact library loads metadata without compiler SDKs. Binding shifts, native entry symbols, actual CUDA parameter ABI, explicit texture/sampler pairings, array/matrix reflection and shader-record scope have regression coverage.
- NVRHI exposes CUDA as a backend and loads artifacts through IShaderProgram. Donut's ShaderFactory consumes the same artifacts. Existing raw shader paths remain available. The public API version is 30. Installed static and shared packages have external-consumer checks; a shared consumer configures with compiler and CUDA SDK discovery disabled.
- CUDA uses the Driver API for resources, command replay, streams, events, dispatch, sampling, and OptiX acceleration structures/pipelines. GPU tests cover triangles, procedural geometry, updates, compaction, local shader records, multiple materials, geometry pre-transforms, cloning, and retained lifetimes.
- The same triangle/procedural material scene passes on D3D12, Vulkan RT and OptiX, including local shader records, cached/uncached shader tables, and retained resources. Native D3D12/Vulkan validation and CUDA sanitizer runs are clean. Vulkan local shader records currently support nonvolatile constant-buffer device addresses; other local resource types fail explicitly.
- Native Windows import tests exercise D3D11 shared textures/keyed mutexes, D3D12 placed heap offsets/fences, and Vulkan external memory/timeline semaphores/ownership transitions. Imported handles can be closed by callers after import. Unsupported peer paths fail explicitly. Public graphics-side exports now expose owned resources, adapter route checks, GPU timeline fences and explicit ownership transfer through nvrhi::interop. Three graphics-to-CUDA-to-graphics round trips pass on D3D11/D3D12/Vulkan with clean native validation and CUDA memory checks; no host wait occurs between API submissions. Native handle ownership and pending D3D11 event-query regressions pass in static/shared builds. [Usage and restrictions](../ethereal-nvrhi/docs/graphics-interop.md) are documented.
- Representative graphics tests pass: basic_triangle on D3D11/D3D12/Vulkan, rt_triangle on D3D12/Vulkan, shader_specializations on Vulkan. Headless compute passes on all four APIs.
- Portable GVDB has 62 compute entries compiled for all four APIs: scan, stable two-word 64-bit radix sort, NaN-aware reduction, topology, scalar and raw atlas operators, sparse raycast, particle/SPH, point keys and fusion, solid voxelization, MAC/PIC-FLIP transfer, subcell binning, and packed point conversion. Independent CPU references cover tail groups, odd packed lengths, nonfinite values, negative coordinates, and repeated simulation steps.
- Standalone VBX loading does not initialize CUDA. Scalar and raw APIs round-trip the real explosion asset and all five channel formats. Raw VBX supports ordered multiple channels with preserved transform and atlas slots; compression, multiple grids and topology reuse remain explicitly unsupported.
- CPU topology construction builds validated sparse hierarchies and scalar atlases/aprons. GPU scalar resampling, downsampling, interior reduction, voxelization, velocity transfer, subcell fusion and packed conversions pass on all four APIs. PIC/FLIP transfer is implemented; particle-to-grid transfer and pressure projection are not.
- Procedural GVDB ray tracing passes analytic volume/surface/shadow, clipping, transformed-instance, update, miss and shared-atlas tests on D3D12, Vulkan RT and OptiX.
- Rewritten render-to-file runs on all four APIs. Its 128 x 96 explosion outputs differ by at most one 8-bit channel value across backends.
- Rewritten render-kernel preserves the custom first-threshold-hit wavefront shader and diffuse/reflected-sky formula. Eight real-asset/analytic tests pass across four APIs; outputs agree to one 8-bit channel value.
- Rewritten sph_fluid_pool runs the complete SPH sequence and four original presets through NVRHI. Four application smoke tests pass. Graphics modes render simulation buffers directly and provide the Inspector, optional GPU timing, orbit/pan/zoom, pause and deferred reset; CUDA runs headless. Native GUI/input tests pass on all three graphics APIs. The original scene graph, fixed camera, one-pixel depth-tested points and ground grid remain in the legacy implementation; exact presentation parity is outstanding.
- Rewritten resample preserves RAW byte/256 conversion, the original transformed/truncated coarse box behavior, sparse activation and a six-face halo. All coarse values and every atlas/apron voxel match independent CPU references. The corrected legacy configuration uses 16-voxel leaves: the head asset has 4,096 dense, 2,472 sparse and 2,997 halo leaves. Eight analytic/asset tests pass on all four APIs. GPU sum/count output and a correctly rounded host division keep exact-threshold topology decisions consistent with the reference; the direct GPU average entry remains available.
- Rewritten 3d-print preserves Lucy's model-to-index transform, four voxel sizes and surface/interior values. Its signed-origin fixtures cover dense classification, sparse atlas/aprons and exact section pixels. At 0.5 mm the original asset produces 47 corrected 32-voxel bricks, 56,839 surface and 131,750 interior voxels. Eight analytic/asset tests pass; the complete leaf set is checked against an independent partition of occupied dense voxels.
- The shared volume viewer renders directly from the GPU result buffer. It provides volume/surface/voxel/section modes, an inset, topology overlays, orbit/pan/zoom/light controls and headless rendering. Independent tests cover section interpolation/blending, distant voxel traversal, odd image/inset dimensions, topology, and presentation value/orientation. Native graphics validation is clean; CUDA memory checks pass for the viewer and both new applications.
- Rewritten depth-map rasterizes Lucy, clips sparse explosion integration with raster depth, and composites through offline Slang on D3D11/D3D12/Vulkan with graphics compute or CUDA. The CUDA path shares textures and GPU timeline fences through public NVRHI interfaces; normal frames have no CPU waits or staging. Twelve analytic/asset CTests pass. Six native-validation runs and six CUDA sanitizer runs across depth-map/public sharing report zero errors. D3D11 now exports unkeyed NT handles; known-faulty odd-sized KMT exports are explicitly rejected while low-level import compatibility remains.
- Rewritten point-fusion scans all 3,028 original city boxes and incrementally preserves scalar/color atlases through topology relocation. Twelve helper/input/city tests pass on all four APIs. Two 240 x 180 scans produce 68,158 hits and 716 corrected 32-voxel support leaves; the final 128 x 96 image has 9,185 finite surface pixels on all four APIs. D3D11 matches D3D12 exactly; Vulkan differs by at most one byte in four pixels and CUDA in 24 pixels. The complete matrices pass; the corrected two-scan CUDA application also passes Compute Sanitizer with zero errors. CPU topology/subcell construction and portable lighting differences remain explicit.
- The viewer now supports explicit view-Z camera clipping, level-set background and raw color, scene overlays/input, and bounded window captures. Shared clipping also covers the procedural RT path; analytic tests cover off-axis near/far planes, large coordinates, section projection and invalid modes.
- The complete isolated graphics-only matrix passed 146/146 tests with CUDA discovery disabled, including depth-map graphics compute, point-fusion and the new mixed-scene applications. No CUDA SDK is required by these portable targets.

- The mixed mesh/volume renderer now executes the retained material, environment, shadow, reflection/refraction and deep-continuation behavior through one Slang library on D3D12, Vulkan RT and OptiX. Resource-array probes and independent optical equations pass. Camera clipping, retained resources, replacement, resize and sample reset have regressions.
- Portable interactive-optix, point-cloud and fluid-surface applications are implemented, including original assets, Inspector controls, bounded captures and headless rendering. Point-cloud reconstruction has 14,583 corrected 16-voxel leaves. The full fluid preset retains 1.5 million SPH particles and the legacy initial 196-brick bounds. A retained CUDA texture read-mode defect caused the old fluid colors to differ. An isolated probe measured the wrong returned bytes; correcting the reference descriptor restored its color gradient. The portable path uses the intended normalized RGBA8 values.
- Native Inspector tests verify visible/hidden draw geometry, input capture and forwarding, exception cleanup and window recreation on D3D11/D3D12/Vulkan. These inspect the real GUI pass, separately from scene-buffer screenshot comparisons.

## Current review corrections

The fourth checkpoint records samples `ff43b9a` and passed **196/196 Release CTests** in 133.16 seconds and **146/146 graphics-only CTests** in 156.14 seconds with CUDA Toolkit discovery disabled. Logs and JUnit are `build/checkpoint-4-tests.log/xml` and `build/checkpoint-4-graphics-tests.log/xml`. Eight fluid analytic/topology cases passed again after strengthening the color fixture. After the final resample artifact-binding correction, all 14 affected full/graphics-only tests passed and the original entry retained its b0/t0/u0 bindings on every backend. Both complete builds passed again. CUDA Compute Sanitizer reported zero errors for corrected resample, print, point-cloud reconstruction and compute/RT applications, point-fusion, fluid and the mixed-scene renderer. Corrected point-cloud windows and Inspector tests passed native validation on D3D11/D3D12/Vulkan. Logs include `build/resample-binding-audit.log`, `build/corrected-*-memcheck.log`, `build/checkpoint-4-*-memcheck.log`, and `build/gui-native-*.log`. Comparison with freshly rebuilt
legacy executables exposed reversed `fromBranching(r4,r3,r2,r1,r0)` arguments in
several sample adapters. Portable configurations are leaf-first: point-cloud and
resample require 16-voxel leaves; fluid, point-fusion, print and spray require
32-voxel leaves. The earlier test counts remain historical execution results,
but their 8-voxel topology counts do not establish legacy configuration parity.
Corrected fixtures now check explicit legacy dimensions and independently
classified leaf sets. The corrected asset counts are recorded above. Historical results are retained as execution records rather than configuration-parity claims.

The [public volume ownership plan](plans/2026-10-18-gvdb-unified-volume-ownership.md)
records the remaining M5 integration. The legacy fluid samples use SPH. No full
FLIP solver was found in the retained sources; particle-to-grid transfer and
pressure projection are future functionality, not a legacy-parity requirement.

## Subsequent CPU ownership and SPH checkpoint

Samples `b0e9af3` adds the SDK-independent mutable host volume and ownership
value types. It preserves node allocation order and IDs, validates manual graph
edits, handles empty/inactive volumes, supports region/mask/value selection and
simultaneous six-face halo activation, and rolls back failed edits. Signed
cross-zero root growth and containing-root promotion correct retained defects.
Standalone CPU tests pass 2/2 with clean AddressSanitizer; integrated graphics-only
CPU tests pass 2/2 in 0.28 seconds with CUDA Toolkit discovery disabled. Logs are
`build/m5-contract/` and `build/m5-host-graphics-tests.log`. See the
[host ownership execution record](plans/2026-10-18-gvdb-host-volume-step-b.md).

Samples `6a71ef4` restores the SPH Inspector and mouse controls, defers resets out
of GUI callbacks, and bounds windows by rendered frames even while paused.
Seven full-build SPH tests pass in 4.63 seconds; six isolated graphics-only SPH
tests pass in 3.26 seconds with clean native validation. Evidence is in
`build/sph-inspector-tests.log/xml`, `build/sph-inspector-native-detail.log`, and
`build/sph-inspector-graphics-tests.log`. These are affected-slice results, not a
new complete matrix run. GPU multi-channel ownership and spray acceptance remain
in progress and are not included in these two sample commits.

## Fifth checkpoint: owned volumes, public API and spray

The [execution record](plans/2026-10-18-gvdb-volume-owner-api-checkpoint.md) records
NVRHI `e4a0e68` and samples `7959786`, `0c94cd5`, and `b47d4d5`. The complete
Release matrix passed **231/231** in 194.07 seconds; the final graphics-only
matrix passed **175/175** in 153.75 seconds with CUDA Toolkit discovery disabled.
Final input/overlay and import changes passed their affected checks; the record
also retains the corrected test-baseline failure rather than hiding it.

The additive owner now publishes one topology and up to 32 raw channels through
caller-owned NVRHI command lists. All five formats preserve compatible interiors
across atlas growth/repacking, while retained snapshots/readbacks survive owner
destruction. The queryable public API has new IIDs, a versioned C factory, and
static/shared installed-consumer coverage. Four-backend owner/API fixtures,
native graphics validation and CUDA memory checks pass. Installed static/shared
consumers each pass 3/3 including actual CUDA lifetime/readback. CPU topology
import passes standalone AddressSanitizer and the real explosion VBX fixture.

Spray-deposit now implements fixed-topology deposition, original ray generation,
five shading modes, Inspector and controls through Slang/NVRHI. Its 19 tests,
native-window checks and CUDA memory checks pass. Final captures are byte-identical
across four backends; the fresh legacy comparison has RGB mean error 0.392708/255,
with explicit fine shading/rasterization differences. The shared viewer now
blends translucent overlays and distinguishes held movement from press-only actions.

## Owned-volume voxel operators

Samples `d00cfc1` adds public fill/clear/copy/apron preparation through the same
owner publication route. Selected channels change allocation/revision; old
snapshots and unchanged topology/channels remain retained. No-op tickets remain
authenticated and one-use. Five-format independent byte fixtures and lifetime,
stale-ticket, failure and repack tests pass on all four APIs. Native graphics
validation and CUDA memory checks are clean.

The affected aggregate checks pass **19/19** (7.98 seconds); the graphics-only
checks pass **15/15** (5.94 seconds) with CUDA SDK discovery disabled. Installed
static/shared packages each pass two CPU consumers and a real CUDA consumer,
including cross-DLL publication/readback after owner destruction. This is an
affected-slice checkpoint, not a repeated complete matrix. See its
[execution record](plans/2026-10-18-gvdb-voxel-api-checkpoint.md).

## Transactional VBX import and coherent save

Samples `d522c84` adds exact host/atlas import and public serializer/save-ticket
interfaces. The same publication path atomically adopts prepared CPU topology,
original slots and all logical channel bytes. Save freezes topology, metadata
and channels from one retained generation and completes after the caller waits,
including after owner destruction. Metadata survives mutations/repacking and
stays associated with old snapshots across later imports.

The affected matrix passed **34/34** (11.70 seconds), and **27/27** (10.19 seconds)
in the graphics-only build with CUDA Toolkit discovery disabled. Native graphics
validation and both CUDA memory checks are clean. Static/shared installed
consumers exercise actual save/load across the package/DLL boundary. Synthetic
five-format and real explosion cases preserve exact channel bytes and original
slots. See the [execution record](plans/2026-10-18-gvdb-vbx-transaction-checkpoint.md)
for initial fixture corrections and supported-format/budget limits.

Dense candidate rebuild/accumulate, remaining voxel families, public point and
voxelizer factories, and helper/sample ownership migration remain unfinished.

## Raw point-stream conversion

Samples `a1fea31` adds byte/ushort/float/double raw conversion with arbitrary
strides and offsets, one to four components, and preserved interleaved fields.
All 16 encoding pairs and rounding/guard/association fixtures pass: **4/4**
aggregate tests and **3/3** graphics-only tests. Native validation and CUDA memory
checks are clean. Arithmetic uses binary32; double output widens the result.
This descriptor/shader slice does not complete public point factories or volume
publication. See its [execution record](plans/2026-10-19-gvdb-point-conversion-checkpoint.md).

## Voxel filters and dense topology replacement

Samples `e86757f` and `aad8fff` add transactional dense candidate replacement and
six public owned-volume filters. Rebuilds preserve surviving interiors by signed
origin, remove absent leaves even without additions, and support an empty result.
Rebuilds advance the host epoch; append-preserving accumulation remains separate.
Filters retain the legacy equations and filter-then-apron schedule with deterministic
separate source/destination passes. Existing public vtables remain unchanged.

The integrated affected suite passed **47/47** (16.98 seconds), and graphics-only
passed **37/37** (15.07 seconds). Native graphics validation, CUDA memory checks,
and installed static/shared consumers pass. See the [execution record](plans/2026-10-19-gvdb-filters-dense-rebuild-checkpoint.md).

The [retained CUDA entry inventory](../ethereal-samples/docs/gvdb-cuda-entry-inventory.md)
accounts for 100 explicit kernels and records each remaining replacement gate.
Its categories are not a completion percentage or authorization to retire references.

## Stable-ID accumulation and first owned renderer

Samples `ca793cc` adds authenticated append-only topology candidates that preserve
existing IDs/epochs, channel interiors and metadata across root growth and inactive
leaf reactivation. Full replacement remains a separate epoch-changing path.
Samples `b2f1185` moves render-to-file onto public serializer/volume snapshots,
binding the raw atlas directly and releasing the owner before rendering.

The full suite passed **274/274** (192.83 seconds); final renderer guard checks
passed **4/4**; the final graphics-only suite passed **208/208** (157.88 seconds).
Private native validation and CUDA memory checks are clean. Owned-renderer color
and depth exactly match the previous portable renderer, including explosion volume
and surface images. A fresh tests-disabled, CUDA-disabled production build and
DX11 execution also pass. See the [execution record](plans/2026-10-19-gvdb-append-render-checkpoint.md).

## Public points, reduction and custom owned rendering

Samples `f18a6b9` adds owned point conversion and transactional signed rebuild/accumulation,
including attribute association, converted XYZ bounds, stable append IDs and CPU pool-limit rollback.
Samples `4d0ee12` adds retained-snapshot R32 reduction with explicit completion, active-interior
traversal and documented placement-dependent float-column arithmetic. Existing public vtables
remain unchanged. Samples `8727803` moves the custom renderer to owned snapshots and checks its
complete raw shader ABI before output allocation. The inventory update is `18c9396`.

The affected suites passed **75/75** (29.98 seconds) and **58/58** graphics-only (24.80 seconds),
with CUDA Toolkit discovery disabled for the latter. Public ABI checks passed **6/6**.
Private native graphics validation and CUDA memory checks are clean; installed static/shared
point and reduction consumers pass. Custom color/depth exactly match the previous portable
renderer, including all 6,144 explosion pixels. A tests-disabled production build and DX11
runs pass. See the [execution record](plans/2026-10-19-gvdb-public-points-reduction-custom-checkpoint.md).
Owned resampling and depth-map consumer migration are the next active slices.

## Acceptance still outstanding

| Milestone | Remaining work |
| --- | --- |
| M0 | Broader deterministic legacy references and controlled performance comparisons |
| M1 | Additional compiler reflection edge cases and Linux package execution |
| M2 | Wider texture/view/error coverage and Linux CUDA execution |
| M3 | Broader mixed-scene edge cases, legacy visual comparisons and platform validation |
| M4 | Linux external-memory run and real multi-GPU peer transfer |
| M5 | Remaining voxel/point/voxelizer adapters and consumer ownership integration and expanded data compatibility |
| M6 | Owned-volume adoption, complete interactive behavior, Linux matrix, production legacy removal and performance comparisons |

Spray-deposit completes the remaining executable rewrite; public ownership adoption and the broader acceptance gates remain in progress. Fluid reference comparisons now document the retained CUDA color-read defect and remaining stochastic differences. The archived plan's eleven sample directories include sample-utils; sph_fluid_pool is separate. The [mixed mesh/volume renderer](plans/2026-10-18-mixed-scene-slang-rt.md), point-cloud and fluid work belong to the current validation slice and are not part of the historical 130-test checkpoint.

The new resample/3d-print viewer frames active index bounds. Its section plane uses normalized data height, and the inset scales with the output. The original fixed camera/section mapping and ImGui presentation are retained in legacy-main.cpp; matching legacy screenshots or performance is not claimed.

Local hardware is Windows x64 with one NVIDIA RTX 4050 Laptop GPU (driver 617.42). CUDA 12.9, OptiX 9.0, and Slang 2026.10.2 are the tested toolchain. No Linux execution or real multi-GPU success is claimed.

Production migration is incomplete. The preserved reference implementations use donut::gp, handwritten CUDA, and their original host interfaces. They are gated by ETHEREAL_BUILD_GVDB_LEGACY; portable targets are gated separately by ETHEREAL_BUILD_GVDB. References remain available until replacements pass their acceptance gates.

## Owned resampling checkpoint (2026-10-19)

Samples `1b6a26c` adds public transactional dense-to-sparse R32 resampling with exact outside-value preservation and explicit caller publication. Final ABI/four-backend tests pass **5/5** and graphics-only **4/4**; native graphics validation, CUDA memory checking and static/shared installed consumers pass. Source NaN/infinity, transformed signed/extreme coordinates, old snapshot lifetime and budget/stale rejection are covered. See the [resample execution record](plans/2026-10-19-gvdb-owned-resample-checkpoint.md). These are affected-slice results, not a new full-matrix run. Depth-map adoption and public ordinary gathering remain in progress; weighted ushort gathering and broader platform/consumer gates remain open.

## Ordinary gather and owned depth-map checkpoint (2026-10-19)

Samples `dab1666` adds public ordinary point gathering with stable authenticated bins, signed/shifted topology, separate support/distance radii and selected-channel publication. Final gather/point regression passes **10/10**, graphics-only **8/8**, and native/memory/static/shared installed checks pass. Samples `ea973c9` migrates depth-map to public snapshots: **24/24** tests and graphics-only **12/12**, with exact old/new portable captures on all six routes. Shared-loader regressions pass **20/20** and graphics-only **15/15**. See the [execution record and remaining compatibility work](plans/2026-10-19-gvdb-gather-depth-checkpoint.md). The full project/platform acceptance gates remain open.

## Point support, apron overrides and owned surfaces (2026-10-19)

Samples `750d7cb`, `a8105e1` and `f643cab` add compatible float support coverage,
per-call apron boundary values and raw colored surface rendering with snapshot-only
viewer metadata/overlays. Both complete builds and matrices pass: **319/319**
(217.49 seconds) and **240/240** graphics-only (178.18 seconds), with no skips.
Native validation, CUDA memory checking, static/shared installed consumers and
tests-disabled graphics production checks pass. See the [execution record](plans/2026-10-19-gvdb-point-apron-surface-checkpoint.md).
Point-fusion consumer migration and dense regional downsampling are the next slices;
platform, broader consumer and reference-retirement acceptance remain open.

## Owned point-fusion and snapshot viewer (2026-10-19)

Samples `61efa21`, `2996733` and `2f41413` fix batch root enclosure, migrate
point-fusion to public ownership/operators and add snapshot voxel/section/inset
viewing. Point-fusion passes 12/12 with exact previous-portable city captures on
all four APIs; native validation and CUDA memory checking pass. Raw views pass
all four backends, affected regressions and tests-disabled graphics production.
The [execution record](plans/2026-10-19-gvdb-owned-point-fusion-view-checkpoint.md)
retains the diagnostic-string regression, production image tolerance and current
downsample boundary issue. The last complete matrices remain 319/319 and 240/240.
This machine also exposes an AMD Radeon 780M graphics adapter alongside its RTX
4050 CUDA device; automatic adapter selection must be recorded explicitly for
cross-build comparisons. No supported native multi-GPU peer route is claimed.

Public regional downsample is committed in samples `dc3a118`; NVRHI `689f89e`
rejects unsupported declared SPIR-V rounding modes. Exact endpoint division and
explicit Vulkan RTE32 resolve the NVIDIA/AMD differences recorded above. All six
explicit graphics adapter/API combinations pass native validation, and CUDA
memory checking is clean. Complete matrices pass **329/329** and **248/248**;
installed shared/static CUDA consumers pass. The [checkpoint](plans/2026-10-19-gvdb-public-downsample-checkpoint.md)
records contracts, hardware findings and evidence. Resample ownership migration
is in progress; no legacy reference retirement is authorized.

Samples `643cdaa` moves the resample application onto public query/topology/halo,
owned publication and snapshot viewing. Independent data/lifecycle references,
both graphics adapters with native validation, CUDA memory checks and a
tests-disabled production build pass. Final complete matrices pass **329/329**
and **248/248**, with no skips. Previous-portable head images differ by at most
one byte in two or three pixels; production matches explicit AMD DX11 exactly.
See the [consumer checkpoint](plans/2026-10-19-gvdb-resample-consumer-checkpoint.md).
3d-print ownership is in progress; public mesh voxelization remains separate.

Samples `7b2d555` migrates 3d-print publication and viewing to public owned
snapshots. Affected matrices pass **20/20** and **15/15**, both graphics adapters
pass native analytic/Lucy validation, CUDA memory checks are clean, and all four
Lucy images exactly match their previous-portable references. Tests-disabled
production also passes. The [checkpoint](plans/2026-10-19-gvdb-print-ownership-checkpoint.md)
records evidence and the next public mesh-voxelizer contract. Its existing
portable voxelizer helper remains explicit; this does not complete the operator
or authorize reference retirement. The preceding full matrices remain 329/329
and 248/248 and precede this ownership slice.


## Public mesh voxelizer and completed 3d-print operator migration (2026-10-19)

Samples `c6bbd34` adds the public device-only two-phase mesh voxelizer and moves
3d-print onto explicit count/sizing/classification recording and completion.
Exact geometric division fixes an AMD DX11 integer-face omission; both graphics
adapters pass native validation and 4,131 compiled division bit goldens. CUDA
memory checks, installed static/shared API consumers and tests-disabled graphics
production pass. All four Lucy captures exactly match preserved portable images.
Complete matrices pass **334/334 (440.40 seconds)** and **252/252 (319.66 seconds)**,
with no skips. See the [execution record](plans/2026-10-19-gvdb-public-voxelize-checkpoint.md)
for contracts, logs, numerical limits and the next point-cloud dependency:
subcell association must remain based on positions before quantization.
The 100-entry inventory now has 31 owned-validated, 12 sample-validated,
27 portable-foundation, 24 partial and 6 pending roles. Weighted ushort color,
scatter, remaining ownership consumers, Linux, supported native multi-GPU routes,
broader interactive/visual/performance gates and reference retirement remain open.


## Owned point-cloud and separate gather evaluation (2026-10-19)

Samples `ab85dff` adds queryable separate association/evaluation positions and
migrates point-cloud topology, gather, aprons, smoothing and viewing to public
owners/snapshots. The mixed RT renderer consumes raw channels directly. Both
complete Windows matrices pass **334/334 (226.93 seconds)** and **252/252
(219.16 seconds)** without skips. Both graphics adapters pass native fixtures;
CUDA memory checks, installed static/shared API consumers, tests-disabled
production and bounded compute windows pass. Compute captures match the prior
portable images exactly; RT differs by at most one byte in two color channels.
See the [checkpoint](plans/2026-10-19-gvdb-owned-point-cloud-checkpoint.md).

A [public quantization operator](plans/2026-10-19-gvdb-public-point-quantization.md)
is implemented and used by point-cloud (`ethereal-samples` commit `6a7ab23`),
removing the application decode/readback/reupload sequence. Its focused API,
sample and installed-consumer acceptance is recorded in the linked plan.

The [inverse-distance gather](plans/2026-10-19-gvdb-inverse-distance-gather.md)
adds a separate factory and entry, preserving the unnormalized weighted sum with
defined saturation and zero-distance behavior. Native Windows, CUDA memory and
installed-consumer tests pass. Complete regression matrices pass 339/339 and
256/256, before the following interactive ownership slice.
The 100-entry inventory has 32 owned-validated, 12 sample-validated, 27 portable
foundations, 23 partial and 6 pending roles. Deposition, packed velocity storage,
remaining ownership consumers and platform/performance/reference-retirement gates
remain open. Interactive mixed-scene snapshot migration now passes 15/15 analytic/asset
tests with all 12 captures byte-identical, both RT adapters, CUDA memory checking,
and a tests-disabled production build. See the [execution record](plans/2026-10-19-gvdb-interactive-owned-snapshot.md).
Fluid reconstruction now uses public owned points/topology/gather/aprons and
shared snapshots for compute/RT rendering. Focused acceptance includes 19 fluid
cases, seven expanded analytic cases, both graphics adapters, CUDA memcheck, and
24 graphics-only fluid/interactive cases. See the [execution record](plans/2026-10-19-gvdb-fluid-owned-snapshot.md).
The remaining point deposition operators and spray ownership are next.

## Public point deposition (2026-10-19)

The [public deposition operator](plans/2026-10-19-gvdb-public-point-deposition.md)
now publishes central/six-neighbor scalar contributions, exact last/average color,
and original-leaf shifted XZ support/material through ordinary generation tickets.
It removes raced scatter writes using stable input ordinals and preserves physical
same-brick apron behavior. ABI/four-API acceptance is **5/5**; graphics-only is
**4/4**. All six native graphics adapter/API combinations and CUDA memcheck pass;
installed static/shared GVDB consumers pass **2/2 each**. Logs are in
`build/m5-point-deposit`. Inventory: **35 owned-validated / 12 sample-validated /
27 portable-foundation / 23 partial / 3 pending**. Spray ownership and retained
snapshot queries are next; full project acceptance remains open.

## Spray retained snapshot ownership (2026-10-19)

Spray now uses public mesh/topology/resample/point/gather/apron/filter operations
and retained raw snapshots for ray queries and all five render modes. The
[execution record](plans/2026-10-19-gvdb-spray-owned-snapshot.md) records 19 affected
and eight expanded tests, six native graphics combinations, CUDA memcheck,
15 graphics-only tests and a tests-disabled AMD production run. Modes 0?3 match
previous portable captures exactly; compositing differs by at most one channel
byte in 177?180 pixels. Inventory counts remain unchanged: exact legacy ray-buffer
compatibility is still separate. Obstacle mapping, tricubic and exception
disposition are the three pending roles; platform, visual/performance and
reference-retirement gates remain open.

## Public obstacle-volume mapping (2026-10-19)

The [public mapping operation](plans/2026-10-19-gvdb-obstacle-mapping.md) replaces
`gvdbMapExtraGVDB` using authenticated retained snapshots, explicit slot ordering
and checked signed leaf lookup. Four-API/ABI tests pass **5/5**, graphics-only
**4/4**, both native adapters pass, CUDA memcheck is clean, and installed static/
shared consumers pass **2/2 each**. Inventory now has **36 owned-validated / 12
sample-validated / 27 portable-foundation / 23 partial / 2 pending**. Tricubic
rendering and OptiX exception disposition are next; broader gates remain open.

The complete Windows regression after obstacle mapping passes **349/349**,
211.71 seconds, without skips (`build/m5-obstacle/full-tests.log`). Tricubic
rendering is now being implemented and is not included in that result.

## Retained tricubic surface (2026-10-19)

The [tricubic renderer](plans/2026-10-19-gvdb-tricubic-surface.md) consumes public
retained snapshots with the original quadratic interpolation contract and
explicit border/refinement repairs. Four-API analytic/asset tests pass **8/8**,
both native graphics adapters pass, CUDA memory checks are clean and production
renders successfully. Full Windows regression passes **357/357** in 199.85 seconds;
graphics-only passes **270/270** in 176.20 seconds, both without skips. Inventory:
**36 owned-validated / 13 sample-validated / 27 portable-foundation / 23 partial /
1 pending**. OptiX diagnostic disposition is next; legacy visual, performance,
Linux and supported multi-GPU gates remain open.

## OptiX exception disposition (2026-10-19)

The [diagnostic implementation](plans/2026-10-19-optix-diagnostics.md) adds an
ABI-preserving opt-in CUDA validation factory and sample --validation support.
Tagged SDK diagnostics and failed launch/completion replace the retained
exception program's black-pixel recovery. Positive RT and isolated trace-depth
failure tests pass, static/shared installed exports pass, and memcheck is clean.
Full Windows regression passes **360/360** in 201.12 seconds, without skips.
Inventory is **36 owned-validated / 14 sample-validated / 27 portable-foundation /
23 partial / 0 pending**. The project remains in progress: packed velocity and
public subcell storage, exact legacy exports, broader visual/performance and
platform acceptance remain. No reference retirement is authorized.

## Public packed velocity encoding (2026-10-19)

The [velocity factory](plans/2026-10-19-gvdb-velocity-quantization.md) adds signed
unpadded extrema, constant-axis repair and GPU ushort3 encode/decode while
preserving position metadata, color and W payloads. Four-API/ABI tests pass **5/5**,
38 affected point/gather/sample regressions pass, both native graphics adapters
pass, CUDA memory checking is clean, and installed static/shared consumers pass
**2/2 each**. Graphics-only acceptance is **4/4**. Inventory remains **36/14/27/23/0**;
public expanded subcell storage is next. Platform, visual/performance and retained
reference gates remain open.

## Public retained subcell storage (2026-10-19)

The [subcell API](plans/2026-10-19-gvdb-public-subcells.md) retains immutable
snapshots/points, exposes stable ranges, signed cell locations and original point
ordinals, and expands exact canonical attributes on the GPU. Position/velocity
ushort3 factories compose on the result. Full Windows regression passes
**365/365** in 211.39 seconds; graphics-only passes **274/274** in 160.00 seconds.
Both native graphics adapters, CUDA memory checking and installed static/shared
consumers pass. Inventory is **41/14/23/22/0**; scalar-grid queries and safe legacy
velocity diagnostics are next. Broader consumer/platform/visual/performance
gates remain open, with no retained source retirement.
