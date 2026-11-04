# Render graph (RDG) for donut: design

- Status: Accepted (2026-11-05)
- Date: 2026-10-21; rebased onto the ethereal-dev RHI on 2026-11-01
- Decision record: [ADR 0003](adr/0003-render-graph-for-donut.md)
- Plan: [`plans/2026-11-05-render-graph.md`](plans/2026-11-05-render-graph.md)
- RHI baseline: ethereal-nvrhi `ethereal-dev` at `123d105`, donut `ethereal-dev` at `4f4b31c`, samples
  `main` at `37ac258` (aggregate `main` at `264ac18`). That baseline includes the CUDA/OptiX backend, the
  offline Slang shader containers and the per-backend graphics factories (nvrhi ADRs 0011-0014). The
  earlier `slang-next` baseline is retired.
- Supersedes: `ethereal-donut/doc/RdgDesign.md` (2026-10-12) and
  [`plans/2026-10-04-framegraph.md`](plans/2026-10-04-framegraph.md). Nothing from the unmerged
  `framegraph` branches is reused; those branches are no longer in the local repositories.

This document is the design of a new render graph for donut. It specifies the interfaces, the
compiler's algorithms, the RHI extensions and the backend lowering closely enough to review code
against. Scheduling heuristics beyond async-compute placement and read grouping are left for later.

## 1. Requirements

| # | Requirement | What it means here |
| --- | --- | --- |
| R1 | No DSL, no DSL parser or compiler | C++ is the only authoring surface. Graphs, their resources and their passes are recorded each frame through `IRenderGraph`. No RPSL, no graph files, no code generation. |
| R2 | Outstanding at resource state transitions and state overlapping | Per-subresource (plane, mip, slice) state tracking. Merging of compatible read states across whole read epochs. UAV ordering control, split barriers, aliasing barriers with first-use initialisation, discard inference, queue-capability-aware transition placement. A device-free verifier proves every plan correct. Section 6 is the core of the design. |
| R3 | The ethereal-dev RHI; four backends: CUDA, D3D11, D3D12, Vulkan | Build on ethereal-nvrhi as it stands on `ethereal-dev`: the IDevice/ICommandList model, the per-backend graphics factories and `IGraphicsSwapChain`, the CUDA/OptiX backend, offline Slang containers with reflection on `IShader`, and `IInteropDevice`. One compiler for all four. Per-backend behaviour comes from a capability profile and a lowering layer, never from `if (api == ...)` in the compiler. |
| R4 | Generic build, compile and execute | The graph is part of `donut_render`, as the `RenderGraph*` files in the `render/` folder. Graph code names no pass and includes nothing from the rest of `donut/render` or `donut/engine`. Every donut pass derives from one base, `IGpuPass`, and adds itself to a graph. The dependency runs from the passes to the graph, never back. |
| R5 | Performance oriented | Every mechanism is chosen and gated by its CPU and GPU cost. A cached plan costs almost nothing per frame, and steady state creates no GPU objects and makes no heap allocations. The plan emits the fewest, narrowest barriers that are correct. Each implementation step has measured exit budgets (section 10). |

Non-goals:
- a visual graph editor and scripting;
- automatic pass reordering beyond async-compute placement and read grouping;
- multi-device graphs: one graph spanning a CUDA device and a graphics device (14.5);
- native render passes with load/store ops. The RHI has none yet; the name `nvrhi::IRenderPass` is
  kept free for them (3.3, 6.9).

## 2. Facts the design is built on

### 2.1 The ethereal-dev RHI

Verified on 2026-11-01 against `ethereal-nvrhi` on `ethereal-dev` (`123d105`, header version 28).

**Objects**

- Resources derive directly from `IRHIObject`: `ITexture`, `IBuffer`, `IStagingTexture`,
  `ISamplerFeedbackTexture`, `rt::IAccelStruct` and `rt::IOpacityMicromap`. There is no common
  resource base.
- Derived backend interfaces: `d3d12::ICommandList` and `cuda::ICommandList` derive from
  `nvrhi::ICommandList`; `d3d12::IDevice`, `vulkan::IDevice` and `cuda::IDevice` derive from
  `nvrhi::IDevice`. The validation layer wraps both (`CommandListWrapper`, and `DeviceWrapper` with its
  `InteropDeviceWrapper` mixin).
- Descriptor debug names are `nvrhi::string` (an EASTL-style string with inline storage).
- Results are `FRESULT` codes, among them `FS_OK`, `FE_INVALID_ARGS`, `FE_NOT_FOUND`,
  `FE_WAIT_TIMEOUT`, `FE_UNSUPPORTED` and `FE_OUT_OF_DATE` (a swap chain needs a resize).

**Devices, swap chains and the version policy** (nvrhi ADRs 0012 and 0014)

- Devices come from one factory per backend: `<backend>::createGraphicsFactory`, then
  `createDevice` (wraps native objects the caller made) or `createDeviceOnAdapter` (creates them
  inside). donut's `DeviceManager` keeps only the window and the frame loop.
- `nvrhi::IGraphicsSwapChain` owns the back buffers. Its `beginFrame` differs per backend:
  - D3D12 waits on the CPU for the back buffer's frame fence;
  - Vulkan acquires the next image and *queues* the acquire-semaphore wait on the graphics queue
    (`vulkan::IDevice::queueWaitForSemaphore`), so the wait rides on the next graphics submission;
  - CUDA has no window: it rotates CUDA-texture back buffers and waits for the reused slot's stream
    work.
- Back-buffer textures are `keepInitialState` with initial state `Present` (`d3d12-swapchain.cpp:232`,
  `vulkan-swapchain.cpp:380`).
- **Interfaces change in place.** `com-interface-abi.md` §3.4 was amended on 2026-10-22: an interface
  may gain, lose or change virtual functions, and struct layouts may change, without a derived
  `IFoo1` and without bumping `c_HeaderVersion` (28). nvrhi and its consumers are built from one tree;
  the installed CMake package is `ExactVersion`. Every other rule (R1-R5, header hygiene) is still
  enforced by `nvrhi_abi_lint`, `nvrhi_header_hygiene` and `nvrhi_header_tus`.

**Subresource sets**

- `TextureSubresourceSet` is four 32-bit fields (mip base and count, slice base and count). It is
  asserted at 16 bytes.
- It is embedded in two hot layouts:
  - `BindingSetItem` (asserted at 40 bytes). It sits in a 16-byte union with `BufferRange`, and that
    union is compared and hashed through `rawData[2]`.
  - `FramebufferAttachment` (32 bytes, `isReadOnly` at offset 25).
- Adding a member would therefore change hot binding layouts. The design leaves the type unchanged
  and adds a separate `SubresourceRegion` for barriers (8.2).

**State tracking**

- `nvrhi::ResourceStates` is a flag enum.
- `CommandListResourceStateTracker` works per mip × slice. It never tracks planes, and it tracks
  buffers only as a whole. Its state lives inside one command list and is cleared at submit.
- Texture read states are never merged. ShaderResource after DepthRead emits a full transition.
- The only barrier API is the tracker: `setTextureState`/`setBufferState` plus `commitBarriers`.
  There are no split barriers, aliasing barriers, discards, layout-only transitions or
  queue-ownership transfers.

**Per backend**

- **D3D12** has legacy and enhanced barriers, chosen per device. On the enhanced path a combined
  ShaderResource|DepthRead asserts.
- **Vulkan** always uses sync2.
  - `Common` maps to `UNDEFINED` with an empty first synchronisation scope. It is an implicit
    discard, and it also waits for nothing, which leaves a write-after-read hazard.
  - `commitBarriers` ends the dynamic-rendering pass.
  - Queue families are always `IGNORED`, and sharing is `EXCLUSIVE`.
- **D3D11 and CUDA** implement every state call as a no-op. CUDA orders work by stream submission.
  D3D11 maps the UAV-barrier toggles to NVAPI UAV overlap.
- **CUDA command lists are deferred** (nvrhi ADR 0011). A list records plain records into a byte
  stream, resolving bindings and uploads while it records. `executeCommandLists` replays them on the
  queue's `CUstream` and records one `CUevent` per submission, which `queueGetCompletedInstance` and
  `runGarbageCollection` retire. Each queue loads its own `CUmodule`, so two queues never race on a
  module's `SLANG_globalParams`.
- **Binding states.** On D3D12 a binding requires the shader-resource state that matches its
  visibility (pixel or non-pixel). On Vulkan nvrhi binds sampled depth as
  `ShaderResource|DepthRead`.

**Queues and synchronisation**

- Queues are `CommandQueue{Graphics, Compute, Copy}`. A command list is created for one queue
  (`CommandListParameters::queueType`). There is no queue object.
- `executeCommandLists` returns an instance value. `queueWaitForCommandList(waitQueue, execQueue,
  instance)` is the only cross-queue primitive:
  - D3D12 uses a fence per queue.
  - Vulkan uses a timeline semaphore per queue (also reachable through `vulkan::IDevice::queueWaitForSemaphore`).
  - CUDA uses one non-blocking stream per queue and waits with `cuStreamWaitEvent`.
  - D3D11 has one queue, so the call is a no-op.
- Vulkan also has *queued* semaphore calls, `queueWaitForSemaphore` and `queueSignalSemaphore`: the
  wait is attached to the next submission on that queue, not to a submission the caller names. The
  swap chain's acquire and the Vulkan interop waits use them.
- `IEventQuery` is a CPU-side completion query. There is no timeline fence object in the public API;
  the backends keep their fences and semaphores internal.

**Memory**

- `IHeap` and `bind*Memory` work on D3D12 and Vulkan only (`Feature::VirtualResources`). A resource
  binds exactly once.
- Vulkan heaps ignore `memoryTypeBits` (`vulkan-device.cpp:827`). D3D11 and CUDA return
  unsupported.
- On D3D12 heap tier 1, render-target and depth heaps are `ALLOW_ONLY_RT_DS_TEXTURES`
  (`d3d12-device.cpp:1255`).
- Vulkan `bindImageMemory` and `bindBufferMemory` ignore the bind result and always report success
  (`vulkan-texture.cpp:408`, `vulkan-buffer.cpp:673`).
- nvrhi cannot report which heap, offset and size a virtual resource is bound to.

**Render targets**

- Framebuffers have no load/store ops; Vulkan hard-codes LOAD/STORE. nvrhi has no render-pass
  object.

**CUDA** (nvrhi ADR 0011)

- `FE_UNSUPPORTED`: graphics and meshlet pipelines, framebuffers, heaps and virtual resources,
  bindless layouts, sampler feedback and opacity micromaps. `clearDepthStencilTexture` reports an
  error.
- Formats: a writable texture (a surface) needs `isUAV` and an uncompressed format; there are no
  3-component or depth-stencil formats.
- Compute, copies and OptiX ray tracing work. An indirect dispatch reads its group counts back on
  the host before it launches, so it stalls.
- `cuda::ICommandList::enqueueNativeWork` hands the stream to application code during replay.

**Shader reflection** (nvrhi ADR 0012)

- Shaders built by ShaderTool's container mode (`ethereal_compile_shader_containers`) carry offline
  Slang reflection. `IShader::getReflection` and `IShaderLibrary::getReflection` return it, or `nullptr`
  for plain bytecode. There is no `IShaderProgram` and no `slang.dll` at run time.
- Each parameter reports its HLSL register class, space and slot (on CUDA as well, through a second
  HLSL layout), so SRV and UAV slots can be told apart.
- Limits: a resource nested in a parameter block or struct gets no register, there is no "no
  binding" marker, and Vulkan reports the shifted bindings (t 0, s 128, b 256, u 384).
- Today only the GVDB samples build containers. donut's `ShaderFactory` loads plain bytecode, so
  donut's own passes have no reflection.

**Interop** (nvrhi ADR 0013)

- A CUDA device paired with a graphics device implements `IInteropDevice` (reached by
  QueryInterface). It imports graphics buffers and textures (every mip and slice) into CUDA objects
  and orders the two devices with `computeQueueWaitForGraphicsQueue` and
  `graphicsQueueWaitForComputeQueue`.
- D3D12 uses a shared `ID3D12Fence` and Vulkan an exportable timeline semaphore, imported into CUDA as
  external semaphores. On Vulkan the graphics-side wait is queued, as above.
- D3D11 interop is unsupported. The Vulkan import refuses layered textures with more than one mip.
- Synchronisation is explicit; nothing touches a resource state tracker.

**Earlier work.** The deprecated `framegraph` branches (archived 2026-10-14, evaluated in
[`rdg-legacy-evaluation.md`](rdg-legacy-evaluation.md)) had already added the following to nvrhi.
None of it is on ethereal-dev:
- aliasing barriers through a derived `ICommandList1`;
- heap-binding queries (`ITexture1/IBuffer1::queryHeapBinding`);
- `CONCURRENT` sharing across Vulkan queue families;
- header versions 28 → 31.

Section 8 keeps the aliasing and heap-binding ideas, but not the derived interfaces.

### 2.2 donut

**There is no common pass base.** The shipped passes derive from three different places:

| Base | Passes |
| --- | --- |
| `nvrhi::ObjectImpl<nvrhi::IObject>` | BloomPass, DeferredLightingPass, DLSS, SkyPass, SsaoPass, TemporalAntiAliasingPass, ToneMappingPass |
| `IGeometryPass` (itself an `ObjectImpl<IObject>`) | DepthPass, ForwardShadingPass, GBufferFillPass, MaterialIDPass |
| nothing | EnvironmentMapPass, JointsRenderPass, LightProbeProcessingPass, ManipulatorPass, MipMapGenPass, PixelReadbackPass |

**`app::IRenderPass` is not a GPU pass.** It is the application's frame participant:
- `DeviceManager` keeps a front-to-back list of them (`AddRenderPassToFront`,
  `AddRenderPassToBack`, `RemoveRenderPass`).
- On each one it calls `Render(framebuffer)`, `Animate`, the resize callbacks and the keyboard,
  mouse and joystick handlers.
- `ApplicationBase` and `ImGuiRenderPass` derive from it. 43 files in ethereal-samples and 5 in
  donut name it or its `DeviceManager` members.

**Barriers.** Passes rely on nvrhi automatic barriers and on textures created with
`keepInitialState=true`. Only DLSS records barriers itself.

**Targets.**
- Passes take targets through a concrete `engine::FramebufferFactory`, through
  `RenderView`/`RenderCompositeView`, or as raw `ITexture*`.
- `FramebufferFactory` caches framebuffers by subresource set only, so the cache goes stale when the
  textures are reallocated.
- These passes bind their targets or formats at construction:
  - BloomPass
  - ToneMappingPass
  - SkyPass
  - EnvironmentMapPass
  - TemporalAntiAliasingPass
- GBufferFillPass, DepthPass and ForwardShadingPass cache pipeline state objects without the
  framebuffer format in the key, so samples recreate them on resize.

**Resources hidden inside passes.**

| Pass | What it keeps internally |
| --- | --- |
| SsaoPass | deinterleaved quarter-resolution arrays |
| BloomPass | per-view chain |
| TemporalAntiAliasingPass | feedback ping-pong, swapped in `AdvanceFrame` |
| ToneMappingPass | histogram and exposure buffers |
| LightProbeProcessingPass | intermediate cube |

**Best fit.** DeferredLightingPass, whose inputs are a per-call `Inputs` struct.

**Swap chain.** `DeviceManager` holds an `nvrhi::IGraphicsSwapChain` (`GetSwapChain`) and calls its
`beginFrame` from `BeginFrame`. Back-buffer textures are `keepInitialState` with initial state
Present (2.1). Declaring their state to a graph once cost a device loss; the import contract in 5.2
makes that impossible. On Vulkan the acquire wait is queued on the graphics queue, so only a
graphics-queue submission waits for the image (6.8).

**Build.** `donut_render` collects `include/donut/render/*.h` and `src/render/*.cpp` with a
non-recursive `file(GLOB)` in `donut-render.cmake`. It links `donut_core` and `donut_engine`.

**Vulkan queue families.** Device creation moved into nvrhi's Vulkan factory, whose
`GraphicsFactory::findQueueFamilies` starts from fresh indices for every physical device
(`vulkan-factory.cpp:473`). The legacy's device loss, where compute lists came from a transfer-only
family on a machine with more than one GPU, cannot happen any more. donut's `DeviceManager_VK.cpp` is
down to window and frame-loop code.

**CUDA in donut.** `DeviceManager` creates D3D11, D3D12 and Vulkan devices only. CUDA work in this
tree (the GVDB samples) creates its `cuda::IDevice` through the CUDA factory, pairs it with the
graphics device, and presents through `IInteropDevice` (`sample-utils/ScreenPresenter.cpp`).

**Thread safety.** `BindingCache` creates missed binding sets while it holds its exclusive lock.
`CommonRenderPasses::BlitTexture` writes its pipeline cache without any lock
(`CommonRenderPasses.cpp:260`).

### 2.3 What the references teach

| Mechanism | Taken from | Used in | Pitfall avoided |
| --- | --- | --- | --- |
| Transition decided per access against a per-subresource state map; a reader set accumulates until the next write | RPS `AccessDAGBuilder`, `NeedTransition` | 6.2, 6.3 | azhirnov replaces the reader record on each read, so a later write waits only for the last reader. Here every reader since the last write is a dependency of the next write. |
| Interval map over a linearised subresource index | O3DE `RHI::ImageProperty`, azhirnov `VLocalImage` | 6.2 | RPS and azhirnov never re-coalesce. Here equal neighbours are merged after every pass. |
| Discard-before/after inferred from lifetime | RPS lifetime phase, Filament `RenderPassNode::resolve`, Unity `DetermineLoadStoreActions` | 6.6 | Persistent and imported resources never get inferred discards. |
| UAV→UAV ordered by default; relaxed only when both sides opt in | RPS `RELAXED_ORDER` | 6.5 | The RPS D3D12 legacy builder ignores the flag; here it is honoured on every backend. |
| Byte-range overlap between deactivating and activating aliases | O3DE `AliasingBarrierTracker` | 6.7 | RPS has no aliasing barrier. |
| Lifetimes widened across async queues before aliasing | O3DE `ExtendTransientAttachmentAsyncQueueLifetimes` | 7.4 | |
| Transitions moved to a queue that can perform them | O3DE DX12 epilogue placement | 6.8 | |
| Prologue/epilogue barrier slots; split begin/end across passes | Unreal RDG, O3DE | 6.4 | RPS (`BEFORE/AFTER` not implemented) and O3DE have no split barriers. |
| Barrier combining only over exact or adjacent ranges | (lesson) | 6.10 | O3DE Vulkan `Barrier::Combine` takes a bounding box and can over-cover. |
| Versioned handles; a write creates a version | Filament, Unity | 5.1 | Filament versions the whole parent on a subresource write. Here hazards are per subresource. |
| Reference-count culling from side-effect passes | Filament, Unity | 7.1 | |
| A reason code on every barrier and every non-merge | Unity `PassBreakReason` | 11.3 | |
| One barrier record type for transitions, UAV and aliasing | D3D12 `D3D12_RESOURCE_BARRIER` | 8.2 | |
| Immediate-mode tracker as the fallback outside the graph | slang-rhi `StateTracking` | 9.1 | |

## 3. Architecture

```
 samples / app ── build a graph each frame (app::RenderGraphLayer, or their own code)
        │
        ▼
 donut_render  (include/donut/render, src/render)
 ├─ RenderGraph*  (generic)
 │    IResourceRegistry (persists across frames)
 │        ▲ bound to
 │    IRenderGraph (recorded per frame) ── Compile ─► ICompiledRenderGraph (data, cached)
 │        └──────────────────────────────── Execute(plan) ◄──┘
 │    IGpuPass, ISetupContext, IPrepareContext, IPassContext    BackendProfile + lowering
 │        ▲ derive from IGpuPass, call AddToGraph
 └─ passes: GBufferFillPass, DeferredLightingPass, ForwardShadingPass, DepthPass, SsaoPass,
            BloomPass, TemporalAntiAliasingPass, ToneMappingPass, SkyPass, ...
        │
        ▼
 ethereal-nvrhi (ethereal-dev) + IResource, SubresourceRegion, ICommandList::barriers, IFence, IDevice::submit (section 8)
   D3D12  |  Vulkan  |  D3D11  |  CUDA
```

### 3.1 Placement

The graph sits in the `render/` folder of `donut_render`, beside the passes. There is no new library,
no subfolder and no adapter layer: the passes themselves become graph passes (section 13).

| File | Contents |
| --- | --- |
| `include/donut/render/RenderGraph.h` | public interfaces (section 12), including `IGpuPass` |
| `include/donut/render/RenderGraphLambdaPass.h` | header-only lambda helper (12.1) |
| `include/donut/render/RenderGraphFrameData.h` | header-only typed blackboard (12.2) |
| `src/render/RenderGraph.cpp` | graph recording (resources, passes, the setup context), frame arena, structural hash |
| `src/render/RenderGraphCompiler.cpp` | phases 1-5 and 7 of section 7 |
| `src/render/RenderGraphTransitions.cpp` | phase 6: the walk of section 6, lattices |
| `src/render/RenderGraphExecutor.cpp` | executor and lowering (9.1) |
| `src/render/RenderGraphRegistry.cpp` | registry, plan cache, pools, fences, retirement |
| `src/render/RenderGraphProfile.cpp` | backend profiles (9.2) |
| `src/render/RenderGraphVerifier.cpp` | device-free verifier (11.1) |
| `src/render/RenderGraphInternal.h` | private concrete classes |

The non-recursive `file(GLOB)` in `donut-render.cmake` picks these up with no build change.

### 3.2 Rules

1. **Graph code stays generic.** The `RenderGraph*` files may include only `nvrhi/`, `donut/core/`,
   other `RenderGraph*` headers and the C++ standard library. A header-hygiene test in CTest fails
   when one of them includes any other `donut/render/` or `donut/engine/` header.
2. **The dependency runs one way.** Passes include `RenderGraph.h` and derive from `IGpuPass`. Graph
   code reaches a pass only through `IGpuPass`.
3. **`RenderGraph.h` follows the nvrhi ABI rules.**
   - COM interfaces with `NVRHI_IID`.
   - `noexcept` and `FRESULT`.
   - Raw pointers in parameters; `AutoPtr` only as a return or out-parameter.
   - No STL in interfaces.
   - No class, struct or union is passed or returned by value through a virtual function (nvrhi
     `doc/com-interface-abi.md`, rule R1). Structs go by `const&`; ids are enums (5.1).
   - No two virtual functions share a name (rule R3).
   - Interfaces evolve in place, as nvrhi's do since its §3.4 amendment (2.1): donut, nvrhi and the
     samples are always rebuilt together, so there is no `IFoo1 : IFoo` and no version constant.
   - `abi_lint --api-all` (nvrhi's `nvrhi_abi_lint` script) and the header-hygiene test cover
     `RenderGraph.h`.

   Pass headers follow ordinary donut conventions.

### 3.3 Names

The design names two types and renames one existing type. All three names are decided (14.7).

**The pass base: `donut::render::IGpuPass`.** Every donut pass derives from it (13.1).
- It covers raster, compute, copy and ray-tracing passes on every backend, CUDA included, where
  "render" or "graphics" would mislead.
- It does not collide with `nvrhi::IRenderPass`, which is kept for the RHI's future render-pass
  object.
- Alternatives considered:
  - `render::IPass`: too generic outside its namespace.
  - `IGraphicsPass`: confusable with the graphics queue and with raster passes.
  - `IRenderGraphPass`: it would tie every pass to the graph, although passes also run outside one.

**The app layer: `donut::app::IRenderPass` becomes `donut::app::IAppLayer`.** The object is a
frame participant that receives input, animation and a back-buffer render call, stacked front to
back. That is what "layer" means in application frameworks.

| Today | New |
| --- | --- |
| `app::IRenderPass` | `app::IAppLayer` |
| `DeviceManager::AddRenderPassToFront` | `DeviceManager::AddLayerToFront` |
| `DeviceManager::AddRenderPassToBack` | `DeviceManager::AddLayerToBack` |
| `DeviceManager::RemoveRenderPass` | `DeviceManager::RemoveLayer` |
| `DeviceManager::m_vRenderPasses` | `DeviceManager::m_vLayers` |
| `app::ImGuiRenderPass` | `app::ImGuiLayer` |

- Alternatives considered: `IFrameLayer`, `IViewLayer`, `IAppComponent`.
- No alias is kept. The rename lands in one commit per repository, across the 5 donut and 43 sample
  files (2.2), so donut has only one "render pass" concept left, the GPU one.

## 4. Object model

| Object | Kind | Lifetime | Responsibility |
| --- | --- | --- | --- |
| `IRenderGraph` | records, compiles and executes | long, bound to one registry; `Reset` starts each frame | The frame's resources (created, imported, persistent, history, extracted), passes and accesses, in a frame arena. `AddPass` records a pass, and the pass declares its accesses through an `ISetupContext` in `Setup`. `Compile(profile, options) → ICompiledRenderGraph` freezes the graph until the next `Reset`; it makes no device calls and runs headless in unit tests. `Execute(plan)` instantiates plan memory through the registry, records command lists (optionally in parallel) and submits them. Carries its structural hash. |
| `ICompiledRenderGraph` | data | cached across frames | Holds, among other things: <br>• schedule and segments<br>• lifetimes and memory plan<br>• prebuilt `ResourceBarrier` arrays<br>• fence operations<br>• diagnostics |
| `IResourceRegistry` | data | long, one per view or pipeline | Holds, among other things: <br>• persistent resources and their cross-frame states<br>• the plan cache<br>• transient heaps and pools<br>• framebuffer and binding caches<br>• per-queue fences<br>• retirement |
| `IGpuPass` | operation, pass-specific | long, owned by its creator | The base of every donut pass. `Setup` declares the accesses of one use, `Prepare` creates pipelines and uploads serially, and `Execute` records the use (12, 13.1). One pass object can be added several times per frame, each use with its own arena data (`void* data`). |

**Why compile is separate from execute:** the two are separate calls with a plan object between
them, which enables the device-free verifier (11.1) and plan caching (7.7). They are methods of the
graph rather than separate compiler and executor objects, as in Filament's `compile()` and
`execute()` (14.11). The compiler and the executor stay separate concrete classes inside
`src/render`.

**Why the registry is separate from the graph:** a graph is rebuilt every frame, while history,
heaps and caches survive.

**Why there is no builder:** the graph is the object that holds what is recorded, so it records it
itself; a pass declares its accesses through a setup context valid only during its `Setup` (14.9).
`Compile` still makes no device calls, and a registry created without a device
(`CreateResourceRegistry(nullptr, ...)`) supports recording and compiling only; `Execute` then
returns `FE_UNSUPPORTED`. The device-free verifier and the unit tests are unaffected.

**Hot paths are concrete classes.** COM interfaces are used at module boundaries only. Inside
`src/render/RenderGraph*.cpp` the compiler and executor are plain C++ over concrete classes, with no
virtual calls in their inner loops (10.1).

## 5. Resource model

### 5.1 Resource ids and versions

`ResourceId` names a texture or a buffer in one graph (5.2). It is a 64-bit enum,
`enum class ResourceId : uint64_t`, holding a 32-bit resource index in the low half and a 32-bit
version in the high half. The index is the resource's position in the graph's resource table for
the frame, which `Reset` clears.
- It is an enum rather than a struct, so it may cross virtual calls by value under nvrhi's ABI rule
  R1 (3.2).
- **Where the layout comes from.**
  - The index-low, version-high packing follows Unity SRP's `ResourceHandle`
    (`RenderGraphResources.cs`). Unity packs a 16-bit index and a 15-bit version into one 32-bit
    word, and uses the top bit to mark a handle as not versioned.
  - Filament's `FrameGraphHandle` keeps the index and the version as separate fields. Its handle is
    valid only while its version equals the resource slot's current one, and a write increments it
    (`createNewVersion`). The stale-id rule below is the same check.
  - The legacy framegraph used `enum class ResourceId : uint16_t` with no version bits: each id named
    one version, and a table mapped it back to its resource. This design keeps the legacy's enum
    form, for R1, but packs the version into the id instead.
  - Both halves are widened to 32 bits. Unity's 16 and 15 bits cap a graph at 65,535 resources
    and 32,767 writes per resource.
  - Unity also keeps a separate per-execution validity word, so that a handle left in pooled pass
    data from an earlier frame is rejected. Here the version carries that check (below): the graph
    is reused across frames and reuses indices after every `Reset`, so an id that a caller or a pass
    member keeps past `Reset` would otherwise look valid.
- The inline helpers `MakeResourceId`, `GetResourceIndex` and `GetResourceVersion` pack and unpack it.
- `InvalidResourceId` (all bits set) is the invalid value.

- **One id type for every kind.** The kind lives in the resource record, not in the id. A
  texture-only access (a render target, a subresource range other than all) on a buffer is a
  validation error, and `IPassContext::GetTexture` returns `nullptr` for a buffer.
- **Writes create versions.** Every write declaration returns a new version.
- **Versions never repeat across frames.** A resource's first version, and every later one, comes
  from one counter in the graph that `Reset` never clears. Index *i* is reused every frame, but the
  version of *i* in frame N+1 can never equal a version of *i* from frame N.
- **Stale ids are rejected.** Using any version other than the current one is a validation error
  naming both passes. That covers an id kept from an earlier frame: its index may be
  valid again, but its version is not. The counter wraps after 2^32 writes, and only an id kept that
  long whose version then matches exactly would escape the check.
- **No cycles.** Because every write creates a version, declaration order is always a valid
  topological order, so a graph cannot contain a cycle.

Hazards are computed per subresource, not per version (6.2).

### 5.2 Resource kinds

| Kind | Created by | Memory | Entry state | Exit state | Aliasable |
| --- | --- | --- | --- | --- | --- |
| Transient | `CreateTexture/Buffer` | Registry heap or pool | Undefined (discard) | None | Yes, single queue only (7.4) |
| Transient, pass-local | `ISetupContext::CreateTransientTexture/Buffer`, in `Setup` | Registry heap or pool; the lifetime is that one pass | Undefined (discard) | None | Yes |
| Imported, tracked | `ImportTexture/Buffer(resource, entry, exit)` | Caller | Declared `entry` | Declared `exit`, reached at last use | No |
| Imported, host-kept | `ImportHostKeptTexture(tex)` for `keepInitialState` resources such as the swap chain | Caller | `desc.initialState` | `desc.initialState` | No |
| Persistent | `GetPersistentTexture/Buffer(name, desc)`, `GetHistory`/`GetHistoryPair` | Registry, dedicated | Exit state of the previous frame, recorded in the registry | Left in its last-use state and recorded; no restore transition | No |
| Extracted | `Extract(transient)` | Registry pool; the lifetime is extended to the end of the graph | as transient | Declared exit | No. It returns to the pool when the caller releases it and the frame retires |

Every "Created by" call is an `IRenderGraph` method (12), except pass-local transients, which come from
the setup context of the pass that owns them. It declares the resource for the current
frame, and the id is valid until the graph's next `Reset`. Declaring creates no GPU object. A
persistent resource or history is looked up by name in the graph's registry, which keeps it and
its cross-frame states; the graph hands out a new id for it each frame.

- **Host-kept imports.** nvrhi restores a `keepInitialState` texture at `close()`, so the graph must
  never declare any other state for it. The compiler rejects tracked imports of such textures.
  - Barriers on a host-kept resource always go through the tracker (`setTextureState` plus
    `commitBarriers`), never through `barriers()`. That way nvrhi's restore at `close()` sees every
    state change.
- **Persistent resources** end each frame in whatever state their last access left them. A TAA
  history therefore costs one transition per frame, not three.
  - End states are recorded per subresource and keyed by registry id and physical resource, never by
    pointer. The legacy keyed them by pointer and needed a keep-alive against address reuse.
  - The hand-off into the next frame follows 6.12.
- **History.** `GetHistory(name, desc, layerCount, ids)` returns `layerCount` ids (2 to
  `c_MaxHistoryLayers`, which is 8), backed by as many physical textures. After RPS's temporal
  resources, it generalises the pair that TAA needs to the longer windows that temporal accumulation
  and denoisers use. `GetHistoryPair(name, desc, &current, &previous)` is an inline wrapper for the
  two-layer case.
  - **Layers.** `ids[0]` is the current frame's layer and the only one that may be written. `ids[k]`
    is the layer written *k* frames ago, and is read-only: a write to it is a validation error.
  - **Rotation.** Layer *k* of frame *f* is physical texture `(f - k) mod layerCount`. The plan stores
    every pointer, and the executor picks them by frame index: O(total history layers) per frame,
    with no recompile.
  - **Usage.** All of a history's textures are created with the union of the usage flags declared on
    any layer, so rotating never needs a different object.
  - **New allocations.** `IsNewAllocation(ids[k])` is true while layer *k* has not been written
    since the history was (re)allocated, that is, for the first *k* frames after it was first
    created or its description changed. For a pair this is the first frame only. It replaces TAA's
    `feedbackIsValid` and the exposure-buffer reset logic.
  - **States** are recorded per physical texture, so the rotation never confuses them.

### 5.3 Subresources and planes

An access names an `nvrhi::SubresourceRegion{baseMip, mipCount, baseSlice, sliceCount, planes}`,
where `planes` is a mask of {Color, Depth, Stencil}. The type is new in nvrhi (8.2), and the graph
and `TransitionBarrier` share it. `TextureSubresourceSet` is unchanged. For buffers the region is
ignored.

The graph tracks planes even though the nvrhi tracker does not. Lowering depends on the backend:
- D3D12: plane slice 0 for Color and Depth, 1 for Stencil.
- Vulkan: aspect masks `COLOR`, `DEPTH`, `STENCIL`.
- D3D11 and CUDA: planes are ignored.

This makes it legal, for example, to write stencil while sampling depth.

## 6. State transitions and overlap handling

The core of the design has three layers:

1. **An abstract access vocabulary** that passes declare.
2. **A backend state lattice** that decides which accesses can share one state.
3. **A per-subresource walk** that produces transitions with reasons, placement and flags.

### 6.1 Access vocabulary

```
Access (bit flags)
  reads : VertexBuffer IndexBuffer IndirectArgs ConstantBuffer ShaderRead UAVRead
          ColorTargetRead(blend) DepthRead StencilRead CopySource ResolveSource
          ShadingRateRead AccelStructRead AccelStructBuildInput Present HostRead
  writes: UAVWrite ColorTarget DepthWrite StencilWrite CopyDest ResolveDest
          AccelStructWrite
AccessFlags
  Clear          the pass initialises the range with a clear as its first operation
  FullWrite      the pass writes every element of the range (makes a discard-before legal)
  RelaxedOrder   consecutive relaxed UAVWrite accesses need no UAV barrier between them
  Preserve       never infer a discard for this access
ShaderStages     Vertex | Hull | Domain | Geometry | Pixel | Compute | RayTracing | Mesh | Amplification
```

When stages are omitted, they come from the pass type. Narrower stages give narrower sync scopes on
Vulkan and on D3D12 enhanced barriers.

`UAVRead` (UAV read-only) counts as a read for hazards. On D3D12, however, it cannot share a
state with ShaderRead, which is what 6.3 resolves.

### 6.2 Per-subresource state map

For each resource the compiler keeps an interval map over a linear index:

```
plane * (mips * slices) + mip * slices + slice
```

With this order a whole mip across all slices is one interval, which is the common case for mip
chains, bloom and Hi-Z. Each interval holds:

```
SubresourceRangeState
  lastWriter     pass index (or entry)                       -- RAW and WAW source
  readers        pass bitset since the last write            -- all are WAR sources
  readUnion      Access | ShaderStages of the current read epoch
  lowered        backend state currently held (from the lattice)
  queue          queue that last touched it
  pendingSplit   an open split-begin, if any
```

After each pass, adjacent intervals whose `SubresourceRangeState` is equal are coalesced.

**Overlapping ranges within one pass.** The declared ranges of one resource may overlap only in
these combinations:
- DepthRead with ShaderRead;
- UAVRead with UAVWrite;
- ColorTarget with ColorTargetRead.

Any other overlap is a compile error naming the pass and the range. Disjoint ranges in one pass are
always legal, for example reading mip N-1 while writing mip N.

### 6.3 Read epochs and the state lattice

A read epoch is the maximal run of scheduled passes that only read a given subresource between two
writes. Before choosing a state, the compiler looks ahead over the whole epoch:

1. **Collect** the accesses of every reader in the epoch.
2. **Combine** them through the backend lattice. `Combine(a, b)` returns either a single state that
   serves both, with a cost, or "incompatible".
3. **One state for all readers:** if a single state serves every reader, emit one transition before
   the first reader and none between readers.
4. **Otherwise:** partition the readers, in schedule order, into the fewest compatible groups, with
   one transition between consecutive groups. Each such transition must wait for every reader of the
   earlier group.
   - With `ScheduleFlags::GroupReads`, readers inside the epoch may also be reordered to bring
     compatible ones together.

| Readers in one epoch | D3D12 legacy | D3D12 enhanced | Vulkan |
| --- | --- | --- | --- |
| depth test (read-only) + compute sampling + pixel sampling | `DEPTH_READ \| PIXEL_SHADER_RESOURCE \| NON_PIXEL_SHADER_RESOURCE` | layout `DIRECT_QUEUE_GENERIC_READ` (direct queue only), access `DEPTH_STENCIL_READ \| SHADER_RESOURCE` | `DEPTH_STENCIL_READ_ONLY_OPTIMAL` |
| sampling + copy source | `*_SHADER_RESOURCE \| COPY_SOURCE` | layout `GENERIC_READ` | `GENERAL` (cost) or two groups, by `LatticePolicy` |
| sampling + UAVRead (texture) | incompatible: two groups | incompatible: two groups | `GENERAL` |
| vertex + index + indirect buffer | OR of the three | OR of accesses | OR of accesses |

*Corrected 2026-11-05 (P1.1), against the layout/access table of the enhanced-barrier specification
and the Agility SDK 1.619 debug layer.* `DEPTH_STENCIL_READ` admits only `DEPTH_STENCIL_READ` access,
and `UNORDERED_ACCESS` admits only `UNORDERED_ACCESS`. `DIRECT_QUEUE_GENERIC_READ` admits depth reads,
shader reads, copy and resolve sources and shading-rate reads together. No layout that is valid on
every queue admits a UAV access together with another access (`DIRECT_QUEUE_COMMON` and
`COMPUTE_QUEUE_COMMON` each serve one queue type), so nvrhi's D3D12 `barriers` refuses such a texture
state on both paths, and the lattice splits those readers. The direct-queue-only layout of the first row
gives the same three groups for async SSAO in 6.11 as the legacy path.

The first row is the case nvrhi handles worst today. A frame that renders depth, tests against it
and samples it costs four transitions per frame, and the combination asserts on the enhanced path.
Here it costs one.

**Enhanced-path rule.** The D3D12 enhanced lowering must always put the state's real access in
`AccessBefore`, never `NO_ACCESS` together with a defined layout. That defect was found on
2026-10-16 (debug-layer message #1331, device removed).

### 6.4 Placement and split barriers

Every transition has two placement points, and both are pass boundaries (each pass has a prologue
slot and an epilogue slot):
- **Begin point:** right after the last access it waits for.
- **End point:** right before the first access that needs the new state.

**Joined barrier.** The transition is a single barrier in the consumer's prologue when either:
- the begin and end points are adjacent, or
- the profile has no split support.

**Split barrier.** The transition is split when at least `SplitMinGap` passes (default 1) lie
between the begin and end points, on the same queue and in the same command-list segment. The begin
half goes in the producer's epilogue and the end half in the consumer's prologue.
- Typical cases:
  - GBuffer targets written in pass 2 and first read in pass 5.
  - Shadow maps rendered early and sampled late.
- Lowering per backend:

  | Backend | Split lowering |
  | --- | --- |
  | D3D12 legacy | `BEGIN_ONLY` / `END_ONLY` |
  | D3D12 enhanced | `SYNC_SPLIT` |
  | Vulkan | `vkCmdSetEvent2` / `vkCmdWaitEvents2`, with an event pool per command list, used only for layout transitions and large resources (profile policy, because events cost) |
  | D3D11 and CUDA | splits are dropped |
- A split never crosses a command-list boundary.

### 6.5 UAV ordering

Two consecutive accesses to the same subresource need a UAV barrier when they are:
- UAVWrite then UAVWrite, or
- UAVWrite then UAVRead.

No barrier is emitted if both accesses carry `RelaxedOrder`. Lowering:

| Backend | UAV barrier lowering |
| --- | --- |
| D3D12 | `ResourceBarrier::Uav` |
| Vulkan | a memory barrier from shader write to shader read/write |
| D3D11 | relaxed runs are wrapped in NVAPI UAV overlap |
| CUDA | no-op (same stream) |

Writes to disjoint subresources need no barrier.

### 6.6 Discard and initialisation

The compiler infers two flags per subresource:
- **discard-before:** the first access of a transient, or any access with no live data before it.
- **discard-after:** the last access of a transient.

It never infers them for imported or persistent resources, or for accesses marked `Preserve`.

A discard-before access must be a `FullWrite` or `Clear` write. Reading a transient before it is
written is a compile error.

| Backend | discard-before lowers to |
| --- | --- |
| D3D12 legacy | transition into the target state, then `DiscardResource` on the range (required for an aliased render target or depth buffer) |
| D3D12 enhanced | `LAYOUT_UNDEFINED` → target layout with `D3D12_TEXTURE_BARRIER_FLAG_DISCARD` |
| Vulkan | `oldLayout = UNDEFINED` |
| D3D11 / CUDA | nothing |

These are all expressed as a transition with `BarrierFlags::Discard` (8.2).

**D3D12 rules.**
- `DiscardResource` requires the range to be in `RENDER_TARGET` (colour), `DEPTH_WRITE` (depth
  and stencil) or `UNORDERED_ACCESS`. The lowering transitions the range there first.
- A placed resource created with `ALLOW_RENDER_TARGET` or `ALLOW_DEPTH_STENCIL` must be initialised
  before *any* use, UAV or SRV use included. Initialisation means a discard, a clear or a full copy.
  So the creation flags decide whether to initialise, not the first access. The legacy skipped this
  for resources whose first use was a UAV, which left UAV+RT textures uninitialised.

### 6.7 Aliasing

For each placed transient, the compiler finds earlier placements in the same heap that overlap it in
bytes and whose lifetimes have ended. At the new resource's first use it emits:

1. `ResourceBarrier::Aliasing(before, after)`, where `before` is `nullptr` when several resources are
   overlapped;
2. the discard-before initialisation from 6.6.

Lowering:
- **D3D12:** an aliasing barrier.
- **Vulkan:** a memory dependency from the old resources' last stages to the new resource's first
  stage, combined with `oldLayout = UNDEFINED`.

Because nvrhi binds memory once, each alias is its own virtual nvrhi resource, bound when the plan is
instantiated and kept while the plan's hash is unchanged.

**Rules.**
- **The first scope is never empty.** It covers every stage and access that any outgoing resource
  used. A `Common` or `UNDEFINED` transition on its own waits for nothing.
  - D3D12 legacy: the aliasing barrier is a full barrier.
  - D3D12 enhanced: each outgoing resource gets a barrier from its last sync and access to
    `NO_ACCESS`. The incoming texture then goes from `LAYOUT_UNDEFINED` with `DISCARD`. Step 1
    checks this form against the enhanced-barriers specification and the debug layer.
  - Vulkan: a memory barrier from the union of the outgoing stages and accesses.
- **Tracker reset.** In Tracked and Restore passes (9.1), the tracker forgets the outgoing
  resource's state and permanent flag. It starts the incoming resource from its post-alias state.
- **No `keepInitialState` on aliased resources.** The compiler never places such a resource.
- **Across frames.** The first occupant of a range also aliases against the previous frame's last
  occupant (6.12).
- **Validation.** The nvrhi validation layer checks that the two resources really overlap in one
  heap, using `IResource::queryHeapBinding` (8.1).

### 6.8 Queues

**No queue object.** Async compute uses what the RHI already has: an `ICommandList` created with
`queueType = CommandQueue::Compute` carries the compute queue's work and is submitted to that queue.
On CUDA each `CommandQueue` is a `CUstream`, so a compute command list is replayed onto the compute
stream.

**Declaring async passes.** Async-compute passes are declared, never inferred. A pass with
`PassFlags::AsyncCompute` runs on the compute queue when the profile has one. Otherwise it is demoted
to graphics, with a diagnostic.

**Cross-queue synchronisation** uses the timeline `IFence` of 8.3, one fence per queue, owned by the
registry:
- the producer segment's submit signals `(fence[q], ++value[q])`;
- the consumer segment's submit waits for that value;
- a consumer that depends on several producer segments of one queue waits only for the highest value,
  so transitive reduction falls out of the timeline;
- waits and signals ride on `IDevice::submit` (8.3), so they cost no extra submissions.

**Queue legality.** A state or stage is legal on a queue only if that queue can hold it and
synchronise on it. The profile holds this table:

| Queue | Illegal states (D3D12) | Illegal stages (Vulkan, from the queue family's capabilities) |
| --- | --- | --- |
| Compute | RenderTarget, DepthWrite, DepthRead, PixelShaderResource, IndexBuffer, VertexBuffer, StreamOut, ResolveSource, ResolveDest, ShadingRateSource | every graphics stage: vertex input, the vertex, tessellation, geometry, mesh and task shaders, the fragment shader, early and late fragment tests, colour attachment output |
| Copy | every state except Common, CopySource and CopyDest | every stage except transfer |

**Transitions are placed on a queue that can perform them.**
- Legality is checked on the queue that executes each half of a barrier, for states and for stages.
  On Vulkan a release or acquire half names only the stages of its own queue.
- A transition that the consumer's queue cannot perform moves to the graphics-queue epilogue of
  the producer, or to the prologue of the next graphics-queue consumer.
- The lattice is queried per queue. An epoch with readers on both queues gets a state that both
  queues can hold. When no such state exists, the epoch is split into groups (6.3), as in 6.11.
- `LatticePolicy` weighs the extra barriers of a split against the overlap that async compute
  gains. When the barriers cost more, it demotes the pass to the graphics queue, with a
  diagnostic.

**Vulkan ownership.** A resource crossing queue families is released in the producer's epilogue and
acquired in the consumer's prologue, using transitions with `QueueRelease` and `QueueAcquire`
(8.2). The layout change is folded into the pair. Graph resources stay `EXCLUSIVE`. When the two
queues share a family, no transfer is emitted.
- The legacy never ran this path: it made cross-queue images `CONCURRENT` instead. Step 6 measures
  ownership transfers under sync validation. If they fail or cost more than they save, the
  profile's fallback is `CONCURRENT` sharing for the resources the plan marks cross-queue, which
  means nvrhi gains a queue-family list on `TextureDesc`/`BufferDesc` again.

**Queued waits.** A wait that nvrhi queues on a queue (the Vulkan swap-chain acquire, and the Vulkan
side of `IInteropDevice::graphicsQueueWaitForComputeQueue`) is attached to whatever submission comes
next on that queue. The legacy hit this trap with `queueWaitForCommandList`. The rules:
- **The back buffer is used only on the graphics queue.** Only graphics-queue work is ordered after
  the acquire. A pass that touches the back buffer and is marked `AsyncCompute` is a compile error,
  not a silent demotion: it can never run asynchronously on any profile, so the flag is a
  declaration mistake.
- **The graph's first graphics submission carries the queued waits.** The executor submits nothing
  on the graphics queue between `beginFrame` (or an interop wait) and its first segment. A queued
  wait also orders every later submission on its queue, so this is not about correctness: a wait
  that lands on unrelated work stalls that work until the image is acquired, and it hides the wait
  from the plan's statistics. Plan fence waits go on the same `submit` (8.3).
- **Interop hand-overs are graph boundaries.** A resource that comes from another device is
  imported (14.5). The application issues the interop wait before `Execute`, and the import's
  first-use prologue assumes it has happened.

**CUDA.** Cross-stream waits go through the same `IFence`. There are no transitions. Each
`CommandQueue` is one non-blocking stream, and work is ordered only by stream submission and
events, so the plan's fence values are the only cross-queue order (2.1). A CUDA `submit` replays
recorded lists, so its waits and signals are enqueued around the replay on the queue's stream.

### 6.9 Render targets

nvrhi has no load/store ops yet. The plan still records, per raster pass and attachment:
- **load:** `Clear`, `DontCare` (from discard-before) or `Load`;
- **store:** `DontCare` (from discard-after) or `Store`.

**Clears are accesses.** A `Clear` access gets its own slot between the prologue and the body:
1. the prologue moves the range into the clear state;
2. the executor records `clearTextureFloat`, `clearDepthStencilTexture` or `clearTextureUInt`;
3. a post-clear batch moves the range into the pass's state.

The profile supplies the clear state:

| Backend | Clear state |
| --- | --- |
| D3D12 | RenderTarget, DepthWrite or UnorderedAccess, depending on the view the clear uses. Usually this equals the pass's state, so step 3 is empty |
| Vulkan | `TRANSFER_DST_OPTIMAL`, because `vkCmdClear*Image` requires it |
| D3D11 and CUDA | none |

CUDA has no depth clears, so a depth `Clear` on CUDA is a compile error (7.1).

When nvrhi gains a render-pass object (the name `nvrhi::IRenderPass` is kept free for it, 3.3),
clears move into the render pass's load op and the clear slot disappears. Pass code does not change.

Merging consecutive raster passes is out of scope for now. The plan records why each adjacent pair
could not merge.

### 6.10 Barrier batching

All barriers with the same end point form one batch per (queue, slot). A batch is a contiguous
`ResourceBarrier` array in the plan, emitted with one `barriers()` call.

- **Range merging.** Regions are merged only when they are exactly equal or adjacent, with equal
  plane masks, never into a bounding box. A region that covers the whole resource becomes the
  default (whole) region.
- **Order within a batch.** Aliasing barriers first, then transitions (discards included), then UAV
  barriers.
- **Vulkan.** Batches sit only at pass boundaries, so the rule that a barrier ends dynamic rendering
  never splits a pass.

### 6.11 Worked example: deferred frame

| # | Pass | Queue | Accesses |
| --- | --- | --- | --- |
| 1 | DepthPrepass | graphics | Depth W |
| 2 | GBuffer | graphics | Depth R (test), GB0-3 W, MV W |
| 3 | SSAO | compute (async) | Depth R (sample), Normals R, AO W |
| 4 | Shadow | graphics | ShadowMap W |
| 5 | DeferredLighting | graphics | Depth, GB, AO, ShadowMap R; HDR W |
| 6 | Forward transparent | graphics | Depth R (test), HDR W (blend) |
| 7 | TAA | graphics | HDR R, MV R, History.prev R, History.cur W |
| 8 | ToneMap | graphics | History.cur R, Backbuffer W |

**Depth.** After the write in pass 1, depth has a read epoch spanning passes 2, 3, 5 and 6.
- **Without async compute** (SSAO on the graphics queue), the lattice finds one state for all four
  readers:
  - D3D12: `DEPTH_READ | PIXEL_SHADER_RESOURCE | NON_PIXEL_SHADER_RESOURCE`;
  - Vulkan: `DEPTH_STENCIL_READ_ONLY_OPTIMAL`.

  That is one barrier per frame, against four in today's hand-written sample.
- **With async SSAO on D3D12**, no single state is legal on both queues, because the compute queue
  cannot hold `DEPTH_READ` (6.8). The epoch splits into three groups. Every transition runs on the
  graphics queue:
  1. pass 1 epilogue: `DEPTH_WRITE → DEPTH_READ`, for pass 2;
  2. pass 2 epilogue, before the signal that pass 3 waits on: `DEPTH_READ →
     NON_PIXEL_SHADER_RESOURCE`, for passes 3 and 5;
  3. pass 6 prologue: `NON_PIXEL_SHADER_RESOURCE → DEPTH_READ`. Pass 5 already waits for SSAO's
     signal, because it reads AO, so this transition cannot overtake the compute read.
- **With async SSAO on Vulkan**, layouts are not queue-restricted, so one layout barrier remains:
  `DEPTH_ATTACHMENT → DEPTH_STENCIL_READ_ONLY`.
  - If the compute queue is in another family, two ownership pairs follow: graphics → compute
    around pass 3, and compute → graphics before pass 5.
  - Each half names only its own queue's stages.
- `LatticePolicy` decides whether async SSAO still pays on D3D12 after the two extra barriers (6.8).

**GB0-3.** Split: begun in pass 2's epilogue, ended in pass 5's prologue.

**AO.** It is used on both queues, so it is neither aliased nor reused within the frame (7.4).

**History.** A persistent pair, with no restore transition.

**Backbuffer.** A host-kept import.

### 6.12 Frame boundary

A plan is compiled on the assumption that the previous frame ran the same plan. The compiler treats
the last accesses of frame N as predecessors of the first accesses of frame N+1, for three hazards:

1. **Aliasing across frames.** For each heap range, the first occupant in frame N+1 gets an
   aliasing barrier (6.7) against the last occupant in frame N, when they are different resources.
   When they are the same transient, its discard-before initialisation is enough.
2. **Write-after-read across queues and frames.** A resource or memory range might be last used on
   queue A in frame N and first used on queue B in frame N+1. Then the first segment on B that
   touches it waits for A's last signal of frame N. The wait rides on `submit` (8.3), and fence
   values reduce it to one wait per other queue. Without this wait, the legacy got "in-flight on
   another queue" from the D3D12 debug layer.
3. **State hand-off at the wrap.** A persistent resource ends frame N in its last-use state on
   queue A. Suppose frame N+1's first access is on queue B.
   - The hand-off transition is placed where both the old and the new state are legal (6.8),
     normally at the end of frame N on queue A.
   - With different Vulkan families, it includes a release on A and an acquire on B.
   - If no queue can perform it, the compile fails, naming the resource and both passes.
   - Without this check the legacy got 10 validation errors per 120 frames, from a fragment-stage
     `srcStageMask` on the compute queue.

**When the plan changes between frames** (a cache miss, or a switch to another cached plan), the
registry keeps the previous plan's last occupants, queues and states. It patches the new plan's
first prologue batches and waits for that one frame.
- Plans that share a memory plan (7.7) share heaps, so their donors are known in advance.
- Plans with different heaps alias nothing across the switch.

The verifier (11.1) replays two consecutive frames, and a switch between two plans, to check all
of this.

## 7. Compiler pipeline

Every phase is device-free and data-oriented (10.1).

**Phases are a list, internally.** The compiler is an ordered list of phase objects over one shared
compile state, not one function. The phases below are the standard list. Diagnostics and debug aids
are phases inserted into it, not special cases inside the others:
- the verifier (11.1), after phase 6, on a miss or always under `StrictValidation`;
- the JSON and Graphviz dumps (11.3);
- the debug switches that rewrite a plan, such as `BarrierAfterEveryPass` and `SerializeQueues`
  (11.4).

`CompileOptions::debugFlags` chooses the list, so a debug build pays for no phase it doesn't run.
RPS exposes this list to applications (`RpsRenderGraphPhaseInfo`). We do not: a public phase
interface would freeze the compile state into the ABI. The list stays inside
`src/render/RenderGraphCompiler.cpp`.

The standard phases run in this order:

1. **Validate.** Rejects:
   - stale versions and invalid ids, including ids kept from an earlier frame (5.1);
   - use of an `ISetupContext` after its `Setup` returned (12);
   - a pass-local transient named by any pass other than the one that created it (5.2);
   - a write to a history layer other than the current one, `ids[0]` (5.2);
   - texture-only accesses on buffers;
   - conflicting overlaps within a pass;
   - transient reads before any write;
   - tracked imports of `keepInitialState` textures;
   - pass types the profile lacks (Raster on CUDA);
   - flags that conflict with an access (UAVWrite needs `isUAV`; on CUDA a UAVWrite texture
     needs an uncompressed format, and 3-component and depth-stencil formats are rejected, 2.1);
   - a state or stage that is illegal on its pass's queue (6.8), and depth clears on CUDA (6.9);
   - a back-buffer access in an `AsyncCompute` pass (6.8);
   - `keepInitialState` on a resource that may be aliased (6.7);
   - two passes of one exclusion group enabled together, and disabled-output policies whose
     substitute or passthrough input does not match the output (13.5).
2. **Cull.** Reference counts run from:
   - `NeverCull` and `SideEffect` passes;
   - writes to imported, persistent or extracted resources;
   - Present.

   Disabled passes (13.5) are removed first, and their outputs follow their policies.
3. **Schedule.**
   - Program order is the default.
   - Async passes are assigned to the compute queue.
   - `GroupReads` is optional.
   - RPS-style heuristics are left as future flags.
   - **Anti-dependencies are explicit edges.** Whenever the scheduler moves a pass (`GroupReads`,
     async placement), a write of version v+1 may not move before any reader of version v. The legacy
     kept explicit write-after-read edges for this; program order hides the need until passes move.
4. **Lifetimes.** Each resource gets [first use, last use].
   - Resources used on more than one queue are never aliased and never reused within the frame, so
     their lifetimes need no widening. They may still be pooled across frames.
   - Resources used only by passes of one exclusion group (13.5) may share memory with each other.
     The queue rule is checked first: a cross-queue resource shares nothing, even inside an
     exclusion group. The legacy's `canReuse` tested the group before the queue mask.
5. **Memory plan.** Tiers:
   - **Placed** (D3D12; Vulkan once `createHeap` honours `memoryTypeBits`):
     - heaps are kept per queue and per heap class (on D3D12 tier 1, render-target/depth textures,
       other textures and buffers). A test asserts the heap count, because the legacy documented one
       heap per queue and created one heap in total;
     - resources are sorted by size descending and placed first-fit in a (byte range × lifetime)
       plane;
     - cross-queue resources are not aliased.
   - **Pooled** (D3D11, CUDA, and Vulkan until then): whole-resource reuse keyed by description, with
     frame-age eviction. CUDA has no heaps (`createHeap` is `FE_UNSUPPORTED`), so it stays here
     until the backend gains virtual memory (`cuMemCreate`/`cuMemMap`).
   - **Dedicated:** the `ForceDedicated` debug switch (11.4).
   - **Choice.**
     - Placed is opt-in per registry (`CompileOptions::placedResources`).
     - It is probed at startup (heap tier, and whether `memoryTypeBits` is honoured), and falls back
       to Pooled with a warning.
     - Every plan computes a placement estimate, on every backend, so the saving can be reported
       before Placed is enabled.
   - **Pool key.**
     - In the key: the description fields that change the created object (dimension, size, format,
       mips, slices, sample count, usage flags, clear value, queue mask).
     - Not in the key: `debugName`, `initialState`, `keepInitialState`.
   - **Determinism.** Ties break by declaration index. The same graph therefore gets the same
     physical resources every frame, and binding caches keep hitting.
   - **Per-resource flags.**
     - `ResourceFlags::NoAlias` keeps a resource out of placement.
     - `ResourceFlags::DebugCapture` keeps it dedicated, so a capture tool sees one stable object.
   - **Heap retirement.** The heaps and placed resources of an evicted plan are retired through the
     fence values of the last frame that used them. Barrier arrays hold raw pointers, so the
     registry, not the command lists, holds the references until then.
   - **Statistics** exclude imports and histories. The legacy once counted imports and reported a
     false 1.11× saving.
6. **Transitions.** The walk of section 6. The output is `ResourceBarrier` batches attached to pass
   slots, each with a parallel array of reasons (11.3).
7. **Segments and caching.**
   - Segments split at queue changes and cross-queue waits, and at `RecordGranularity` when
     parallel recording is on.
   - The structural hash covers passes, accesses, descriptions and import entry/exit states, but not
     the imported objects or the passes' per-use data. It is accumulated incrementally while the
     graph is recorded.
   - On a plan-cache hit, phases 1-7 are skipped. Only the import slots are patched: O(number of
     imports).
   - **The pass-enable mask is not in the structural hash** (13.5). A plan is compiled for the superset
     of its passes.
     - Its memory plan serves every mask.
     - Its barrier schedule is cached per mask, as a partial compile of phases 2, 6 and 7.
     - So toggling a pass never reallocates.
   - **The cache is bounded** (`CompileOptions::maxCachedPlans`, default 8, least recently used).
     Plans with the same memory-plan hash share heaps.
   - **The cache must pay for itself.** Filament compiles every frame and is fast enough, while the
     cache adds import patching, per-mask schedules and eviction. `maxCachedPlans = 0` is the
     no-cache baseline: every frame runs phases 1-7. The registry still keeps its pools and heaps,
     so the baseline measures CPU cost, not GPU object churn.
     - `rdg_bench` and the samples report the frame cost both ways (10.3).
     - If the no-cache frame also meets the cache-hit budget on the step-5 samples, the cache is
       reviewed for removal before step 6. The per-mask schedules of 13.5 would then become
       recompiles.

## 8. RHI changes (ethereal-nvrhi, `ethereal-dev` → `rdg`)

These changes extend existing interfaces in place and add new types; no existing struct changes.
That is nvrhi's standing version policy (2.1): the header version stays at 28 and there is no
separate barrier interface. Section 8.4 lists what the changes touch.

### 8.1 `IResource`: a common base for resources

```cpp
struct HeapBinding { IHeap* heap = nullptr; uint64_t offset = 0; uint64_t size = 0; };

NVRHI_IID(IResource, "<new uuid>")
struct IResource : IRHIObject
{
    NVRHI_DECLARE_UUID_TRAITS(IResource)
    // Virtual (placed) resources: the heap and byte range they are bound to.
    // FE_NOT_FOUND for committed resources, and before the resource is bound.
    virtual FRESULT queryHeapBinding(HeapBinding& binding) const noexcept = 0;
};

struct IBuffer : IResource { ... };                 // was : IRHIObject
struct ITexture : IResource { ... };
struct IStagingTexture : IResource { ... };
struct ISamplerFeedbackTexture : IResource { ... };
namespace rt { struct IAccelStruct : IResource { ... }; struct IOpacityMicromap : IResource { ... }; }
```

The model is D3D12's `ID3D12Resource`: barriers name an `IResource*`, and the derived interface is
reached with `QueryInterface`. `IResource` carries no type tag. Every resource class adds
`NVRHI_IMPLEMENTS_INTERFACE(IResource)` to its explicit QI table (nvrhi ADR 0007). Existing calls
that take `ITexture*` or `IBuffer*` are unchanged.

**Type dispatch in `barriers()`.** A backend tests each barrier's resource with
`QueryInterface(uuid_of<ITexture>(), nullptr)`, then `uuid_of<IBuffer>()`, then the rare kinds, and
casts with `checked_cast`. A null `ppv` only reports support (nvrhi ADR 0006): no pointer is
returned and no reference is added, so the hot path does no atomic reference-count traffic.
- The cost is one virtual call and a short walk of the class's interface table per barrier.
  Textures are tested first because they are most barriers.
- Step 1 measures it against the executor budget (10.3, 15).
- The validation layer resolves its wrappers the same way, by QI on the wrapper and then
  `unwrapResource`.

**Heap bindings.** `queryHeapBinding` is the legacy branches' `ITexture1/IBuffer1::queryHeapBinding`,
moved to the base. It lets the validation layer check that an aliasing barrier's resources overlap in
one heap (8.2), and lets tests assert placements. On CUDA and D3D11, which have no heaps, it always
returns `FE_NOT_FOUND`.

**CUDA and interop resources.** The CUDA backend's buffers and textures, including those that
`IInteropDevice::importBuffer`/`importTexture` create, implement `IResource` like any other. An
imported CUDA texture is a different object from its graphics texture, on a different device, so a
graph only ever sees one of the two (14.5).

**Binding results.** Vulkan `bindImageMemory` and `bindBufferMemory` check the `VkResult` and
return `false` on failure (2.1).

### 8.2 `ResourceBarrier` and `ICommandList::barriers`

```cpp
enum class PlaneMask : uint8_t { Color = 1, Depth = 2, Stencil = 4, All = 7 };

// The region of a texture that a barrier (or a render-graph access) names. ~0u counts mean
// "to the end". Ignored for buffers. Separate from TextureSubresourceSet, which views keep using.
struct SubresourceRegion {
    uint32_t  baseMip = 0, mipCount = ~0u, baseSlice = 0, sliceCount = ~0u;
    PlaneMask planes = PlaneMask::All;
};

enum class BarrierType : uint8_t { Transition, Uav, Aliasing };

enum class BarrierFlags : uint8_t {
    None = 0,
    SplitBegin   = 1 << 0,   // begin half; tracker is updated at the matching SplitEnd
    SplitEnd     = 1 << 1,
    Discard      = 1 << 2,   // contents before are undefined (UNDEFINED / DISCARD / DiscardResource)
    QueueRelease = 1 << 3,   // ownership release to otherQueue (Vulkan family transfer)
    QueueAcquire = 1 << 4,   // ownership acquire from otherQueue
};

struct TransitionBarrier {
    IResource*            resource;
    SubresourceRegion     region;         // ignored for buffers
    ResourceStates        before;         // combined read states are legal
    ResourceStates        after;
    ShaderType            stagesBefore;   // narrows the sync scope; None = derive from state
    ShaderType            stagesAfter;
    CommandQueue          otherQueue;     // QueueRelease / QueueAcquire only
};
struct UavBarrier      { IResource* resource; };                  // nullptr = all UAV accesses
struct AliasingBarrier { IResource* before; IResource* after; };  // before may be nullptr

struct ResourceBarrier {
    BarrierType  type = BarrierType::Uav;
    BarrierFlags flags = BarrierFlags::None;
    union {
        TransitionBarrier transition;
        UavBarrier        uav;
        AliasingBarrier   aliasing;
    };

    // SubresourceRegion has default member initialisers, so the union needs a constructor.
    ResourceBarrier() noexcept : uav{ nullptr } { }

    // Helpers in the CD3DX12_RESOURCE_BARRIER style
    static ResourceBarrier Transition(IResource* resource, ResourceStates before, ResourceStates after,
                                      const SubresourceRegion& region = {},
                                      BarrierFlags flags = BarrierFlags::None) noexcept;
    static ResourceBarrier Uav(IResource* resource) noexcept;
    static ResourceBarrier Aliasing(IResource* before, IResource* after) noexcept;
};

struct ICommandList : IRHIObject {
    ...
    // Records exactly these barriers, in order. Pending tracker barriers are committed first.
    // For resources tracked in this command list, the tracker is set to each `after`
    // (at SplitEnd for split pairs); untracked resources are not added to the tracker.
    virtual FRESULT barriers(const ResourceBarrier* barriers, uint32_t count) noexcept = 0;

    // Validation aid. While a scope is open (`owner` != nullptr), the validation layer reports
    // every barrier-changing call as an error naming `owner`: barriers, setTextureState,
    // setBufferState, setPermanent*State, beginTracking*State, commitBarriers,
    // setEnableAutomaticBarriers(true) and setEnableUavBarriersFor*(..., true). nullptr closes the
    // scope. The backends implement it as a no-op.
    virtual void setExplicitBarrierScope(const char* owner) noexcept = 0;
};
```

**Explicit-barrier scopes.** These close gap 2 of the Unity comparison (14.10). Unity's restricted
`RasterCommandBuffer` stops a pass body from changing render-target state. In the same way, the
graph's executor opens a scope around every Native body (9.1), so a body cannot silently move a
resource away from the state the plan's next barrier expects. The check lives in the validation layer,
which already keeps per-command-list state, so a release build pays one empty virtual call per pass.

The helper definitions and the layout assertions live in a new source file,
`src/common/resource-barrier.cpp`, not in the header. The assertions cover
`std::is_trivially_copyable_v<ResourceBarrier>` and the sizes and member offsets. Plans copy barrier
arrays with `memcpy`, and the user-provided default constructor does not affect trivial copyability.

**Validation** (the validation layer): it rejects a barrier when:
- `before` disagrees with the tracked state;
- a split pair is unmatched within the command list;
- a `QueueRelease` has no matching `QueueAcquire` within the submission graph;
- a barrier names a `keepInitialState` resource, whose barriers go through the tracker (5.2);
- an aliasing barrier's `before` and `after` do not overlap in bytes within one heap
  (`queryHeapBinding`, 8.1);
- a transition with a plane mask other than `All` names a resource that the command list tracks,
  because the tracker works per mip × slice and cannot represent planes. Native graph passes never
  track resources, so they are unaffected;
- a barrier-changing call is made while an explicit-barrier scope is open.

**Per backend:**

| Backend | Behaviour |
| --- | --- |
| D3D12 legacy | one `ResourceBarrier` call per batch, with `BEGIN_ONLY` and `END_ONLY` splits, per-plane subresource indices, `DiscardResource` after a discard transition, and aliasing barriers |
| D3D12 enhanced | one `Barrier` call with texture, buffer and global groups. Combined read layouts are mapped (this fixes the ShaderResource\|DepthRead assert), and `AccessBefore` always carries the real access |
| Vulkan | one `vkCmdPipelineBarrier2`, using events for splits and aspect masks for planes. Real queue-family indices are used for release/acquire, and like `commitBarriers` it ends dynamic rendering |
| D3D11 | validation, then a no-op. UAV barriers inside relaxed runs map to NVAPI overlap |
| CUDA | validation, then a no-op: nothing is recorded into the deferred list, because one stream executes in order |

**Feature queries.** New `Feature` values `SplitBarriers`, `AliasingBarriers` and
`QueueOwnershipTransfer` let the profile tell which flags have native effect. On backends where a
flag has none, the call still succeeds.

### 8.3 Cross-queue synchronisation: `IFence` and `IDevice::submit`

**The primitive is a timeline fence, not an event.**

- **Timeline values compose.** A monotonically increasing value composes under transitive reduction:
  wait for the maximum value.
- **One fence serves two jobs.** The same fence that orders queues also retires frames, which
  replaces `IEventQuery` polling in the registry.
- **It maps to every backend.** D3D12, Vulkan 1.2 and D3D11.4 all have timeline fences.
- **Binary events do not fit.**
  - D3D12 has no GPU event object.
  - A `VkEvent` cannot synchronise across queues.
  - Resettable objects need reuse bookkeeping and invite reset races.
- **No name clash.** The name `IFence` avoids confusion with `IEventQuery` and with the `VkEvent`s
  that split barriers use internally.

```cpp
static constexpr uint64_t c_InfiniteTimeout = ~0ull;

struct FenceDesc {
    uint64_t initialValue = 0;
    bool     shared = false;            // exportable through the interop device
    string   debugName;
};

NVRHI_IID(IFence, "<new uuid>")
struct IFence : IRHIObject {
    NVRHI_DECLARE_UUID_TRAITS(IFence)
    [[nodiscard]] virtual const FenceDesc& getDesc() const noexcept = 0;
    // The highest value the fence has reached. Never blocks.
    [[nodiscard]] virtual uint64_t getCompletedValue() noexcept = 0;
    // CPU wait: blocks the calling thread until getCompletedValue() >= value (8.3.1).
    virtual FRESULT wait(uint64_t value, uint64_t timeoutNs = c_InfiniteTimeout) noexcept = 0;
    // CPU signal: sets the fence to value from the host.
    virtual FRESULT signal(uint64_t value) noexcept = 0;
};

struct FenceValue { IFence* fence; uint64_t value; };

struct SubmitDesc {
    ICommandList* const* commandLists = nullptr; uint32_t numCommandLists = 0;
    CommandQueue         queue = CommandQueue::Graphics;
    const FenceValue*    waits = nullptr;   uint32_t numWaits = 0;     // GPU waits before the lists start
    const FenceValue*    signals = nullptr; uint32_t numSignals = 0;   // GPU signals after the lists complete
};

struct IDevice : IRHIObject {
    ...
    virtual FRESULT  createFence(const FenceDesc& desc, IFence** fence) noexcept = 0;
    virtual uint64_t submit(const SubmitDesc& desc) noexcept = 0;   // returns the instance, as executeCommandLists
    virtual FRESULT  queueWaitFence(CommandQueue queue, IFence* fence, uint64_t value) noexcept = 0;
    virtual FRESULT  queueSignalFence(CommandQueue queue, IFence* fence, uint64_t value) noexcept = 0;
    // CPU wait on several fences: all of them (waitAll) or any one of them.
    virtual FRESULT  waitFences(const FenceValue* fences, uint32_t count, bool waitAll,
                                uint64_t timeoutNs = c_InfiniteTimeout) noexcept = 0;
};
```

`submit` is the hot path: one native submission carries its waits and signals. The standalone
`queueWaitFence` and `queueSignalFence` are GPU-side operations for interop and tools. They are
ordered with submissions to the same queue.
- **They are immediate, not queued.** Unlike Vulkan's `queueWaitForSemaphore` (2.1), a standalone
  wait is its own submission (an empty `vkQueueSubmit2` on Vulkan), so it never attaches to someone
  else's work (6.8).
- `executeCommandLists` and `queueWaitForCommandList` remain and are implemented on the same
  machinery. So do `vulkan::IDevice::queueWaitForSemaphore`/`queueSignalSemaphore`, which the swap
  chain uses.

| Backend | `IFence` | `submit` waits and signals |
| --- | --- | --- |
| D3D12 | `ID3D12Fence` | `queue->Wait` → `ExecuteCommandLists` → `queue->Signal` |
| Vulkan | timeline `VkSemaphore` | `VkSubmitInfo2` wait and signal infos, in one `vkQueueSubmit2`. A standalone signal is an empty submit |
| D3D11 | `ID3D11Fence` (`ID3D11Device5::CreateFence`); `FE_UNSUPPORTED` before D3D11.4 | `ID3D11DeviceContext4::Wait`/`Signal`. There is one queue, so waits are trivially satisfied |
| CUDA | host-side ring of (value, pooled `CUevent`) per fence. A shared fence is a CUDA external semaphore with true timeline values, the mechanism `IInteropDevice` already uses (2.1) | signal: `cuEventRecord` on the queue's stream after the replay, then append. Wait: `cuStreamWaitEvent` before the replay, on the earliest recorded event whose value ≥ the target. A GPU wait must be enqueued after its signal (host submission order); otherwise `FE_INVALID_ARGS`. The graph always submits producers first |

On D3D11 before 11.4, `createFence` returns `FE_UNSUPPORTED`. There the registry retires frames with
one `IEventQuery` per frame. D3D11 has one queue, so no cross-queue wait is needed (9.1).

#### 8.3.1 CPU wait and signal semantics

`IFence::wait(value, timeoutNs)` waits for "at least", never "exactly": it returns once
`getCompletedValue() >= value`.

| Call | Behaviour | Returns |
| --- | --- | --- |
| any call where the value is already reached | returns at once, without a kernel call | `FS_OK` |
| `wait(v, 0)` | polls and never blocks | `FS_OK` or `FE_WAIT_TIMEOUT` |
| `wait(v, n)`, n finite | blocks for at most n nanoseconds | `FS_OK` or `FE_WAIT_TIMEOUT` |
| `wait(v)` or `wait(v, c_InfiniteTimeout)` | blocks until the value is reached, with no time limit | `FS_OK`; never `FE_WAIT_TIMEOUT` |
| device lost during any wait | the wait ends instead of blocking forever | `FE_GENERIC_ERROR`, and the device reports the loss through its message callback |

Rules:
- **Unreachable values.** An infinite wait for a value that nothing will ever signal blocks forever,
  as it does on every native API. To catch this, the validation layer reports a wait for a value
  above every signal that has been submitted or set from the host, before it blocks.
- **Threads.** `wait`, `getCompletedValue` and `waitFences` may be called from any thread,
  concurrently.
- **CPU signals** must increase the value. `signal(v)` with `v` not above the current value returns
  `FE_INVALID_ARGS`.
- **`waitFences`** follows the same table. With `waitAll = false` it returns when any one fence
  reaches its value.

Usage:

```cpp
// Frame retirement: block until the GPU has finished frame N-2 on the graphics queue.
const uint64_t target = frameFenceValues[(frameIndex - 2) % c_FramesInFlight];
if (graphicsFence->getCompletedValue() < target)
    NVRHI_CHECK(graphicsFence->wait(target));               // infinite timeout

// Non-blocking check, for example before reusing a pooled resource.
const bool done = graphicsFence->wait(target, 0) == nvrhi::FS_OK;

// Both queues, at most 100 ms.
const nvrhi::FenceValue values[] = { { graphicsFence, gfxTarget }, { computeFence, computeTarget } };
const nvrhi::FRESULT result = device->waitFences(values, 2, /*waitAll*/ true, 100'000'000);
```

CPU wait per backend:

| Backend | Infinite wait | Finite wait | `waitFences` |
| --- | --- | --- | --- |
| D3D12 | `SetEventOnCompletion` + `WaitForSingleObject(INFINITE)` | the same with a millisecond timeout, rounded up | `ID3D12Device1::SetEventOnMultipleFenceCompletion` (all or any) |
| Vulkan | `vkWaitSemaphores(UINT64_MAX)` | `vkWaitSemaphores(timeoutNs)` | `vkWaitSemaphores`, with `VK_SEMAPHORE_WAIT_ANY_BIT` for any |
| D3D11 | `ID3D11Fence::SetEventOnCompletion` + `WaitForSingleObject` | the same with a timeout | one event per fence + `WaitForMultipleObjects` |
| CUDA | wait (on a condition variable) until a signal ≥ value is recorded, then `cuEventSynchronize` | `cuEventQuery` with back-off until the deadline | per fence, in turn (all), or polling (any) |

**CPU signal per backend.** D3D12 uses `ID3D12Fence::Signal`, Vulkan `vkSignalSemaphore` and D3D11
`ID3D11Fence::Signal`. On CUDA the ring records a host-completed entry. A GPU wait that only a later
CPU signal can satisfy is rejected with `FE_INVALID_ARGS`, under the same ordering rule as GPU
signals.

CUDA stream memory operations (`cuStreamWriteValue64` and `cuStreamWaitValue64` with
`CU_STREAM_WAIT_VALUE_GEQ`) would give true timeline semantics and lift that ordering rule. Whether
the target Windows drivers support them is checked in step 1. Until then, the event ring is the
design.

**Interop.** `IInteropDevice` keeps its two queue-wait calls; they need no fence object from the
caller. Internally they use a shared `ID3D12Fence` or an exportable timeline semaphore on the
graphics side and an external semaphore on the CUDA side (2.1), which is exactly a `shared = true`
`IFence`. Rebuilding those calls on `IFence`, and adding a call that hands the shared fence to a
graph so the hand-over wait rides on the graph's `submit` (6.8), is a follow-up.

### 8.4 ABI consequences

The header version stays at 28, as nvrhi's §3.4 now prescribes, so `verifyHeaderVersion` cannot
detect a mismatched binary. These changes alter existing virtual tables:

- `barriers` and `setExplicitBarrierScope` are appended to `nvrhi::ICommandList`, which also shifts
  the derived `d3d12::ICommandList` and `cuda::ICommandList`.
- `createFence`, `submit`, the fence queue calls and `waitFences` are appended to `IDevice`, which
  shifts the derived `d3d12::IDevice`, `vulkan::IDevice` and `cuda::IDevice`.
- `IResource` (`queryHeapBinding`) is inserted under each resource interface.
- The validation layer's `CommandListWrapper` and `DeviceWrapper` implement the new calls. A CUDA
  device's `IInteropDevice` identity (`NVRHI_IMPLEMENTS_ROUTE_PARENT`) is unaffected, because
  `IDevice` only grows at its end.

No existing struct layout changes: `SubresourceRegion` and the barrier, fence and submit types are
new, and `TextureSubresourceSet` is untouched.

nvrhi, donut, the samples and every installed consumer package are rebuilt together, which is
already the rule on ethereal-dev (ADR 0012). The installed-consumer tests and the full ctest matrix
are rerun at step 1, and the ABI layout assertions are updated in the same commit.

## 9. Backend lowering

### 9.1 Executor

**Prepare.** Before any segment is recorded, the executor calls `Prepare` for every pass use. It
does so serially, in schedule order (12, 13.1).
- Pipelines are created there, so recording, possibly on worker threads, creates no objects.
- Static uploads are recorded there, on one graphics command list. It is the first list of the
  frame's first graphics submission, so it carries no queued wait of its own (step 5).
- The legacy's first compile spent 3.7–6.2 ms creating pipelines.

The executor then handles each segment in order:

1. **Acquire a command list.** It is taken from the registry's pool for the segment's queue: one list
   per segment slot, reused across frames, and never created in steady state.
2. **Start tracking only where needed.** `beginTracking*State` is called only for resources that
   Tracked-mode passes in the segment touch. Native passes never consult the tracker, so a
   graph-native frame makes no tracker calls at all.
3. **Run each pass:**
   1. Call `barriers(plan.prologue)`, a pointer into plan memory.
   2. Call the pass's `Execute(context, data)`.
   3. Call `barriers(plan.epilogue)`.
4. **Pass modes:**
   - **Native.** `setEnableAutomaticBarriers(false)` and `setEnableUavBarriersFor*` false for the
     body. The plan is the only barrier source, which is what makes `RelaxedOrder` work.
     - The executor brackets the body with `setExplicitBarrierScope(passName)` and
       `setExplicitBarrierScope(nullptr)` (8.2). In validation builds, any state-tracker or
       `barriers()` call by the body is reported with the pass name; otherwise the next plan
       barrier's `before` would silently be wrong.
     - A body that needs such calls is not Native: it is declared Tracked or Restore.
   - **Tracked** (`PassFlags::Tracked`, for passes whose `Execute` reuses code that relies on
     automatic barriers):
     - Automatic barriers stay on. The prologue batch has already moved the tracker, so a correctly
       declared body triggers nothing.
     - In validation builds the executor compares tracker snapshots before and after the body, and
       reports any change as an undeclared access, with the pass name.
     - Declarations must use exact states, including nvrhi's visibility-exact shader-resource states
       (2.1). Otherwise the cross-check fires on every wrapped pass.
   - **Restore** (`PassFlags::Restore`). This is a Tracked pass whose body changes states
     internally, for example a UAV write followed by an SRV read in SsaoPass, MipMapGenPass and
     ToneMappingPass, or an SDK body such as VXGI.
     - After the body, the executor uses the tracker to return each declared range to its declared
       state, and commits. The next plan barrier's `before` is then right in every build.
     - Restoring costs state calls, so it is chosen per pass. Removing it from passes that did not
       need it cut the legacy's state calls per frame from 37 to 27.
5. **Close and submit** with `IDevice::submit`, attaching the plan's fence waits and signals.
   - The first graphics-queue submission of the frame is also the one that picks up the swap
     chain's queued acquire wait on Vulkan (6.8). The executor submits nothing else on that queue
     before it, including the `Prepare` upload list, which goes into the first segment's
     submission instead.
   - The registry records the end states of persistent resources, per subresource and per
     physical resource (5.2).
   - It also records the per-queue fence values for retirement. Heaps, pooled resources and command
     lists are reused only after `getCompletedValue()` reaches the frame's values. When a pool is
     exhausted, the registry blocks with `waitFences` on the oldest frame in flight.
   - On D3D11 before 11.4 it uses one `IEventQuery` per frame instead (8.3).
6. **Fallback.** On a device without `barriers` (a stock nvrhi build), batches lower through
   `setTextureState`/`commitBarriers`.
   - Split barriers become joined, aliasing is disabled (Pooled tier) and incompatible reads fall back
     to groups.
   - Regions convert to `TextureSubresourceSet`; plane masks are widened to all planes.
   - Cross-queue waits use `queueWaitForCommandList`.

### 9.2 Backend profiles

`BackendProfile` is computed once per device. The compiler sees only the profile.

| | D3D12 | Vulkan | D3D11 | CUDA |
| --- | --- | --- | --- | --- |
| Barrier model | legacy states or enhanced layout/access/sync | layout/access/stage (sync2) | implicit | implicit, stream ordered |
| Lattice | per model (6.3) | Vulkan table | trivial | trivial |
| Planes | plane slices | aspect masks | ignored | ignored |
| Split barriers | yes | events, policy-limited | no | no |
| Memory tier | Placed | Pooled, then Placed after the `memoryTypeBits` fix | Pooled | Pooled (CUDA virtual memory later) |
| Queues | graphics, compute, copy | graphics, compute, copy (families, ownership transfer) | graphics only; async demoted | one stream per `CommandQueue` |
| Cross-queue sync | `IFence` (`ID3D12Fence`) | `IFence` (timeline semaphore) | none needed | `IFence` (event ring) |
| Pass types | all | all | Raster, Compute, Copy | Compute, Copy, RayTracing (OptiX); Raster is a compile error |
| Back buffer | host-kept; `beginFrame` waits on the CPU | host-kept; acquire queued on the graphics queue | host-kept | host-kept CUDA texture; no window |
| Recording | immediate | immediate | immediate, serial | deferred records replayed at submit; indirect dispatch stalls the host |
| Plan verified | yes | yes | yes, simulated | yes, simulated |

## 10. Performance design (R5)

### 10.1 CPU

**Recording**
- **Frame arena.** All per-frame graph data lives in a graph-owned arena, reset by `Reset`: resource
  records, passes, accesses, each pass use's data and the lambda-pass objects of 12.1.
- **Allocation-free steady state.** There is no `std::function` and no per-access heap allocation.
- **Long-lived passes.** donut pass objects are created once and added every frame. Only their
  per-use data is allocated, from the arena.

**Cache hits**
- The structural hash is accumulated while declarations are recorded, so the plan lookup at
  `Compile` is a single hash-table probe.
- A hit runs no compile phase. The executor patches import slots (O(number of imports)) and replays
  the prebuilt barrier arrays.
- No `ResourceBarrier` is built per frame. Pointers to transient and persistent resources are fixed
  in the plan. Only two things are patched: imported pointers, and histories, which select their
  textures by frame index (O(total history layers), 5.2).

**Compiling on a miss**
- **Data layout.** Structure-of-arrays with dense indices.
- **Reader sets** are bitsets: `uint64_t` up to 64 passes, a dynamic bitset beyond that.
- **Interval maps** keep small inline storage, and inner loops use no hash maps.
- **Complexity.** O(P·A·log S), where P is passes, A is accesses per pass and S is intervals per
  resource. Coalescing keeps S near 1 for uniformly used resources.

**Executing**
- **Few calls per pass.** No virtual calls per barrier: one `barriers()` call per non-empty slot,
  plus one `Execute` call.
- **Tracker.** Its cost is paid only by Tracked passes (9.1).
- **No object churn in steady state:**
  - Command lists are pooled.
  - Framebuffers and binding sets are cached by allocation generation, so a plan hit creates none.
  - Placed and pooled resources are instantiated once per plan.
- **Parallel recording.** Segments are recorded on worker threads through a host-supplied
  task-scheduler callback, with no threading-library dependency. Submission stays in plan order.
  - **Rules**, from the legacy measurements. On Vulkan, 64 passes recorded in 91 µs on one list
    against 50 µs on four threads.
    - Record in parallel only from 16 passes per segment. Below that, one list is faster.
    - Use at most as many ranges as worker threads. Each range costs about 0.7 µs, on top of about
      1.4 µs per pass.
    - Call `runGarbageCollection` once per frame. Otherwise every range opens a new Vulkan command
      pool, at about 25 µs.
    - D3D11 records serially.
  - **Prerequisites in donut** (2.2):
    - `BindingCache` creates missed binding sets outside its lock, inserts them under it, and drops
      duplicates.
    - `CommonRenderPasses::BlitTexture` guards its pipeline cache.
    - Volatile constant buffers are written only in `Execute`, on the command list that uses them
      (13.1).

**Diagnostics**
- Reason arrays, the JSON dump and the verifier are off the hot path. They are computed on a compile
  miss, or on demand.

### 10.2 GPU

- **Fewest barriers.** Read epochs merge (6.3), persistent resources skip restore transitions, and
  UAV barriers are dropped for relaxed runs and disjoint ranges.
- **Narrowest scopes.** Stages come from declarations, so compute-only readers do not stall graphics
  stages. Plane masks keep a stencil write from transitioning the depth plane.
- **Overlap.** Split barriers hide transition latency. Async compute overlaps graphics, synchronised
  by one fence wait per dependency, already reduced.
- **Bandwidth and footprint.** Aliasing shrinks transient memory. Discards avoid preserving or
  decompressing contents nobody reads, and recorded load/store intent prepares for native render
  passes.
- **Lattice cost model.** `LatticePolicy` holds per-backend costs: for example Vulkan `GENERAL`
  against a second transition. These costs decide between a merged state and split groups, and they
  can be tuned per vendor once measured.

### 10.3 Budgets (exit gates)

| Metric | Budget | Measured where |
| --- | --- | --- |
| Compile, cache miss, 64 passes / 256 resources | ≤ 1 ms | `rdg_bench` (device-free) |
| Compile, cache miss, 1024 passes | ≤ 16 ms | `rdg_bench` |
| Frame cost on a cache hit (record + lookup at `Compile` + patch), 64 passes | ≤ 0.05 ms | `rdg_bench` |
| Frame cost without the cache (`maxCachedPlans = 0`: record + full compile), same graphs | reported beside the cache-hit cost, not gated; decides whether the cache stays (7.7) | `rdg_bench` and the step-5 samples |
| Executor overhead per frame, excluding pass bodies | ≤ 0.2 ms | sample with an empty-body variant |
| Heap allocations per frame, steady state | 0 | allocation hook in `rdg_bench` and the sample |
| `create*` calls per frame, steady state | 0 | nvrhi validation-layer counters |
| Barriers per frame | ≤ original sample, each with a reason | plan counters and native capture |
| GPU frame time | ≤ original sample | timer queries |
| CPU frame time | ≤ original sample | sample frame timer |
| Peak transient memory | ≤ 60 % of the sum of poolable transient sizes, excluding imports and history, on a graph with reusable transients (bloom chain, SSAO, tone-mapping histogram). On the 6.11 frame, where every transient is live at DeferredLighting, it is reported but not gated | plan statistics |
| Parallel recording, 64 passes, 4 threads | ≤ 60 % of single-list recording time | `rdg_bench` |
| First frame after a plan miss, including `Prepare` and pipeline creation | reported, not gated | sample frame timer |

### 10.4 Measurement protocol

- **Builds.** Release builds, NVIDIA adapter selected explicitly.
- **Runs.** One GPU process at a time, with before/after runs alternated against thermal drift.
  Report the median of at least 300 frames after 100 warm-up frames.
- **Validation runs** are separate from timing runs. Each one first confirms that the validation
  layer is loaded, by provoking a known message. A Debug run without layers reports "clean" for
  nothing, which happened on the legacy's Linux runs.
- **Determinism.** Graph samples and their originals take `-fixedstep`, `-frames N` and
  `-screenshot`. `tools/ab_compare.py` compares them pixel by pixel.
- **Results.** Numbers go into the plan's execution record with the commit hashes.

## 11. Correctness and diagnostics

### 11.1 Device-free plan verifier

`VerifyPlan(compiled, graph)` replays the plan against a simulated per-subresource state machine,
using the profile's rules. It asserts that:

- every access sees a compatible state;
- every hazard (RAW, WAR, WAW, UAV) has a barrier or a fence wait between its two accesses;
- no split is left open at the end of a segment;
- aliases never overlap in both lifetime and bytes;
- every discard-before is a full write or a clear;
- every release has its acquire;
- every exit state matches its declaration;
- every state and stage is legal on the queue that executes it (6.8);
- two consecutive frames, and a switch between two cached plans, are free of hazards across the
  boundary (6.12).

It runs in unit tests over a corpus of graphs for all four profiles. In debug builds it can also run
on every compile miss.

### 11.2 GPU validation

- **Tracker cross-check:** Tracked mode, 9.1.
- **Native-body guard:** explicit-barrier scopes around Native bodies, 8.2 and 9.1.
- **Reflection cross-check:** in debug builds a pass may register its `IShader`s. Where
  `IShader::getReflection` returns reflection (shaders built as containers, 2.1), the reflected SRV
  and UAV registers must match the declared accesses: a UAV register needs a UAVRead or
  UAVWrite declaration, and every declared access needs a register. Parameters without a register
  (nested in a parameter block or struct) are skipped and counted, so a pass that the check cannot
  cover is visible. Shaders without reflection, which today includes all of donut's own passes, are
  not checked. Moving donut's shaders to containers is outside this design.
- **Native validation:**
  - D3D12 debug layer, including GPU-based validation.
  - Vulkan validation, including synchronisation validation.
  - CUDA Compute Sanitizer.

### 11.3 Diagnostics

**Barrier reasons.** Every barrier carries one of these reasons:

| Reason | Meaning |
| --- | --- |
| `RAW` | read after write |
| `WAR` | write after read |
| `WAW` | write after write |
| `UavOrder` | UAV-to-UAV ordering |
| `ReadGroupChange` | incompatible readers in one epoch |
| `Alias` | first use after an aliased resource |
| `QueueTransfer` | cross-queue ownership release/acquire |
| `Discard` | discard-before initialisation |
| `ExitState` | transition to an import's exit state |
| `Persistent` | a persistent resource's cross-frame state |

Every adjacent raster pair that does not merge also records a reason.

**Outputs of `ICompiledRenderGraph`:**
- a JSON dump of passes, lifetimes, heap offsets, batches with reasons, and fence waits;
- a Graphviz export;
- the counters of 10.3;
- per-pass GPU timers (`ExecuteDesc::timers`) and run statistics (frame, compile, record and submit
  times; barrier, state-call and allocation counts).

GPU markers use the pass names.

**Visualizer.** `app::RenderGraphVisualizer`, an `app::IAppLayer`, draws the data above with ImGui:
lifetimes, heap placement, barriers with their reasons, and pass toggles that drive
`SetPassEnabled` (13.5).

### 11.4 Debug switches

`CompileOptions::debugFlags` can be changed at run time. A change costs one plan-cache miss. Each
switch that changes the plan is a phase inserted into the compiler's list (7); the others act in the
executor.

| Switch | Effect | Use |
| --- | --- | --- |
| `ForceDedicated` | every transient gets its own memory | bit-exact reference for aliasing bugs |
| `NoAliasing` | Placed tier without overlap | isolates aliasing from placement |
| `BarrierAfterEveryPass` | a full barrier after every pass | isolates missing barriers |
| `FillTransients` | discard-before also fills with a pattern | exposes reads of undefined contents |
| `SerializeQueues` | async passes run on the graphics queue | isolates cross-queue bugs |
| `StrictValidation` | runs the verifier on every frame, not only on a miss | |
| `SkipAliasingBarriers` | tests only: drops aliasing barriers | negative test, which must fail, to prove the aliasing test detects the fault |

## 12. Public interfaces

`include/donut/render/RenderGraph.h`, abridged. IIDs are placeholders.

```cpp
namespace donut::render
{
    // A texture or buffer in one graph: index in the low 32 bits, version in the high 32 (5.1).
    // An enum, so it may cross virtual calls by value (rule R1).
    enum class ResourceId : uint64_t {};
    constexpr ResourceId InvalidResourceId = ResourceId(~0ull);
    constexpr uint32_t c_MaxHistoryLayers = 8;
    constexpr ResourceId MakeResourceId(uint32_t index, uint32_t version) noexcept;
    constexpr uint32_t GetResourceIndex(ResourceId id) noexcept;
    constexpr uint32_t GetResourceVersion(ResourceId id) noexcept;

    enum class PassId : uint32_t {};

    enum class Access : uint32_t { /* 6.1 */ };
    enum class AccessFlags : uint32_t { None = 0, Clear = 1, FullWrite = 2, RelaxedOrder = 4, Preserve = 8 };
    enum class PassType : uint8_t { Raster, Compute, Copy, RayTracing };
    enum class PassFlags : uint32_t { None = 0, AsyncCompute = 1, NeverCull = 2, SideEffect = 4, Tracked = 8,
                                      Restore = 16 /* implies Tracked */ };
    enum class ResourceFlags : uint32_t { None = 0, NoAlias = 1, DebugCapture = 2 };
    enum class DisabledOutput : uint8_t { Cull, Substitute, Passthrough };   // 13.5

    struct ClearValue { float color[4]; float depth; uint8_t stencil; };
    struct PassDesc   { const char* name; PassType type; PassFlags flags; uint32_t exclusionGroup = 0; };  // 0 = none

    struct IResourceRegistry;   // what survives between frames (4); its interface is omitted here

    // The accesses of one pass use, declared in IGpuPass::Setup (13.2). Valid only until that
    // Setup returns; a call after that is a validation error reported by Compile, and Write
    // returns InvalidResourceId.
    NVRHI_IID(ISetupContext, "...")
    struct ISetupContext : nvrhi::IObject
    {
        NVRHI_DECLARE_UUID_TRAITS(ISetupContext)
        // Scratch that lives only inside this pass use (5.2): no other pass may name it. The pass
        // still declares its accesses below; the first one must be a FullWrite or a Clear.
        virtual ResourceId CreateTransientTexture(const nvrhi::TextureDesc& desc, ResourceFlags flags) noexcept = 0;
        virtual ResourceId CreateTransientBuffer(const nvrhi::BufferDesc& desc, ResourceFlags flags) noexcept = 0;
        // Reads do not create versions. The region is ignored for buffers; {} is the whole resource.
        virtual void Read(ResourceId resource, Access access, nvrhi::ShaderType stages,
                          const nvrhi::SubresourceRegion& region) noexcept = 0;
        // Returns the new version.
        virtual ResourceId Write(ResourceId resource, Access access, nvrhi::ShaderType stages,
                                 const nvrhi::SubresourceRegion& region, AccessFlags flags) noexcept = 0;
        virtual ResourceId SetColorTarget(uint32_t slot, ResourceId texture,
                                          const nvrhi::SubresourceRegion& region,
                                          AccessFlags flags, _In_opt_ const ClearValue* clear) noexcept = 0;
        virtual ResourceId SetDepthTarget(ResourceId texture, bool readOnly, AccessFlags flags,
                                          _In_opt_ const ClearValue* clear) noexcept = 0;
        // What consumers of `written` see when this pass is disabled (13.5).
        virtual void SetDisabledOutput(ResourceId written, DisabledOutput policy,
                                       ResourceId substituteOrInput) noexcept = 0;
    };

    // Serial, before recording: pipelines and static uploads (13.1).
    NVRHI_IID(IPrepareContext, "...")
    struct IPrepareContext : nvrhi::IObject
    {
        NVRHI_DECLARE_UUID_TRAITS(IPrepareContext)
        virtual nvrhi::IDevice* GetDevice() noexcept = 0;
        virtual nvrhi::ICommandList* GetUploadCommandList() noexcept = 0;   // first list of the first graphics submit
        virtual const nvrhi::FramebufferInfoEx& GetFramebufferInfo() noexcept = 0;   // raster passes
        virtual const nvrhi::TextureDesc* GetTextureDesc(ResourceId id) noexcept = 0;   // nullptr for a buffer
        virtual const nvrhi::BufferDesc* GetBufferDesc(ResourceId id) noexcept = 0;     // nullptr for a texture
    };

    NVRHI_IID(IPassContext, "...")
    struct IPassContext : nvrhi::IObject
    {
        NVRHI_DECLARE_UUID_TRAITS(IPassContext)
        virtual nvrhi::ICommandList* GetCommandList() noexcept = 0;
        virtual nvrhi::IResource* GetResource(ResourceId id) noexcept = 0;
        virtual nvrhi::ITexture* GetTexture(ResourceId id) noexcept = 0;    // nullptr for a buffer
        virtual nvrhi::IBuffer* GetBuffer(ResourceId id) noexcept = 0;      // nullptr for a texture
        virtual nvrhi::IFramebuffer* GetFramebuffer() noexcept = 0;         // cached per allocation generation
        virtual bool IsNewAllocation(ResourceId id) noexcept = 0;
        virtual uint64_t GetFrameIndex() noexcept = 0;
    };

    // The base of every donut pass (13.1).
    NVRHI_IID(IGpuPass, "...")
    struct IGpuPass : nvrhi::IObject
    {
        NVRHI_DECLARE_UUID_TRAITS(IGpuPass)
        // Declares the accesses of one use through `context`; `data` is that use's frame-arena
        // record. Called only by IRenderGraph::AddPass.
        // FE_UNSUPPORTED: this pass cannot run in a graph yet.
        virtual nvrhi::FRESULT Setup(ISetupContext* context, void* data) noexcept = 0;
        // Serial, before any recording. Creates pipelines and records static uploads.
        // Must not write volatile constant buffers.
        virtual nvrhi::FRESULT Prepare(IPrepareContext* context, void* data) noexcept = 0;
        // Records that use. May run on a worker thread.
        virtual nvrhi::FRESULT Execute(IPassContext* context, const void* data) noexcept = 0;
        // The registry released the resources this pass's caches may reference (resize, plan
        // eviction). Drop framebuffers and binding sets that point at them.
        virtual void OnResourcesReleased() noexcept = 0;
    };

    // The frame's resources, passes and accesses. Bound to one registry and reused across frames.
    // Declaring a resource records a description; no GPU object is created until a plan is
    // instantiated.
    NVRHI_IID(IRenderGraph, "...")
    struct IRenderGraph : nvrhi::IObject
    {
        NVRHI_DECLARE_UUID_TRAITS(IRenderGraph)
        virtual IResourceRegistry* GetResourceRegistry() noexcept = 0;     // not AddRef'd
        virtual void Reset() noexcept = 0;                                 // start a frame; resets the arena

        // Resources (5.2). The ids are valid until the next Reset.
        virtual ResourceId CreateTexture(const nvrhi::TextureDesc& desc, ResourceFlags flags) noexcept = 0;
        virtual ResourceId CreateBuffer(const nvrhi::BufferDesc& desc, ResourceFlags flags) noexcept = 0;
        virtual ResourceId ImportTexture(nvrhi::ITexture* texture, nvrhi::ResourceStates entry,
                                         nvrhi::ResourceStates exit) noexcept = 0;
        virtual ResourceId ImportHostKeptTexture(nvrhi::ITexture* texture) noexcept = 0;
        virtual ResourceId ImportBuffer(nvrhi::IBuffer* buffer, nvrhi::ResourceStates entry,
                                        nvrhi::ResourceStates exit) noexcept = 0;
        // Kept by the registry under `name`; a new id for the same resource each frame.
        virtual ResourceId GetPersistentTexture(const char* name, const nvrhi::TextureDesc& desc) noexcept = 0;
        virtual ResourceId GetPersistentBuffer(const char* name, const nvrhi::BufferDesc& desc) noexcept = 0;
        // `layerCount` ids, 2..c_MaxHistoryLayers: ids[0] is this frame's layer (writable), ids[k] was
        // written k frames ago (read-only) (5.2). FE_INVALID_ARGS for another layer count.
        virtual nvrhi::FRESULT GetHistory(const char* name, const nvrhi::TextureDesc& desc,
                                          uint32_t layerCount, ResourceId* ids) noexcept = 0;
        // Keeps a transient past the end of the graph; `outTexture` is set when the graph executes.
        virtual void Extract(ResourceId texture, nvrhi::ResourceStates exit, nvrhi::ITexture** outTexture) noexcept = 0;

        // Passes. AddPass calls pass->Setup(context, data) with a setup context for the new pass,
        // and holds a reference to `pass` until Reset; `data` must come from AllocateFrameData.
        virtual nvrhi::FRESULT AddPass(const PassDesc& desc, IGpuPass* pass, void* data,
                                       _Out_opt_ PassId* outPass) noexcept = 0;
        // Not part of the structural hash (7.7, 13.5).
        virtual void SetPassEnabled(PassId pass, bool enabled) noexcept = 0;
        virtual void PushMarker(const char* name) noexcept = 0;
        virtual void PopMarker() noexcept = 0;
        // Frame arena. Released at Reset without running destructors: use NewFrameData (below).
        virtual void* AllocateFrameData(size_t size, size_t alignment) noexcept = 0;

        // Compiles the recorded frame, or returns the cached plan for its structural hash (7.7), and
        // freezes the graph until the next Reset. No device calls.
        virtual nvrhi::FRESULT Compile(const BackendProfile& profile, const CompileOptions& options,
                                       ICompiledRenderGraph** outPlan) noexcept = 0;
        // Runs a plan that Compile returned for this frame (9.1). FE_UNSUPPORTED when the
        // registry has no device; FE_INVALID_ARGS for a plan from another graph or frame.
        virtual nvrhi::FRESULT Execute(ICompiledRenderGraph* plan, const ExecuteDesc& desc) noexcept = 0;

        virtual uint64_t GetStructuralHash() noexcept = 0;
        virtual uint64_t GetEnableMaskHash() noexcept = 0;
        virtual uint32_t GetPassCount() noexcept = 0;
        virtual uint32_t GetResourceCount() noexcept = 0;
    };

    // The two-layer history that TAA uses. Inline, not virtual.
    inline nvrhi::FRESULT GetHistoryPair(IRenderGraph* graph, const char* name, const nvrhi::TextureDesc& desc,
                                         ResourceId* current, ResourceId* previous) noexcept
    {
        ResourceId ids[2];
        const nvrhi::FRESULT result = graph->GetHistory(name, desc, 2, ids);
        *current = ids[0];
        *previous = ids[1];
        return result;
    }

    // Places one pass use's data in the frame arena. Inline, not virtual: it is outside the ABI.
    template <typename T, typename... Args>
    T* NewFrameData(IRenderGraph* graph, Args&&... args) noexcept
    {
        static_assert(std::is_trivially_destructible_v<T>,
                      "frame data is released at Reset without running destructors");
        void* memory = graph->AllocateFrameData(sizeof(T), alignof(T));
        return memory ? new (memory) T{ std::forward<Args>(args)... } : nullptr;
    }

    // `device` may be nullptr: such a registry supports recording and compiling only (tests, rdg_bench).
    nvrhi::FRESULT CreateResourceRegistry(nvrhi::IDevice* device, IResourceRegistry** out) noexcept;
    // One graph per registry: FE_INVALID_ARGS if `registry` already has one.
    nvrhi::FRESULT CreateRenderGraph(IResourceRegistry* registry, IRenderGraph** out) noexcept;
    nvrhi::FRESULT ComputeBackendProfile(nvrhi::IDevice* device, BackendProfile* out) noexcept;
}
```

**Recording rules.**
- **The setup context is the open pass.** `AddPass` hands `Setup` an `ISetupContext` for the pass
  being added, so a declaration always knows its pass. The concrete graph implements it, pointed at
  that pass, so nothing is created per pass. The context replaces the old `IPassBuilder`. Calling
  `AddPass` from inside `Setup` is rejected.
- **Where transients are created.** A transient that several passes share, such as a bloom chain
  that one pass writes and the next reads, is created on the graph in `AddToGraph`, before `AddPass`.
  Scratch that only one pass uses, such as SsaoPass's deinterleaved arrays, is created in `Setup`
  through `ISetupContext::CreateTransientTexture/Buffer`. It stays out of the pass's `AddToGraph`
  signature but is still placed, aliased and pooled by the graph (5.2, 13.3).
- **Frame data is trivially destructible.** `Reset` releases the arena without running destructors,
  so per-use data holds ids, plain values and non-owning pointers only, never reference-counted
  pointers or containers. `NewFrameData<T>` checks this with a `static_assert`. That closes gap 1 of
  the Unity comparison: nothing ever destroyed the data that `AddToGraph` placed with `new`.
- **One graph per registry.** The registry keeps one graph's persistent states, plan instances and
  frame retirement. Two graphs sharing it could execute the same cached plan, and so the same
  physical transients, in one frame. A view or pipeline that needs a second graph gets a second
  registry.
- **Compile freezes the graph.** After `Compile` and until the next `Reset`, resource declarations,
  `AddPass` and `SetPassEnabled` are rejected, so the executor sees exactly what was compiled.

As in nvrhi's interface style (`com-interface-abi.md` 3.2), the virtual functions take no default
arguments. Callers pass `{}` for a whole resource and `ResourceFlags::None` explicitly.

The rest of the header follows the same style:
- `BackendProfile`, `CompileOptions` and `ExecuteDesc` are plain structs. `CompileOptions` holds
  `placedResources`, `maxCachedPlans` and `debugFlags` (7.5, 7.7, 11.4). `ExecuteDesc` holds the
  task-scheduler callback and the timer switch.
- `ICompiledRenderGraph` provides queries and the dump.
- `IResourceRegistry` holds persistent resources, the plan cache, the pools and caches, the fences
  and retirement.

The graph is reused across frames: `Reset` starts a frame instead of creating a new graph object,
which keeps the frame path free of allocations.

### 12.1 Lambda helper (header-only, outside the ABI surface)

```cpp
// include/donut/render/RenderGraphLambdaPass.h
// setup(ISetupContext*, Data&) declares the accesses; exec(IPassContext*, const Data&) records the work.
template <typename Data, typename SetupFn, typename ExecFn>
const Data& AddLambdaPass(IRenderGraph* graph, const PassDesc& desc, SetupFn&& setup, ExecFn&& exec);
```

The helper places an `IGpuPass` object and its `Data` in the frame arena (`AllocateFrameData`). The
object is an `ObjectImpl<IGpuPass>` whose virtual table lives in the caller's module.
- **Destruction.** The graph releases its reference at `Reset`. The object's `DestroyObject` then
  runs the destructors of the lambdas and of `Data` but frees nothing, because the arena owns the
  memory. This is the one arena object with a destructor, so the lambdas' captures may own
  resources. `Data` itself follows the frame-data rule (12).
- Its reference count protects only against misuse: the graph owns the object for the frame.
- Its `Prepare` and `OnResourcesReleased` do nothing unless the caller passes a prepare function.

Samples use the helper for one-off passes; donut's own passes are long-lived classes (section 13).

### 12.2 Frame data: a typed blackboard (header-only, outside the ABI surface)

A frame put together from optional, independent features needs a place where one feature publishes
the ids it produced and another finds them, without threading them through every `AddToGraph`
signature. URP has `ContextContainer frameData` for this, and Filament has its `Blackboard`.

```cpp
// include/donut/render/RenderGraphFrameData.h
class FrameData
{
public:
    void Clear() noexcept;                                    // right after IRenderGraph::Reset
    template <typename T> T& Create(IRenderGraph* graph);     // once per type per frame, in the graph's arena
    template <typename T> T* Find() noexcept;                 // nullptr if nothing created it this frame
    template <typename T> T& Get() noexcept;                  // asserts it exists
private:
    struct Entry { const void* key; void* value; };
    Entry    m_Entries[32];
    uint32_t m_Count = 0;
};

struct SceneTargets { ResourceId depth, color, motionVectors; };

// depth feature
auto& scene = frame.Create<SceneTargets>(graph);
scene.depth = depthPass->AddToGraph(graph, { graph->CreateTexture(depthDesc, ResourceFlags::None), view }).depth;

// SSAO feature, optional, elsewhere
if (SceneTargets* s = frame.Find<SceneTargets>())
    frame.Create<AmbientOcclusion>(graph).ao = ssao->AddToGraph(graph, { s->depth, ... }).ao;
```

Rules:
- **Keyed by C++ type**, through the address of an inline per-type tag, with no strings and no RTTI.
  A misspelled key is a compile error. Producers and consumers of one type must be built into one
  module, because an inline variable's address can differ across DLL boundaries.
- **Values are structs of ids**, so related ids travel together. They are trivially destructible
  and live in the graph's frame arena (12), so a lookup is a few pointer compares and allocates
  nothing.
- **Creating and reading are separate calls.** `Create<T>` is the only call that makes an entry;
  `Find<T>` and `Get<T>` never insert one.
- **Writes are stored back.** A write returns a new version, so the feature that writes a resource
  stores the returned id in the entry. If it forgets, the next reader uses the old version, and
  `Compile` rejects it as a stale id naming both passes (5.1).
- **For composing frames only.** `app::RenderGraphLayer::BuildGraph` and sample code use it.
  donut's passes keep their typed `AddToGraph` inputs and outputs and never read the blackboard,
  so what each pass consumes stays visible in its signature.
- The graph, the compiler and the plan never see it: no ABI change, and no effect on the structural
  hash.

**Why not Filament's `Blackboard`.** Filament stores one `FrameGraphHandle` per name in a
`std::unordered_map<std::string_view, FrameGraphHandle>`.
- The map allocates every frame, against R5.
- String keys turn a misspelling into an empty entry at run time.
- `operator[]` is implemented as `insert_or_assign(name, {})`, so using it to read resets the entry.
- One handle per key splits related resources across separate names.

## 13. donut's passes in the graph

### 13.1 One base: `IGpuPass`

Every donut pass derives from `IGpuPass`, through the existing `ObjectImpl` pattern:

```cpp
class BloomPass : public nvrhi::ObjectImpl<IGpuPass> { ... };     // was ObjectImpl<nvrhi::IObject>

class IGeometryPass : public nvrhi::ObjectImpl<IGpuPass>          // was ObjectImpl<nvrhi::IObject>
{
public:
    NVRHI_BEGIN_INTERFACE_TABLE_INLINE(IGeometryPass)
    NVRHI_IMPLEMENTS_INTERFACE(IGpuPass)
    NVRHI_IMPLEMENTS_INTERFACE(nvrhi::IObject)
    NVRHI_END_INTERFACE_TABLE()
    ...
};
```

This covers all the passes in 2.2:
- The seven `ObjectImpl<IObject>` passes and `IGeometryPass` change their base.
- The four geometry passes inherit it through `IGeometryPass`.
- The six passes with no base become reference counted. Their owners in donut and the samples
  switch to `nvrhi::RefCountPtr`.

The graph knows nothing else about a pass.

**Lifecycle.**

| Call | When | What it does |
| --- | --- | --- |
| `Setup` | inside `AddPass`, every frame | declares the accesses of the use being added, and its disabled-output policies (13.5), through its `ISetupContext` |
| `Prepare` | serially, after compile and before recording | creates pipelines (from `GetFramebufferInfo` and the descriptions) and records static uploads |
| `Execute` | while recording, possibly on a worker thread | records commands. Volatile constant buffers are written here only, on the list that uses them. The legacy enforced this rule with an upload guard, and the validation build keeps it |
| `OnResourcesReleased` | after a resize or a plan eviction | drops cached framebuffers and binding sets, so that they do not pin pooled memory |

### 13.2 Adding a pass to a graph

Each pass gets a typed entry point, `AddToGraph`. It allocates the use's data in the frame arena,
calls `AddPass` with itself and the data, and returns the output ids. `Setup` reads the data to
declare the accesses through its `ISetupContext`; `Execute` reads it, resolves the ids through
`IPassContext`, and
records the work through the same code that the immediate entry point uses.

```cpp
// DeferredLightingPass.h
struct DeferredLightingGraphInputs  { ResourceId depth, gbuffer[4], ambientOcclusion, shadowMap, output; const ICompositeView* view; ... };
struct DeferredLightingGraphOutputs { ResourceId output; };

DeferredLightingGraphOutputs AddToGraph(IRenderGraph* graph, const DeferredLightingGraphInputs& inputs);

// DeferredLightingPass.cpp
struct UseData { DeferredLightingGraphInputs inputs; ResourceId output; };

DeferredLightingGraphOutputs DeferredLightingPass::AddToGraph(IRenderGraph* graph,
                                                              const DeferredLightingGraphInputs& inputs)
{
    auto* data = NewFrameData<UseData>(graph, inputs);   // UseData is trivially destructible (12)
    graph->AddPass({ "DeferredLighting", PassType::Compute, PassFlags::None }, this, data, nullptr);
    return { data->output };   // written by Setup
}

nvrhi::FRESULT DeferredLightingPass::Setup(ISetupContext* context, void* data) noexcept
{
    auto& use = *static_cast<UseData*>(data);
    context->Read(use.inputs.depth, Access::ShaderRead, nvrhi::ShaderType::Compute, {});
    ...
    use.output = context->Write(use.inputs.output, Access::UAVWrite, nvrhi::ShaderType::Compute,
                                {}, AccessFlags::FullWrite);
    return nvrhi::FS_OK;
}

nvrhi::FRESULT DeferredLightingPass::Execute(IPassContext* context, const void* data) noexcept
{
    const auto& use = *static_cast<const UseData*>(data);
    ...
}
```

Rules:
- **Several uses per frame.** One pass object can be added several times, for example DepthPass once
  per shadow cascade. Each use has its own arena data, which `AddPass` hands back to `Setup`,
  `Prepare` and `Execute`.
- **Arena data lives one frame.** It is released at the graph's `Reset`, together with the ids it
  holds. A pass that copies an id into a member and uses it in a later frame gets a stale-id error
  (5.1).
- **Views.** Overloads that take an `ICompositeView` add one use per child view, for stereo or cube
  faces. Per-view temporaries have disjoint lifetimes, so the memory plan gives them the same memory
  (7.5). No extra API is needed; a test checks the folding.
- **Immediate entry points stay.** The existing calls, such as `DeferredLightingPass::Render(
  commandList, inputs, view)`, keep working, so samples that do not use the graph are unaffected.
  Graph and immediate paths share the recording code.
- **Passes that cannot run in a graph yet** return `FE_UNSUPPORTED` from `Setup`. `AddPass` then
  fails with a diagnostic naming the pass, and the caller imports the results instead.

### 13.3 Mapping of the shipped passes

| Pass | Graph entry | Mode | Pass changes |
| --- | --- | --- | --- |
| DeferredLightingPass | one compute pass; `Inputs` from ids | Native | none beyond the base |
| GBufferFillPass / DepthPass / ForwardShadingPass / MaterialIDPass | raster via `RenderCompositeView`; framebuffer from `IPassContext` | Tracked, then Native | PSO cache key gains `FramebufferInfo` |
| CascadedShadowMap / PlanarShadowMap (not passes) | shadow texture persistent; DepthPass used once per slice | Tracked | none |
| SsaoPass | one pass; the deinterleaved arrays become pass-local transients (`ISetupContext::CreateTransientTexture`), so the graph aliases and pools them | Restore | the arrays leave the class; no change to the `AddToGraph` signature |
| BloomPass | graph-native chain (downsample/blur per mip) | Native | shaders reused; class chain bypassed |
| TemporalAntiAliasingPass | motion vectors + resolve; `GetHistoryPair` (two layers); `feedbackIsValid = !IsNewAllocation(prev)` | Native | per-call textures; `AdvanceFrame` no longer swaps |
| ToneMappingPass | histogram transient, exposure persistent | Native | per-call framebuffer and buffers |
| SkyPass / EnvironmentMapPass | one pass each | Native | per-call framebuffer or texture |
| MipMapGenPass | one pass; the body writes and then reads mips | Restore | per-call texture |
| SDK bodies (VXGI in the samples) | one pass | Restore | none |
| LightProbeProcessingPass / PixelReadbackPass / ManipulatorPass / JointsRenderPass / DLSS | `Setup` returns `FE_UNSUPPORTED`; results imported | | base only |

**Changes to the existing passes are additive:**
- the base class;
- `AddToGraph`, `Setup` and `Execute`;
- overloads that take formats or targets per call.

The existing API keeps working.

### 13.4 App integration

`app::RenderGraphLayer` (an `app::IAppLayer`, 3.3) owns the registry, its graph and a `FrameData`
blackboard (12.2), which it clears right after `Reset`. Each frame,
after `DeviceManager::BeginFrame` has run the swap chain's `beginFrame`, it:
1. calls the graph's `Reset`, then imports the current back buffer (from `IGraphicsSwapChain`)
   with `ImportHostKeptTexture`;
2. calls a virtual `BuildGraph(IRenderGraph*, FrameData&)`;
3. compiles and executes. The first graphics submission carries the queued acquire wait on Vulkan
   (6.8).

A resize changes resource descriptions, which changes the hash, which forces a recompile. No pass is
recreated.

### 13.5 Conditional passes and exclusion groups

**Toggling.** `AddPass` returns a `PassId`. `SetPassEnabled(id, enabled)`, called before `Compile`,
turns a pass off without changing the structural hash (7.7). The plan's memory therefore stays, and
a toggle costs at most one partial compile per new mask.

**Disabled outputs.** A disabled pass's outputs follow the policy its `Setup` declared with
`SetDisabledOutput`:

| Policy | Effect | Example |
| --- | --- | --- |
| `Cull` (default) | consumers that need the output are disabled too | debug overlays |
| `Substitute` | consumers read a substitute resource instead | SSAO off: a 1×1 white AO texture |
| `Passthrough` | the output becomes an input of the same description | bloom off: HDR passes through |

The compiler checks that each substitute or passthrough input matches the output's description and
reads.

**Exclusion groups.** Passes with the same `PassDesc::exclusionGroup` are never enabled together, and
validation rejects a mask that enables two of them. Resources used only by different members of a
group may share memory (7.4).

## 14. Decisions

These are the decisions made in review.

### 14.1 Branches (decided)

Fresh `rdg` branches, based on the current development line, carry the feature development:
- the aggregate, plus `ethereal-nvrhi`, `ethereal-donut` and `ethereal-samples`;
- each started from the commit that aggregate `main` records for it: nvrhi `ethereal-dev` `123d105`,
  donut `ethereal-dev` `4f4b31c` (shader-tool `b5bec4b`), samples `main` `37ac258`.

The aggregate worktree is `.worktrees/rdg`. Its `rdg` branch is `ac93875` plus the design commit,
so step 0 rebases it onto aggregate `main` (`264ac18`) before the submodules are initialised. The
`slang-next` line is no longer a reference: everything it was meant to provide is on ethereal-dev.

### 14.2 RHI extension shape (decided)

- **`ICommandList` is extended in place.** It gains `barriers(const ResourceBarrier*, uint32_t)`;
  there is no `IBarrierCommandList`.
- **`ResourceBarrier` is a single type.** It is a D3D12-style union of transition, UAV and aliasing
  barriers, distinguished by `type`. Transitions carry a `SubresourceRegion`.
- **New `IResource` base** under `IBuffer`, `ITexture`, `IStagingTexture`,
  `ISamplerFeedbackTexture`, `IAccelStruct` and `IOpacityMicromap`.
- **New `SubresourceRegion`** (mips, slices, plane mask), shared by barriers and graph accesses.
  `TextureSubresourceSet` is not changed.
- **No header-version bump and no derived `IFoo1`.** This was a review decision for the rdg work; it
  is now nvrhi's general policy (§3.4, ADR 0012). See 8.4 for what it requires.
- **Layout assertions** for `ResourceBarrier` live in the source file, not the header.

### 14.3 Async compute and cross-queue synchronisation (decided)

- **Async compute** runs on `ICommandList`s created for `CommandQueue::Compute` (a `CUstream` on
  CUDA).
- **Cross-queue synchronisation** uses a new timeline `IFence`, with waits and signals attached to
  `IDevice::submit` (8.3). CPU waits follow 8.3.1, where an infinite timeout blocks until the value
  is reached.
- **Vulkan ownership** across families is explicit release/acquire, through transition flags.

### 14.4 Old records (decided)

- `ethereal-donut/doc/RdgDesign.md` becomes "Superseded by aggregate ADR 0003". This happens in
  step 0, because donut is not checked out in the worktree yet.
- The 2026-10-04 framegraph plan is "Abandoned". That is already done in this worktree.
- Both are kept as history.

### 14.5 Multi-device graphs (decided: later)

Each graph runs on one device. A CUDA graph and a graphics graph that share data follow the
pattern the GVDB samples already use with `IInteropDevice` (`sample-utils/ScreenPresenter.cpp`):
- The shared resource is created on the graphics device. The CUDA graph imports the CUDA object that
  `importTexture`/`importBuffer` returned, and the graphics graph imports the original. Both are
  tracked imports with declared entry and exit states. On CUDA those states only document intent.
- The application orders the two graphs with `computeQueueWaitForGraphicsQueue` and
  `graphicsQueueWaitForComputeQueue` between their `Execute` calls (6.8, queued waits).
- Interop is D3D12 and Vulkan only. On Vulkan, layered textures with more than one mip cannot be
  imported, so such a resource cannot be shared at all.

One graph spanning both devices, with the hand-over waits inside its plan, is the later step. It
builds on the shared-fence follow-up in 8.3.

### 14.6 Placement, pass base and resource ids (decided)

- The graph sits in the `render/` folder of `donut_render` as the `RenderGraph*` files. There is no
  subfolder and no adapter layer: the passes derive from one base and add themselves (section 13).
- Graph resources are named by one `ResourceId` type (index plus version), and accesses name an
  `nvrhi::SubresourceRegion`.
- Graph per-subresource state is `SubresourceRangeState`.

### 14.7 Names (decided)

- **Pass base:** `donut::render::IGpuPass` (3.3). Every donut rendering pass derives from it.
- **App layer:** `app::IRenderPass` becomes `app::IAppLayer`, and the `DeviceManager` members follow
  it:
  - `AddLayerToFront`, `AddLayerToBack` and `RemoveLayer`;
  - `m_vLayers`;
  - `ImGuiRenderPass` becomes `ImGuiLayer`.

  No alias is kept, and the name `nvrhi::IRenderPass` is reserved for the RHI.

### 14.8 Lessons from the legacy framegraph (decided)

[`rdg-legacy-evaluation.md`](rdg-legacy-evaluation.md) compared this design with the deprecated
`framegraph` branches. These changes were adopted from it:

1. the frame boundary: aliasing, cross-queue waits and state hand-off (6.12);
2. a full queue-legality table for states and stages, and the corrected async example (6.8, 6.11);
3. clears as accesses with their own slot (6.9);
4. the Restore pass mode (9.1);
5. an R1-compliant header with enum ids and abi_lint coverage (3.2, 5.1, 12). The legacy's
   derived-interface evolution (`IFoo1`) was dropped in the rebase: interfaces now change in place,
   as nvrhi's do;
6. `IResource::queryHeapBinding` and checked Vulkan memory binding (8.1). The queue-family fix
   is no longer needed: it went into nvrhi's Vulkan factory (2.2);
7. the D3D12 discard and alias rules (6.6, 6.7);
8. the pass lifecycle: `Prepare` and `OnResourcesReleased` (12, 13.1);
9. history pairs specified, persistent buffers, and poolable extracted resources (5.2);
10. conditional passes, exclusion groups and a bounded plan cache (7.7, 13.5);
11. debug switches, a visualizer, timers and deterministic A/B tooling (10.4, 11.3, 11.4);
12. a corrected memory budget, the parallel-recording rules, and more samples (10.1, 10.3, 15).

The rebase onto ethereal-dev (2026-11-01) was checked against the evaluation again. Six more lessons
came out of its sections 2, 4 and 6, and of how ethereal-dev reintroduced one of the legacy's traps:

13. **Queued waits.** The legacy's `queueWaitForCommandList` trap (a Vulkan wait attached to the
    next submission) now sits inside nvrhi's swap chain and Vulkan interop. The back buffer is
    graphics-queue only, and the first graphics submission carries the queued waits (6.8, 9.1).
14. **Explicit write-after-read edges** once the scheduler moves passes (7.3, evaluation 4).
15. **The queue rule before exclusion groups** when deciding whether memory can be shared (7.4,
    evaluation 6, the legacy `canReuse` defect).
16. **A heap-count test** for heaps per queue and per class (7.5, evaluation 6).
17. **A `CONCURRENT` fallback** in case EXCLUSIVE ownership transfers, which the legacy never ran,
    fail validation or cost too much (6.8, evaluation 2).
18. **Interop hand-overs as graph boundaries,** with the existing `IInteropDevice` waits, until
    fences can be shared (8.3, 14.5).

The evaluation itself stays a dated record of the 2026-10-21 design against the slang-next RHI. Its
section 5 facts about Vulkan memory binding still hold on ethereal-dev (2.1). Its queue-family fact
does not.

### 14.9 Review of 2026-11-04 (decided)

1. **UAV access names.** `StorageRead` and `StorageWrite` became `UAVRead` and `UAVWrite` (6.1). The
   names match nvrhi's own vocabulary (`isUAV`, `ResourceStates::UnorderedAccess`). nvrhi's spelling
   is mixed (`isUAV`, but `setEnableUavBarriersFor*`). The access names use `UAV`, while 8.2
   (`BarrierType::Uav`, `UavBarrier`) and 11.3 (`UavOrder`) keep `Uav`, as nvrhi's own barrier
   calls do.
2. **No `IResource::getResourceType`.** Backends reach the derived interface with `QueryInterface`
   (8.1). The conflict was R5: the old text chose the type tag to avoid a QI per barrier.
   `QueryInterface(riid, nullptr)` adds no reference, so the per-barrier cost is one virtual call and
   a table walk, which step 1 measures. `ResourceType` is gone with it.
3. **No builder objects.** `IPassBuilder` and `IRenderGraphBuilder` are deleted (12), and their
   methods moved to other interfaces:
   - resource creation and importing (`CreateTexture`, `CreateBuffer`, the imports,
     `GetPersistent*`, `GetHistoryPair`, `Extract`) and pass recording (`AddPass`,
     `SetPassEnabled`, the markers, `Reset`, `AllocateFrameData`) to `IRenderGraph`, which is bound
     to its registry (`GetResourceRegistry`);
   - the access declarations of the old `IPassBuilder` (`Read`, `Write`, `SetColorTarget`,
     `SetDepthTarget`, `SetDisabledOutput`) to a new `ISetupContext`, which `AddPass` hands to
     `Setup`.

   `IResourceRegistry` keeps only its original role: persistent resources and their cross-frame
   states, the plan cache, heaps and pools, the framebuffer and binding caches, fences and
   retirement. `IGpuPass` keeps its per-use `void* data`: `Setup(ISetupContext*, void* data)`,
   `Prepare(IPrepareContext*, void* data)`, `Execute(IPassContext*, const void* data)`, and use data
   stays in the graph's frame arena (13.2). The review wrote `SetUp`, `IResourceRegistery` and
   `GetPersistant*`; the doc's existing spellings `Setup`, `IResourceRegistry` and `GetPersistent*`
   are kept.

   Two follow-ups on 2026-11-05 shaped this:
   - The first withdrew the pass keeping its own data (with use records found by a `GetPassId`),
     dropped the old rule 3.2.4, "data and operations are separate objects", as a principle of this
     design, and freed the `IPassBuilder` methods from having to go to `IRenderGraph`.
   - The second moved resource creation and importing from the registry to the graph, introduced
     `ISetupContext`, and returned the registry to its original role.

   Consequences:
   - **Ids belong to the graph again** (5.1). The graph is reused across frames and reuses indices,
     so versions come from a counter in the graph that `Reset` never clears, and ids kept from an
     earlier frame fail the stale-id check.
   - **`Finish` is gone.** `Compile` freezes the graph until its next `Reset`, and the plan-cache
     parameter of `Compile` is gone because the graph reaches its registry.
   - **The setup context is the open pass** (12). It is valid only during `Setup`; using it later
     is a validation error.
   - **One graph per registry** (12). The registry no longer holds frame-scoped records, but it
     still keeps one graph's persistent states, plan instances and retirement.
   - **Kept although the review did not list it:** `IGpuPass::OnResourcesReleased`. `Prepare` and
     `Execute` return `FRESULT`.

### 14.10 Comparison with Unity RenderGraph (decided 2026-11-05)

Comparing the interfaces with Unity's RenderGraph (Unity 6 Core RP) and Filament's `Blackboard` led to
four additions:

1. **Frame data is trivially destructible** (12, gap 1). The arena never ran destructors on per-use
   data. `NewFrameData<T>` enforces the rule; the lambda helper is the one arena object that is
   destroyed (12.1).
2. **Explicit-barrier scopes around Native bodies** (8.2, 9.1, gap 2). This is the counterpart of
   Unity's restricted command buffers: in validation builds, a Native body cannot change resource
   states behind the plan.
3. **Pass-local transients** on `ISetupContext` (5.2, 12, option 1), after Unity's
   `CreateTransientTexture`. A pass's internal scratch is aliased and pooled by the graph without
   appearing in its `AddToGraph` signature.
4. **A typed blackboard**, `FrameData` (12.2, option 2), after URP's `ContextContainer`. It is keyed
   by type rather than by string, which is where it departs from Filament's `Blackboard`.

Not adopted: a setup interface per pass kind (Unity's `IRasterRenderGraphBuilder` and its siblings).
One `ISetupContext`, with misuse reported by `Compile` with the pass name, keeps the ABI smaller.

### 14.11 Comparison with Filament's FrameGraph (decided 2026-11-05)

1. **Compile and execute are methods of `IRenderGraph`** (4, 12), as Filament's `compile()` and
   `execute()` are methods of `FrameGraph`.
   - `IRenderGraphCompiler`, `IRenderGraphExecutor`, `CreateRenderGraphCompiler` and
     `CreateRenderGraphExecutor` are gone. `IRenderGraph::Compile(profile, options, &plan)` and
     `IRenderGraph::Execute(plan, desc)` replace them.
   - Once rule 3.2.4 was dropped, separate operation objects bought nothing. Being device-free comes
     from a registry created without a device, and plan caching from the separate
     `ICompiledRenderGraph`.
   - Inside `src/render`, the compiler and the executor remain separate concrete classes.
2. **The plan cache must pay for itself** (7.7, 10.3). Filament recompiles every frame.
   `maxCachedPlans = 0` is the no-cache baseline, its frame cost is reported beside the cache-hit
   cost, and the cache is kept or removed on those numbers after step 5.

Not adopted: templated resource types (Filament's `RESOURCE` concept), because every resource here is
an nvrhi texture or buffer and templates cannot cross the COM ABI. Still open from the same
comparison: `[[nodiscard]]` on the declaration calls that return a new version, `desc.debugName` as
the resource name in diagnostics, the capture rule for lambda passes, and resource forwarding.

### 14.12 Comparison with AMD RPS (decided 2026-11-05)

1. **N-layer histories** (5.2, 12), after RPS's temporal resources. `GetHistory(name, desc,
   layerCount, ids)` replaces the virtual `GetHistoryPair`, which becomes an inline two-layer
   wrapper. Layer 0 is the only writable layer, and `IsNewAllocation` is reported per layer.
2. **The compiler is an internal phase list** (7, 11.4). The verifier, the dumps and the
   plan-changing debug switches are phases in that list. Unlike RPS's `RpsRenderGraphPhaseInfo`,
   the list is not part of the ABI.

Also confirmed by the comparison, with no change: the split between pass objects and per-use data
(RPS's `pUserContext` plus node arguments); access declarations made in `Setup` rather than in a
static node signature; and the graph owning submission, which the queued-wait rule (6.8) needs.

Section 2.3 says RPS has no aliasing barrier. That holds for RPS's legacy D3D12 path, which has no
`ALIASING` barrier and initialises placed resources with a discard instead. RPS's enhanced path does
deactivate aliased resources, in the same form as 6.7. 2.3 is frozen, so the nuance is recorded here.

## 15. Implementation steps and exit criteria

| Step | Content | Exit criterion |
| --- | --- | --- |
| 0 | Rebase aggregate `rdg` onto `main`, then `rdg` branches per 14.1; mark the old donut record superseded; nvrhi ADR for section 8 (next number after 0014) | All four repositories build at their starting points; the ethereal-dev ctest matrix (45/45) unchanged |
| 1 | nvrhi: `IResource` with `queryHeapBinding`; `SubresourceRegion`; `ResourceBarrier` + `barriers` on D3D12 (legacy, enhanced), Vulkan, D3D11, CUDA; checked Vulkan `bind*Memory`; `IFence`, `submit` and `waitFences` on all four, with validation-layer wrappers; `setExplicitBarrierScope` (validation layer only); check of CUDA stream memory operations | nvrhi tests per backend: combined depth-read layouts, plane-masked transitions, split pairs, aliasing (including byte-overlap validation and the enhanced alias form of 6.7), discard, release/acquire, fence ordering across queues (including CUDA streams around deferred replay), the CPU wait table of 8.3.1 (poll, finite, infinite), and a state call inside an explicit-barrier scope reported by the validation layer. `cuda-tests` and the interop tests unchanged. Clean under debug layers, GBV, sync validation and Compute Sanitizer. Installed-consumer tests pass after the full rebuild (8.4) |
| 2 | donut and samples: the `app::IAppLayer` rename (3.3), in one commit per repository | All samples build on every backend they built on before, the GVDB CUDA samples included; the sample runs are unchanged |
| 3 | `RenderGraph*` core: graph with frame arena, `NewFrameData` and setup context (pass-local transients included), compiler phases 1-7 as an internal phase list (7) with queue legality, frame boundary (6.12) and enable masks (13.5), profiles for all four APIs, verifier, JSON dump, `rdg_bench`, header-hygiene test and abi_lint | Verifier passes a device-free corpus (≥ 40 graphs × 4 profiles), including two-frame and plan-switch replays; golden barrier lists for the 6.11 frame, with and without async SSAO; compile and cache-hit budgets of 10.3 met, with the no-cache frame cost reported beside them |
| 4 | Executor (Native with explicit-barrier scopes, Tracked, Restore), `Prepare` phase, registry (persistent resources and N-layer histories, plan cache with bound, pooled tier, fences, `IEventQuery` fallback, retirement), command-list pool, debug switches (11.4) | Headless compute graph on D3D11, D3D12, Vulkan and CUDA with clean validation; zero allocations and zero `create*` calls per steady-state frame; a three-layer history rotates correctly and reports `IsNewAllocation` per layer; `SkipAliasingBarriers` makes the aliasing test fail |
| 5 | `IGpuPass` on every donut pass; `AddToGraph` for DeferredLighting, GBuffer, Forward, Depth/Shadow, Sky, Blit, ToneMapping, TAA, SSAO, Bloom, MipMapGen; `deferred_shading_rdg` and `variable_shading_rdg`; deterministic options and `ab_compare.py`; visualizer and timers; `FrameData` (12.2) used by `RenderGraphLayer` | Images match the originals pixel for pixel on D3D12, Vulkan and D3D11; 120 Debug frames with zero validation messages, with the layer confirmed loaded; barrier, CPU and GPU budgets of 10.3 met; frame cost with and without the plan cache reported, and the cache kept or removed on those numbers (7.7); immediate entry points unchanged for the other samples |
| 6 | Placed tier on D3D12 (opt-in, probe, estimate), async SSAO, split barriers, `async_compute_rdg` | Memory budget of 10.3 met on the bloom/SSAO graph; GPU-time budget met; sync validation clean, including across the frame boundary; each feature measured on and off; Vulkan ownership transfers kept or replaced by the `CONCURRENT` fallback, on measurements (6.8) |
| 7 | Parallel segment recording, with the donut prerequisites of 10.1 | Executor and parallel-recording budgets met; `BindingCache` and `BlitTexture` concurrency tests pass |
