# CUDA queue pools: command lists bound to pooled streams

- Status: Done (2026-11-21). The headers were approved, and P0-P5 are implemented and verified (see
  "As built").
- Date: 2026-11-21
- Repositories: `ethereal-nvrhi` and `ethereal-donut`, on their `rdg` branches; the aggregate for docs.
- ADR: nvrhi [0016](../../ethereal-nvrhi/doc/adr/0016-command-queue-objects-and-cuda-queue-pools.md).

## Context

nvrhi's CUDA backend gives each `CommandQueue` type exactly one non-blocking `CUstream`. That is three
streams in all (`cuda-device.cpp:206-214`, `Queue` in `cuda-backend.h:973`).
- A command list records into a byte stream. At submit it is replayed onto the stream of its
  `queueType`.
- Each queue loads its own `CUmodule`, so `SLANG_globalParams` never race between streams
  (`ShaderLibrary::m_Modules`, `ComputePipeline::m_Kernels`, both `[c_NumQueues]`). The kernel is
  chosen at record time (`cuda-commandlist.cpp:959`).
- Cross-stream order comes from cuEvents. On rdg there is the `IFence` event ring (`cuda-fence.cpp`)
  plus `submit` waits and signals (`cuda-queue.cpp:61-114`). `queueWaitForCommandList` uses
  `cuStreamWaitEvent`.

CUDA can run many streams concurrently on one device. Today, though, two independent workloads of the
same type always serialise on one stream.

**Goal.** An opt-in overlapped execution mode:
- the device keeps a pool of queues (streams) per type;
- each recording binds to a free queue of its type when it is opened;
- recording and submission go to that queue;
- cuEvent fences order work across queues;
- the render graph uses the pool, spreading independent same-type work over queues.

**Decisions** (the user, 2026-11-07):
- Work on the `rdg` branches (nvrhi, donut, aggregate), on top of `IFence`/`submit`.
- A generic `nvrhi::ICommandQueue`. The user confirmed this after a clarification round in which
  index-only alternatives were offered and rejected.
- Automatic binding at `open()`. Pinning (`CommandListParameters::commandQueue`) is optional; the render
  graph uses it for its lanes.
- The render graph is in scope.

The conventions of the previous plans apply:
- commit per step, in the order nvrhi → donut → aggregate;
- LF line endings; messages written to a scratchpad file and passed with `git commit -F`;
- show headers before implementing;
- record deviations in the plan;
- one GPU process at a time;
- validation claims only from Debug runs with the layer confirmed loaded;
- nothing is pushed unless asked;
- never edit design section 2.3.

## Design

### 1. nvrhi API (`include/nvrhi/nvrhi.h`): headers first, for review

```cpp
NVRHI_IID(ICommandQueue, "...")
struct ICommandQueue : IRHIObject {        // getNativeObject: CUDA_Stream, D3D12_CommandQueue, VK_Queue
    virtual CommandQueue getType() const noexcept = 0;
    virtual uint32_t getIndex() const noexcept = 0;   // in its type's pool; 0 = the type's primary queue
    virtual uint64_t getLastSubmittedInstance() noexcept = 0;
    virtual uint64_t getCompletedInstance() noexcept = 0;
};
// IDevice
virtual uint32_t getCommandQueueCount(CommandQueue type) noexcept = 0;   // 0 if unsupported; 1 except pooled CUDA
virtual FRESULT getCommandQueue(CommandQueue type, uint32_t index, ICommandQueue** out) noexcept = 0;
// ICommandList
virtual ICommandQueue* getCommandQueue() noexcept = 0;   // this recording's queue (set by open()); not AddRef'd
// CommandListParameters
ICommandQueue* commandQueue = nullptr;   // pins every recording to this queue; nullptr: open() picks a free one
// SubmitDesc
ICommandQueue* commandQueue = nullptr;   // target of a submit without lists (fence waits/signals); else the lists'
```

- **Binding at `open()`.** A pinned list uses its queue. An unpinned list takes the queue of
  `queueType` with the fewest pending bindings, then the fewest in-flight submissions, then the lowest
  index. A pending binding lasts from `open()` until the recording is submitted or reopened. The pick
  runs under a device mutex and never fails.
- **Submits.** All of a submit's lists must have `desc.queue`'s type. If they are bound to different
  queues, the submit forks and joins:
  - each queue replays its own lists in order;
  - the waits are enqueued on every participating queue;
  - the other streams join onto the first list's queue through events, and the signals are recorded
    there.
- **Instance numbers stay per queue.** A pool queue with index > 0 encodes its index in bits 56-59 of
  the instances it returns. Index 0 is unchanged, so every existing caller and test sees today's values.
- **Type-based legacy calls** act on the type's primary queue (index 0): `queueWaitForCommandList` (which
  decodes the executing queue from the instance), `getNativeQueue`, `setEventQuery`,
  `cuda::IDevice::queueGetCompletedInstance`, the interop waits and the swap chain. This is documented.
  Ordering in overlapped mode is fences or pinning.
- **Mode switch:** `cuda::DeviceDesc::queueCounts[3] = {1, 1, 1}`, at most 8 per type. With all counts at
  1, behaviour is identical to today.

### 2. CUDA backend (`src/cuda`)

- **`Queue` becomes the `ICommandQueue` object.** It gains a type and index, and the pool is
  `m_Queues[type]` as a vector of pool size. It is created at `Device::initialize`. `c_NumQueues` stays
  the number of types. A global slot (type-major) indexes the per-stream state.
- **Modules and kernels per slot:** `ShaderLibrary::m_Modules` and `ComputePipeline::m_Kernels` become
  vectors over all slots, loaded lazily on first use (the existing `getKernel` pattern). `getKernel`
  takes the bound queue's slot. `CommandList` stores the bound `Queue*` in `open()` (replacing
  `m_Instance->queue = m_Desc.queueType`). `getNativeObject(CUDA_Stream)` returns the bound stream.
- **Submit:**
  - `Device::submit` (`cuda-fence.cpp:256`) groups the taken instances by bound queue.
  - The single-queue path is today's `Queue::submit`.
  - The multi-queue path forks and joins with pooled `CUevent`s.
  - A submit without lists goes to `desc.commandQueue`, or to the type's primary.
- **OptiX compaction** stores the build's `Queue*` and instance (`cuda-optix.cpp:1217`,
  `AccelStruct::buildQueue`). `queueWaitForCommandList` and `getSubmissionEvent` decode the queue
  index. `runGarbageCollection` and `waitForIdle` loop over every pool queue.

### 3. D3D12, Vulkan and D3D11

The existing per-type `Queue` classes implement `ICommandQueue`, with one per type:
- `getCommandQueueCount` returns 1, or 0 for a missing type;
- `getCommandQueue(type, 0)` returns that queue;
- a list's `getCommandQueue()` returns its type's queue;
- a pinned queue must be that queue.

D3D11 has the Graphics queue only.

### 4. Validation layer (`src/validation`)

- A `CommandQueueWrapper` per backend queue, created on demand and cached by pointer. Pinned queues
  and `SubmitDesc::commandQueue` are unwrapped, and `getCommandQueue()` is wrapped.
- Errors:
  - a pinned queue whose type is not `queueType`;
  - a list whose bound queue is not of `desc.queue`'s type;
  - a list-less submit whose `commandQueue` type is not `desc.queue`;
  - an index ≥ count.
- `CommandListWrapper` and `DeviceWrapper` keep reaching the CUDA interfaces as they do now. The
  existing `!cuda` workaround in `testTransient` stays.

### 5. donut render graph: queue lanes

- **Profile:** `BackendProfile::queueLanes[3]` from `getCommandQueueCount`, so CUDA reports its pool
  sizes and every other backend 1. It is added to `HashProfile`. A new `ReferenceProfile::CUDAOverlapped`
  has lanes {2, 2, 1}, for the device-free corpus.
- **Compiler, a new lanes phase after scheduling** (`RenderGraphCompiler.cpp`, near `:611-629`):
  - A pass of a type with more than one lane takes the lane of its latest same-type producer. A pass
    that depends on nothing of its type starts on the least-loaded lane.
  - Segments also split on lane changes.
  - `SegmentWait` and the cross-queue lifetime rule (design 7.4) key on (queue, lane), so a cross-lane
    resource counts as cross-queue.
  - `DebugFlags::SerializeQueues` also forces lane 0.
  - The verifier models every (queue, lane) as its own queue.
- **Executor** (`RenderGraphExecutor.cpp`, `RenderGraphInternal.h:607-641`):
  - lists are pooled per (queue, lane, ordinal) and pinned to `getCommandQueue(type, lane)`;
  - `fences`, `fenceValues` and `lastFrameValues` become per (queue, lane);
  - `addWait` skips only its own (queue, lane), and batching stays within one (queue, lane);
  - the prologue is Graphics lane 0;
  - `CollectInstances` and `WaitForFrames` cover every lane fence;
  - `PlanStatistics` gains the lanes used.

## Steps

1. **P0: docs and headers.**
   - nvrhi ADR 0016, "Command-queue objects and CUDA queue pools" (amends ADR 0011's one stream per
     queue).
   - This plan as `docs/plans/2026-11-21-cuda-queue-pools.md`, with an index row.
   - The section 1 header declarations shown for review before backend code.
2. **P1: nvrhi API, plus the D3D12, Vulkan and D3D11 single-queue implementations, plus validation.**
   All backends build. The existing ctest suite is unchanged.
3. **P2: CUDA pools.** Pool creation, binding at `open()`, modules per slot, fork/join submit, instance
   encoding, OptiX, GC and idle. New nvrhi tests (Verification).
4. **P3: graph, device-free.** Profile lanes, the lanes phase, the verifier and the corpus under
   `CUDAOverlapped`.
5. **P4: graph executor.** Lanes on CUDA, and GPU tests on an overlapped CUDA device.
6. **P5: verification and as-built.** Release and Debug builds and the full ctest. The amendments to
   aggregate `docs/rdg-design.md`: 6.8's "No queue object" and its CUDA paragraph, 9.2's CUDA row, and
   section 12's header listing. Section 2.3 is not touched.

## Critical files

- **nvrhi:**
  - `include/nvrhi/nvrhi.h`, `include/nvrhi/cuda.h` (`DeviceDesc::queueCounts`)
  - `src/cuda/cuda-backend.h`, `cuda-device.cpp`, `cuda-queue.cpp`, `cuda-fence.cpp`, `cuda-commandlist.cpp`,
    `cuda-compute.cpp`, `cuda-shader.cpp`, `cuda-optix.cpp`
  - `src/d3d12/d3d12-backend.h:1249`, `src/vulkan/vulkan-backend.h:279`, and the D3D11 device
  - `src/validation/validation-device.cpp:2541-2604`, `validation-barriers.cpp:321-418`,
    `validation-backend.h`
  - `tests/cuda-tests.cpp`, `tests/explicit-barriers.cpp`, `tests/CMakeLists.txt`
- **donut:**
  - `include/donut/render/RenderGraph.h` (`BackendProfile`, `ReferenceProfile`, `PlanStatistics`)
  - `src/render/RenderGraphProfile.cpp:255-415`, `RenderGraphCompiler.cpp`, `RenderGraphVerifier.cpp`
  - `RenderGraphExecutor.cpp:1400-1417, 1661-1970`, `RenderGraphInternal.h`, `RenderGraphRegistry.cpp:48-83`
  - `tests/src/render/test_render_graph.cpp`, `rdg_corpus.*`, `test_render_graph_gpu.cpp:1940-1962`

## Verification

- **nvrhi `cuda-tests`, new entries in the CMake list:**
  - `queue_pool`: counts, distinct streams, auto-binding spreads two open lists, pinning, and the
    mode-off identity (all lists on index 0; `transient`'s instance numbers unchanged).
  - `queue_fences`: a producer on pool queue A and a consumer on B through `IFence`, and a fork/join
    submit whose signal follows both queues.
  - `queue_globals`: the same pipeline with different `SLANG_globalParams` on two streams at once gives
    both correct results.
  - `queue_overlap`: two independent long kernels on two queues. The cuEvent timings show the overlap;
    this is reported, not gated.
- **`explicit_barriers_*`:**
  - the single queue per type on D3D12, Vulkan and D3D11;
  - validation errors for a mismatched pinned queue and a mismatched submit target;
  - CUDA `testCrossQueue` across two pooled Compute queues.
- **donut:**
  - `test_render_graph`: the corpus verified under `CUDAOverlapped`, and two independent compute chains
    landing on two lanes with one wait where they join.
  - `test_render_graph_gpu cuda-overlapped` (a CUDA device with counts {2, 2, 1}): buffer chains and
    plan switches between one lane and two, with correct results, zero `create*` calls and zero
    allocations in the steady state.
- **Full matrix:**
  - Release and Debug ctest: every existing test unchanged, and the CUDA default identical.
  - `explicit_barriers_cuda` and `test_render_graph_gpu cuda` in Debug, behind the validation layer.
  - A report-only GPU time for two independent compute chains with lanes 2 against 1.

## As built

Commits, all on the `rdg` branches:

| Step | Repository | Commit | Subject |
| --- | --- | --- | --- |
| P0, P1 | ethereal-nvrhi | `bb8343b` | ICommandQueue: command-queue objects on every backend (ADR 0016) |
| P2 | ethereal-nvrhi | `2cb93fc` | CUDA queue pools: recordings bound to pooled streams at open() (ADR 0016) |
| P3 | ethereal-donut | `9b18e09` | Render graph queue lanes: passes spread over pooled queues (nvrhi ADR 0016) |
| P4 | ethereal-donut | `34c88f2` | Render graph executor: one stream per queue lane (nvrhi ADR 0016) |
| P5 | aggregate | this plan, the design amendments (6.8, 9.2, 12) and the gitlinks | |

Implemented:
- **nvrhi.** The API is as designed in section 1.
  - Each backend's `Queue` is a `DelegatingObjectImpl<ICommandQueue>` that shares the device's
    reference count. It is created with `MAKE_RC_DELEGATING` and owned by a
    `MonoPtr<Queue, DelegatingObjectDeleter>`.
  - D3D11 gains a graphics queue object whose native object is the immediate context.
  - The validation layer wraps queues in `CommandQueueWrapper`.
  - CUDA: pools of 1-8 queues per type, with queue slot = type × 8 + index. Modules and kernels are
    kept per slot and loaded on first use. A recording binds at `open()` to the queue with the fewest
    pending bindings, then the fewest in flight, then the lowest index. A submit spanning several
    queues forks and joins with pooled events. A queue with index i > 0 carries i in bits 56-59 of its
    instances.
- **donut.** As designed in section 5.
  - `BackendProfile::queueLanes`, `ReferenceProfile::CUDAOverlapped`, `ScheduledPass::lane`,
    `PlanSegment::lane`, `SegmentWait::lane` and `PlanStatistics::streams`.
  - Streams are `StreamOf(queue, lane) = queue × 8 + lane`, with at most 24.

Deviations:
- **Lanes are assigned in the structure phase**, per program pass over the superset, not in a phase
  after scheduling. Every mask of a structure therefore has the same lanes, and the pooled slots and the
  cross-queue rule of 7.4, which are computed per structure, hold for every mask.
- **The transition builder keys waits on streams through the schedule index.** A stream follows from
  the schedule index, so the builder's accesses carry no lane of their own. Split barriers also require
  one stream.
- **nvrhi tests.** `queue_globals` and `queue_overlap` became one test, `queue_kernels`:
  - one pipeline launched on two queues at once writes both buffers correctly;
  - the overlap is reported for a kernel with `SLANG_globalParams` and for one without;
  - its negative control (a module shared between queues) fails, which shows the per-slot modules
    are needed.
- **Cross-queue fences in a pool are tested by `cuda_queue_fences`**, pools {1, 2, 1}, raw and through
  the validation layer, instead of a CUDA variant of `explicit_barriers`. `explicit_barriers` gained
  `testCommandQueues` for every backend:
  - one queue per type, the same object each time, and its native object;
  - an index past the pool refused;
  - a list pinned to a queue of another type refused;
  - a submission naming a queue of another type refused.
- **Overlap.** On the RTX 4050 Laptop GPU under WDDM, without hardware-accelerated GPU scheduling, two
  kernels on two queues of a pool do not run concurrently (100 % serial). This holds with and without
  global parameters and without nvrhi's submission events. ADR 0016 records it.
  - The pools still give each lane independent ordering, and the render graph's lanes are verified
    for correctness.
  - The report-only bulk-copy timing (two chains, each 4 × 32 MiB copies per frame) gives 3.4-3.8 ms
    per frame on either one or two lanes.
- **Steady-state allocations.** nvrhi's CUDA lists allocate an instance at every `open()` and a
  vector at every `submit`, so "zero allocations" holds for the graph's own work only:
  - recording and the cached compiles allocate nothing;
  - execution on two lanes allocates what the same nvrhi calls by hand allocate (33 and 33 per
    frame), as `steady_state` already checks for one queue.
  - Each measured frame starts with the GPU idle. Otherwise nvrhi's event ring, upload chunks and
    the submission deque warm up at different times in the two loops, and the counts differ by a few
    either way. `RDG_ALLOC_TRACE` showed every difference to be inside nvrhi's CUDA backend.
- **`steady_state` measures the one-lane plan.** On the overlapped device its buffer chain spreads over
  two lanes (the clear starts on lane 1), while its hand-made baseline records one list.
- **Additions:**
  - a plan with more lanes than the device has queues fails `Execute` with `FE_INVALID_ARGS`;
  - the JSON dump names a lane only when it is not 0, so single-lane dumps are unchanged;
  - the verifier's messages name streams ("Compute lane 1").
- **`test_render_graph_gpu cuda-overlapped`** runs the whole GPU suite on a device with pools
  {2, 2, 1}, plus `queue_lanes`, and is registered as `test_render_graph_gpu_cuda_overlapped`.

Verification:
- Device-free (`test_render_graph`):
  - 33/33 tests;
  - the corpus under seven profiles: 51 graphs, 499 verified plans and 499 plan switches, 6 of them
    on two lanes;
  - `queue_lanes`: one same-frame wait at the join, one stream on CUDA, one stream with
    `SerializeQueues`, and a verified switch from one lane to two.
  - Negative control: with lane-blind waits in the transition builder, the verifier reports the
    missing join wait and the previous frame's write-after-read across lanes, both in `queue_lanes`
    and in the corpus.
- GPU, Release: `test_render_graph_gpu` passes on cuda-overlapped, cuda, d3d12, vulkan and d3d11.
- Full matrix:
  - The Release build of the whole aggregate succeeds, and ctest passes 67/67 (one new test,
    `test_render_graph_gpu_cuda_overlapped`).
  - The Debug build succeeds apart from WaveWorks, whose Debug static_asserts on recovered object
    sizes fail as before. ctest passes 67/67.
  - The two builds needed reruns for the known "file in use" link flakes.
- Debug, behind nvrhi's validation layer:
  - `cuda_queue_pool` and `cuda_queue_fences` pass in their validation passes. The layer is live: it
    reports the refused pin (`createCommandList: commandQueue is a Graphics queue, but queueType is
    Compute`).
  - `test_render_graph_gpu_cuda_overlapped` runs every graph through the layer with no NVRHI errors.
