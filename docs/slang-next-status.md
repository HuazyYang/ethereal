# Slang-next implementation status

The agreed scope and acceptance gates are in [the archived plan](plans/2026-10-18-ethereal-nvrhi-slang-support.md). This is an implementation checkpoint, not a completion claim. See [build and run instructions](slang-next-build.md).

## Workspace and references

Root, NVRHI, Donut, samples, and nested shader-tool have linked worktrees on `slang-next` in `D:/ps/repo/ethereal-slang-next`. The original checkout's local edits are preserved. Commit `431a68a` archives the plan and exact starting revisions.

The first implementation checkpoint records shader-tool `15b6ab0`, Donut `8e922b4`, NVRHI `0cb60f1`, and samples `2f7057b`. All **77 configured Release CTests passed** on Windows, in 35.50 seconds. Results are in `build/checkpoint-tests.log` and `build/checkpoint-tests.xml`. The expanded GVDB CUDA suite also passed Compute Sanitizer with zero errors (`build/gvdb-extended-memcheck.log`).

The original checkout's existing test suite passed 26/26. Its legacy render-to-file executable rendered explosion.vbx at 1024 x 768 in 7.121 ms, reporting 40.04 MiB atlas and 1.75 MiB topology. Logs, CTest XML and the image are under build/baseline. This is an existing executable reference, not a fresh rebuild of the selected source revision. New renderer timings include readback and use different camera framing, so they are not a performance comparison.

The second local checkpoint passed **102/102 Release CTests** in 46.44 seconds. The complete matrix was rebuilt before the run; logs and JUnit are in build/checkpoint-2-tests.log and build/checkpoint-2-tests.xml. The public graphics export implementation is committed as NVRHI a3b261b, Donut e5cdf7d enables the supported Vulkan DrawParameters feature required by Slang vertex-ID shaders, and samples fd5fb55 records the viewer/resample/3d-print migration. After precision-bound and test-oracle review fixes, all 25 affected tests passed again in 13.75 seconds (build/review-regressions-tests.log).

## Implemented and exercised

- Shader-tool uses Slang sessions/components to produce DXBC, DXIL, SPIR-V, CUDA PTX and OptiX PTX artifacts. A separate artifact library loads metadata without compiler SDKs. Binding shifts, native entry symbols, actual CUDA parameter ABI, explicit texture/sampler pairings, array/matrix reflection and shader-record scope have regression coverage.
- NVRHI exposes CUDA as a backend and loads artifacts through IShaderProgram. Donut's ShaderFactory consumes the same artifacts. Existing raw shader paths remain available. The public API version is 29. Installed static and shared packages have external-consumer checks; a shared consumer configures with compiler and CUDA SDK discovery disabled.
- CUDA uses the Driver API for resources, command replay, streams, events, dispatch, sampling, and OptiX acceleration structures/pipelines. GPU tests cover triangles, procedural geometry, updates, compaction, local shader records, multiple materials, geometry pre-transforms, cloning, and retained lifetimes.
- The same triangle/procedural material scene passes on D3D12, Vulkan RT and OptiX, including local shader records, cached/uncached shader tables, and retained resources. Native D3D12/Vulkan validation and CUDA sanitizer runs are clean. Vulkan local shader records currently support nonvolatile constant-buffer device addresses; other local resource types fail explicitly.
- Native Windows import tests exercise D3D11 shared textures/keyed mutexes, D3D12 placed heap offsets/fences, and Vulkan external memory/timeline semaphores/ownership transitions. Imported handles can be closed by callers after import. Unsupported peer paths fail explicitly. Public graphics-side exports now expose owned resources, adapter route checks, GPU timeline fences and explicit ownership transfer through nvrhi::interop. Three graphics-to-CUDA-to-graphics round trips pass on D3D11/D3D12/Vulkan with clean native validation and CUDA memory checks; no host wait occurs between API submissions. Native handle ownership and pending D3D11 event-query regressions pass in static/shared builds. [Usage and restrictions](../ethereal-nvrhi/docs/graphics-interop.md) are documented.
- Representative graphics tests pass: basic_triangle on D3D11/D3D12/Vulkan, rt_triangle on D3D12/Vulkan, shader_specializations on Vulkan. Headless compute passes on all four APIs.
- Portable GVDB has 61 compute entries compiled for all four APIs: scan, stable two-word 64-bit radix sort, NaN-aware reduction, topology, scalar and raw atlas operators, sparse raycast, particle/SPH, point keys and fusion, solid voxelization, MAC/PIC-FLIP transfer, subcell binning, and packed point conversion. Independent CPU references cover tail groups, odd packed lengths, nonfinite values, negative coordinates, and repeated simulation steps.
- Standalone VBX loading does not initialize CUDA. Scalar and raw APIs round-trip the real explosion asset and all five channel formats. Raw VBX supports ordered multiple channels with preserved transform and atlas slots; compression, multiple grids and topology reuse remain explicitly unsupported.
- CPU topology construction builds validated sparse hierarchies and scalar atlases/aprons. GPU scalar resampling, downsampling, interior reduction, voxelization, velocity transfer, subcell fusion and packed conversions pass on all four APIs. PIC/FLIP transfer is implemented; particle-to-grid transfer and pressure projection are not.
- Procedural GVDB ray tracing passes analytic volume/surface/shadow, clipping, transformed-instance, update, miss and shared-atlas tests on D3D12, Vulkan RT and OptiX.
- Rewritten render-to-file runs on all four APIs. Its 128 x 96 explosion outputs differ by at most one 8-bit channel value across backends.
- Rewritten render-kernel preserves the custom first-threshold-hit wavefront shader and diffuse/reflected-sky formula. Eight real-asset/analytic tests pass across four APIs; outputs agree to one 8-bit channel value.
- Rewritten sph_fluid_pool runs the complete SPH sequence and four original presets through NVRHI. Four application smoke tests pass. Graphics modes render simulation buffers directly and support orbit/pause/reset; CUDA runs headless. The original scene/ImGui integration remains in the legacy implementation.
- Rewritten resample preserves RAW byte/256 conversion, the original transformed/truncated coarse box behavior, sparse activation and a six-face halo. All coarse values and every atlas/apron voxel match independent CPU references. The original head asset has 32,768 dense, 17,609 sparse and 20,616 halo leaves. Four-backend images are byte-identical.
- Rewritten 3d-print preserves Lucy's model-to-index transform, four voxel sizes and surface/interior values. Its signed-origin fixtures cover dense classification, sparse atlas/aprons and exact section pixels. At 0.5 mm the original asset produces 801 bricks, 56,839 surface and 131,750 interior voxels; all four output images are byte-identical.
- The shared volume viewer renders directly from the GPU result buffer. It provides volume/surface/voxel/section modes, an inset, topology overlays, orbit/pan/zoom/light controls and headless rendering. Independent tests cover section interpolation/blending, distant voxel traversal, odd image/inset dimensions, topology, and presentation value/orientation. Native graphics validation is clean; CUDA memory checks pass for the viewer and both new applications.
- An isolated graphics-only build with CMAKE_DISABLE_FIND_PACKAGE_CUDAToolkit=TRUE passed all 39 selected graphics/compute/application tests in 21.73 seconds, including the new viewer, resample and 3d-print targets. Results are in build/graphics-only-tests.log.

## Acceptance still outstanding

| Milestone | Remaining work |
| --- | --- |
| M0 | Fresh legacy rebuild and broader deterministic references |
| M1 | Additional compiler reflection edge cases and Linux package execution |
| M2 | Wider texture/view/error coverage and Linux CUDA execution |
| M3 | Advanced GVDB materials, mixed mesh/volume continuation and remaining sample behavior |
| M4 | Depth-map application integration, Linux external-memory run, real multi-GPU peer transfer |
| M5 | Full GVDB host API migration, incremental topology/atlas ownership, remaining CUDA algorithms, full FLIP pipeline and expanded data compatibility |
| M6 | Remaining GVDB applications, complete interactive behavior, Linux matrix, production legacy removal and performance comparisons |

Remaining executable examples are depth-map, fluid-surface, interactive-optix, point-cloud, point-fusion, and spray-deposit, plus their shared sample-utils implementation. The archived plan's eleven sample directories include sample-utils; sph_fluid_pool is separate. Depth-map and incremental point-fusion are the next application slices.

The new resample/3d-print viewer frames active index bounds. Its section plane uses normalized data height, and the inset scales with the output. The original fixed camera/section mapping and ImGui presentation are retained in legacy-main.cpp; matching legacy screenshots or performance is not claimed.

Local hardware is Windows x64 with one NVIDIA RTX 4050 Laptop GPU (driver 617.42). CUDA 12.9, OptiX 9.0, and Slang 2026.10.2 are the tested toolchain. No Linux execution or real multi-GPU success is claimed.

Production migration is incomplete. Remaining legacy examples use donut::gp, handwritten CUDA, and their original host interfaces. They are gated by ETHEREAL_BUILD_GVDB_LEGACY; portable targets are gated separately by ETHEREAL_BUILD_GVDB. References remain available until replacements pass their acceptance gates.
