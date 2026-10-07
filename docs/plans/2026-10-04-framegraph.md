# FrameGraph for donut

- Status: Draft
- Date: 2026-10-04

## Context

donut has no pass-composition layer. Every sample hand-writes its frame: it owns a `RenderTargets`
struct, allocates each render target explicitly, nulls everything in `BackBufferResizing()`, and calls
passes in source order inside `app::IRenderPass::Render(nvrhi::IFramebuffer*)`. Pass ordering, resource
lifetimes and barrier placement are all implicit in statement order. Every transient is a separate
committed allocation held for the whole frame, nothing reuses memory, and the frame cannot be
inspected, reordered or toggled without editing the sample.

This plan adds a FrameGraph in which passes declare what they read and write, and the framework derives
execution order, resource allocation (including memory aliasing), barriers and introspection.

The design decisions are recorded separately:

- [`ethereal-donut/doc/adr/0001-framegraph-for-donut-render-passes.md`](../../ethereal-donut/doc/adr/0001-framegraph-for-donut-render-passes.md)
  â€?placement in `donut_render`, the declaration model, the pass lifecycle, and why the public headers
  follow the nvrhi ABI rules although the rest of donut does not.
- donut ADR 0002 (to be written in step 1) â€?resource lifetimes, residency classes, pooling and memory
  aliasing.
- donut ADR 0003 (step 3) â€?pass adapters over the existing render passes.
- donut ADR 0004 (step 6) â€?conditional passes and iterated subgraphs.
- donut ADR 0005 (step 8) â€?queues and cross-queue synchronization.
- donut ADR 0006 (step 2, accepted at step 5) â€?introspection and debug switches as a supported
  contract.
- nvrhi ADR 0008 (step 7) â€?aliasing barriers for virtual resources.
- [`../adr/0001-snake-case-directory-names.md`](../adr/0001-snake-case-directory-names.md) â€?the
  directory-naming change this work prompted.

Scope confirmed before planning: all four goals (declarative pass wiring, automatic resource
management, memory aliasing, tooling and introspection); C++-only authoring with no scripting layer;
port the key donut passes and rebuild existing samples; and all four execution features (single
graphics queue, async compute and multi-queue, conditional and dynamic passes, multi-view and iterated
subgraphs).

### Constraints established before step 1

These were verified against the tree and shape the steps below.

**nvrhi already provides everything except an aliasing barrier.** `HeapType`/`HeapDesc`/`IHeap`,
`TextureDesc::isVirtual`, `createHeap`, `getTextureMemoryRequirements`, `bindTextureMemory`,
`bindBufferMemory` and `bindAccelStructMemory` all exist. Multi-queue is exposed through
`CommandQueue`, `CommandListParameters::queueType`, `executeCommandLists`, `queueWaitForCommandList`
and `createCommandListLifetimeTracker`, and `ethereal-samples/src/async_compute` already demonstrates
the pattern. Profiling has `beginMarker`/`endMarker` and the timer-query API. But a search of
`ethereal-donut/ethereal-nvrhi/include` for "alias" matches only `antialiasedLineEnable`: **there is no aliasing
barrier**, which is why step 7 forks nvrhi.

**The cheap substitute for an aliasing barrier is incorrect, not merely noisy.** Transitioning a
freshly-placed resource from `ResourceStates::Common` maps, on Vulkan, to a first synchronization scope
of top-of-pipe with no access flags, which waits for nothing and leaves a real write-after-read hazard
against the outgoing alias; and on D3D12 enhanced barriers to `LAYOUT_COMMON` with no discard, which is
a false claim about memory last used as a render target. Restricting aliasing to cases that clear
anyway does not rescue it, because a clear is itself a GPU write needing the same missing dependency.

**Vulkan aliasing has two further blockers**, independent of the barrier: `createHeap` requests
`memoryTypeBits = ~0u` and the allocator then selects the first device-local memory type, unrelated to
any image's real mask, and `MemoryRequirements` does not expose `memoryTypeBits` for the caller to
check; and `bindTextureMemory` discards the result of `bindImageMemory` and unconditionally reports
success. So aliasing ships on D3D12 first and Vulkan stays on pooling. A third finding is informational:
D3D12 `createHeap` sets `ALLOW_ONLY_RT_DS_TEXTURES` on resource heap tier 1 and neither the tier nor
the heap flags are exposed, so step 7 probes at init rather than adding API.

**`nvrhi::IDevice::createGraphicsPipeline1` takes a `FramebufferInfo`, not an `IFramebuffer`** (the
variant taking an `IFramebuffer` is deprecated). Pipeline state therefore depends on formats and sample
counts but not on resolution, which is what makes the `createPipelines`/`bindResources` split in donut
ADR 0001 worth having: a resize recreates no pipelines.

**`engine::FramebufferFactory` is not reusable under pooling.** Its cache is keyed on
`nvrhi::TextureSubresourceSet` alone while its textures are mutable public members, so swapping a
texture behind it returns a stale framebuffer silently, with a correct-looking key. Pooling makes
physical identity unstable, so this fires immediately; it is the highest-probability defect in the work
and its fix lands in step 2, before any sample is ported.

**`donut-render.cmake`'s `file(GLOB)` is non-recursive**, so the new subdirectories need explicit
entries. `build.ps1` reconfigures on every run, so a new file is picked up automatically, but a build
driven from the Visual Studio solution without reconfiguring will silently omit it.

**Unit tests are off by default and the aggregate never enables them.** `CMakeLists.txt` calls
`enable_testing()` but nothing sets `DONUT_WITH_UNIT_TESTS`, so a bare `build.ps1 -Test` runs zero
FrameGraph tests and passes. Every verification command below passes the option explicitly, and the
verification results must state the expected test count so that a short run is a failure rather than a
pass.

**donut's test harness is not GTest.** `ethereal-donut/tests/` builds one executable per `test_*.cpp`, each with
a hand-written `main()` using the `CHECK` macro from `ethereal-donut/tests/include/ethereal-donut/tests/utils.h`. GTest
appears only in nvrhi's tests, behind an optional `find_package`. New tests follow donut's style.
There is also no `test-render.cmake` yet; step 1 adds one.

**Pixel-exact A/B is impossible until animation is deterministic.** `deferred_shading.cpp` advances
`m_Rotation` from wall-clock time in `Animate()`. The fixed-timestep, frame-count and screenshot
switches in step 2 are a blocking prerequisite for the comparison in Verification, not a convenience.

### Branching

A git worktree cannot be used for this tree. Submodule gitdirs live under the shared common directory
(`.git/modules/donut`, `.git/modules/ethereal-donut/modules/nvrhi`) and each pins a single `core.worktree` path,
so a second worktree plus `git submodule update` rewrites that path and breaks the submodules in the
original checkout; the two checkouts cannot hold `ethereal-donut` and `nvrhi` on different branches at once.

The work therefore proceeds on a branch named `framegraph` in all four repositories, in place. This is
a deliberate exception to the usual practice of committing directly to the working branch, made for
this work because it spans four repositories and two risky subsystems; it is not a change of practice.

Commit order within every step is forced by the submodule nesting, and each submodule must be committed
before its parent can record the new SHA:

```
ethereal-donut/ethereal-nvrhi  ->  donut (bumps nvrhi)  ->  ethereal-samples  ->  aggregate (bumps donut, ethereal-samples)
```

Only step 7 touches nvrhi, so most steps are donut, then ethereal-samples, then the aggregate. One
aggregate bump per step, not per submodule commit. Commit messages follow the existing history:
imperative sentence case, with `; bump nvrhi` appended when the gitlink moved, and aggregate commits as
`bump donut, ethereal-samples (<what>)`.

## Steps

Each step builds, commits and demonstrates on its own. Every goal and execution feature is assigned a
step so that nothing is silently dropped.

| Step | Lands | Repository | Delivers |
| --- | --- | --- | --- |
| 0 | Branches; `adr/` and `plans/` with README indexes in donut, ethereal-samples and the aggregate; `naming.md` rewritten to `snake_case` with recorded exceptions; aggregate ADR 0001 and donut ADR 0001, both Proposed; this plan | aggregate, donut, ethereal-samples | conventions and agreement before code |
| 1 | Declaration model, builder, channels, SSA versions, topological sort, culling, validation, lifetimes, immutable compiled plan, `detail/` pure logic; `test-render.cmake` and unit tests, **no device**; donut ADR 0002 | donut | **declarative pass wiring** |
| 2 | Executor, pooled allocator, batched barriers, markers, framebuffer cache, plan dump, **all debug switches**, determinism switches on `ApplicationBase`; donut ADR 0006 | donut | **automatic resource management** |
| 3 | `GBufferFillPass` and `DeferredLightingPass` adapters; `deferred_shading_fg` sample; first full A/B on D3D12, Vulkan and D3D11; donut ADR 0003 | donut, ethereal-samples | first pixels, end to end |
| 4 | `SkyPass`, `DepthPass`, `ForwardShadingPass`, `MipMapGenPass` adapters; `SsaoPass`, `BloomPass`, `ToneMappingPass`, `TemporalAntiAliasingPass` refactors; persistent and history resources; `variable_shading_fg` | donut, ethereal-samples | cross-frame state survives |
| 5 | Introspection query interface, timer queries, ImGui visualizer in `donut_app`, debug view of any intermediate | donut | **tooling and introspection** |
| 6 | Conditional passes, exclusion groups, view groups and iterated subgraphs; `vxgi_samples` `-framegraph` path; donut ADR 0004 | donut, ethereal-samples | **conditional passes**, **multi-view** |
| 7 | nvrhi aliasing barrier, nvrhi ADR 0008, header-version bump, the discarded-bind-result fix (and the memory-type exposure for Vulkan); placement solver; heap realization; D3D12 aliasing with pooled fallback | ethereal-donut/ethereal-nvrhi, donut, ethereal-samples | **memory aliasing** |
| 8 | Queue assignment, segment scheduling, cross-queue fences and state handoff; `async_compute_fg`; donut ADR 0005 | donut, ethereal-samples | **async compute and multi-queue** |
| 9 | ADRs Proposed to Accepted; this plan gains its Execution record, Verification results and follow-ups | ethereal-donut/ethereal-nvrhi, donut, aggregate | the record |

Steps 1 to 6 are the core that must work before the two features that can produce silent corruption.
If effort must be cut, cut **depth, not features**, using these pre-approved reductions so the decision
is not re-litigated under pressure:

- step 6 to single-level iteration only, deferring nested subgraphs;
- step 8 to the compute queue only, forcing any cross-queue resource to committed allocation, which
  sidesteps the interaction in step 7 entirely at a memory cost;
- step 5 to the plan dump and the switches, deferring the ImGui visualizer.

### Step detail

**Step 1** adds `include/ethereal-donut/render/framegraph/` and `src/render/framegraph/`, with the device-free
lifetime and packing logic in `src/render/framegraph/detail/`, and the explicit `file(GLOB)` entries in
`donut-render.cmake`. Lifetime intervals are half-open over pass-instance indices. The validation set
includes the checks Falcor declared but never wired up â€?writer and reader format compatibility, depth
against colour slot legality, dimension view legality, subresource ranges within the resolved mip and
array counts, sample-count agreement within a render-target group, format support for every required
usage bit, and queue legality â€?plus the check neither Falcor nor donut has: a transient whose first
use is a read with no in-frame producer is a compile error, not a warning.

**Step 2** keeps nvrhi's automatic barriers on and pre-transitions instead, so the automatic path finds
nothing to do: one site per pass issues aliasing barriers, then one `setTextureState` per declared use,
then a single `commitBarriers()` before the first draw. Graph-owned transients use
`keepInitialState = false` with `beginTrackingTextureState` at the top of each command list.
The debug switches land here, in full, because they are the bisection tool for every later step: force
committed allocation, disable pooling, disable aliasing, disable culling, disable reordering, barrier
after every pass, fill recycled memory with a garish pattern, serialize queues, and dump the compiled
plan. All are runtime toggles.

**Step 3** ports the two passes that prove the mechanism with the least refactoring noise.
`DeferredLightingPass` goes first because it already takes all its I/O per `Render()` call and already
holds an `engine::BindingCache`, so it demonstrates that the cache absorbs resource churn.
`GBufferFillPass` drives the existing `RenderView` free function with a graph-supplied framebuffer.

**Step 4** carries the hard ports. `TemporalAntiAliasingPass` is the worst: all seven I/O textures are
baked into `CreateParameters` and the history double-buffer into two binding sets selected by frame
parity. Its history must never be pooled or aliased; the graph must report reallocation so the adapter
can pass `feedbackIsValid = false` on the first frame after a resize; and it needs the side-effect flag
so culling cannot remove it and corrupt history permanently. `ToneMappingPass`'s histogram buffer
becomes a graph transient while its exposure buffer is persistent and never aliased. `BloomPass` splits
into five graph passes so its four intermediates become aliasable transients.

**Step 7** adds the aliasing barrier as a new interface derived from `ICommandList` with a fresh IID
that the object also answers, per section 3.4 of the ABI rules, rather than changing a released vtable,
and bumps the header version. The validation layer forwards it and checks that both resources are
virtual, bound, in the same heap, and that their byte ranges genuinely overlap â€?a check nothing else
can perform, and on its own a good reason to prefer the fork over issuing the barrier natively.
Aliasing and async compute are **not** combined: aliasing reuse is by definition the case with no data
dependency, so no fence exists where one would be needed, and barriers are queue-local. One transient
heap per queue, and any resource touched by more than one queue is allocated committed.

## Verification

### Unit tests, no device

New `ethereal-donut/tests/test-render.cmake`, mirroring `test-engine.cmake`: one executable per
`src/render/test_*.cpp`, linked against `donut_render donut_engine donut_core donut_tests_utils`,
registered with `add_test`, and included from `ethereal-donut/tests/CMakeLists.txt` inside the existing
`if (DONUT_WITH_NVRHI)` block. Written with a hand-written `main()` and the `CHECK` macro, matching the
existing tests rather than introducing GTest.

Lifetime cases, including the two that protect the interval arithmetic: a pass that reads A and writes
B must yield overlapping intervals, so the two may not alias; and a resource consumed two passes before
another is produced must yield disjoint intervals, so they may. Also exported resources living to the
end of the graph, imported resources excluded from allocation, culled resources excluded without a
diagnostic, a read-modify-write chain collapsing to one interval, iterated-subgraph temporaries being
pairwise disjoint while a subgraph-scoped accumulator spans all iterations, superset against recompile
peaks under conditional passes, exclusion groups suppressing a conflict, and a cross-queue resource
excluded from packing. The first-use-is-a-read detector must produce exactly one diagnostic when the
resource is declared transient and none when it is declared persistent.

Packer cases: disjoint intervals share an offset; overlapping intervals do not; alignment is respected
(a 100-byte block followed by a 64-byte-aligned request lands at 128, not 100); MSAA alignment is
respected; growth granularity does not recreate a heap for a small increase; and the result is
deterministic â€?shuffling the input with a fixed seed many times must give bit-identical placement,
which is what keeps physical identity stable across recompiles. Randomized property tests assert the
non-overlap invariant over generated interval sets.

A device-level smoke test and the heap-capability probe test are registered with a ctest label so they
can be excluded on machines without a usable adapter.

```powershell
# Required: the tests are off by default and the aggregate does not enable them,
# so a bare `build.ps1 -Test` runs zero FrameGraph tests and passes.
.\build.ps1 -ConfigureOnly -CMakeArgs '-DDONUT_WITH_UNIT_TESTS=ON'
.\build.ps1 -Test                                    # ctest --preset release (Release only)
.\build.ps1 -Config Debug -Target donut_all_tests    # Debug, for asserts and nvrhi validation
ctest --test-dir build -C Debug -R framegraph --output-on-failure
```

Build from PowerShell, not a POSIX shell: `build.ps1` sources the Visual Studio environment when
`cl.exe` is absent, and without it the compiler cannot find the standard headers while a stale
"up to date" can mean nothing compiled. Build and run both Debug and Release at each step boundary
before committing.

### Header rules

Point `ethereal-donut/ethereal-nvrhi/tests/abi_lint.py` at the new header directory; it already walks any directory and
applies R1, R2, R3, R5, the module-private-type check and the export rule, so only R4 needs a one-line
change to its hardcoded API-header set. `header_hygiene.cmake` hardcodes the `nvrhi/` subdirectory in
its glob and needs a parameter to be reused. Add an equivalent of the standalone-header check, in which
each public header is compiled twice in its own translation unit.

The step 7 addition is in a real nvrhi API header and so is subject to all three checks automatically.
Design it to R1, R3 and R5 from the first draft and budget one lint-rejection iteration.

### Graphical correctness

Capture the original and the ported sample with identical determinism switches, and confirm the same
API and frame index before trusting anything downstream. Then, with the RenderDoc tooling:

- The draw count must match â€?the graph reorders and pools, it does not change the work â€?while the
  resource count falls. A changed draw count means something was wrongly culled.
- The final backbuffer must be bit-identical. A stored golden image gives a regression gate that does
  not need RenderDoc.
- On failure, locate the first divergent draw and inspect its pipeline and bindings. A wrong binding is
  the framebuffer or binding-cache hazard; wrong input content is the allocator or barriers, which the
  debug switches then separate.
- Compare every intermediate, not only the backbuffer: a matching final image can hide compensating
  errors that surface on the next shader change.
- Compare the driver's pass list and dependencies against the graph's own plan dump. This is the only
  check that tests what the graph believes it scheduled against what the driver saw, and it is why the
  per-pass markers are in step 2 rather than step 5.
- For every pair of resources sharing a heap range, assert that the last use of one precedes the first
  use of the other and that no read of the first occurs after the second is written. This is the
  definitive aliasing test and, unlike an image comparison, it does not depend on the corruption being
  visible â€?an aliasing violation very often produces a plausible image.
- The unused-target query must come back empty on the ported capture; on the original it finds the
  over-allocation, which is the before-and-after story for free.
- Run the API-misuse check on every capture on every backend.

The complete detector is the forced-committed switch against aliasing enabled, on the same frame: any
difference is an aliasing bug. This becomes CI-able once the determinism switches exist.

### Memory

Report the graph's own accounting as the headline: committed bytes, aliased bytes, the packing lower
bound, the no-reuse baseline, and the saving attributable to iterated-subgraph reuse. Two derived ratios
carry the story â€?aliased bytes against the lower bound measures the packer, and the no-reuse baseline
against the total measures the feature. The accounting is reportable from a unit test on a recorded
declaration set, with no GPU. Corroborate with the RenderDoc texture statistics. Whole-process figures
from the DXGI and Vulkan budget queries are noisy and are quoted as a range.

`IRHIObject::queryMemoryRequirements` is not usable here: textures report failure on every backend. Use
the `IDevice` getter. Report pooling and aliasing separately so the additional win from placed resources
is visible against the cost of the barrier work, and state which resources are excluded from aliasing
by construction â€?TAA history, the exposure buffer, and anything crossing a queue.

### Backends

| Backend | What it proves |
| --- | --- |
| D3D12, Debug, with GPU-based validation once | barrier correctness and that aliasing barriers are accepted; the only check that catches a wrong resource state at dispatch time |
| Vulkan, Debug, with validation layers | image-layout transitions and undefined-layout re-initialization, where the aliasing abstraction will leak if it is going to |
| D3D11, Debug | the fallback path: `createHeap` is unsupported and asserts in debug, so this run is precisely the test that the allocator never attempts virtual resources. It also validates that the no-aliasing switch is equivalent, since D3D11 is permanently in that mode |

`deferred_shading` is the only ported sample that builds for D3D11 â€?the others are guarded by the
D3D12-or-Vulkan condition in `ethereal-samples/src/CMakeLists.txt` â€?so it carries that duty alone,
which is a further reason it is ported first. Run D3D12 both with and without enhanced barriers.
`NVRHI_WITH_VALIDATION` is on by default.

### Samples

The originals are kept, not replaced: they are the comparison reference, sixteen other samples still
use the non-graph API, and two implementations of the same frame side by side is the most useful
artifact this work produces. Ported samples are sibling directories under the same API guards, except
`vxgi_samples`, which takes a switch inside the existing sample because duplicating its supporting
classes is not sensible. Migrating the originals and deleting the duplicates is a follow-up for after
the ADRs are accepted, not part of this plan.
