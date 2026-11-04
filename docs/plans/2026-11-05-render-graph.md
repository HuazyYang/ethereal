# Render graph (RDG) for donut: implementation

- Status: Approved (2026-11-05). Pass 1 in progress; pass 2 on hold until the user starts it.
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
  decision. **On hold:** it starts only when the user says so.

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
  covers the Placed tier on both D3D12 heap tiers.

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

## Pass 2: samples (on hold)

Starts only on the user's instruction. Planned content, to be detailed then:

- Reference captures and timings from the unchanged main checkout (screenshots on `-d3d11`, `-d3d12`,
  `-vk`; frame times), one GPU process at a time.
- `deferred_shading_rdg`, `variable_shading_rdg` and `async_compute_rdg` in ethereal-samples, built on
  `app::RenderGraphLayer` and `FrameData`.
- Deterministic options (`-fixedstep`, `-frames N`, `-screenshot`) and `tools/ab_compare.py`.
- Design step 5's exit: pixel-identical images on D3D12, Vulkan and D3D11; 120 Debug frames with zero
  validation messages; the barrier, CPU and GPU budgets of 10.3; the frame cost with and without the
  plan cache, and the decision to keep or remove the cache (7.7).
- Design step 6's exit: the memory budget on the bloom/SSAO graph, the GPU-time budget, async SSAO and
  split barriers measured on and off, and the decision on Vulkan ownership transfers versus
  `CONCURRENT` (6.8).
- Design step 7's exit: the executor and parallel-recording budgets measured in the samples.

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
