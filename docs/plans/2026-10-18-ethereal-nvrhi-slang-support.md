# Ethereal–NVRHI Slang Support Mega Project

Approved 2026-10-18. This document archives the agreed implementation plan and user decisions.

## 1. Objective and agreed scope

Make Slang a first-class shader language and make ethereal-nvrhi its unified execution layer across graphics, compute, and ray tracing.

| Backend | Platforms | Required functionality |
| --- | --- | --- |
| D3D11 | Windows | Slang graphics and portable GVDB compute |
| D3D12 | Windows | Slang graphics, compute, and ray tracing |
| Vulkan | Windows, Linux | Slang graphics, compute, and ray tracing |
| CUDA | Windows, Linux | Slang compute, OptiX ray tracing, and native interop |

- Preserve NVRHI interface design style; API and ABI changes are permitted.
- Compile Slang offline and ship executable artifacts with reflection. Runtime source compilation is deferred; CUDA driver PTX compilation remains part of execution.
- Implement CUDA to D3D11/D3D12/Vulkan interop and CUDA multi-GPU transfers.
- Native paths only: unsupported sharing or peer transfers return FE_UNSUPPORTED, without host staging.
- Port all GVDB GPU sources, including SPH and OptiX programs, plus representative graphics, compute, and ray-tracing examples.
- Retain existing HLSL support elsewhere.
- ROCm, Metal, and SYCL influence extensibility but receive no backend implementation in this project.

## 2. Workspace and baseline

Workspace: D:/ps/repo/ethereal-slang-next. Branch slang-next in root and every submodule, including nested shader-tool.

| Repository | Starting commit |
| --- | --- |
| ethereal | 80084a8d8ce8f433c95229ab36f35877dc84a88a |
| ethereal-nvrhi | 296422b024c882e8bd1f48a56c134ae77fb8e46b |
| ethereal-donut | 9f51e7a1c25cf57da5ac2b7cf7f4875e16950dd0 |
| ethereal-samples | 01b4945547c7a46f1a71c65b945b27e6066f0916 |
| shader-tool | afbf2734e3d8dcad3553467d1e4427f20378feca |

- Create linked worktrees explicitly parent-to-child and verify branch, common Git directory, and starting commit.
- Leave the original checkout's uncommitted CMake changes and untracked NVRHI ADR in place.
- Record selected submodule revisions in the parent and update gitlinks as milestones land.
- All project work and fresh build directories belong in the new workspace.
- Capture legacy sample outputs, deterministic fixtures, timings, and memory use before replacing implementations.
- Initial toolchain pins: Slang 2026.10.2, CUDA Toolkit 12.9, OptiX 9.0. Verify on Windows and Linux.

## 3. Architecture and interface changes

### Offline compiler and artifacts

Extend shader-tool rather than introduce another executable.

- Use Slang component/session APIs for modules, composition, offline specialization, compilation, and target reflection.
- Support DXBC, DXIL, SPIR-V, CUDA PTX, and OptiX PTX. DXBC compilation remains Windows-only.
- Versioned artifacts contain executable code, entry symbols/stages, target requirements, binding/uniform layouts, thread-group sizes, and compiler identity.
- Retain NVSP for legacy shaders. Provide a compiler-independent artifact reader/writer target within shader-tool usable by standalone NVRHI without Donut or compiler libraries.
- Extend CMake helpers for .slang, imported modules, PTX, and dependencies. Cache identity includes source dependencies, specialization values, compiler versions, target, and options.
- NVRTC/compiler SDK dependencies belong to offline tooling. Packaged applications execute without Slang or NVRTC.
- Serialize reflection from the exact linked program/target producing code; never assume graphics and CUDA parameter layouts coincide.

### Unified runtime

- One model: IDevice, resources, samplers, binding layouts/sets, pipelines, ICommandList, and existing ray-tracing interfaces.
- Add GraphicsAPI::CUDA, adapter identity, capability and limit queries for compute, RT, formats, sharing, and peers.
- Add IShaderProgram and artifact loading; programs expose entry shaders/reflected layouts for existing pipeline and binding APIs.
- Support target-specific uniform packing and explicit texture/sampler pairing. CUDA texture objects represent distinct pairs; do not discard sampler state.
- Extend RT descriptors where portable record data, payloads, attributes, or callables need it.
- Preserve AutoPtr, QueryInterface, C exports, noexcept, and FRESULT conventions. Bump API version and changed interface identities, maintain ABI/header hygiene.
- Validation covers every new operation. Unsupported capabilities fail explicitly; failed creation clears output handles.
- Remove temporary donut::gp dependencies from migrated production code. GVDB algorithms/scene integration remain in samples; backend mechanisms move to NVRHI.

### CUDA and OptiX

- nvrhi_cuda uses CUDA Driver API exclusively, explicit adapter selection, retained primary context, and scoped per-thread context activation.
- Implement buffers, CUDA arrays, texture/surface views, upload/readback, copies, compute pipelines, queries, and queue synchronization.
- Record command lists on CPU and replay onto streams. Dispatch group counts plus reflected thread dimensions define launches.
- Pack CUDA arguments from metadata and retain parameter allocations/resources through GPU completion.
- CUDA reports raster/presentation unsupported; interactive applications use a graphics device for display.
- Map NVRHI acceleration structures, shaders/hit groups, shader tables, and dispatches to OptiX.
- Support triangles, AABBs, instances, build/update, compaction, record bindings, and stack calculation.
- Use portable Slang payloads/attributes in samples rather than CUDA payload pointers.
- Keep SDK types in implementation or backend-specific native-access headers.

### Interop

- IInteropDevice provides capability queries, import/export, external synchronization, and cross-device copies.
- Match UUID/LUID/node identities, not adapter enumeration order.
- CUDA to D3D11/D3D12/Vulkan sharing requires compatible devices and correctly created shared resources.
- Track allocation size, bound offset, dedicated allocation, formats, mips, and handle ownership.
- Use Win32 handles/fences/D3D11 keyed mutexes and Vulkan external memory/semaphores via Win32 handles or Linux FDs.
- Integrate ownership acquire/release with NVRHI state tracking and Vulkan layout/queue transitions.
- Query directional peer support before CUDA peer access/copies.
- Graphics to remote CUDA may use an explicit local CUDA bridge plus a supported peer copy. Reject routes without a fully native path.
- Distinguish shared views and copies; expose selected transfer path and synchronization requirements.
- Retain imported allocations/handles/synchronization until GPU completion.

## 4. GVDB migration and milestones

Replace embedded GPU pointers/texture handles with buffer-relative references, explicit resource bindings, and ordinary parameter data. Preserve VBX compatibility and the existing 64-byte serialized Node layout; separate execution layouts from serialization when necessary.

D3D11 uses SM5-compatible two-word 64-bit IDs, fixed resource bindings, bounded UAV sets, and group-shared algorithms without mandatory wave operations. Split channel work into dispatches for binding limits.

Replace Thrust with Slang radix sort, scans, and reductions. Specify conversions/sampling and use buffer storage for atlas formats lacking suitable texture support.

| Milestone | Completion gate |
| --- | --- |
| M0 Workspace/references | All branches/worktrees; pinned dependencies; legacy fixtures and baseline test results. |
| M1 Compiler/graphics | Artifacts/reflection; NVRHI loading; basic_triangle on graphics APIs; shared compute D3D11/D3D12/Vulkan; CUDA/OptiX generation validated. |
| M2 CUDA compute | Shared compute fixtures through NVRHI CUDA; buffer/texture/sampling/dispatch/lifetime/error coverage. |
| M3 Unified RT | Shared triangle/procedural scene on D3D12/Vulkan/OptiX; payload/SBT/geometry/update coverage. |
| M4 Native interop | Windows CUDA/graphics, Linux Vulkan/CUDA, supported real peer-copy route and unsupported rejection. |
| M5 Portable GVDB | Allocation/topology, voxels, particles, sort/scan, raycast, SPH in order; each against references. |
| M6 Samples/completion | All GVDB samples plus basic_triangle/headless/rt_triangle/shader_specializations; platform matrix; legacy production removal. |

- Generalize OptixRenderer to NVRHI RT.
- Port all GVDB .cu/.cuh implementation and supporting presentation/debug shaders to Slang.
- Expose compute/graphics API and adapter selection and deterministic headless runs.
- Preserve reference implementation for comparison until replacements pass; then remove production gpdevice/Thrust/cudart/NVCC dependencies.
- Independent Slang/CUDA/OptiX options; graphics-only GVDB does not require CUDA.
- Keep milestones buildable and document support/migration.

## 5. Validation and acceptance

Compiler/interface: artifact round trips/corruption/version/target/entry errors; nested struct/array/matrix/buffer/texture pair/multi-entry/specialization reflection; object/QI/ABI/header/cross-module checks; standalone installed NVRHI/static/shared/no-CUDA/no-OptiX.

Backend/interop: four-backend compute including tail dispatches/barriers/copies/readback/lifetimes; three-backend RT with multi-geometry/procedural hits; interop offsets/subresources/ownership/repeated sync/teardown/mismatched adapters/unavailable P2P/unsupported formats. Use D3D debug layers, Vulkan validation, and CUDA Compute Sanitizer where applicable.

GVDB: CPU-reference sort/scan/reduction/IDs/topology; VBX round trips and existing assets; cross-backend voxel/resample/point-fusion/raycast/fixed-step SPH. Exact integer comparison and documented fixture-specific float/image tolerances. Smoke all eleven sample directories plus sph_fluid_pool.

Completion:
- Windows D3D11/D3D12/Vulkan/CUDA and Linux Vulkan/CUDA pass.
- Required hardware jobs fail unexpected skips; developer skips are explicit.
- Real supported multi-GPU peer configuration is required; local RTX4050 alone cannot prove this.
- Compare timing/memory to baseline separately from correctness.
- Packaged shaders execute without Slang/NVRTC.
- Migrated production has no donut::gp, handwritten CUDA kernels, cudart, or Thrust.
- All repositories build from committed parent gitlinks.

## References

- [Git worktrees](https://git-scm.com/docs/git-worktree.html)
- [Slang reflection](https://docs.shader-slang.org/en/stable/external/slang/docs/user-guide/09-reflection.html)
- [Slang CUDA/OptiX](https://docs.shader-slang.org/en/stable/external/slang/docs/cuda-target.html)
- [CUDA interoperability](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/graphics-interop.html)
- [CUDA peer API](https://docs.nvidia.com/cuda/cuda-driver-api/cuda_driver_api/group__CUDA__PEER__ACCESS.html)

