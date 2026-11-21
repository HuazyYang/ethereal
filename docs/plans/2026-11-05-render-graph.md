# Render graph (RDG) for donut: implementation

- Status: Approved (2026-11-05). Pass 1 done and verified (P1.0-P1.7); pass 2 done and verified (P2.0-P2.4),
  scheduled by the user's instruction of 2026-11-05. Nothing is pushed: origin/rdg needs a force-push, which
  is the user's call.
- Date: 2026-11-05
- Design: [`../rdg-design.md`](../rdg-design.md) (Accepted 2026-11-05); decision record
  [ADR 0003](../adr/0003-render-graph-for-donut.md). The RHI changes get their own nvrhi ADR in step P1.0.
- Branch: `rdg` in the aggregate (worktree `.worktrees/rdg`), `ethereal-nvrhi`, `ethereal-donut` and
  `ethereal-samples`. `ethereal-donut/thirdparty/shader-tool` stays at its gitlink.
- This aggregate copy is the maintained plan: the *Step as built* notes go into its execution record.

## Context

The design was accepted on 2026-11-05 after the reviews recorded in its sections 14.1-14.12. This plan
turns its section 15 into two passes:

- **Pass 1: nvrhi and donut.** The RHI features of design section 8 in ethereal-nvrhi, and the render
  graph of sections 4-13 in ethereal-donut, with every test that runs without a sample. The one change
  to ethereal-samples is the mechanical `app::IRenderPass` → `app::IAppLayer` rename, without which the
  samples stop building.
- **Pass 2: samples.** The graph versions of the samples, the A/B tooling, and every exit criterion
  that needs a sample: pixel comparison, sample budgets, the memory budget, and the plan-cache
  decision. **Scheduled** (2026-11-05): it follows pass 1, with each step after the pass-1 steps it
  needs.

**Decided in the design; do not re-litigate:** the access vocabulary with `UAVRead`/`UAVWrite`
(6.1); `IResource` without a type tag, dispatched with `QueryInterface` (8.1); `ResourceBarrier` and
`ICommandList::barriers` plus `setExplicitBarrierScope` (8.2); the timeline `IFence` with
`IDevice::submit` (8.3); no builder objects: `IRenderGraph` records resources and passes and compiles
and executes, `ISetupContext` declares accesses, `IResourceRegistry` keeps what survives between frames
(12, 14.9-14.11); `void* data` per pass use, trivially destructible (`NewFrameData`); pass-local
transients; `FrameData`; N-layer histories; the compiler as an internal phase list (14.12); the plan
cache kept only if it beats the no-cache baseline (7.7).

**Conventions:**
- nvrhi's COM ABI rules (`ethereal-nvrhi/doc/com-interface-abi.md`); interfaces change in place and
  `c_HeaderVersion` stays 28 (§3.4). No smart-pointer parameters.
- The interface headers are the ones accepted in the design (sections 8 and 12). Any deviation found
  while implementing is shown to the user before the code that depends on it.
- Build from PowerShell through `build.ps1`, which sets up VsDevCmd. A build that prints only "Running
  utility command" lines compiled nothing.
- One GPU process at a time. Validation claims come from Debug runs with the layer confirmed loaded.
- Line endings: after every edit, `git ls-files --eol` must match the index; several files are CRLF.
- Each step ends with a commit on the `rdg` branches, in dependency order: nvrhi, donut, samples, then
  the aggregate gitlinks. Nothing is pushed without the user's instruction.

## Working tree and branches

- **Worktree.** The aggregate worktree `.worktrees/rdg` (branch `rdg`) is rebased onto aggregate `main`
  (`264ac18`), as design 14.1 says. `origin/rdg` holds the pre-rebase docs commit, so pushing it later
  needs a force-push, which is the user's call.
- **Submodules inside the worktree.** With git 2.53, a linked worktree keeps its submodule git
  directories under `.git/worktrees/rdg/modules/`, apart from the main checkout's `.git/modules/`. The
  2026-10-04 framegraph plan's finding that a worktree rewrites the shared `core.worktree` no longer
  holds. The submodules are cloned from the local repositories (no network), and their `origin` URLs
  are then set back to the real remotes.
- **Branch points.** `rdg` starts at the gitlinks of aggregate `main`: ethereal-nvrhi `123d105`,
  ethereal-donut `4f4b31c`, ethereal-samples `37ac258`.
- **Build directory.** `.worktrees/rdg/build`, configured like the main checkout's build (samples,
  benchmarks, GVDB, CUDA/OptiX, donut and nvrhi tests), sharing the vcpkg install directory. Local
  copies of the fetched dependencies are used if the network fails.

## Pass 1: nvrhi and donut

### P1.0 Worktree, branches, records, baseline

- Rebase, initialise the submodules, create the `rdg` branches (above).
- `ethereal-donut/doc/RdgDesign.md` becomes "Superseded by aggregate ADR 0003" (design 14.4).
- nvrhi ADR 0015, *Explicit barriers, timeline fences and a resource base*, records design section 8,
  with an index row.
- **Exit:** the worktree builds Release and Debug, and its ctest matrix matches the main checkout's
  (45/45 on 2026-10-27).

### P1.1 nvrhi: the RHI features (design section 8, step 1)

Done in this order, each with its tests:

1. **`IResource`** under every resource interface, with `queryHeapBinding` on D3D12, Vulkan, D3D11 and
   CUDA (`FE_NOT_FOUND` without heaps), and in the validation wrappers. Vulkan `bindImageMemory` and
   `bindBufferMemory` check the `VkResult`.
2. **`SubresourceRegion`, `ResourceBarrier`, `ICommandList::barriers`** on D3D12 legacy, D3D12
   enhanced, Vulkan, D3D11 and CUDA, with the helper definitions and layout assertions in
   `src/common/resource-barrier.cpp`. The new `Feature` values `SplitBarriers`, `AliasingBarriers` and
   `QueueOwnershipTransfer`. Type dispatch through `QueryInterface(riid, nullptr)` (8.1).
3. **`setExplicitBarrierScope`**: a no-op in the backends, a checked scope in the validation layer.
4. **Validation rules** of 8.2: tracked `before`, unmatched splits, release without acquire,
   `keepInitialState` resources, byte overlap of aliasing barriers, plane masks on tracked resources,
   and calls inside an explicit-barrier scope.
5. **`IFence`, `IDevice::submit`, `queueWaitFence`, `queueSignalFence`, `waitFences`** on D3D12, Vulkan,
   D3D11 (`FE_UNSUPPORTED` before 11.4) and CUDA (the event ring), plus the validation wrappers.
   `executeCommandLists` and `queueWaitForCommandList` are reimplemented on the same machinery.
6. **Check:** whether `cuStreamWriteValue64` and `cuStreamWaitValue64` work on this driver (design
   8.3.1). The result is recorded; the event ring stays the design either way.

New test executables in `ethereal-nvrhi/tests`: `nvrhi_barrier_tests` and `nvrhi_fence_tests`, one ctest
entry per backend, each creating its device through `createDeviceOnAdapter`.

**Exit (design step 1):**
- Per-backend tests for: combined depth-read layouts, plane-masked transitions, split pairs, aliasing
  (byte-overlap validation and the enhanced alias form of 6.7), discard, release/acquire, fence
  ordering across queues (CUDA streams around deferred replay included), the CPU wait table of 8.3.1
  (poll, finite, infinite), and a state call inside an explicit-barrier scope reported by validation.
- Clean under the D3D12 debug layer with GPU-based validation, Vulkan synchronisation validation, and
  Compute Sanitizer, each confirmed loaded.
- `nvrhi_abi_lint`, `nvrhi_header_hygiene`, `cuda-tests` and the interop tests pass. The full ctest
  matrix passes after a full rebuild.

### P1.2 donut: the `app::IAppLayer` rename (design 3.3, step 2)

- donut: `app::IRenderPass` → `app::IAppLayer`; `DeviceManager::AddLayerToFront`, `AddLayerToBack`,
  `RemoveLayer`, `m_vLayers`; `ImGuiRenderPass` → `ImGuiLayer`. No alias is kept.
- ethereal-samples: the same rename in its 43 files, mechanically. This is the only sample change in
  pass 1.
- **Exit:** every sample builds on every backend it built on before; ctest unchanged; a Debug smoke run
  of one D3D12 and one Vulkan sample renders and closes cleanly.

### P1.3 donut: the graph core, device-free (design 4-7, 11.1, 12, step 3)

- Headers first: `include/donut/render/RenderGraph.h` (12, with `NewFrameData`, `GetHistoryPair`),
  `RenderGraphLambdaPass.h` (12.1) and `RenderGraphFrameData.h` (12.2).
- Sources: `RenderGraph.cpp` (recording, frame arena, structural hash, setup context, version counter),
  `RenderGraphCompiler.cpp` (the phase list of section 7), `RenderGraphTransitions.cpp` (section 6:
  interval maps, read epochs, lattices, placement, splits, UAV ordering, discard, aliasing, queues,
  render targets, batching, frame boundary), `RenderGraphProfile.cpp` (9.2), `RenderGraphVerifier.cpp`
  (11.1), the JSON and Graphviz dumps (11.3), and `RenderGraphRegistry.cpp` for the compile-side parts
  (plan cache, persistent and history records).
- Tests in `ethereal-donut/tests/src/render`: the header-hygiene test (3.2), abi_lint over
  `RenderGraph.h`, and a verifier corpus.
- `rdg_bench`, a device-free benchmark executable in donut.
- **Exit (design step 3):** the verifier passes a device-free corpus of at least 40 graphs × 4
  profiles, including two-frame and plan-switch replays; golden barrier lists for the 6.11 frame,
  with and without async SSAO; the compile and cache-hit budgets of 10.3, with the no-cache frame
  cost reported beside them.

### P1.4 donut: the executor and the registry (design 9, 11.4, step 4)

- Executor: `Prepare`; segments; Native mode with explicit-barrier scopes; Tracked mode with the
  tracker cross-check; Restore mode; `submit` with plan fences; the fallback for a device without
  `barriers`.
- Registry: persistent resources and N-layer histories; the bounded plan cache; the pooled tier;
  per-queue fences and retirement, with the `IEventQuery` fallback; the command-list pool.
- The debug switches of 11.4, as phases where they change the plan.
- Headless GPU tests in donut: compute graphs executed on D3D11, D3D12, Vulkan and CUDA.
- **Exit (design step 4):** headless graphs run with clean validation on all four backends; zero
  allocations and zero `create*` calls per steady-state frame; a three-layer history rotates correctly
  and reports `IsNewAllocation` per layer; `SkipAliasingBarriers` makes the aliasing test fail.

### P1.5 donut: the passes (design 13, the donut half of step 5)

- `IGpuPass` as the base of every donut pass (13.1); the six passes with no base become reference
  counted, and their owners in donut switch to `nvrhi::RefCountPtr`. That touches the samples only if
  they own those passes; any such change is mechanical, like P1.2's.
- `AddToGraph` for DeferredLighting, GBuffer, Forward, Depth/Shadow, Sky, Blit, ToneMapping, TAA, SSAO
  (pass-local transients), Bloom and MipMapGen (13.2, 13.3).
- `app::RenderGraphLayer` with `FrameData` (13.4); `app::RenderGraphVisualizer` and per-pass timers
  (11.3).
- **Exit:** donut builds; device-free tests check each `AddToGraph`'s declarations against golden
  access lists; a headless test executes one pass of each type through the graph; the immediate entry
  points are unchanged, so the samples build and run as before.

### P1.6 donut: placed memory, async compute, split barriers (design step 6, donut half)

- The Placed tier on D3D12: opt-in, probe, and an estimate on every backend (7.5).
- Async-compute placement and cross-queue fences (6.8); split barriers (6.4).
- **Exit:** headless graphs with an async pass and with split barriers run clean under D3D12 debug
  layer + GBV and Vulkan synchronisation validation, across the frame boundary; the verifier corpus
  covers the Placed tier on both D3D12 heap tiers; on the GPU, `SkipAliasingBarriers` makes the aliasing
  test fail (moved from P1.4).

### P1.7 donut: parallel recording (design step 7, donut half)

- Segment recording on worker threads through `ExecuteDesc`'s task-scheduler callback (10.1).
- The donut prerequisites: `BindingCache` creates missed sets outside its lock; `CommonRenderPasses::
  BlitTexture` guards its pipeline cache.
- **Exit:** `rdg_bench` meets the parallel-recording budget of 10.3; `BindingCache` and `BlitTexture`
  concurrency tests pass.

### Pass 1 verification

- Release and Debug builds of the whole worktree; the full ctest matrix.
- nvrhi and donut GPU tests under Debug with the validation layers confirmed loaded.
- `rdg_bench` numbers for every 10.3 budget that needs no sample, recorded with the commit hashes.
- Every sample still builds; one D3D12 and one Vulkan sample smoke-run in Debug.

## Pass 2: samples (scheduled)

Scheduled after pass 1 on 2026-11-05. The steps run in this order. Each starts when the pass-1 steps
it needs are done, and P2.0 needs none. Same conventions as pass 1: one GPU process at a time,
validation claims from Debug runs with the layer confirmed loaded, one commit per step and repository.

### P2.0 References and A/B tooling (no pass-1 dependency)

- Deterministic options in the original samples: `-fixedstep`, `-frames N`, `-screenshot`.
- `tools/ab_compare.py`: a pixel comparison of two screenshots, with a report of the differing pixels.
- The Vulkan swap chain gains `eTransferSrc` where the surface supports it (known issues). Without it,
  Vulkan screenshots are a validation error.
- Reference captures and timings from the unchanged main checkout: screenshots on `-d3d11`, `-d3d12`
  and `-vk`, and frame times (10.4 protocol: Release, NVIDIA adapter, median of 300 frames after 100,
  runs alternated).
- **Exit:** reference images and timings, with commit hashes, in the execution record; `ab_compare.py`
  reports identical for two captures of the same build.

### P2.1 `deferred_shading_rdg` (design step 5; needs P1.4, P1.5)

- The graph version of the deferred-shading sample on `app::RenderGraphLayer` and `FrameData`, through
  the passes' `AddToGraph`; the visualizer and timers enabled.
- **Exit (design step 5):**
  - images identical to the originals on D3D12, Vulkan and D3D11;
  - 120 Debug frames with zero validation messages, the layer confirmed loaded;
  - barriers per frame no more than the original, each with a reason;
  - CPU and GPU frame time no more than the original;
  - executor overhead within 0.2 ms, measured on an empty-body variant;
  - frame cost with and without the plan cache recorded, and the cache kept or removed on those
    numbers (7.7).

### P2.2 `variable_shading_rdg` (design step 5; needs P1.5)

- The graph version of the variable-shading sample: shading-rate surfaces as `ShadingRateRead`
  accesses.
- **Exit:** as P2.1, for this sample.

### P2.3 `async_compute_rdg` (design step 6; needs P1.6)

- A bloom/SSAO graph with async SSAO, split barriers and the Placed tier on D3D12.
- **Exit (design step 6):**
  - the memory budget of 10.3 on the bloom/SSAO graph;
  - the GPU-time budget;
  - Vulkan synchronisation validation clean, across the frame boundary included;
  - async SSAO, split barriers and the Placed tier each measured on and off;
  - Vulkan ownership transfers kept, or replaced by the `CONCURRENT` fallback, on measurements (6.8).
    P1.3's separate-family result, where async SSAO is demoted by the default `LatticePolicy`, is an
    input to that decision.

### P2.4 Parallel recording in the samples (design step 7; needs P1.7)

- The samples record segments on worker threads through `ExecuteDesc`.
- **Exit (design step 7):** the executor and parallel-recording budgets of 10.3, measured in the
  samples.

### Pass 2 verification

- Release and Debug builds of the whole worktree; the full ctest matrix.
- The A/B comparisons and the budget numbers of P2.1-P2.4 in the execution record, with commit hashes.
- WaveWorks' Debug build (known issues), if the user asks for it in this pass.

## Execution record

*Filled in per step: what was done, the commits (repository and short hash), and every deviation from
the plan with its reason.*

*P1.0 as built (2026-11-05).*
- The aggregate `rdg` (docs only) was rebased onto `main` `264ac18`: `7f52e22` (design draft) and
  `0965ff7` (design accepted, this plan). The one conflict, the plan index, kept both rows.
- The submodules were cloned into the worktree from the local repositories with `protocol.file.allow`
  and per-command URL overrides. Their git directories are under `.git/worktrees/rdg/modules/`; the main
  checkout's `.git/modules/*` and its `core.worktree` settings are unchanged. `origin` was set back to
  the GitHub remotes. donut's own config records `thirdparty/shader-tool`, which stays at `b5bec4b`.
- `rdg` branches: ethereal-nvrhi from `123d105`, ethereal-donut from `4f4b31c`, ethereal-samples from
  `37ac258`.
- Build directory `.worktrees/rdg/build`, configured with the main checkout's options (samples,
  benchmarks, GVDB, WaveWorks, CUDA, nv_asteroids, donut and nvrhi tests, discrete GPU) and the shared
  vcpkg install directory. Configure fetched its dependencies over the network without trouble.
- Commits: ethereal-nvrhi `505503b` (ADR 0015 and its index row), ethereal-donut `364b270`
  (`doc/RdgDesign.md` superseded).
- **Baseline:** Release build of all 1452 steps; ctest 45/45, the same as the main checkout.
- **Deviation:** no separate Debug baseline build. The branch points are the main checkout's own
  commits, and every later step builds Debug for its validation runs.

*P1.1 as built (2026-11-05).* The ADR 0015 RHI is in ethereal-nvrhi `rdg`, as one commit.
- **Interfaces:**
  - `IResource` (with `queryHeapBinding`) under textures, staging textures, sampler-feedback
    textures, buffers, opacity micromaps and acceleration structures, in all 19 QI tables;
  - `SubresourceRegion`, `PlaneMask` and `ResourceBarrier`, plus `ICommandList::barriers` and
    `setExplicitBarrierScope`;
  - the three `Feature` values;
  - `IFence`, `FenceDesc`, `FenceValue`, `SubmitDesc`, `IDevice::createFence`, `submit`,
    `queueWaitFence`, `queueSignalFence` and `waitFences`.

  They are as accepted in design section 8. `executeCommandLists` is a `submit` on every backend.
- **Backends:**
  - D3D12 legacy and enhanced: `d3d12-barriers.cpp`, `d3d12-fence.cpp`.
  - Vulkan: sync2 barriers, events for splits, queue-family release/acquire, timeline semaphores
    (`vulkan-barriers.cpp`, `vulkan-fence.cpp`).
  - D3D11: validation only; `ID3D11Fence` through `ID3D11Device5`.
  - CUDA: validation only; the (value, `CUevent`) ring.
  - Validation layer: the rules of 8.2 (`validation-barriers.cpp`).
- **Tests:** `nvrhi_explicit_barrier_tests`, with ctest entries `explicit_barriers_d3d11`, `_d3d12`,
  `_vulkan` and `_cuda`. Each creates its device through `createDeviceOnAdapter` on the NVIDIA adapter.
  They cover:
  - features and heap bindings;
  - colour barriers: discard, a split pair across unrelated work, a combined read state, UAV
    barriers, and a readback;
  - depth and stencil planes transitioned separately (D24S8);
  - aliasing: placed textures, the byte-overlap rule, and a readback of the incoming alias;
  - every validation rule, including a state call inside an explicit-barrier scope and a texture
    state D3D12 cannot hold;
  - the CPU wait table: poll, finite (about 20 ms), infinite, `waitFences` any and all;
  - CPU and GPU signals;
  - a producer/consumer pair on two queues with a fence and, on Vulkan, an ownership transfer, read
    back;
  - on Vulkan, a deliberate write-after-write hazard that synchronization validation must report.
- **Deviations from the plan text:**
  - One test executable, not `nvrhi_barrier_tests` and `nvrhi_fence_tests`: the cross-queue test
    needs both.
  - The `SubresourceRegion` helpers are inline in `nvrhi.h`, because ABI rule E forbids bodyless
    non-virtual members in public headers. `resource-barrier.cpp` holds the layout assertions
    (`SubresourceRegion` 20 bytes, `TransitionBarrier` 48, `ResourceBarrier` 56 with the union at
    offset 8) and the shared helpers.
  - D3D11 signals from the CPU through `ID3D11DeviceContext4::Signal` plus a flush, and flushes before
    every wait. `ID3D11Fence` has no CPU-side signal that orders against the context.
  - CUDA fences with `FenceDesc::shared` return `FE_UNSUPPORTED` (follow-up below).
  - Vulkan enables `separateDepthStencilLayouts` when the device has it and records it in
    `vulkan::DeviceDesc`. Without it, a one-plane barrier is reported and widened to both aspects.
- **Fixes found on the way:**
  - Vulkan queue waits on submitted semaphores used `eTopOfPipe`, so nothing waited. They now use
    `eAllCommands`.
  - A Vulkan transition to `ResourceStates::Unknown` is a memory barrier, not a layout transition to
    `UNDEFINED`: VUID-VkImageMemoryBarrier2-newLayout-01198.
  - Vulkan `bindImageMemory`/`bindBufferMemory` catch `vk::SystemError` and return false.
- **Design correction (6.3):** on the enhanced path, `LAYOUT_DEPTH_STENCIL_READ` does not admit
  `ACCESS_SHADER_RESOURCE`. The Agility SDK 1.619 debug layer rejected it, and the specification's
  table agrees.
  - Combined read sets now map to `GENERIC_READ`, or to `DIRECT_QUEUE_GENERIC_READ` once a depth,
    resolve or shading-rate read joins.
  - A texture state that combines a UAV or write access with another access has no layout on every
    queue. D3D12 `barriers` refuses it on both paths (`FE_INVALID_ARGS`).
  - nvrhi's automatic enhanced path uses the same resolver. It used to assert on
    `DepthRead | ShaderResource`, and in Release it kept the first layout.
  - Design 6.3 and ADR 0015 were updated to match.
- **Item 6, CUDA stream memory operations**, on an RTX 4050 Laptop GPU with driver 13.04 under WDDM:
  - `CAN_USE_64_BIT_STREAM_MEM_OPS` = 1, `CAN_USE_STREAM_WAIT_VALUE_NOR` = 1,
    `TIMELINE_SEMAPHORE_INTEROP_SUPPORTED` = 1.
  - `cuStreamWriteValue64` and `cuStreamWaitValue64` each work, and a wait on host-pinned memory is
    released by a CPU write.
  - A GPU wait enqueued *before* the GPU write that satisfies it, on another non-blocking stream,
    deadlocks: the writing stream never completes.
  - The event ring stays, as the design chose, and the rule "a GPU wait is enqueued after its signal"
    stands for any future memory-op variant.
- **Enhanced barriers on this machine:** Windows 10's in-box D3D12 has none, and the worktree build has
  `NVRHI_WITH_RTXMU=ON`, which turns them off. The enhanced path was therefore verified in a standalone
  nvrhi build (D3D12 only, RTXMU off) running the same test executable with the Agility SDK 1.619 in
  `.\D3D12\` (`NVRHI_TEST_AGILITY_SDK_VERSION=619`). It reported `enhanced barriers: 1`.

*P1.2 as built (2026-11-05).* The rename of design 3.3 is in ethereal-donut `3bfe4cb` and
ethereal-samples `d5bad16`, one commit each.
- **donut:** `app::IAppLayer`, `AddLayerToFront`, `AddLayerToBack`, `RemoveLayer`, `m_vLayers` and
  `app::ImGuiLayer` in 5 files. The parameter and comment wording in `DeviceManager` follows the new
  names (`pLayer`, "layers").
- **samples:** the same names in 40 source files and 2 READMEs. The script is word-bounded, keeps the
  line endings (8 of the files are CRLF) and leaves `nvrhi::IRenderPass` alone.
- **Deviations:**
  - The header and source follow the class: `donut/app/ImGuiLayer.h` and `src/app/ImGuiLayer.cpp`
    (git renames). The design named only the class.
  - Some files keep the old names on purpose because they describe history:
    - ethereal-samples ADR 0001;
    - nv_asteroids `docs/class_map.md` and `docs/featuredemo_map.md`, which map the 2018 binary,
      whose donut class was `IRenderPass`.
  - The design's count of 43 sample files was approximate. 42 files change.
- **Exit:**
  - Release: all 120 steps after the reconfigure. Debug: everything except the 5 WaveWorks steps,
    as before (known issues). ctest 49/49 in both configurations.
  - Debug smoke runs of `point-cloud` (GVDB: `ImGuiLayer`, `AddLayerToBack`, `RemoveLayer`), each
    captured through DBWIN by PID with the layer DLL confirmed in the process:
    - `-d3d12 --debug --screenshot`: `D3D12SDKLayers.dll` loaded; saved frame 60; exit 0; no warnings
      or errors.
    - `-vk --debug`, closed with `CloseMainWindow` after 20 s: `VkLayer_khronos_validation.dll`
      loaded; exit 0; no warnings or errors.
    - With `--screenshot`, the Vulkan run reports the back buffer's missing `TRANSFER_SRC` usage
      (known issues). That is older than this plan.

*P1.3 as built (2026-11-05).* The device-free graph core is in ethereal-donut; nvrhi's `abi_lint.py`
gained the option that lints it.
- **Headers** (`include/donut/render`): `RenderGraph.h`, `RenderGraphLambdaPass.h` and
  `RenderGraphFrameData.h`. They follow design section 12, plus these additions, which were summarised
  to the user before the sources:
  - the `Access` bits of 6.1;
  - `BackendProfile`, `LatticePolicy` and `GetReferenceProfile` with six device-free profiles;
  - `CompileOptions`, `DebugFlags`, `ScheduleFlags` and `ExecuteDesc`;
  - the `ICompiledRenderGraph` queries. Barriers are device-free `PlanBarrier`s that name graph resource
    indices; the executor lowers them once per plan. RPS's counterpart is
    `RpsCmdDiagnosticInfo::transition`;
  - the `IResourceRegistry` methods;
  - the device-free import stand-ins `ImportTextureDesc` and `ImportBufferDesc`;
  - `GetFrameIndex` and `GetDiagnostics`;
  - `VerifyPlan` with an optional previous plan;
  - `AddLambdaPassWithPrepare` and the optional `outPass` parameter.

  Added while implementing: `BackendProfile::resourceHeapTier`, for the D3D12 tier-1 heap classes of 7.5.
- **Sources** (`src/render`):

  | File | Contents |
  | --- | --- |
  | `RenderGraphInternal.h`, `RenderGraphCompile.h` | the concrete classes, the frame arena, the compile state |
  | `RenderGraph.cpp` | recording, the setup context, the structural hash, `Compile` and `Execute` |
  | `RenderGraphCompiler.cpp` | phases 1-5 and 7, the plan and its queries |
  | `RenderGraphTransitions.cpp` | phase 6 |
  | `RenderGraphProfile.cpp` | 9.2 and the lattice |
  | `RenderGraphRegistry.cpp` | persistent and history records; the bounded LRU plan cache |
  | `RenderGraphVerifier.cpp` | 11.1 |
  | `RenderGraphDump.cpp` | the JSON and Graphviz dumps of 11.3 |

  `Execute` returns `FE_UNSUPPORTED` without a device, and `FE_NOT_IMPLEMENT` until P1.4.
- **Two cache levels.**
  - The *structure*, per structural hash: queue assignment, including the `LatticePolicy` check that
    demotes an async pass whose barriers cost more than its overlap gains; the superset's lifetimes; the
    memory plan. Every pass-enable mask shares it.
  - The *plan*, per mask: policies and culling, schedule, transitions, segments.
- **The verifier shares no code with the walk.** It replays the plan's segments in submission order
  against per-subresource state machines of the physical resources, with happens-before between queues
  taken from the plan's fence waits only. A fence round-trip back to the same queue also orders memory.
  - Its first frame learns the states the plan assumes at frame start; later frames check them. A
    history is replayed through its whole rotation.
  - A plan switch replays the old plan's frame, then the registry's patch (shared physical resources
    moved to the states the new plan expects at their first touch, and a full wait for the old frame),
    then the new plan.
- **Tests** (ethereal-donut `tests/`):
  - `test_render_graph`, 31 tests;
  - `rdg_bench`, and a `rdg_bench_smoke` ctest entry;
  - `donut_render_graph_header_hygiene` (3.2);
  - `donut_render_graph_abi_lint`, which runs nvrhi's `abi_lint.py --api-header` over `RenderGraph.h` with
    the nvrhi headers' types known; a planted by-value struct and a missing `noexcept` were detected;
  - `donut_render_graph_header_tus`, one compile-only `/W4` unit per header.
- **The corpus:** 31 hand-written graphs and 20 seeded random ones, 51 in all.
  - Each runs on the six reference profiles; CUDA skips the 20 that have raster passes. Profiles with
    the Placed tier run with and without it. That makes 377 verified plans.
  - Each verified plan is replayed for at least two frames.
  - Each also switches to its variant (another mask or another graph): 377 verified plan switches.
  - Negative test: `SkipAliasingBarriers` makes the verifier fail on the aliasing chain.
- **Golden barrier lists** in `tests/src/render/golden/deferred_frame_6_11.txt` (under `src/`, because
  `test_vfs` expects the tests folder to hold only `include/` and `src/`): four profiles, without and
  with async SSAO, and a separate-family plan with async SSAO forced. Reviewed against 6.11:
  - D3D12 without async: one depth read state for all four readers. GB0, GB1, GB3 and MV are split
    from GBuffer's epilogue to their consumers.
  - D3D12 with async SSAO: the three groups of 6.11, in its order. `DEPTH_READ → NON_PIXEL` sits in
    GBuffer's epilogue, ahead of SSAO's signal, and the splits are joined across the segment boundary.
  - Vulkan with one family: one depth layout barrier, with or without async SSAO.
- **Deviations from the design text:**
  1. 6.11's depth read state is `DepthRead|NonPixelShaderResource`: SSAO and DeferredLighting are
     compute passes in the encoded frame. The discard back to `DepthWrite` at frame start is a second
     depth transition per frame; the design counted only the read one.
  2. With a separate compute family, depth readers on both queues split into groups as on D3D12,
     because nvrhi's lowering adds a depth read's fragment-test stages to an acquire on the compute
     queue. The default `LatticePolicy` then demotes async SSAO, with a warning; 6.11 expected one layout
     barrier and two ownership pairs. The golden file records the forced plan. This feeds pass 2's
     ownership-versus-`CONCURRENT` decision (6.8).
  3. With one Vulkan family, a read group that spans queues holds a state legal on its first reader's
     queue, where the transition runs.
  4. The plan-switch patch is the registry's work at execution (P1.4): its tracked per-subresource
     states, plus a full wait for the previous frame. The verifier models it; there is no device-free
     patch builder.
  5. `ScheduleFlags::GroupReads` is accepted but does not reorder yet.
  6. `Compile` runs the verifier only under `StrictValidation`, not on every Debug miss.
  7. `HostRead` lowers to `CopyDest`, because D3D12 readback heaps never leave `COPY_DEST`.
  8. Hazard rules beyond 6.5:
     - A UAV read followed by a UAV write gets a UAV barrier (reason WAR): a hazard 6.5's list omits.
     - On Vulkan, a write after a write in one state gets a same-layout barrier. D3D12 relies on its
       implicit ordering of non-UAV writes in one state.
  9. On D3D12 legacy, a discard is recorded only into RT, DS or UAV states, as `DiscardResource`
     requires. Other first uses are full writes.
  10. The overlap rule of 6.2 is checked on the declared regions in phase 1, so profiles that ignore
      planes still accept a stencil write beside a depth read.
  11. Culling keeps earlier writers alive behind a `FullWrite` that covers only part of a resource.
- **Exit (design step 3):** met. The numbers are in the verification results below.

*P1.4 as built (2026-11-05).* The executor and the registry's runtime half are in ethereal-donut
(`351921a`).
- **Sources:** `RenderGraphExecutor.cpp` (new) holds the executor. `RenderGraphRegistry.cpp` gained
  waiting, release and statistics. The compile side gained three things the executor needs:
  - `CompiledRenderGraph::m_EntryStates`, the plan's frame-start state per unit. It replaces the
    per-resource `entry` that the P1.3 follow-up called out.
  - `PlanUse::accessIndex`, which finds a use's clear value.
  - `PlanResource::isRenderTarget`.
- **Lowering, once per plan.** `PlanBarrier`s become `nvrhi::ResourceBarrier` arrays per pass and slot.
  Host-kept resources become tracker operations, and so does every barrier on a profile without
  `explicitBarriers`. Each frame patches only the resource pointers of imports, persistent resources,
  history layers and extracted textures.
- **Physical resources** belong to a structure instance (all masks of one structural hash), to a
  persistent or history record, or to the extract pool.
  - Each tracks per-subresource states and the plan serial that owns them. While one plan repeats, its
    cyclic model holds and nothing is checked.
  - On a plan switch, `FinalizeStates` makes the old plan's states exact. History layers take the
    frame-start state of the layer they serve next. Patch barriers then reach the new plan's entry
    states.
  - Unused structure instances are collected; the free pool ages out after 120 frames.
  - An extracted texture returns to the pool when the pool holds its only reference.
- **A frame:**
  - The prologue graphics list opens only when there are patches or a `Prepare` upload. It is submitted
    first. On a switch it waits for the previous frame's other queues, and every queue's first segment
    waits for it.
  - One command list per segment, recorded in plan order on the calling thread. Each segment signals its
    queue's fence and waits for its producers. A wait on the previous frame uses that frame's values
    unless the plan switched; after a switch, the first segment of each queue waits for the whole
    previous frame.
  - Pass modes:
    - Native passes run inside `setExplicitBarrierScope`.
    - Tracked passes begin tracking at the declared states, run with automatic barriers, and are
      cross-checked in Debug.
    - Restore passes set the declared states back and commit.
  - Graph markers wrap the passes.
  - Without fences (D3D11 before 11.4), one `IEventQuery` per frame.
- **The registry:** per-queue fences, `WaitForFrames`, and `ReleaseResources`. `ReleaseResources`
  finalizes the last plan's states, then drops plans, instances and pools; persistent resources stay.
  `ReleasePersistent` reallocates on next use. `RegistryStatistics` gained `objectsCreated`, the count
  of every `create*` call.
- **Tests:** `test_render_graph_gpu <backend>`, with ctest entries `test_render_graph_gpu_{d3d11,d3d12,
  vulkan,cuda}` (`RUN_SERIAL`, label `gpu`). Copies and clears only, every result read back:
  - buffer chains on one queue and with an async fill;
  - twelve frames of mask and async plan switches;
  - Tracked and Restore passes;
  - the debug switches;
  - a persistent buffer across plan switches, `ReleaseResources` and `ReleasePersistent`;
  - a `Prepare` upload;
  - render-target and depth clears through the framebuffer;
  - a three-layer history with `IsNewAllocation` per layer, across `ReleaseResources`;
  - `Extract` with pool reuse;
  - the tracker fallback (a profile without `explicitBarriers`);
  - the Native-scope guard, which expects the validation layer's error;
  - on Vulkan, a deliberate hazard proving that synchronization validation is loaded;
  - the steady state.
- **Steady-state measurement.** The test replaces `operator new` and counts allocations in its own
  module, where the graph, the executor and nvrhi are linked; the native runtimes allocate elsewhere.
  - It runs on the device without the nvrhi validation layer.
  - Recording and the cached compile must allocate nothing.
  - Execution must allocate no more, per frame (median), than a hand-written loop making the same nvrhi
    calls. Those allocations are nvrhi's own: 20 per frame on D3D12, 2 on Vulkan, 0 on D3D11, 23 on
    CUDA, identical in both loops.
  - `RDG_ALLOC_TRACE=1` prints the stack of each allocation of one measured frame.
- **Fixed on the way:**
  - On Vulkan, a write to an import in its entry state after the previous frame's write had no barrier.
  - The prologue list was opened and closed every frame but submitted only with work, which nvrhi
    reports.
  - The executor called `runGarbageCollection` itself; on Vulkan that allocates, and in an app it runs
    twice.
  - Tracked-mode checks ran on D3D11, where the tracker is not real.
  - The tracker fallback left automatic barriers on.
  - `ReleaseResources` dropped the last plan without finalizing its history states.
  - Segments waited for the prologue only when it held patches, not when it held only uploads.
- **Deviations from the plan and the design:**
  1. The Placed tier returns `FE_UNSUPPORTED` until P1.6. The GPU half of the exit criterion
     "`SkipAliasingBarriers` makes the aliasing test fail" moves to P1.6. The device-free negative test
     (P1.3) stands.
  2. `ExecuteDesc::timers` is P1.5 (per-pass timers) and `parallelFor` is P1.7. Segments are recorded
     on the calling thread.
  3. `ReleaseResources` calls no `OnResourcesReleased`: a cached plan holds no pass, because passes
     belong to one frame. P1.5 calls it for the current frame's passes when donut passes have caches.
  4. A `Write` access with `AccessFlags::Clear` clears to zero; `Write` has no clear value.
     `SetColorTarget` and `SetDepthTarget` carry one.
  5. The executor does not call `runGarbageCollection`. The host does, once per frame (10.1), as
     DeviceManager already does.
  6. A new hazard rule (Vulkan only), extending P1.3 deviation 8. When an import's first access is in its
     entry state and either side writes, the plan emits a same-state barrier: Vulkan orders nothing
     across submissions. D3D12 orders and flushes between `ExecuteCommandLists` calls.
  7. The tracker fallback keeps automatic barriers off and applies the plan through `setState` and
     `commitBarriers`.
     - A fresh resource starts tracking from `Common`, its creation state on every backend.
     - A global UAV barrier (`resource ~0u`) has no tracker form and is dropped.
  8. Tracked and Restore change nothing on D3D11 and CUDA, which record no barriers.
- **Exit (design step 4):** met, except the GPU aliasing test (deviation 1). Headless graphs run with
  clean validation on all four backends. Steady-state frames make no `create*` call and add no
  allocation. A three-layer history rotates correctly and reports `IsNewAllocation` per layer.

*P1.5 as built (2026-11-05).* donut's passes run in a graph (ethereal-donut `5794e0f`); ethereal-nvrhi gained
one Vulkan fix (`bfb25e3`).
- **Bases (13.1).**
  - The seven `ObjectImpl<IObject>` passes and `IGeometryPass` now derive from `ObjectImpl<IGpuPass>`.
  - The six passes with no base are reference counted now. No owner in donut or the samples needed
    changing: those passes are constructed only in their own files. nv_asteroids declares a
    `shared_ptr<PixelReadbackPass>` but never creates it.
  - DLSS, LightProbeProcessing, PixelReadback, Manipulator and JointsRender return `FE_UNSUPPORTED` from
    `Setup`.
- **Graph entries (13.2, 13.3).** Each is an `AddToGraph(graph, Inputs)` returning the written ids, and
  its body is the immediate path's code:

  | Pass | Uses | Mode |
  | --- | --- | --- |
  | GBufferFill, Depth/shadow, Forward, MaterialID | `IGeometryPass::AddToGraph`, one per child view (a cascade, a cube face) | Tracked |
  | DeferredLighting | one compute use | Native |
  | Sky, EnvironmentMap | one raster use per view | Native |
  | ToneMapping | histogram (transient buffer, cleared), exposure (persistent buffer), one resolve per view | Native |
  | TAA | motion vectors per view, then the resolve; the feedback is a two-layer history; `feedbackIsValid = !IsNewAllocation(previous)` | Native |
  | SSAO | one use; the deinterleaved arrays are pass-local transients | Restore |
  | Bloom | per view: two downscales, two blurs, a blended apply, on transients | Native |
  | MipMapGen | one use: reads mip 0, writes the others | Restore |
  | Blit | the new `BlitPass`, over `CommonRenderPasses::BlitTexture` | Native |

  - Graph constructions (Sky, ToneMapping, TAA, SSAO, Bloom, EnvironmentMap, MipMapGen) take no target.
    They create nothing until `Prepare`, which makes their shader variants and pipelines from the graph's
    framebuffer and descriptions. DeferredLighting and the geometry passes keep `Init`.
  - The geometry passes' pipeline caches recreate a pipeline when the framebuffer formats change,
    instead of asserting (13.3).
- **App (13.4, 11.3).**
  - `app::RenderGraphLayer` resets the graph, clears `FrameData`, imports the back buffer (host-kept),
    calls `BuildGraph`, then compiles and executes. Pass toggles by name are resolved through the last
    plan. A resize releases the pooled memory.
  - `app::RenderGraphVisualizer` is an `ImGuiLayer`. It shows statistics, timers, passes with their
    barriers and reasons, lifetimes with heap placement, the debug switches and pass toggles.
    `DrawWindow` embeds it in another UI layer.
  - Per-pass GPU timers (`ExecuteDesc::timers`): timer queries in a ring of four frames, read back when
    they complete. The copy queue is not timed.
  - Run statistics: record and submit times, passes, segments, barriers and tracker calls.
- **Tests:**
  - `test_render_graph_passes`, device-free, using `tests/src/render/rdg_donut_frame.*`:
    - one frame of every graph entry on a null device, 22 uses, compiled and verified on all five
      barrier profiles;
    - golden access lists on D3D12 legacy (`golden/pass_accesses.txt`, with each pass's mode);
    - per-view folding: two Bloom chains over a stereo view share physical textures;
    - an unsupported pass, which `AddPass` and `Compile` name.
  - `test_render_graph_gpu` executes the same frame for six frames on D3D11, D3D12 and Vulkan under
    validation, with timers and run statistics checked.
  - `test_render_graph_layer {d3d11,d3d12,vulkan}` runs `RenderGraphLayer` on a headless
    DeviceManager. It covers toggles (with passthrough), a resize and statistics.
  - nvrhi `explicit_barriers_vulkan` gained a depth texture sampled on the compute queue. Without the
    fix below it reports `VUID-vkCmdPipelineBarrier2-dstStageMask-09676`.
- **Fixed on the way:**
  - *Vulkan sampled depth.* nvrhi samples a depth texture in `eDepthStencilReadOnlyOptimal`
    (`ShaderResource | DepthRead`), and its descriptors declare that layout. On Vulkan the graph now
    lowers a shader read of a depth or stencil texture to that pair; the queue rule accepts it on the
    compute queue.
  - nvrhi's Vulkan `barriers()` drops graphics-only stages and accesses on a compute or copy queue. The
    6.11 golden lists change accordingly: one fewer read-group change on Vulkan.
  - *D3D12 legacy discards.* `DiscardResource` takes a render-target texture only in RENDER_TARGET and a
    depth texture only in DEPTH_WRITE. A texture that is both render target and UAV is no longer
    discarded in UAV state, and the verifier checks the rule.
  - *Tracked and Restore.* They track the plan's actual state (`PlanTrackedState`, per pass), which a
    merged read group widens beyond the pass's own access. They used to declare the narrower state.
  - *MipMapGen null textures.* They are per pass object now: a process-wide static outlived its device
    at exit and gave the first device's textures to every other device. They are in the target's format,
    as Vulkan storage images require.
  - `ReleaseResources` calls `OnResourcesReleased` on the current frame's passes, once per object (P1.4
    deviation 3).
  - The dump lists each pass's type, mode and declared uses.
  - `GetPlanHash` is the cache key (structural hash, profile, options), not the structural hash.
- **Deviations from the plan and the design:**
  1. `ISetupContext::SetDepthTarget` takes a region, like `SetColorTarget`. 13.3 runs DepthPass once per
     shadow-map slice, which needs one; design 12's signature has none (an ABI change).
  2. `IRenderGraph::GetTextureDesc` and `GetBufferDesc`, so that a pass sizes its transients from its
     inputs. They copy no debug name, so recording still allocates nothing.
  3. `IResourceRegistry::GetRunStatistics`, `GetPassTimingCount` and `GetPassTiming`, with the
     `RunStatistics` and `PassTiming` structs, for 11.3. The run statistics count tracker calls, not
     allocations.
  4. The geometry passes share one `IGeometryPass::AddToGraph` rather than one entry each, so sample
     subclasses (VXGI's `VoxelShadingPass`) get it too. They stay Tracked; 13.3's "then Native" is a
     follow-up.
  5. Blit is a new `BlitPass` class. EnvironmentMap is in the graph too: 13.3 lists it, the plan's list
     did not.
  6. SSAO's graph construction takes no `CreateParameters`; its shader options come per `AddToGraph`.
  7. The Visualizer is compiled and linked but not run: there is no windowed test. Pass 2's samples
     show it.
- **Exit:** met. donut and every sample build; WaveWorks still fails in Debug only (known issues). The
  device-free golden access lists pass. A headless frame of every pass type runs clean on three
  backends. The immediate entry points are unchanged; their bodies are now shared with the graph path.

*P1.6 as built (2026-11-05).* The Placed tier executes (ethereal-donut `29cf8f8`). ethereal-nvrhi gained
`Feature::MixedResourceHeaps` and a device-removed reason in its D3D12 message (`68b59e1`). Async compute
(6.8) and split barriers (6.4) were already compiled and executed by P1.3 and P1.4; this step runs them on
the GPU across frames, beside the Placed tier.
- **Probe (7.5).** `ComputeBackendProfile` on D3D12 sets `maxMemoryTier` to Placed when the device has
  `Feature::VirtualResources`. It takes `resourceHeapTier` from the new `Feature::MixedResourceHeaps`:
  D3D12 resource heap tier 2, and always true on Vulkan. Vulkan, D3D11 and CUDA stay Pooled. Every
  backend reports the placement estimate (`placedPeakBytes`).
- **Placement (executor).** It runs once per structure instance, which now owns the heaps:
  - Each physical object the plan placed becomes a virtual texture or buffer. Its actual size and
    alignment come from `getTextureMemoryRequirements` and `getBufferMemoryRequirements`.
  - A first-fit placement per planned heap, largest first, uses those numbers. Two objects share bytes
    only if their lifetimes are disjoint and the plan also placed them in shared bytes. The plan's
    aliasing barriers therefore cover every actual overlap.
  - The heaps (`DeviceLocal`) are sized to the actual placement, and the resources are bound.
  - On D3D12 resource heap tier 1, only render-target and depth textures are placed; buffers and other
    textures stay pooled (deviation 2).
  - If a heap or a binding fails, every object is dedicated instead, with a warning.
  - Placed objects never enter the free pool. When the instance's plans leave the cache, the registry
    retires its heaps and placed resources until every queue's fence passes the last frame's values
    (7.5). Barrier arrays hold raw pointers, and nvrhi's explicit barriers keep no references.
- **Aliasing barriers (6.7).** Once per plan instance, after the transients' slots are patched:
  - A barrier's `before` stays only if it actually overlaps the incoming resource; otherwise it is null.
  - A barrier whose incoming resource ended up unplaced is skipped when recorded.
  - Then the executor checks the actual placement: every resource whose bytes another placed resource
    shares must start with an aliasing barrier. Each uncovered resource is reported as an error.
- **Tests:**
  - The verifier corpus runs the Placed tier on both D3D12 heap tiers: 479 verified plans and 479 plan
    switches (377 before).
  - `heap_count` (design 14.8 item 16): one heap per queue on tier 2, one per queue and class on tier 1
    (2 and 5 heaps), on D3D12 legacy and enhanced.
  - `test_render_graph_gpu` gained:
    - `testPlaced`. Buffers X and Y and targets A and B alias on the graphics queue. A buffer used only
      by async passes gets a compute-queue heap, and one that crosses queues stays pooled. It runs 12
      frames with frames in flight and reads every third back. Frames 8-9 compile with `NoAliasing` (a
      second structure instance) and switch back. It runs on D3D12 at the device's tier and again
      compiled for tier 1; on the other backends it checks that the opt-in falls back to Pooled. Eight
      more frames alternate two placements with one cached plan, so that every frame retires the
      other plan's heaps while earlier frames are in flight.
    - `testSkipAliasingBarriers`: the executor's check reports X, Y, A and B, and the run with barriers is
      clean.
    - `testSplitBarriers`: A's transition is split around two passes, with 512² targets so that Vulkan
      splits too, and four frames in flight between readbacks.
    - `testVvlEventWitness` (below).
    - Harness switches: `RDG_GPU_ONLY=<name>` runs some tests; `RDG_GPU_DUMP=1` prints each new plan;
      `RDG_D3D12_NO_GBV=1` turns GPU-based validation off. A D3D12 run that throws prints the debug
      layer's stored messages.
- **Found on the way:**
  - *A VVL false positive.* VVL 1.4.357 reports a split barrier's `vkCmdWaitEvents2` layout transition
    as `SYNC-HAZARD-WRITE-AFTER-READ` against a read in an earlier submission. It does so even when a
    full `ALL_COMMANDS` → `ALL_COMMANDS` barrier separates the two: VVL's own `read_barriers` then list
    every stage. By the specification the wait's first scope is everything before its `vkCmdSetEvent2`
    in submission order, and execution dependencies chain across submissions. Nothing races.
    `testVvlEventWitness` records the pattern on raw nvrhi, without the graph, and asserts that VVL
    still reports it. The test's message handler sets aside exactly this report: `command =
    vkCmdWaitEvents2`, `hazard_type = WRITE_AFTER_READ`, `access = SYNC_IMAGE_LAYOUT_TRANSITION`, found
    at submit time. It matches syncval's structured properties
    (`VK_KHRONOS_VALIDATION_SYNCVAL_MESSAGE_EXTRA_PROPERTIES`). When VVL stops reporting it, the
    witness fails and the exemption goes.
  - nvrhi's D3D12 "Device Removed!" names the reason (`DXGI_ERROR_INVALID_CALL` found the test's own
    size mismatch on the way).
- **Deviations from the plan and the design:**
  1. The GPU aliasing test detects a missing barrier through the executor's check of the actual
     placement, not through a debug layer. D3D12's debug layer and GPU-based validation do not track
     aliasing: the Agility SDK 1.619 `d3d12sdklayers.h` has no aliasing message. The Placed tier runs on
     D3D12 only. A content race would need long-running shaders and would not fail deterministically.
  2. On D3D12 heap tier 1, the executor places render-target and depth textures only. nvrhi's
     `createHeap` makes tier-1 heaps for those only, and `HeapDesc` has no heap class. The compiler still
     plans all three classes, and the corpus verifies those plans.
  3. The executor does not replay the plan's offsets: the actual sizes differ from the estimate (a
     256-byte D3D12 placed buffer takes 64 KiB). Instead it places constrained by the plan's byte sharing.
     Members of one exclusion group (7.4) whose lifetimes meet are kept apart in the actual placement,
     where the plan let them share bytes: correct, but more memory.
  4. The Vulkan GPU test sets aside the VVL false positive above.
- **Exit:** met.
  - Headless graphs with async passes (buffer chains, plan switches, the Placed test's compute heap) and
    with split barriers run clean, frames in flight, under the D3D12 debug layer with GPU-based
    validation and under Vulkan synchronization validation (the one VVL report above set aside).
  - The verifier corpus covers the Placed tier on both D3D12 heap tiers.
  - On the GPU, `SkipAliasingBarriers` makes the aliasing test fail.

*P1.7 as built (2026-11-05).* Segments record on worker threads (ethereal-donut `df5dd96`); ethereal-nvrhi gained
one Vulkan fix (`4b1437a`).
- **Executor (10.1).** With `ExecuteDesc::parallelFor`:
  - At most `workerCount` tasks record the segments (0: one per segment). Each task records whole
    segments in plan order, and submission stays in plan order.
  - A pass object records on one thread: the segments that share one (a pass's per-view uses) form a
    group. The groups go to the tasks largest first, to the least loaded.
  - The command lists, pass contexts and per-pass timer slots are taken on the calling thread before any
    task runs. The barrier, state-call, pass and framebuffer counters are atomic. The tracker
    fallback's scratch belongs to each segment's context.
  - The per-frame scratch is sized once per plan instance, so a steady-state frame allocates nothing
    new in the executor (by construction; the allocation tests run serially).
  - D3D11 records on the calling thread. `RunStatistics::recordTasks` reports the tasks.
  - A split never crosses a segment (P1.3), so a finely segmented plan has fewer split barriers: the
    donut frame in eight segments has 53 barriers on D3D12, against 65 in one.
- **donut prerequisites (10.1).**
  - `BindingCache::GetOrCreateBindingSet` creates a missed set outside its lock and inserts it under the
    lock. The first insert wins, and every caller gets that set.
  - `CommonRenderPasses::BlitTexture` guards its pipeline cache with a shared mutex, creating a missed
    pipeline outside the lock.
  - The geometry passes and `MaterialBindingCache` already lock their caches.
- **Tests:**
  - `tests/src/render/rdg_worker_pool.h`: a fixed worker pool behind `ParallelForFunction`. The caller
    works too, a call allocates nothing, and workers spin briefly before they sleep.
  - `test_render_graph_gpu` gained:
    - `testParallelRecording`: buffer chains with async fills (one pass per segment), and a chain of
      32 blits, each by its own `BlitPass` sharing one `CommonRenderPasses`. Four tasks; contents read
      back.
    - `testDonutPasses(parallel)`: donut's frame in eight segments by four tasks, six frames, with
      timers.
    - `testBindingCacheConcurrency`: eight threads × 16 descriptions × 32 rounds; every thread gets the
      same set for a description.
    - `testBlitConcurrency`: four threads blit into four formats with two blend states each, so that
      the pipeline cache misses on every thread at once. Not on D3D11, whose lists are immediate.
  - `rdg_bench --parallel d3d12|vulkan [--gate]`: 64 passes (a seed, 62 blits, a copy) recorded on one
    list and on four threads (16 passes per segment). It measures `RunStatistics::recordMilliseconds`
    (patches, `Prepare` and recording) per 10.4: Release, no validation layers, 100 warm-up frames,
    then 300 frames per mode in alternating blocks of 50, medians. The ctest smoke runs are
    `rdg_bench_parallel_{d3d12,vulkan}` (`--quick`, RUN_SERIAL).
- **Fixed on the way:**
  - *Vulkan read-only depth attachments.* nvrhi stored them with `VK_ATTACHMENT_STORE_OP_STORE`, which
    is a depth-stencil write at the end of rendering that the read-only layout's barriers do not order.
    Recorded in segments, donut's frame reported it as `SYNC-HAZARD-WRITE-AFTER-WRITE`: Sky's end of
    rendering against SSAO's restore barrier in an earlier submission. In one list it went unreported.
    A read-only attachment now stores nothing (`VK_ATTACHMENT_STORE_OP_NONE`, core in Vulkan 1.3).
    nvrhi's tests have no graphics pipelines, so the parallel donut frame is the regression test.
- **Deviations from the plan and the design:**
  1. `RunStatistics::recordTasks` is new, a field of a struct returned by reference.
  2. The parallel-recording budget is measured on a device, through `rdg_bench --parallel`. 10.3 lists
     `rdg_bench` as device-free; recording needs command lists.
  3. The executor does not enforce 10.1's "from 16 passes per segment" rule. The host chooses
     `recordGranularity`, and the `ExecuteDesc` comment states the rule; the tests use smaller
     segments to exercise the threads.
- **Exit:** met. `rdg_bench --parallel` measures four threads at 50.5 % of one list on D3D12 and 37.8 %
  on Vulkan (budget 60 %). The `BindingCache` and `BlitTexture` concurrency tests pass on every backend
  that records in parallel; on D3D11, `BindingCache` only.

*P2.0 as built (2026-11-05).* Deterministic runs and A/B tooling (ethereal-samples `1ac249c`, ethereal-nvrhi
`27b93fb`, aggregate `tools/ab_compare.py`), and the references.
- **Deterministic options.** `ethereal-samples/src/sample_harness/SampleHarness.h`, used by
  `deferred_shading` and `variable_shading`:
  - `-frames N` exits after N frames; `-screenshot F` saves the last frame's back buffer. On Vulkan the
    swap chain is BGRA8, so the back buffer is blitted to RGBA8 first.
  - `-fixedstep` gives `Animate` 1/60 s per frame.
  - `-timings F` writes, as JSON, the median CPU frame time and the median GPU frame time of the frames
    after `-warmup N` (default 100). The CPU time is measured from one frame's start to the next; the
    GPU time is a timer query from a layer in front of the sample's to one behind it.
  - The harness layers render unfocused, so a scripted run does not stall.
  - `async_compute` is left out: a 100 Hz producer thread drives it, so no run of it repeats. P2.3's
    sample is a new bloom/SSAO graph, not a port of it.
- **`tools/ab_compare.py A B [--tolerance N] [--diff F]`** compares two images pixel by pixel. It reports
  identical, or the differing pixels, the largest channel difference and their bounding box; exit code
  1 beyond the tolerance. It ignores alpha unless `--alpha` is given. Two captures of one build
  (`deferred_shading -d3d12`, Debug) are identical.
- **Vulkan screenshots.** nvrhi's Vulkan swap-chain images gain `eTransferSrc` where the surface allows
  it (the known issue). The Debug runs that save a Vulkan back buffer are clean under the validation
  layer.
- **References from the unchanged main checkout.** The main checkout's commits (aggregate `264ac18`,
  ethereal-nvrhi `123d105`, ethereal-donut `4f4b31c` with shader-tool `b5bec4b`, ethereal-samples
  `37ac258`) were extracted with `git archive` into `D:\ps\repo\ethereal-rdg-baseline`, outside every
  repository, so that no checkout or worktree changed. The harness was added to its two samples,
  translated to the pre-rename layer API (`IRenderPass`, `AddRenderPassToBack`); nothing else changed.
  It was built in Release with the worktree's configure flags.
  - Captures: `-fixedstep -frames 400 -screenshot`, Release, NVIDIA adapter. They are kept in
    `D:\ps\repo\ethereal-rdg-baseline\references` (SHA-256 prefixes):

    | Image | SHA-256 |
    | --- | --- |
    | `deferred_shading-{d3d11,d3d12,vk}.png` | `92FCBAA9CE91CB13` (the three are identical) |
    | `variable_shading-d3d12.png` | `FBC4B407FC41FB36` |
    | `variable_shading-vk.png` | `1F59F9E9A061ED44` |

  - The first `variable_shading -d3d12` run after the build differed from every later run in 4 pixels
    by 1 (kept as `variable_shading-d3d12.first-run.png`). Later baseline runs and the worktree's runs
    are identical to each other, so the reference is a later run.
  - Timings, 10.4 protocol: Release, no validation, `-frames 401 -warmup 100` (300 frames), medians;
    two rounds, the second in reverse order:

    | Sample | CPU frame, ms (round 1 / 2) | GPU frame, ms (round 1 / 2) |
    | --- | --- | --- |
    | `deferred_shading -d3d11` | 0.505 / 0.505 | 0.390 / 0.390 |
    | `deferred_shading -d3d12` | 0.300 / 0.302 | 0.249 / 0.246 |
    | `deferred_shading -vk` | 0.346 / 0.342 | 0.275 / 0.276 |
    | `variable_shading -d3d12` | 0.820 / 0.792 | 0.765 / 0.737 |
    | `variable_shading -vk` | 0.809 / 0.822 | 0.755 / 0.767 |

  - The worktree's original samples, after pass 1, are identical to these references on every API:
    the bodies P1.5 shared between the immediate and the graph paths render the same.
- **Deviations:**
  1. The references come from the main checkout's commits plus the harness, not from the main checkout
     itself, which has no deterministic options. The harness is the only change.
  2. The timings report the CPU frame (start to start) and the GPU frame, not the sample's own frame
     timer: the original samples have none.
- **Exit:** met. Reference images and timings, with commit hashes, are above; `ab_compare.py` reports
  identical for two captures of the same build.

*P2.1 as built (2026-11-05).* `deferred_shading_rdg` (ethereal-samples `d40ee50`) and two executor fixes it
found (ethereal-donut `57db135`).
- **The sample.** It has the scene, view and passes of `deferred_shading`, recorded each frame on
  `app::RenderGraphLayer` through `GBufferFillPass`, `DeferredLightingPass` and `BlitPass`
  `AddToGraph`.
  - The G-buffer and the shaded colour are transients; the back buffer is the layer's import.
  - Per-pass GPU timers are on. `RenderGraphVisualizer` shows the plan in interactive runs, but not in
    the harness's deterministic ones, where it would draw over the image.
  - The measurement switches:
    - `-graphstats F`: the layer's frame cost (BuildGraph, Compile, Execute), the executor's record
      and submit time, and barriers per frame;
    - `-nocache`: `maxCachedPlans = 0`;
    - `-emptybodies`: the same graph with empty pass bodies;
    - `-notimers`.
- **Fixed on the way (donut):**
  - *D3D11 frames.* The executor signalled a fence on every submission, a `Signal` in the immediate
    context, which cost the D3D11 frame 10 % of its CPU and GPU time. D3D11 has one in-order queue, so
    the executor now tracks frames with the `IEventQuery` fallback of P1.4. This is the first time
    that fallback runs. It uses a ring of three queries, each read before it is ended again; D3D11
    warned about abandoned results with one. The layer's own D3D11 cost fell from 0.078 to 0.021 ms.
  - *D3D12 legacy discards.* A transient whose first use is a clear is no longer discarded first.
    `DiscardResource` is a command of its own, and the clear initializes the subresources (a placed
    render target or depth texture may start with either). Enhanced barriers and Vulkan keep the
    discard, which leaves the undefined layout. The 6.11 golden lists lose those flags.
- **Results** (Release, NVIDIA adapter, `-fixedstep`; timing runs `-frames 401 -warmup 100`, 300
  frames; the baseline is P2.0's build of the main checkout's commits):
  - *Images:* identical to the references on D3D11, D3D12 and Vulkan (`ab_compare.py`, 0 differing
    pixels), before and after the fixes.
  - *Validation:* 120 Debug frames on each API with zero messages: the D3D12 debug layer, the Vulkan
    validation layer with `VK_LAYER_VALIDATE_SYNC=1`, and the D3D11 debug layer. Each layer's DLL
    was seen in the process.
  - *Barriers per frame:*

    | API | Original (native capture) | Graph |
    | --- | --- | --- |
    | D3D12 | 15 (RenderDoc) | 14 (RenderDoc and `RunStatistics`, equal) |
    | Vulkan | 27 image barriers (RenderDoc) | 19 (`RunStatistics`) |
    | D3D11 | implicit | implicit |

    Each graph barrier carries its reason in the plan (dump and visualizer).
  - *Frame times,* timers off, medians over alternating rounds (8 rounds on D3D12 and Vulkan, 6 on
    D3D11 after the fixes); per-run medians, then their median (and minimum):

    | API | CPU frame, ms: original / graph | GPU frame, ms: original / graph |
    | --- | --- | --- |
    | D3D12 | 0.305 (0.299) / 0.301 (0.295) | 0.175 (0.174) / 0.176 (0.175) |
    | Vulkan | 0.275 (0.274) / 0.274 (0.270) | 0.210 (0.210) / 0.207 (0.206) |
    | D3D11 | 0.375 (0.374) / 0.380 (0.378) | 0.266 (0.265) / 0.265 (0.265) |

  - *Executor overhead* with empty bodies (record and submit, barriers and clears included): 0.025 ms
    on Vulkan, 0.041 ms on D3D12, 0.004 ms on D3D11 (budget 0.2 ms).
  - *Plan cache (7.7):* the layer's frame cost is 0.069 ms with the cache and 0.112 ms without on
    D3D12; 0.054 and 0.104 ms on Vulkan; 0.021 and 0.054 ms on D3D11. The cache stays.
  - *Timers:* per-pass timers add 0.016 ms to the layer on D3D12 and 0.002 ms on D3D11.
- **Deviations:**
  1. The frame-time comparison runs with `-notimers`. The original has no per-pass timers, and on
     D3D11 timer queries cost both CPU and GPU time.
  2. Two budgets are met within noise rather than strictly. D3D12's GPU frame is 0.001 ms (0.6 %)
     above the original, while frame-to-frame clock changes on this laptop GPU reach 40 %. D3D11's CPU
     frame is 0.005 ms (1.3 %) above it in every round: the graph's fixed per-frame work (recording,
     plan lookup, bookkeeping) has no barrier tracking to save there, unlike D3D12 and Vulkan, where
     the graph is at or below the original.
  3. The Vulkan barrier comparison counts the graph through `RunStatistics`. That count matched
     RenderDoc's exactly on D3D12.
- **Exit:** met, with deviation 2. Images are identical, validation is clean, barriers are fewer, the
  executor overhead is within budget, and the cache is kept on its numbers.

*P2.2 as built (2026-11-05).* `variable_shading_rdg` (ethereal-samples `61a3b43`), with two donut additions
(ethereal-donut `dbcbd85`) and a fix to the original sample. A DeviceManager change went in on the way
(ethereal-donut `4fe8394`, by the user's request): a new window neither takes the focus nor comes to the
front of the display (`DeviceCreationParameters::bringWindowToFront`, default false).
- **The sample** records variable_shading's frame in the original's order:
  1. TAA's motion vectors (from the second frame on);
  2. the shading-rate compute pass;
  3. the forward pass, a Tracked lambda pass. It prepares the lights on its own list (the light
     constants are a volatile buffer) and draws opaque then transparent, with the surface as the
     framebuffer's shading-rate attachment through a `ShadingRateRead` access;
  4. TAA's resolve; 5. a blit.
  - Colour, depth and motion vectors are persistent resources, as the original's targets carry from
    frame to frame, with the original's clear value. TAA's feedback is its history pair.
  - It is an `ApplicationBase` for its scene loading and renders through a `RenderGraphLayer` it
    owns.
  - Its switches match P2.1's.
- **donut:**
  - The executor makes a raster pass's `ShadingRateRead` use its framebuffer's shading-rate attachment.
    The framebuffer cache keys on a tenth slot. `testShadingRateAttachment` checks it on D3D12 and
    Vulkan.
  - `TemporalAntiAliasingPass::AddMotionVectorsToGraph` and `AddResolveToGraph` are `AddToGraph`'s two
    stages, for a frame that uses the motion vectors before it draws the scene. `AddToGraph` is
    unchanged.
- **The original's TAA bug.** variable_shading never called `TemporalAntiAliasingPass::AdvanceFrame`,
  so its resolve read `feedback1` on every frame while writing `feedback2`. Its history was a texture
  nothing wrote. The graph version's history pair feeds back correctly, so from the second frame on
  the images differed in 82 % of pixels (frame 1 matched). The original now advances after its
  resolve, in the worktree and in the P2.0 baseline build. The variable_shading references were
  captured again from that build (`variable_shading-d3d12.png` SHA-256 `15158E7C2F609829`,
  `variable_shading-vk.png` `A2913C16D14A17E6`). The earlier ones are kept as `*.no-advance-frame.png`.
- **Fixed on the way (in the sample):**
  - `RenderView` does not prepare a draw strategy for the scene: `PrepareForView` first, as
    `RenderCompositeView` does.
  - Without the optimized clear value the D3D12 clears were not fast clears, and the graph frame was
    10 % slower than the original.
- **Results** (Release, NVIDIA adapter; D3D12 and Vulkan only, as the original):
  - *Images:* the original itself varies between runs in three pixels: (1015, 272), (1144, 639) and
    (1145, 639). Over five baseline runs and three graph runs on each API, every graph pixel value is
    one the baseline also produces.
  - *Validation:* 120 Debug frames on each API with zero messages: the D3D12 debug layer, and the
    Vulkan validation layer with `VK_LAYER_VALIDATE_SYNC=1`; each layer's DLL was seen loaded.
  - *Barriers per frame:* D3D12: 20 in the original (RenderDoc) against 15 in the graph. Vulkan: 17
    in the graph (`RunStatistics`); the original was not counted there.
  - *Frame times,* `-notimers`, alternating rounds, median of the per-run medians (and minimum):

    | API | CPU frame, ms: original / graph | GPU frame, ms: original / graph |
    | --- | --- | --- |
    | D3D12 (6 rounds) | 0.886 (0.814) / 0.850 (0.772) | 0.833 (0.761) / 0.798 (0.716) |
    | Vulkan (14 rounds) | 0.829 (0.762) / 0.856 (0.761) | 0.782 (0.710) / 0.804 (0.711) |

  - *Executor overhead* with empty bodies: 0.047 ms on D3D12, 0.027 ms on Vulkan (budget 0.2 ms).
  - *Plan cache:* the layer's frame cost is 0.104 ms with it and 0.145 ms without on D3D12; 0.088 and
    0.142 ms on Vulkan. The cache stays.
- **Deviations:**
  1. The comparison is against the original with its TAA fix, in both builds.
  2. On Vulkan the graph's median frame is 3 % above the original (paired per-round median +0.029 ms
    GPU); the minimums are equal, and between sessions the medians moved by 10 % either way. Met
    within noise, as P2.1's deviation 2.
  3. Vulkan's barrier count is the graph's own; the original was counted on D3D12 only.
  4. The geometry passes' `AddToGraph` cannot carry this frame's forward pass: the light constants
     are a volatile buffer written by `PrepareLights`, which must run on the drawing list. The sample
     records the forward pass as a lambda pass instead.
- **Exit:** met, with deviations 1-3.

*P2.3 as built (2026-11-05).* `async_compute_rdg` (ethereal-samples `7d33ae8`), with donut additions and a
timer fix (ethereal-donut `7b2c20f`) and an nvrhi fix (ethereal-nvrhi `3d4e449`).
- **The frame,** Sponza, deferred:
  1. GBufferFill: the G-buffer and depth, transients;
  2. SSAO with `PassFlags::AsyncCompute`, on the compute queue;
  3. ShadowDepth: the sun's four 2048² cascades, into the `CascadedShadowMap`'s texture, which is
     imported host-kept. It needs nothing that SSAO writes, so it overlaps SSAO;
  4. DeferredLighting with the ambient occlusion and the shadow map;
  5. Sky; 6. TAA (motion vectors from depth, then the resolve); 7. Bloom; 8. ToneMapping; 9. a blit.
  - After DeferredLighting the G-buffer is dead. The motion vectors, the TAA output, the bloom chain
    and the tone-mapped colour reuse its memory: these are the reusable transients of 10.3.
  - `-immediate` records the same frame without a graph, on one list with nvrhi's automatic barriers,
    with SSAO on the graphics queue. There is no original sample (P2.0), so this is the GPU-time
    reference. Its images match the graph's within the frame's own variation.
  - Switches: `-sync`, `-nosplit` and `-placed` turn each step-6 feature on or off. `-asyncgain N`
    overrides `LatticePolicy::asyncOverlapGain`. `-graphstats`, `-passtimes` (per-stage GPU times, from
    the graph's timers or from timer queries around the immediate stages) and `-size WxH` measure.
- **donut:**
  - `SsaoGraphInputs::asyncCompute`.
  - A non-const `RenderGraphLayer::GetProfile()`. The plan cache keys on the profile.
  - `PlanStatistics::unplacedTransientBytes`: transients kept out of placement (cross-queue, `NoAlias`,
    `DebugCapture`). They take memory of their own, so the peak transient memory is
    `placedPeakBytes + unplacedTransientBytes`. `heap_count` checks it.
  - `RegistryStatistics::placedObjectBytes`: the device's sizes of the placed objects, summed.
- **Found and fixed on the way:**
  1. *nvrhi, D3D12:* every timer query resolved into one readback buffer. A timed compute list in
     flight beside a timed graphics list is debug-layer error #1047, because a buffer is written by one
     queue at a time. Each queue now has its own resolve buffer, and a query reads its own queue's
     timestamp frequency. `testTimerQueriesOnTwoQueues` reports #1047 on the old code and passes on
     D3D12 and Vulkan.
  2. *donut, Vulkan:* the per-pass timers stopped after the fourth frame. `CollectTimers` re-polled
     the set it had just read, and nvrhi's Vulkan `getTimerQueryTime` marks a query not started, so
     the four sets stayed pending. Each set is now polled once. `donut_passes` checks that the last
     frame publishes the frame before it; it fails on the old code on Vulkan, and passes on all four
     backends.
  3. *In the sample:* the shadow map keeps its initial state, so it is imported host-kept. A clear
     value is set only on render targets: D3D12 rejects one on a UAV-only texture.
- **Results** (Release, NVIDIA RTX 4050 Laptop GPU, 1280×720 unless stated):
  - *Memory,* D3D12 with the Placed tier. The poolable transients are 57.5 MB (54.9 MiB).

    | SSAO | Peak, plan statistics | Peak, device sizes (`heapBytes / placedObjectBytes`) |
    | --- | --- | --- |
    | graphics queue | 34.4 MB, **59.79 %** (one heap) | 36.37 / 60.62 MB, **60.00 %** |
    | compute queue | 27.0 MB in two heaps + 12.1 MB cross-queue, **68.0 %** | heaps 59.6 % of their objects |

    - At 1024×768, 1600×900 and 1920×1080 the graphics-queue peak is 60.08-60.12 % by the plan
      statistics and 59.85-60.08 % by the device's sizes.
    - The peak is the live set at DeferredLighting: the G-buffer, depth, the occlusion and the
      lighting output, 37 of the frame's ~62 bytes per pixel. Placement reaches it.
    - Async SSAO costs 8 points. Its depth, normals and occlusion cross queues, and are never aliased
      (design 7.4). Its arrays sit in a compute-queue heap of their own (7.5).
    - No `create*` call after the warm-up, in any configuration.
  - *Validation:* 120 Debug frames, zero messages, with the layer's DLL seen loaded in each run.
    - D3D12 debug layer: async + split + Placed (with per-pass timers), `-sync`, `-nosplit`, Pooled
      and `-immediate`.
    - Vulkan with `VK_LAYER_VALIDATE_SYNC=1`: default (SSAO demoted), forced async with ownership
      transfers, forced async without splits, and `-immediate`. Each run crosses 119 frame boundaries.
    - The same session's `nvrhi_explicit_barrier_tests` provoked a WAW hazard under the same layer and
      variable, and synchronization validation reported it.
  - *Images:* graph against immediate, 38 pixels of 921,600 differ on D3D12, and 43 on D3D11. Two runs
    of one mode differ in 40-51 pixels, in the same region, so the frame itself is not deterministic
    there.
  - *Frame times:* 20 alternating rounds per API, `-notimers`, 300 frames after 100. Each value is the
    median of the per-run medians; the paired column is the median of the per-round differences.

    | API, configuration | GPU frame, ms (min) | paired against immediate, GPU |
    | --- | --- | --- |
    | D3D12 immediate | 1.886 (1.796) | |
    | D3D12 graph: async, split, Placed | 1.890 (1.715) | +0.013 ms, lower in 9 of 20 rounds |
    | D3D12 graph: `-sync` | 1.910 (1.790) | +0.006 |
    | D3D12 graph: `-nosplit` | 1.902 (1.737) | +0.025 |
    | D3D12 graph: Pooled | 1.871 (1.763) | −0.013, lower in 10 of 20 |
    | Vulkan immediate | 1.774 (1.688) | |
    | Vulkan graph, default (SSAO demoted) | 1.815 (1.663) | +0.040 ms, lower in 4 of 20 |
    | Vulkan graph, `-nosplit` | 1.804 (1.694) | +0.044 |
    | Vulkan graph, forced async | 1.960 (1.737) | +0.186 |
    | Vulkan graph, forced async, `-nosplit` | 1.990 (1.817) | +0.223 |

  - *Each feature on and off,* paired per round:
    - Async SSAO: D3D12 −0.066 ms GPU (lower in 13 of 20). Vulkan, forced across families:
      +0.178 ms (higher in 19 of 20).
    - Split barriers: D3D12 −0.035 ms (lower in 14 of 20). Vulkan +0.001 with SSAO demoted, −0.027
      with async.
    - Placed: D3D12 +0.008 ms (lower in 9 of 20): no measurable cost. It saves 40 % of the transient
      memory against unaliased objects.
  - *Barriers:* D3D12 64 per frame (async, Placed; 11 aliasing, 2 split halves, 4 fence waits) and 75
    with `-sync`. Vulkan 68 by default and 67 with forced async (5 ownership pairs).
  - *Per stage* (`-passtimes`, 6 runs each): the graph's pass bodies are as fast as the immediate
    stages or faster. On Vulkan they sum to 1.573 ms against 1.716, and the immediate stages include
    their clears and barriers. The Vulkan difference is in the work between passes.
  - *Vulkan ownership transfers (6.8): kept.* They validate clean under synchronization validation.
    Forced async SSAO is slower than demoted SSAO in 19 of 20 rounds. Per stage, SSAO stretches from
    0.265 to 0.378 ms on the compute queue, and the shadow and lighting passes slow by 0.045 and
    0.034 ms beside it. The five ownership pairs are a small part of a 0.18 ms loss that `CONCURRENT`
    would not remove. The default `LatticePolicy` demotion on a separate family is confirmed, and
    nvrhi gains no queue-family list.
- **Deviations:**
  1. The GPU-time reference is the sample's own `-immediate` frame; no original exists.
  2. The memory budget is met at its limit. With SSAO on the graphics queue it is 59.79 % at 1280×720
     (60.00 % by the device's sizes), and 60.08-60.12 % at three other resolutions. With async SSAO it
     is 68 %, by design 7.4 and 7.5.
  3. On Vulkan the graph's GPU frame is 0.040 ms (2.3 %) above the immediate frame (higher in 16 of 20
     rounds; the graph's minimum is lower). It is the work between passes (above). On D3D12 the budget
     is met.
  4. Async SSAO stays on the graphics queue on Vulkan by the default `LatticePolicy`. The forced runs
     exercise the ownership transfers.
- **Exit:** met, with deviations 2 and 3.

*P2.4 as built (2026-11-05).* Parallel recording in the samples (ethereal-samples `a154a89`), with three
executor changes (ethereal-donut `5deb2b2`).
- **donut:**
  - `RenderGraphWorkerPool.h`: P1.7's test pool, now a public donut_render header, so that the samples
    and the tests share it. The header TU and the hygiene test cover it.
  - **Batched submissions** (P1.7's follow-up). Consecutive segments of one queue share one
    `IDevice::submit` when:
    - every segment after the first waits for nothing; and
    - nothing waits for one before the last (`PlanSegment::signals`).

    Waits, the signals anything waits for, and plan order are unchanged. Before this, a 19-segment
    frame submitted each segment alone, which cost 0.3 ms on D3D12. `RunStatistics::submissions` counts
    the calls. `donut_passes` checks that the parallel frame's 8 segments take one submission where
    fences exist, and 8 on D3D11.
  - **Task weights.** The recording tasks are balanced by each segment's recording time in the previous
    frame, not by pass counts: five cheap bloom passes outweighed a shadow cascade's draws. Until every
    segment has been recorded once, pass counts stand in. `rdg_bench --parallel --gate` now gives
    D3D12 43.2 % of one list (P1.7: 50.5 %) and Vulkan 37.0 % (37.8 %).
- **Samples:**
  - `sample_harness/GraphRecording.h` adds `-parallel N`: the caller and N - 1 workers. It also adds
    `-granularity G` (`CompileOptions::recordGranularity`), which defaults to 3 with `-parallel`.
  - `deferred_shading_rdg`, `variable_shading_rdg` and `async_compute_rdg` take both switches. Their
    `-graphstats` report the recording time and the record tasks.
  - `async_compute_rdg` gives each shadow cascade its own `DepthPass`, pass context and draw strategy.
    A pass object's uses share one task (10.1), and the cascades hold most of the frame's draws. The
    passes and their GPU work are those P2.3 measured.
- **Results** (Release, NVIDIA, `-notimers`, alternating rounds, medians of the per-run medians):
  - *Parallel-recording budget* (10.3: ≤ 60 % of one list's recording time), `async_compute_rdg`, 4
    threads:

    | Granularity | D3D12 (6 rounds) | Vulkan (6 rounds) |
    | --- | --- | --- |
    | 1 (19 segments) | 65.6 % | 58.6 % |
    | 2 | 60.2 % | 53.1 % |
    | 3, the default | 56.7 % | 53.0 % |
    | 4 | 52.1 % | 56.2 % (3 tasks) |
    | 2, three threads | 69.5 % | 65.2 % |

    - At the default, over 12 more rounds: D3D12 0.188 → 0.110 ms, **58.6 %** (9 segments, 4 tasks).
      Vulkan 0.177 → 0.094 ms, **53.4 %** (7 segments).
    - Record plus submit: D3D12 0.265 → 0.192 ms, Vulkan 0.197 → 0.115 ms.
    - Each segment opens, closes and sets up a list, so finer segments lose on D3D12.
    - `variable_shading_rdg` records one heavy forward pass: 75 % of serial on D3D12, 82 % on Vulkan, at
      granularity 1. `deferred_shading_rdg` has three small passes: 71-73 %.
  - *Frame time,* same 12 rounds: the frame is GPU-bound at ~1.85 ms, and parallel recording leaves it
    where it was:
    - D3D12 GPU −0.032 ms (lower in 8 of 12);
    - Vulkan GPU +0.025 ms (lower in 2 of 12; seven lists against one).
  - *Executor overhead* (10.3: ≤ 0.2 ms; record plus submit with empty bodies), 10 rounds:

    | Sample | D3D12: serial / 4 threads | Vulkan: serial / 4 threads |
    | --- | --- | --- |
    | `deferred_shading_rdg` | 0.041 / 0.040 ms | 0.024 / 0.025 ms |
    | `variable_shading_rdg` | 0.048 / 0.045 ms | 0.025 / 0.024 ms |

  - *Validation:* 120 Debug frames with `-parallel 4`, zero messages, with each layer's DLL seen
    loaded. On D3D12: `async_compute_rdg` (Placed, granularity 3 and 1), `variable_shading_rdg` and
    `deferred_shading_rdg`. On Vulkan with `VK_LAYER_VALIDATE_SYNC=1`: `async_compute_rdg` with forced
    async SSAO and with demoted SSAO at granularity 1, `variable_shading_rdg` and
    `deferred_shading_rdg`.
  - *Images:* parallel recording against serial, identical on Vulkan for both samples and on D3D12 for
    `deferred_shading_rdg`. One pixel differs in `variable_shading_rdg` on D3D12, at (1015, 272), one of
    the three pixels the original varies in (P2.2).
  - The GPU tests, `test_render_graph` (32 tests) and `rdg_bench --parallel --gate` pass on the final
    executor.
- **Deviations:**
  1. The parallel-recording budget is defined on rdg_bench's 64 passes. In the samples it is met in the
     19-pass `async_compute_rdg` at granularity 2-4 (2-3 on D3D12). It is not met in the 5-pass and
     3-pass samples, where one pass, or very little work, dominates.
  2. With 4 threads the Vulkan GPU frame is 0.025 ms (1.4 %) above serial recording; its frame time is
     not part of the exit.
- **Exit:** met. The executor overhead is 0.024-0.048 ms against 0.2. Parallel recording is at 58.6 %
  (D3D12) and 53.4 % (Vulkan) of one list in `async_compute_rdg`, at the default granularity.

## Verification results

**P1.1 (2026-11-05)**, on the NVIDIA RTX 4050 Laptop GPU, Windows 10 19045:

| Run | Layers confirmed | Result |
| --- | --- | --- |
| `explicit_barriers_d3d12`, Debug, legacy barriers | debug layer (`ID3D12InfoQueue`) and GPU-based validation | PASS, no messages |
| the same tests, standalone Debug nvrhi, Agility SDK 1.619, `enhanced barriers: 1` | debug layer and GPU-based validation, live `ID3D12InfoQueue1` messages | PASS after the 6.3 correction |
| `explicit_barriers_vulkan`, Debug | `VK_LAYER_KHRONOS_validation` enabled, `VK_LAYER_VALIDATE_SYNC=1`; the deliberate hazard reported as `SYNC-HAZARD-WRITE-AFTER-WRITE` | PASS |
| `explicit_barriers_d3d11`, Debug | debug device | PASS |
| `explicit_barriers_cuda`, Debug, under Compute Sanitizer 12.9 | memcheck (with leak check), synccheck, racecheck | PASS, 0 errors, 0 bytes leaked |
| full Debug build | — | 1069 of 1074 steps; the 5 left are WaveWorks, which fails in every Debug build (known issues) |
| ctest, Debug | — | 49/49 (the 45 of the baseline and the four `explicit_barriers_*`) |
| full Release build | — | 828 steps, 76 executables and libraries linked |
| ctest, Release | — | 49/49, including `nvrhi_abi_lint`, `nvrhi_abi_lint_selftest`, `nvrhi_header_hygiene`, `cuda_*` and `cuda_interop-*` |

**P1.3 (2026-11-05)**, device-free (no GPU process):

| Run | Result |
| --- | --- |
| `test_render_graph`, Release and Debug | 31/31: 51 graphs, 377 verified plans, 377 verified plan switches; golden 6.11 lists identical |
| `rdg_bench --gate`, Release, D3D12 legacy profile, medians | compile on a miss: 487 µs for 64 passes / 256 resources (budget 1 ms) and 14.5 ms for 1024 passes / 4096 resources (16 ms); frame on a cache hit: 21.5 µs (50 µs); frame without the cache: 512 µs (reported); 0 heap allocations per steady-state frame (0); all budgets met |
| `donut_render_graph_abi_lint`, `donut_render_graph_header_hygiene`, `donut_render_graph_header_tus` | pass; the lint checks 7 interfaces and 63 virtual functions of `RenderGraph.h` |
| full Release build | complete (a rerun after applocal "file in use" link failures, the known flake) |
| ctest, Release | 53/53: the 49 of P1.2 and `test_render_graph`, `rdg_bench_smoke`, `donut_render_graph_header_hygiene`, `donut_render_graph_abi_lint` |
| full Debug build | everything except the 5 WaveWorks steps (known issues) |
| ctest, Debug | 53/53 |

**P1.4 (2026-11-05)**, on the NVIDIA RTX 4050 Laptop GPU, Windows 10 19045. Each GPU test ran alone.

| Run | Layers confirmed | Result |
| --- | --- | --- |
| `test_render_graph_gpu d3d12`, Debug, legacy barriers (`enhanced barriers: 0`) | debug layer (`ID3D12InfoQueue`) and GPU-based validation | PASS, no messages; the Native-scope guard reports its expected error |
| `test_render_graph_gpu vulkan`, Debug | `VK_LAYER_KHRONOS_validation` enabled, `VK_LAYER_VALIDATE_SYNC=1`; the deliberate hazard reported as `SYNC-HAZARD-WRITE-AFTER-WRITE` | PASS, no messages; the async fill crosses compute and graphics families with an ownership transfer |
| `test_render_graph_gpu d3d11`, Debug | nvrhi validation layer (no D3D11 debug runtime, as in nvrhi's own tests); fences through D3D11.4 | PASS |
| `test_render_graph_gpu cuda`, Debug | nvrhi validation layer | PASS |
| steady state, the same runs | — | 0 `create*` calls in 32 frames; 0 allocations in recording and the cached compile; execution allocates the same as the same nvrhi calls by hand (per frame: D3D12 20, Vulkan 2, D3D11 0, CUDA 23) |
| `test_render_graph`, Debug and Release | — | 31/31; golden 6.11 lists unchanged |
| `rdg_bench --gate`, Release, D3D12 legacy profile, medians | — | compile on a miss: 444 µs for 64 passes (1 ms), 13.2 ms for 1024 passes (16 ms); frame on a cache hit: 21.4 µs (50 µs); 0 heap allocations per steady-state frame (0); all budgets met |
| full Release build | — | complete (reruns after applocal "file in use" link failures, the known flake) |
| ctest, Release | — | 57/57: the 53 of P1.3 and the four `test_render_graph_gpu_*` |
| full Debug build | — | everything except the 5 WaveWorks steps (known issues) |
| ctest, Debug | — | 57/57 |

**P1.5 (2026-11-05)**, the same machine; each GPU test ran alone.

| Run | Layers confirmed | Result |
| --- | --- | --- |
| `test_render_graph_gpu d3d12`, Debug | debug layer and GPU-based validation | PASS: the frame of every pass (22 uses, 65 barriers) for six frames, no messages; 22 pass timings |
| `test_render_graph_gpu vulkan`, Debug | validation layer, `VK_LAYER_VALIDATE_SYNC=1`, hazard probe | PASS: the same frame (64 barriers), no messages |
| `test_render_graph_gpu d3d11` and `cuda`, Debug | nvrhi validation layer | PASS (CUDA runs the non-raster tests) |
| `test_render_graph_layer` d3d11, d3d12, vulkan, Debug | DeviceManager with the debug runtime, GPU-based validation on D3D12, and the nvrhi validation layer; no error logged | PASS |
| `nvrhi_explicit_barrier_tests vulkan`, Debug | as in P1.1 | PASS, with the compute-queue depth test; FAIL with the fix reverted (`VUID-vkCmdPipelineBarrier2-dstStageMask-09676`) |
| `test_render_graph`, `test_render_graph_passes`, Debug and Release | — | 31/31 and 3/3; the 6.11 golden lists change as described above |
| `rdg_bench --gate`, Release | — | miss 449 µs (64 passes), 13.5 ms (1024 passes); hit 21.6 µs; 0 allocations; all budgets met |
| full Release build | — | complete (reruns after applocal "file in use" link failures) |
| ctest, Release | — | 61/61: the 57 of P1.4, `test_render_graph_passes`, three `test_render_graph_layer_*` |
| full Debug build | — | everything except WaveWorks (known issues) and one applocal flake |
| ctest, Debug | — | 61/61 |

**P1.6 (2026-11-05)**, the same machine; each GPU test ran alone.

| Run | Layers confirmed | Result |
| --- | --- | --- |
| `test_render_graph_gpu d3d12`, Debug, legacy barriers (`enhanced barriers: 0`) | debug layer (`ID3D12InfoQueue`) and GPU-based validation | PASS, no messages. Placed: 2 heaps, 4 aliasing barriers, contents right in every frame read back; heap tier 1: 3 planned heaps, 1 created (targets); retirement clean. `SkipAliasingBarriers`: X, Y, A and B reported. Split: 1 split barrier, 4 frames in flight |
| the Placed and negative tests again with the Agility SDK 1.619 runtime (`NVRHI_TEST_AGILITY_SDK_VERSION=619`) | as above, plus live `ID3D12InfoQueue1` messages | PASS |
| `test_render_graph_gpu vulkan`, Debug | validation layer 1.4.357, `VK_LAYER_VALIDATE_SYNC=1`, hazard probe | PASS. The split test's frame-boundary reports and the witness's are the VVL false positive (4 set aside); everything else clean. Placed falls back to Pooled |
| `test_render_graph_gpu d3d11` and `cuda`, Debug | nvrhi validation layer | PASS; Placed falls back to Pooled |
| `test_render_graph`, Debug and Release | — | 32/32: 51 graphs, 479 verified plans and 479 plan switches; `heap_count` |
| `rdg_bench --gate`, Release | — | miss 432 µs (64 passes), 14.5 ms (1024 passes); hit 21.1 µs; 0 allocations; all budgets met |
| full Release build | — | complete (reruns after applocal "file in use" link failures) |
| ctest, Release | — | 61/61 |
| full Debug build | — | everything except WaveWorks (known issues), after applocal reruns |
| ctest, Debug | — | 61/61 |

**P1.7 (2026-11-05)**, the same machine; each GPU process ran alone.

| Run | Layers confirmed | Result |
| --- | --- | --- |
| `test_render_graph_gpu d3d12`, Debug | debug layer and GPU-based validation | PASS, no messages: buffer chains in 4 segments by 4 tasks; 32 blits in 9 segments by 4 tasks; donut's frame in 8 segments by 4 tasks; both concurrency tests |
| `test_render_graph_gpu vulkan`, Debug | validation layer 1.4.357, `VK_LAYER_VALIDATE_SYNC=1`, hazard probe | PASS after the store-op fix (FAIL before it, as above); only the VVL false positive of P1.6 set aside |
| `test_render_graph_gpu d3d11`, Debug | nvrhi validation layer | PASS; one task, `BindingCache` from eight threads |
| `test_render_graph_gpu cuda`, Debug | nvrhi validation layer | PASS; buffer chains by 4 tasks |
| `rdg_bench --parallel d3d12 --gate`, Release | none (timing run) | one list 150.0 µs, four threads 75.7 µs: 50.5 % (budget 60 %) |
| `rdg_bench --parallel vulkan --gate`, Release | none (timing run) | one list 129.0 µs, four threads 48.8 µs: 37.8 % (budget 60 %) |
| `rdg_bench --gate`, Release | — | miss 441 µs (64 passes), 13.5 ms (1024 passes); hit 21.7 µs; 0 allocations; all budgets met |
| full Release build | — | complete (a rerun after applocal "file in use" link failures) |
| ctest, Release | — | 63/63: the 61 of P1.6 and `rdg_bench_parallel_{d3d12,vulkan}` |
| full Debug build | — | everything except WaveWorks (known issues), after an applocal rerun |
| ctest, Debug | — | 63/63 |

**Pass 1 verification (2026-11-05)** at ethereal-nvrhi `4b1437a`, ethereal-donut `df5dd96`, ethereal-samples
`d5bad16` (aggregate `20e50bd`), on the NVIDIA RTX 4050 Laptop GPU, Windows 10 19045. Each GPU process ran
alone. The builds, ctest runs, donut GPU tests and benchmarks are those of P1.7, at the same commits.

| Item | Run | Result |
| --- | --- | --- |
| Builds | full Release and Debug builds of the worktree | Release complete; Debug complete except WaveWorks (known issues); applocal "file in use" flakes rerun |
| ctest | Release and Debug | 63/63 each |
| nvrhi GPU tests | `nvrhi_explicit_barrier_tests d3d12`, Debug | PASS; "the D3D12 debug layer is loaded (ID3D12InfoQueue)", `enhanced barriers: 0` |
| | `nvrhi_explicit_barrier_tests vulkan`, Debug | PASS; "the Vulkan validation layer is loaded", the deliberate hazard reported as `SYNC-HAZARD-WRITE-AFTER-WRITE` |
| donut GPU tests | `test_render_graph_gpu` d3d12, vulkan, d3d11, cuda, Debug | PASS on all four (P1.7 table); `test_render_graph_layer_*` in ctest |
| Sample smoke runs | `deferred_shading -d3d12`, Debug, 25 s, closed through its window | exit 0; `D3D12SDKLayers.dll` loaded; no warning or error in its debug output |
| | `deferred_shading -vk`, Debug, 25 s | exit 0; `VkLayer_khronos_validation.dll` (SDK 1.4.357) loaded; no warning or error |
| Samples | every sample target | builds in Release; in Debug all but WaveWorks |

10.3 budgets that need no sample:

| Budget | Measured | Result |
| --- | --- | --- |
| Compile on a miss, 64 passes / 256 resources, ≤ 1 ms | `rdg_bench --gate`, Release, D3D12 legacy profile | 441 µs |
| Compile on a miss, 1024 passes, ≤ 16 ms | the same | 13.5 ms |
| Frame on a cache hit, 64 passes, ≤ 0.05 ms | the same | 21.7 µs |
| Frame without the cache, 64 passes (reported) | the same | 508 µs |
| Heap allocations per steady-state frame, 0 | the same (device-free); `test_render_graph_gpu` steady state on the GPU | 0; on the GPU recording and the cached compile allocate nothing and execution matches the same nvrhi calls by hand |
| `create*` calls per steady-state frame, 0 | `test_render_graph_gpu` steady state, all four backends | 0 in 32 frames |
| Parallel recording, 64 passes, 4 threads, ≤ 60 % of one list | `rdg_bench --parallel`, Release | D3D12 50.5 % (75.7 / 150.0 µs); Vulkan 37.8 % (48.8 / 129.0 µs) |

The executor overhead, barrier, frame-time and memory budgets need the samples: P2.1-P2.4.

**Pass 2 verification (2026-11-05)** at ethereal-nvrhi `3d4e449`, ethereal-donut `5deb2b2`, ethereal-samples
`a154a89` (aggregate `098b100`), on the NVIDIA RTX 4050 Laptop GPU, Windows 10 19045. Each GPU process ran
alone.

| Item | Run | Result |
| --- | --- | --- |
| Builds | full Release and Debug builds of the worktree | Release complete. Debug complete except WaveWorks (known issues; not fixed, as the user did not ask). Applocal "file in use" flakes on five links were rerun |
| ctest | Release and Debug | 63/63 each |
| nvrhi GPU tests | `explicit_barriers_d3d12` and `_vulkan`, Debug | PASS. "the D3D12 debug layer is loaded"; "the Vulkan validation layer is loaded", with the deliberate hazard reported as `SYNC-HAZARD-WRITE-AFTER-WRITE`. Includes P2.3's `testTimerQueriesOnTwoQueues` |
| donut GPU tests | `test_render_graph_gpu` on d3d12, vulkan, d3d11 and cuda, Debug and Release | PASS (555 checks on Vulkan, Debug) |
| `rdg_bench --gate` | Release, D3D12 legacy profile | Compile miss, 64 passes: 485.9 µs (budget 1 ms). 1024 passes: 14.5 ms (16 ms). Cache hit: 20.8 µs (50 µs). No cache: 444.7 µs (reported). 0 allocations |
| `rdg_bench --parallel --gate` | Release | D3D12 43.2 %, Vulkan 37.0 % of one list (budget 60 %) |

The 10.3 budgets in the samples (details in the steps' as-built entries):

| Budget | `deferred_shading_rdg` (P2.1) | `variable_shading_rdg` (P2.2) | `async_compute_rdg` (P2.3, P2.4) |
| --- | --- | --- | --- |
| Images against the original | identical on D3D12, Vulkan and D3D11 | within the original's own three varying pixels | within the frame's own variation (against `-immediate`) |
| Validation, 120 Debug frames, layer loaded | clean | clean | clean in 9 configurations; with `-parallel 4` in 4 more |
| Barriers per frame ≤ original | D3D12 14 / 15; Vulkan 19 / 27 | D3D12 15 / 20 | no original |
| GPU frame ≤ original | met; D3D12 within noise (+0.6 %) | met on D3D12; Vulkan +3 %, within noise | met on D3D12 (+0.7 %, lower in 9 of 20 rounds); Vulkan +2.3 % (deviation) |
| CPU frame ≤ original | met; D3D11 +1.3 % (deviation) | met on D3D12; Vulkan within noise | equal on D3D12 (+0.008 ms) |
| Executor overhead ≤ 0.2 ms | 0.025-0.041 ms; with 4 threads 0.040 ms (D3D12), 0.025 ms (Vulkan) | 0.027-0.047 ms; with 4 threads 0.045 / 0.024 ms | not measured (no empty-body variant) |
| Plan cache (reported, 7.7) | kept: 0.069 against 0.112 ms (D3D12) | kept: 0.104 against 0.145 ms | |
| Peak transient memory ≤ 60 % | | | 59.8 % with SSAO on graphics, at the limit; 68 % with async SSAO, by design 7.4/7.5 |
| `create*` calls after warm-up | | | 0 |
| Parallel recording, 4 threads ≤ 60 % | 71-73 % (3 small passes) | 75-82 % (one heavy pass) | D3D12 58.6 %, Vulkan 53.4 % |

## Known issues and follow-ups

- **WaveWorks does not build in Debug** (ethereal-samples, since `01b4945`, before this plan). The
  size assertions in `Wind_Waves_Simulation_Manager_Compute_Impl.h` and `..._CPU_Impl.h` assume
  Release `std::vector`, which is 24 bytes; Debug's is 32. Pass 1 leaves samples alone; fix it in pass 2
  or on its own when asked.
- **CUDA shared fences** (`FenceDesc::shared`) return `FE_UNSUPPORTED`. The device reports
  `TIMELINE_SEMAPHORE_INTEROP_SUPPORTED`, so an external-semaphore implementation is possible. It is
  needed only by an interop graph boundary (design 14.8 item 18).
- **Vulkan render targets with per-aspect layouts.** With `separateDepthStencilLayouts`, a depth plane
  in a read layout and a stencil plane in an attachment layout need the attachment's layout to be
  `eDepthReadOnlyStencilAttachmentOptimal`. nvrhi's rendering setup derives one layout per attachment
  from the tracked state. Address it in P1.4 if the executor's Native mode produces that split, or have
  the graph keep both planes together for attachments.
- **Fixed in P2.0 (ethereal-nvrhi `27b93fb`): Vulkan swap-chain images lacked `TRANSFER_SRC` usage**
  (ethereal-nvrhi `vulkan-swapchain.cpp`, since ADR 0014's `123d105`). They are created with `eColorAttachment | eTransferDst | eSampled`, so a
  back-buffer readback (the GVDB `--screenshot` path) is a validation error on Vulkan
  (VUID-vkCmdCopyImageToBuffer-srcImage-00186). The fix is to add `eTransferSrc` where the surface
  supports it. It is not part of P1.1 or P1.2, and the screenshots of pass 2 need it.
- **Enhanced barriers in the worktree build** need `NVRHI_WITH_RTXMU=OFF` and the Agility SDK. Until
  the aggregate build can turn RTXMU off, the enhanced path is verified with the standalone nvrhi build.
- **P1.3 follow-ups** (graph core):
  - The 1024-pass compile takes 14.5 ms against a 16 ms budget. Profile it before P1.6 adds phases.
  - An import whose last use is on the compute queue, and whose exit state the compute queue cannot
    hold, needs a later graphics pass; the compile fails otherwise. The executor could add a trailing
    graphics batch instead.
  - `ScheduleFlags::GroupReads` does not reorder yet.
- **P1.4 follow-ups** (executor):
  - The `IEventQuery` fallback for D3D11 without fences is not exercised on this machine: its D3D11
    has 11.4 fences. (Since P2.1 every D3D11 run uses it.)
  - The enhanced-barrier path is verified device-free only; the GPU run needs the Agility SDK build
    above.
  - The Vulkan per-aspect attachment layouts above are not exercised by the GPU test: no pass reads
    depth while it writes stencil.
- **P1.5 follow-ups** (passes):
  - The geometry passes in Native mode (13.3): their scene buffers and material textures need declaring
    or importing first.
  - P1.7: a pass's per-view uses share its draw strategy and pass context, so a parallel recorder keeps
    them on one thread or gives each its own.
  - Persistent and history names of pass objects (ToneMapping's exposure, TAA's feedback) carry a
    per-process instance number. They are stable within a process, not across processes.
  - The Visualizer runs in pass 2's samples; no test drives it.
- **P1.6 follow-ups** (Placed tier):
  - **The VVL false positive** (`testVvlEventWitness`) is worth reporting to Khronos with the witness as
    the reproduction; that is the user's call. When a VVL release stops reporting it, the witness fails
    and the exemption in the test's message handler goes.
  - D3D12 heap tier 1 places targets only (deviation 2). A heap class in nvrhi's `HeapDesc` would place
    buffers and other textures too.
  - The Placed tier with enhanced barriers runs device-free only (the RTXMU build above).
  - Exclusion-group members do not share bytes in the actual placement (deviation 3).
- **P2.3 follow-ups** (async compute):
  - Vulkan's work between passes costs 0.04 ms more than the immediate frame's. Find it with a GPU trace
    (Nsight Systems or Graphics): batch boundaries, clears and layout transitions.
  - Aliasing across queues: a heap shared by the graphics and compute queues, and lifetimes ordered by
    the plan's fences, would bring async SSAO's peak down to the graphics-queue figure.
  - nvrhi's Vulkan `getTimerQueryTime` marks a query not started, and D3D12's does not. The executor
    no longer depends on it; the backends could agree.
  - `RegistryStatistics::pooledBytes` stays 0; the Pooled tier's memory is not measured.
- **P2.4 follow-ups** (parallel recording):
  - Each segment opens and closes its own list. Recording a segment's passes into a list that another
    task continues would remove the per-segment cost that limits fine granularity on D3D12.
  - The workers sleep between frames; a frame's first task waits for them to wake.
- **P1.7 follow-ups** (parallel recording):
  - Done in P2.4: consecutive segments of one queue with no waits between them share one submission.
  - The steady-state allocation test runs serially; a parallel variant would confirm the executor's
    scratch reuse by measurement.
