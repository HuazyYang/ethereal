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

The remaining voxel families, point/voxelizer/serializer adapters, transactional
host adoption and helper/sample ownership migration remain unfinished.

## Acceptance still outstanding

| Milestone | Remaining work |
| --- | --- |
| M0 | Broader deterministic legacy references and controlled performance comparisons |
| M1 | Additional compiler reflection edge cases and Linux package execution |
| M2 | Wider texture/view/error coverage and Linux CUDA execution |
| M3 | Broader mixed-scene edge cases, legacy visual comparisons and platform validation |
| M4 | Linux external-memory run and real multi-GPU peer transfer |
| M5 | Public operator/serializer adapters, transactional host adoption, consumer ownership integration and expanded data compatibility |
| M6 | Owned-volume adoption, complete interactive behavior, Linux matrix, production legacy removal and performance comparisons |

Spray-deposit completes the remaining executable rewrite; public ownership adoption and the broader acceptance gates remain in progress. Fluid reference comparisons now document the retained CUDA color-read defect and remaining stochastic differences. The archived plan's eleven sample directories include sample-utils; sph_fluid_pool is separate. The [mixed mesh/volume renderer](plans/2026-10-18-mixed-scene-slang-rt.md), point-cloud and fluid work belong to the current validation slice and are not part of the historical 130-test checkpoint.

The new resample/3d-print viewer frames active index bounds. Its section plane uses normalized data height, and the inset scales with the output. The original fixed camera/section mapping and ImGui presentation are retained in legacy-main.cpp; matching legacy screenshots or performance is not claimed.

Local hardware is Windows x64 with one NVIDIA RTX 4050 Laptop GPU (driver 617.42). CUDA 12.9, OptiX 9.0, and Slang 2026.10.2 are the tested toolchain. No Linux execution or real multi-GPU success is claimed.

Production migration is incomplete. The preserved reference implementations use donut::gp, handwritten CUDA, and their original host interfaces. They are gated by ETHEREAL_BUILD_GVDB_LEGACY; portable targets are gated separately by ETHEREAL_BUILD_GVDB. References remain available until replacements pass their acceptance gates.
