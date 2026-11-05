# Render graph (RDG) for donut: implementation

- Status: Approved (2026-11-05). Pass 1 in progress (P1.0-P1.5 done); pass 2 scheduled after it, by the
  user's instruction of 2026-11-05.
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
- **Vulkan swap-chain images lack `TRANSFER_SRC` usage** (ethereal-nvrhi `vulkan-swapchain.cpp`,
  since ADR 0014's `123d105`). They are created with `eColorAttachment | eTransferDst | eSampled`, so a
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
    has 11.4 fences.
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
