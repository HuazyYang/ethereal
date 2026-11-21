# Entity component system (ECS) for donut: design

- Status: Accepted (2026-11-21)
- Date: 2026-11-12; revised 2026-11-18 after the first review; decisions settled 2026-11-21
- Scope: a data-oriented runtime store under `donut::engine::SceneGraph`, the scene graph rebuilt as an API
  over that store, and the contracts through which rendering and simulation services consume its data
- Baseline: donut `ethereal-dev` at `4f4b31c`, nvrhi `ethereal-dev` (header version 28), aggregate `main` at
  `264ac18`. Render integration targets the render graph of `docs/rdg-design.md` on the `rdg` branches
  (accepted 2026-11-05, not merged to `main`).
- Decision record: [ADR 0004](adr/0004-ecs-under-the-scene-graph.md)

This document fixes the architecture, the data model, how the scene graph sits on the world, the scheduling
model and the service contracts, and records the decisions made in review (section 13). Interfaces in
section 9 are sketches: each header is reviewed on its own before it is implemented.

Revision 2 folds in the first review:
- **No data bridge.** The scene graph and the ECS are not two representations kept in sync. The world is the
  only store; `SceneGraphNode` and the leaves are handles that read and write its columns. The change
  journal, the bakers, write-back, mirror mode and pull-through of revision 1 are gone (sections 3 and 5).
  An object outside any graph keeps its state in a record until it is attached (5.3).
- **The core is part of `donut_engine`**, as flat files in the engine directory (3.2). D1 is decided.
- Consequences: the phases `SceneSync` and `SceneWriteBack` are removed (6.3). Migration step E3 replaces the
  node storage in one step and is verified against dumps from a baseline build (12). D12 and D15 are
  withdrawn, and D16-D20 are new (13).

Revision 3 settles every open decision (13.2); each took its recommendation.

## 1. Requirements

| # | Requirement | What it means here |
| --- | --- | --- |
| R1 | The scene graph stays the authoring API | `SceneGraph`, `SceneGraphNode`, `SceneGraphLeaf`, `Material`, `MeshInfo`, the JSON and glTF importers and the COM object model stay. Samples that use the public `SceneGraph`/`Scene` API keep building and keep producing the same images through the migration (5.7 lists the exact surface). |
| R2 | An SoA runtime dataset | Entities live in archetype tables split into fixed-size chunks; each component is a contiguous column. Iteration is linear, SIMD-friendly and parallel by chunk. Columns can be uploaded to the GPU in place. |
| R3 | One store, no bridge | The scene graph is an API over the world. Each item of scene state has exactly one home, so nothing is copied, translated or written back between a scene-graph object and the world. What systems compute (world transforms, bounds, simulated poses) is what the scene-graph getters return. |
| R4 | Inputs for services | Rendering receives an immutable per-frame snapshot plus persistent GPU buffers with stable slots, and builds on the render graph. Simulation domains (ethereal-phys, the MotrixSim C SDK, SPH, GVDB) receive batched, index-addressed views, lifetime events and a fixed-step clock, and write their results back. |
| R5 | Parallel and deterministic | Systems declare what they read and write; the scheduler runs non-conflicting systems in parallel. Structural changes inside phases are deferred and played back in a defined order. The same inputs give a bit-identical world on 1 or N threads. Differential simulation testing depends on this. |
| R6 | Production quality | Scale targets in section 10. No heap allocation in steady state. Uploads and simulation exchange touch only what changed. Reflection-driven inspector, statistics and snapshot/restore. |
| R7 | The COM ABI rules where modules meet | Interfaces implemented by other modules (simulation DLLs) follow `ethereal-nvrhi/doc/com-interface-abi.md`. The per-entity hot path is header-only code over plain memory, with no virtual call per entity. |
| R8 | Incremental migration | Every step builds, runs the samples and is compared A/B against a baseline build of `main` (sections 11.2 and 12). |

Non-goals:
- a gameplay scripting layer, networking and replication (the design must not prevent them);
- an editor; USD;
- replacing the internal storage of simulation engines. They keep their own SoA state; the ECS addresses
  it by index (section 8);
- an ECS that lives on the GPU. Columns are mirrored to the GPU; the world itself is CPU memory.

## 2. Facts the design is built on

### 2.1 donut's scene today

Verified against `ethereal-donut` at `4f4b31c`.

| Area | What the code does | Consequence for this design |
| --- | --- | --- |
| Node storage (`include/donut/engine/SceneGraph.h`) | Each `SceneGraphNode` is a reference-counted heap object with an owning first-child/next-sibling chain. It stores local, global and previous transforms in double precision, float copies of the global and previous global transforms, TRS components and a world bounding box: about 580 bytes of transform and bounds state per node, before links, name, object header and the leaf object. | The graph is a good authoring API and a poor iteration structure. The node's state moves into columns and the node object becomes a handle (5.2). Runtime-only entities (instances, debris, particles) need no node at all. |
| Construction and ownership (`SceneGraph.cpp`, `GltfImporter.cpp`, `SceneImporterImpl.cpp`, `Scene.cpp`) | Nodes and leaves are created free-standing (`MAKE_RC_OBJ_PTR(SceneGraphNode)`: 20 sites in donut including 2 in tests, 1 in the samples) and linked into orphaned subgraphs. Importers build whole orphaned subgraphs off the main thread and attach them with `SetRootNode`. A parent owns its children; a child that is still referenced outlives a destroyed parent as the root of its own subgraph (`~SceneGraphNode`). `Attach` adopts an orphaned subgraph and deep-copies a subgraph that already belongs to a graph. | An object outside any graph has no world, so it keeps its state in a record until it is attached (5.3). Ownership rules stay as they are. |
| Leaf data | Lights and cameras expose public fields (`color`, `intensity`, `range`, `verticalFov`, `zNear`, `shadowMap`, ...) that donut and the samples read and write directly, in about 35 files; `app/UserInterfaceUtils.cpp` hands their addresses to ImGui (`&light.intensity`). `SkinnedMeshInstance` exposes `joints` and its GPU objects. `MeshInstance` has accessors only. | Leaf state is split by scale: columns for what is iterated at scale, the leaf object for low-count parameters (4.11, D16). |
| Refresh (`src/engine/SceneGraph.cpp`, `SceneGraph::Refresh`) | One single-threaded pre-order walk through pointers. Dirty flags select subtrees. Every visited node copies its transforms into the previous slots; bounds are unioned up the tree; content flags are recomputed. | Transform propagation and bounds become parallel systems over columns (6.3, 4.7). |
| Index assignment (`SceneGraph::Refresh`, structure-change branch) | On any structural change every instance index, geometry-instance index, geometry index, mesh index and material ID is renumbered. Meshes and materials are numbered in the iteration order of an `unordered_map` keyed by `AutoPtr`, whose hash is the object address (`nvrhi/core/autoptr.h`). | GPU-visible indices are neither stable nor deterministic between runs. Stable slots (4.8, 7.2) fix both. |
| Leaf registration (`SceneGraph::RegisterLeaf`, `UnregisterLeaf`) | A `query_cast` chain per leaf; flat vectors of `AutoPtr`; removal is `std::find` plus `erase`. The two functions are protected virtuals, overridden by `GVDBSceneGraph` (samples) and `PhysSceneGraph` (ethereal-phys). **Defect:** `UnregisterLeaf` returns from the `MeshInstance` branch before it reaches the `SkinnedMeshInstance` branch, so a detached skinned instance stays in `m_SkinnedMeshInstances` (and keeps being skinned). | Registration becomes an observer on the leaf-object component, which still calls the virtuals (5.5). The defect should be fixed on its own, independently of this work. |
| GPU buffers (`src/engine/Scene.cpp`, `Scene::RefreshBuffers`) | If any transform changed, every instance's `InstanceData` is rebuilt and the whole instance buffer is written. Every material is visited every frame to poll its `dirty` flag. Skinning writes joint matrices and dispatches per instance. | Uploads follow change versions at chunk granularity (7.2). |
| Draw strategies (`src/render/DrawStrategy.cpp`) | `InstancedOpaqueDrawStrategy` and `TransparentDrawStrategy` walk the graph per view and `query_cast` each leaf. `DrawItem` holds raw pointers to `MeshInstance`, `MeshInfo`, `MeshGeometry`, `Material`, `BufferGroup`. | Visibility and draw-packet generation become queries (7.3); the strategies become adapters. |
| GPU layout (`include/donut/shaders/bindless.h`) | `InstanceData` is 112 bytes: flags, first geometry-instance index, first geometry index, geometry count, `float3x4` transform and previous transform. | Kept unchanged at first, so shaders do not change during the migration. |
| Extensions | Samples add leaves with private content-flag bits and walk the graph to find them (`SPHFluidInstance`, `SceneContentFlags(0x200)`, `collectFluidInstances` in `ethereal-samples/src/gvdb_samples/sph_fluid_pool`; `GVDBScene.h`). ethereal-phys subclasses `SceneGraph` (`PhysSceneGraph`, four leaf types) and drives the engine through `PhysSceneService::SyncToPhysics` / `Step` / `SyncFromPhysics`. | Every extension re-implements registration and synchronisation. Leaf columns, observers and simulation domains (4.11, 5.5, 8) give them one mechanism. |
| Threading (`include/donut/engine/ThreadPool.h`) | A `std::function` queue with `WaitForTasks`; no dependencies, no work stealing. The RDG work adds a worker pool for parallel recording. | A job system with dependency counters is needed (decision D10). |
| API footprint | In `ethereal-samples`: `GetMeshInstances` in 7 files, `GetLights` 7, `Refresh(` 9, `GetLocalToWorldTransform` and `GetLocalToWorldTransformFloat` 9 each, `SceneGraphWalker` 3, `GetInstanceIndex` 5, `GetInstanceBuffer`/`GetGeometryBuffer` 4 each, subgraph content flags 2, `GetGlobalBoundingBox` 1. `GetPrev*Transform*` and `GetDirtyFlags` are used only inside donut. | The compatibility surface of 5.7 is small enough to keep exactly; the previous-transform getters can go. |

### 2.2 Constraints from the rest of the tree

- **ABI** (`ethereal-nvrhi/doc/com-interface-abi.md`). Across a module boundary: no class, struct or union by
  value in a virtual signature (R1), so ids are `enum class` integers, as the render graph's `ResourceId` is;
  `noexcept` everywhere and `FRESULT` errors; no `std::` types in public headers; callbacks are interfaces or C
  function pointers; no overloaded virtual names; out parameters last. `SceneGraphLeaf` and its subclasses are
  implementation classes, so anything that takes them is module-private (ethereal-phys already keeps its
  scene integration in a static library for this reason).
- **Function design**: raw `T*` parameters, never `nvrhi::AutoPtr<T>` parameters; returning `AutoPtr` is fine.
- **Data and operations are separate objects** for new subsystems: the world holds data; the scene graph's
  objects, systems, the scheduler and services operate on it.
- **Placement**: new donut code goes into the existing library and folder it belongs to, as flat files. The
  render graph set the precedent: `RenderGraph*` files in `render/`, no subfolder (rdg design 14.6).
- **Render graph** (`rdg` branches): every pass is an `IGpuPass` with `Setup(ISetupContext*, void*)`,
  `Prepare(IPrepareContext*, void*)` and `Execute(IPassContext*, const void*)`; per-frame data lives in the
  graph's arena (`NewFrameData<T>`, trivially destructible) and in the typed `FrameData` blackboard; persistent
  buffers enter a frame through `ImportBuffer`.
- **Simulation engines own their state.** ethereal-phys keeps particles and shapes in nvrhi buffers and runs on
  the graphics queue for now. The MotrixSim work defines a versioned C ABI with opaque handles, keeps the
  original engine as an oracle and validates replacements by replay; it needs deterministic inputs. SPH and
  GVDB keep their data on the GPU.

### 2.3 What the references teach

| Reference | Mechanism | Taken | Not taken |
| --- | --- | --- | --- |
| Unity Entities 1.x [1][2][3] | Archetypes; 16 KiB chunks with SoA columns; per-chunk, per-component change versions; enableable components; shared and chunk components; `EntityCommandBuffer` with sort keys for parallel writers; baking of authoring GameObjects into entities with `TransformUsageFlags`; Entities Graphics uploading changed chunks into a persistent buffer for `BatchRendererGroup`. | Chunks and change versions; enableable bits; command-buffer sort keys for determinism; changed-chunk uploads. | Baking: a second representation translated from the authoring objects. Here the authoring API reads and writes the runtime store directly. Shared components as the default batching key (fragmentation, 4.4). Managed components as a general escape hatch (only the leaf-object reference of 4.11). |
| Bevy 0.14-0.16 [4][5] | Table storage plus sparse-set storage chosen per component; change ticks per row; `Commands`; schedules, system sets, ambiguity detection; component hooks and observers (0.14); required components (0.15); `ChildOf`/`Children` relationships (0.16); bundles of component values that exist before they are spawned; a separate render world filled by an extract schedule, then prepare/queue/render phases, optionally pipelined with the next frame's simulation. | Two storage kinds; ambiguity detection; hooks/observers for engine-object lifetime; required components (a mesh instance always gets bounds); bundles as the state of objects outside a world (5.3); extraction into an immutable snapshot and optional pipelining. | A second full `World` for rendering: a frame-arena snapshot plus a persistent GPU scene is cheaper here (D8). Per-row ticks everywhere (D9). A contiguous `Children` list (D20). |
| flecs v4 [6][7] | Archetype tables; relationships as `(relation, target)` pairs; `ChildOf` hierarchies with breadth-first "cascade" iteration; `IsA` prefab inheritance; pipelines of phases; cached queries matched per table; observers; runtime reflection (meta) and a web explorer. | Phases; cached queries; runtime reflection for the inspector and serialisation; prefab instancing. | `ChildOf` as part of the table type: children of different parents land in different tables, which fragments storage when parents have few children (D5). General relationships stay out of the first version. |
| EnTT [8][9] | Sparse sets per component; owning groups that pack co-iterated components; construction/update/destruction signals. | Sparse sets for volatile tags and rare components. | Sparse sets as primary storage: multi-component iteration is linear only inside groups. |
| Unreal Engine Mass [10] | Fragments, tags, shared and chunk fragments; processors in execution groups; translators that copy between actor components and fragments in both directions; representation LOD switching between actors and instanced meshes. | Entities that have no OOP object at all (5.8). | Translators: they keep two representations in sync, which R3 rules out. |
| NVIDIA Omniverse Fabric / USDRT [11] | A hierarchical OOP scene (USD) mirrored into buckets of prims with the same attribute set, stored as columns, mirrored to CUDA memory with per-device validity, with change tracking; renderer and physics read the columns; world transforms computed in the runtime layer. USDRT offers a USD-shaped API whose prims are handles that read and write Fabric directly. | The USDRT model: the familiar hierarchical API stays, its objects are handles over a columnar store, services read the columns, GPU mirrors carry a validity version. | Fabric's population from a separate USD stage, which is a bridge. |
| Pixar Hydra [12] | Scene delegates and a render index; a change tracker with per-prim dirty bits; sync pulls only dirty data; scene indices in Hydra 2.0. | Consumers pull only what changed (chunk versions, 4.5). | A delegate that copies from the authoring scene. |
| Filament [13], Bitsquid/Stingray [14] | Integer entities with generations; one component manager per subsystem with SoA instance data (`TransformManager`, `RenderableManager`); swap-remove packed arrays; the public API hands out instance handles into the manager's arrays. | Generational ids; API objects as handles into SoA storage; services keep their own SoA where they must (GPU scene, simulation). | One store per manager as the general model: joins across managers need an indirection per entity. |
| UE5 GPU Scene, Unity BRG [3][15] | A persistent GPU primitive/instance buffer with stable slots and scatter uploads of dirty entries. | Stable GPU slots and scatter upload (7.2). | |
| PhysX 5 direct GPU API, MuJoCo `mjData` [16][17] | Simulation state exposed as flat, index-addressed arrays and batched get/set. | Simulation exchange through batched column views, not per-object calls (8.2). | |
| Overwatch (GDC 2017) [18] | Systems plus singleton components; deferred side effects. | World resources (4.9); deferral. | |

## 3. Architecture

### 3.1 Layers

```
 Scene-graph API (OOP, COM)   SceneGraph, SceneGraphNode, leaves, Material, MeshInfo, importers.  (donut_engine)
                              Attached objects are handles into the world; objects outside a graph
                              keep their state in records until they are attached.
        |  immediate column reads and writes; structural changes outside phases
        v
 Runtime data (SoA)           IWorld: entities, archetypes, chunks, columns, versions,           (donut_engine)
                              sparse sets, world resources, asset tables
        |  queries, column views
        v
 Operations                   IScheduler + ISystem in phases, observers, IJobSystem             (donut_engine)
        |
        +--> Render service   extract -> frame snapshot (RDG arena) -> GpuScene -> IGpuPass     (donut_render)
        +--> Simulation       ISimulationDomain: lifetime events, gather, step, scatter         (ethereal-phys,
                                                                                                 MotrixSim SDK,
                                                                                                 samples)
```

There is no layer between the scene-graph API and the runtime data. An attached node's transform is read and
written in the `LocalTransform` column; its world transform is the `WorldTransform` column that propagation
wrote.

### 3.2 Placement (decided in review)

- The ECS core is part of `donut_engine`. Its files sit flat in `include/donut/engine` and `src/engine`, with no
  subfolder and no separate target. `donut-engine.cmake` globs that folder, so adding them needs no build
  change.
- Namespace `donut::engine`, like the rest of the library.
- The `Ecs*` files name no scene, render or simulation type, as the render graph names no pass. A separate
  target would have enforced this; now review enforces it, and so does a check that the `Ecs*` headers
  include only nvrhi core and `donut/core` headers.
- Planned files:

| File | Content |
| --- | --- |
| `EcsTypes.h` | `Entity`, `ComponentId`, `ComponentTypeDesc`, component flags, field reflection, `DONUT_ECS_COMPONENT` |
| `EcsWorld.h`, `EcsWorld.cpp` | `IWorld`: registry, entity table, archetypes, chunks, sparse sets, dynamic buffers, resources, snapshot |
| `EcsQuery.h`, `EcsQuery.cpp` | `IQuery`, `ChunkView`, and the header-only typed layer (`Query<...>`, `Read<T>`, `Write<T>`, ...) |
| `EcsCommandBuffer.h`, `EcsCommandBuffer.cpp` | `ICommandBuffer`, sorted playback, batched archetype moves |
| `EcsScheduler.h`, `EcsScheduler.cpp` | `ISystem`, `IScheduler`, phases, observers, ambiguity detection |
| `EcsSimulation.h` | `ISimulationDomain`, `ISimulationContext`, `ColumnView` |
| `JobSystem.h`, `JobSystem.cpp` | `IJobSystem`, next to `ThreadPool.h` (D10) |
| `AssetTables.h`, `AssetTables.cpp` | `MeshId`, `MaterialId`, `GeometryId`, `TextureId` and their tables (4.8) |
| `SceneComponents.h` | The scene graph's components: transforms, `Parent`, `SceneLinks`, `HierarchyDepth`, bounds, `SceneNode`, `LeafObject`, `MeshRef`, `RenderFlags` |
| `SceneGraph.h`, `SceneGraph.cpp` | Existing; nodes and leaves become handles (section 5) |
| `SceneSystems.cpp` | Transform propagation, bounds, and the scene graph's observers |

  In `donut_render`, flat in `render/`: `GpuScene.h/.cpp` and `RenderExtract.h/.cpp`.
- Simulation adapters live with their engines: an `ethereal_phys_ecs` static library next to
  `ethereal_phys_scene`; a MotrixSim domain in the motphys work; SPH and GVDB in the samples.

### 3.3 Rules

1. **One home per item of state.** Every item of scene state is stored in exactly one place: a world column, a
   leaf object (low-count leaf parameters, 4.11), or the record of an object that is in no graph (5.3). Nothing
   is copied between these places to be kept in sync. Values move between a record and a row when an object is
   attached or detached.
2. **One writer per component per phase.** The scene-graph API writes only outside phases (5.6). Within a frame,
   derived data (world transforms, bounds, visibility, GPU slots) is written by its system, and simulated data
   by its domain in its scatter step.
3. **Structural changes inside phases are deferred.** Systems record them in command buffers; playback happens
   at sync points in a defined order. Only exclusive systems change structure immediately. Outside phases (the
   scene-graph API, loading), structural changes are immediate.
4. **No virtual call per entity in systems.** Virtual calls happen per system, per chunk batch or per event
   batch. Per-entity code is inline header code over plain memory. The one exception is the leaf objects of
   low-count leaf types (lights, cameras), which their consumers call per leaf, as today (D16).
5. **Stable ids.** An `Entity` is valid until destroyed; a GPU slot, an asset id and a simulation body index are
   stable for the lifetime of what they name.
6. **Determinism.** Iteration order is chunk order; chunk order depends only on the order of structural
   changes, and those are applied in a defined order: playback sorted by (phase, system order, sort key), and
   pre-order for attached subgraphs. No order may depend on an address, a hash of an address or thread timing.
7. **Data and operations are separate.** `IWorld` is data with primitive accessors. Scene-graph objects are
   handles: they give the data an identity and an API, and own no copy of it. Everything that transforms data
   is a system, an observer or a service.

## 4. Data model

### 4.1 Entities

`enum class Entity : uint64_t`: index in the low 32 bits, generation in the high 32 bits; 0 is null and index 0 is
never handed out. The entity table holds, per index, the generation and the location (archetype, chunk, row).
Destroying an entity bumps the generation and returns the index to a FIFO free list, so a stale `Entity` fails
`IsAlive` and is not reused soon. 64 bits are chosen over Filament-style 32-bit ids so that generations never
wrap in long simulations and so that serialised references survive (D3).

### 4.2 Component types

A component type is registered once per world from a `ComponentTypeDesc`: a GUID (cross-module identity, the
same `nvrhi::GUID` the IIDs use), a name, size, alignment, flags, lifecycle hooks as C function pointers (null
means trivial), and reflected fields. The world returns a dense `enum class ComponentId : uint32_t`; ids are
per world and in registration order, so they are deterministic when registration is.

A header-only macro gives C++ types their descriptor:

```cpp
struct LocalTransform { dm::double3 translation; dm::dquat rotation; dm::double3 scaling; };
DONUT_ECS_COMPONENT(LocalTransform, "<guid>", DONUT_ECS_FIELDS(translation, rotation, scaling));
```

Flags:

| Flag | Meaning |
| --- | --- |
| `Tag` | Zero-size; presence only. |
| `Sparse` | Stored in a sparse set; adding or removing it does not move the entity between archetypes. For volatile markers (selection, pending upload, debug). |
| `Shared` | One value per chunk; the value partitions chunks. For low-cardinality partitions only (4.4). |
| `Chunk` | One value per chunk, not a partition key (chunk bounds). |
| `Enableable` | A per-row enabled bit; toggling is not a structural change. |
| `Buffer` | A dynamic buffer: inline capacity in the chunk, overflow on the heap. |
| `Relocatable` | Can be moved with `memcpy`. Required for `GpuMirrored` and for simulation-visible components. || `GpuMirrored` | The render service mirrors the column (7.2). |
| `NoSerialize` | Skipped by snapshots (transient caches). |

Components should be plain data. A component may hold a COM reference if it registers
construct/destruct/relocate hooks: the scene graph's `SceneNode` and `LeafObject` (5.2) do, and so does the
`ISPHParticles*` of an SPH fluid. Such components cannot be `GpuMirrored` and are never handed to simulation
domains as raw columns (D14).

### 4.3 Storage

- **Archetypes.** An archetype is a sorted set of `ComponentId`s plus the values of its `Shared` components. It
  is found by hash and connected to neighbours by cached add/remove edges, so moving an entity between
  archetypes is a lookup, not a search.
- **Chunks.** Fixed-size blocks from a page allocator built on nvrhi's default allocator: 16 KiB, or 64 KiB for
  archetypes whose rows exceed 128 bytes, so that a chunk holds about 128 rows or more (D6). Layout inside a
  chunk: the `Entity` column, then each component column aligned to 64 bytes, then the enabled bitmasks, then
  the per-column change versions. Capacity per chunk is computed per archetype.
- **Removal** swaps the last row in, keeping chunks dense. Because structural changes are applied in a
  defined order (3.3.6), the resulting row order is deterministic.
- **Sparse sets** hold `Sparse` components: a dense array of values, a dense array of entities, and a paged
  sparse index. Queries can filter on them; iteration over them is a second, slower path.
- **Dynamic buffers** (`Buffer`) hold variable-length data: skin joints, material ranges.

### 4.4 Shared and chunk components

A shared component splits chunks by value. That makes per-chunk decisions free (a chunk is entirely in one
simulation domain or one scene layer) but fragments storage when the cardinality is high: ten thousand unique
meshes as a shared key give ten thousand mostly empty chunks. Therefore shared components are used only for
low-cardinality partitions (simulation domain, scene layer, hierarchy depth bucket, static/dynamic). Draws are
batched by sort keys at extraction (7.3), not by mesh/material chunks (D11).

Chunk components hold per-chunk aggregates; the first one is `ChunkWorldBounds`, the union of the world bounds
of a chunk's rows, used for chunk-level culling.

### 4.5 Change detection

The world keeps a version counter that advances each time a system runs. Each chunk stores, per column, the
version of the last write. Writing through a query that declared `Write` access stamps the column; reading never
does. Writes through the scene-graph API stamp it the same way (5.4). A query can filter on `Changed<T>` (column
version newer than the system's last run) and `Added<T>` (chunk-level structural version), at chunk granularity,
so a static scene costs one comparison per chunk.

Chunk granularity over-reports: one moved entity marks its whole chunk. The GPU upload and simulation exchange
therefore treat a changed chunk as a set of candidate rows and copy all of them, a few KiB per changed chunk and
column. If measurement (10.2) shows this is too coarse, components flagged `RowTracked` get a tick per row on
top of the chunk version (D9). That is a later addition; nothing in the first version depends on it.

### 4.6 Hierarchy

The scene graph's tree is stored in the world:
- `Parent { Entity }` on every entity that has a parent. Transform propagation uses it.
- `SceneLinks { Entity firstChild, lastChild, prevSibling, nextSibling }` (32 B) on scene-graph nodes: an
  intrusive, ordered child list. `GetChildren`, `GetNextSibling`, `SceneGraphWalker`, `Attach` (append) and
  `Detach` stay O(1) per step, as with today's pointer links (D20).
- `HierarchyDepth`, a shared component: 0 for roots and for entities without a parent, capped at 63; deeper
  entities take a slow path.

A runtime-only entity (5.8) may have a `Parent` without `SceneLinks`. It then follows its parent's transform
but is not a child in the scene-graph API. Entities without a hierarchy, which is the bulk of instanced and
simulated content, are depth 0 and never touch the hierarchy code.

Transform propagation runs depth level by depth level: each level is a parallel loop over the chunks of that
depth, reading the parent's `WorldTransform`, which the previous level finished. Alternatives are per-root
recursion in parallel over roots (Unity) and flecs-style pairs (D5).

### 4.7 Transforms, bounds and precision

| Component | Layout | Notes |
| --- | --- | --- |
| `LocalTransform` | `double3` translation, `dquat` rotation, `double3` scaling (80 B) | Written by `SceneGraphNode::SetTransform`, animation or scripts. A node that never set a transform has none, and its world transform is its parent's: today's `m_HasLocalTransform`. |
| `WorldTransform` | `dm::daffine3` (96 B) | Written by transform propagation, or by a simulation domain for entities it drives. |
| `TransformDriver` | `uint8_t`: `Authored`, `Animation`, `Simulation`, `Script` | Who may write `WorldTransform`; drives conflict handling (5.2). |
| `Static` | tag | Never moves once created: skipped by propagation, uploaded once. |
| `LocalBounds` | `box3` (24 B) | From the mesh, or from the leaf's `GetLocalBoundingBox` when the leaf is attached or invalidated. |
| `WorldBounds` | `box3` (24 B) | Computed by the bounds system. |
| `ChunkWorldBounds` | chunk component | Union of `WorldBounds` in the chunk. |

World transforms stay in double precision, as in `SceneGraphNode` today and as physics engines use; rendering
receives float transforms relative to a render origin, computed at extraction (7.1). The float transform that
`GetLocalToWorldTransformFloat` returns is converted on the call. Previous-frame transforms for motion vectors
are kept by the GPU scene (7.2), not as a component. The subgraph bounds that
`SceneGraphNode::GetGlobalBoundingBox` returns are computed on demand (5.7). A float-only archetype for very
large instance counts is an opt-in, added when a sample needs it (D4).

### 4.8 Assets

Meshes, geometries, materials and textures are not entities. They live in typed asset tables in
`donut_engine`, each a dense table with generational handles (`enum class MeshId : uint32_t`, `MaterialId`,
`GeometryId`, `TextureId`) and reference counts held by the components that use them. A row holds the
authoring object itself (`MeshInfo`, `Material`), its stable slot and its version. The object is the only CPU
home of its parameters; the GPU rows (`MaterialConstants`, `GeometryData`) are what the render service uploads
from it, like any GPU mirror (7.2). Slots are stable for the lifetime of the asset, so geometry and material
indices on the GPU no longer change when the structure changes, and they no longer depend on object addresses.

During the migration, the material table polls the public `dirty` flag of its materials, as
`Scene::RefreshBuffers` does today; the cost is linear in materials, not instances. A setter that marks the
row changed replaces the poll later.

### 4.9 World resources

Singletons keyed by GUID: `FrameTime`, `FixedStepState`, `RenderOrigin`, `ActiveViews`, the asset tables, the
`GpuScene`. Systems declare resource access the same way as component access.

### 4.10 Prefabs and instancing

`Instantiate(prefab, count, out)` copies a prefab entity's columns into `count` new rows of the same archetype in
one operation. The scene graph uses it when `Attach` copies a subgraph that already belongs to a graph (today's
deep copy, 5.3), and runtime systems use it for crowds, scatter and debris.

### 4.11 Leaf state: columns and leaf objects

A leaf's state lives either in columns or in the leaf object, never in both:
- **Columns** hold what systems iterate at scale. A leaf class declares its columns in a static
  `LeafTypeDesc` (D19); its accessors read and write them. `MeshInstance` is the main case.
- **The leaf object** stays the home of low-count parameters: the public fields of lights and cameras, the
  channels of `SceneGraphAnimation`, and the joints and GPU objects of `SkinnedMeshInstance`. Their consumers
  read them per leaf, as today.

Every attached leaf is referenced from its entity by `LeafObject { SceneGraphLeaf* }`, a strong reference with
hooks. It also gets one tag per class in its class chain (a `SpotLight` gets `LightLeaf` and `SpotLightLeaf`),
so queries select leaf kinds without casts. A leaf type that later needs scale (thousands of lights) moves its
parameters into columns, and the API change is limited to that type (D16).

## 5. The scene graph as an API over the world

### 5.1 Mapping

Every attached `SceneGraphNode` is one entity. donut allows one leaf per node, and the leaf's columns sit on the
same entity.

| Scene-graph object | Its entity |
| --- | --- |
| node `Car`, no leaf, no transform set | `SceneNode`, `SceneLinks`, `WorldTransform`, depth 0 |
| node `Body` with `MeshInstance(mesh M)` | `SceneNode`, `SceneLinks`, `Parent(Car)`, `LocalTransform`, `WorldTransform`, `LeafObject`, `MeshInstanceLeaf`, `MeshRef(M)`, `RenderFlags` (from M's material domains), `LocalBounds`, `WorldBounds`, depth 1; the GPU-scene observer adds `GpuInstanceSlot` |
| node with `SkinnedMeshInstance` | as above, plus `SkinnedMeshInstanceLeaf` and `SkinnedMesh { prototype MeshId, output MeshId }`; the joints stay in the leaf object |
| node with `PointLight` | node components, `LeafObject`, `LightLeaf`, `PointLightLeaf`; color, intensity, radius and range stay in the leaf object |
| node with `PerspectiveCamera` | node components, `LeafObject`, `CameraLeaf`, `PerspectiveCameraLeaf` |
| node with ethereal-phys `PhysShapeLeaf` | node components, `LeafObject`, `PhysShapeRef { domain, shape index }` (written by the domain's observer), `TransformDriver = Authored` (the shape follows the node) |
| node with `SPHFluidInstance` | node components, `LeafObject`, `SphFluidRef` (holds `ISPHParticles*`), `SphRenderAttributes`; bounds from the domain's readback |
| `Material`, `MeshInfo` | a row in the material or mesh table (4.8) |

### 5.2 Nodes and leaves are handles

A `SceneGraphNode` holds its graph (weak), its `Entity`, its name, and a record pointer that is set only while
the node is in no graph (5.3). That is about 64 bytes, against about 700 today. The name stays in the object
because only path lookups and UI read it.

- **Reads.** Getters resolve the entity to its row through the entity table and the archetype's cached column
  offsets. Getters of derived state (`GetLocalToWorldTransform`, `GetLocalToWorldTransformFloat`,
  `GetGlobalBoundingBox`) and of TRS return by value. Callers that copy the result or bind it to a
  `const&` compile unchanged, and no caller can keep a reference into a chunk that a structural change moves.
- **Writes.** `SetTransform`, `SetTranslation`, `SetRotation` and `SetScaling` write the `LocalTransform` column
  through `GetComponentForWrite`, which stamps the chunk's column version. The first `SetTransform` on a node
  without a transform adds the component (a structural change, allowed outside phases).
- **Structure.** `GetParent`, `GetChildren`, `GetFirstChild`, `GetNextSibling` and the walker read `Parent` and
  `SceneLinks`, and map entities back to node objects through `SceneNode { SceneGraphNode* }`.
- **Leaves.** A leaf finds its entity through its node. Columnar leaves read and write their columns with the
  same helper the node uses (9.2); other leaves keep their fields.
- **Simulation-driven entities.** When `SetTransform` targets an entity whose `TransformDriver` is
  `Simulation`, the write is not applied to the pose. It becomes a teleport command for the owning domain,
  which applies it at its next step. Animation-driven entities are handled the same way by the animation
  system.

### 5.3 Objects outside a graph

An object that is in no graph has no world, so its columnar state lives in an *orphan record* that the object
owns. The record is a small, type-erased list of component values keyed by component GUID, like a Bevy bundle.
An orphaned node's record also holds its leaf and the references to its children. Importers therefore build
orphaned subgraphs on worker threads without touching any world, as they do now.

- **Attach of an orphaned subgraph.** One pre-order pass creates the entities, batched per archetype, and moves
  the record values into the rows. It then releases the records and runs the leaf observers (5.5). The values
  move; the object keeps no copy. Pre-order creation makes entity indices and row order deterministic.
- **Values that name other things change form.** An asset reference is a `MeshInfo*` in a record and a `MeshId`
  in a row; an entity reference is a node object in a record and an `Entity` in a row. Attach resolves them,
  adding the mesh to the graph's mesh table as `RegisterLeaf` adds it to the `ResourceTracker` today. Detach
  reverses this. Snapshots remap entity references the same way (11.4).
- **Detach.** The subgraph's rows move back into records in pre-order and its entities are destroyed. The
  caller receives the subgraph's root, as today. The cost is proportional to the subgraph; today's `Detach`
  also walks it to unregister leaves.
- **Attach of a subgraph that is already in a graph** makes a deep copy, as today: new node objects, cloned leaf
  objects, and rows copied with `Instantiate` within one world or by GUID from another world.
- **Lifetime.** An attached entity holds its node object through `SceneNode` and its leaf through `LeafObject`.
  Both are strong references, in place of the parent's child list and `m_Leaf`. `Detach` hands the node's
  reference to the caller. When a graph is torn down, every node whose object is still referenced elsewhere is
  first detached into a record, so it outlives the graph as the root of its own subgraph. Today a referenced
  child outlives its destroyed parent in the same way. The same applies to referenced leaf objects.

Construction stays as it is: `MAKE_RC_OBJ_PTR(SceneGraphNode)`, free-standing leaves, `AttachLeafNode`,
`SetRootNode`. D17 records why records were chosen over creating every object in a world or a staging world
per importer.

### 5.4 Change tracking without a journal

API writes stamp column versions (5.2). Structural API calls (`Attach`, `Detach`, `SetLeaf`, a first
`SetTransform`) are immediate world operations and run their observers at once. Systems see both at their next
run through `Changed<T>` and `Added<T>`. No list of edits is kept anywhere.

Leaf-object parameters (lights, cameras) carry no versions; their consumers read them every frame, as today.
`InvalidateContent` and `SetProperty` mark the `LeafObject` column changed for consumers that want to know.
`HasPendingStructureChanges` and `HasPendingTransformChanges` are answered from the world's structural version
and the `LocalTransform` column versions.

The `DirtyFlags` of `SceneGraphNode` are removed in step E3 together with the node storage.

### 5.5 Leaf registration and extensions

The graph's observer on `LeafObject` (`OnAdd`, `OnRemove`) maintains the leaf vectors (`GetMeshInstances`,
`GetSkinnedMeshInstances`, `GetLights`, `GetCameras`, `GetAnimations`). It runs in playback or pre-order, so the
order of the vectors is deterministic. The observer still calls the virtual `RegisterLeaf` and
`UnregisterLeaf`, so `GVDBSceneGraph` and `PhysSceneGraph` keep working unchanged. New code uses component
observers and queries instead of subclassing the graph and walking it: `collectFluidInstances` becomes a query
over `SphFluidRef`. Removal is per component, so the class of defect in 2.1 cannot recur.

### 5.6 When the API may be used

The scene-graph API is used from one thread at a time, outside the scheduler's phases: between frames, during
loading, and from the application's update code. That matches what today's API already assumes. There,
structural changes are immediate. Inside a phase, systems use queries and command buffers. In Debug builds a
node or leaf object asserts if it writes the world while a phase runs. Orphaned subgraphs may be built on any
thread, because they touch no world.

### 5.7 Scene-graph API compatibility

| Current API | After the change |
| --- | --- |
| `SceneGraph::Refresh(frameIndex)` | Runs the phases `TransformPropagation` and `Bounds` (6.3). Index assignment is gone, because slots are stable and assigned by observers. |
| `Scene::RefreshBuffers` | Delegates to `GpuScene` (7.2). |
| `GetMeshInstances`, `GetSkinnedMeshInstances`, `GetLights`, `GetCameras`, `GetAnimations` | Still vectors of leaf objects, maintained by the observer of 5.5, in deterministic order. |
| `RegisterLeaf` / `UnregisterLeaf` overrides | Still called, from that observer. |
| `MeshInstance::GetInstanceIndex`, `GetGeometryInstanceIndex` | The stable `GpuInstanceSlot` and geometry-instance slot. |
| `GetLocalToWorldTransform`, `GetLocalToWorldTransformFloat`, `GetLocalToParentTransform`, `GetTranslation`, `GetRotation`, `GetScaling` | Read the columns and return by value. |
| `GetGlobalBoundingBox`, `GetSubgraphContentFlags` | Computed on demand over the subgraph and cached per node until the next structural or transform version. `GetLeafContentFlags` asks the leaf, as today. |
| `GetPrevLocalToWorldTransform*`, `GetPrevLocalToParentTransform`, `GetDirtyFlags`, `DirtyFlags` | Removed. Only donut used them; the motion-vector history lives in `GpuScene`. |
| `MAKE_RC_OBJ_PTR(SceneGraphNode)`, free-standing leaves, orphaned subgraphs | Unchanged (5.3). |
| `Attach`, `AttachLeafNode`, `Detach`, `SetRootNode`, `SetLeaf` | Same semantics: orphaned subgraphs move in, attached subgraphs are copied, `Detach` hands the root back. |
| `SceneGraphWalker`, `FindNode`, `GetPath` | Unchanged API; they walk `SceneLinks`. |
| `GetMeshes`, `GetMaterials` | The asset tables, with the same iteration shape, in slot order instead of hash order. |
| `SceneGraph::OnMeshAdded` and the other callbacks | Raised from asset-table observers. |
| Public leaf fields (lights, cameras, skinning) | Unchanged; they stay in the leaf objects (D16). |
| `Scene::GetInstanceBuffer`, `GetGeometryBuffer`, `GetMaterialBuffer` | The `GpuScene` buffers, same layouts. |

### 5.8 Runtime-only entities

Entities created by systems or services directly in the world have no node object: instanced scatter,
particles that spawn meshes, debris, crowd agents. They render and simulate like scene-graph entities but are
invisible to `SceneGraphWalker` and `GetMeshInstances`. This is where scale comes from. A dynamic mesh instance
costs about 250 bytes of columns (8 entity + 80 local + 96 world + 24 + 24 bounds + 4 mesh + 4 flags + 4 slot +
padding). A scene-graph node adds `SceneNode`, `SceneLinks` and `Parent` (48 B) plus its node and leaf
objects. Today a node carries about 580 bytes of transform and bounds state alone, before its leaf object.

## 6. Operations: queries, systems, scheduling

### 6.1 Queries

A query is created from terms: component, operator (`All`, `Any`, `Without`, `Changed`, `Added`, `Enabled`,
`Disabled`) and access (`Read`, `Write`). It is cached: the set of matching archetypes updates incrementally
when archetypes are created. Iteration hands out `ChunkView`s (entity column, one pointer per data term, row
count, enabled masks, chunk index). A header-only typed layer sits on top:

```cpp
Query<Read<LocalTransform>, Write<WorldTransform>, Without<Parent>> roots(world);
roots.ForEachChunk(ctx, [](const ChunkView& chunk, const LocalTransform* local, WorldTransform* world)
{
    for (uint32_t i = 0; i < chunk.count; ++i)
        world[i].value = ComposeAffine(local[i]);
});
roots.ParallelForChunks(ctx, /*chunksPerTask*/ 4, ...);
```

The term operator is `Without`, not `None`: X11 defines `None` as a macro, and donut builds on Linux.

In Debug builds a query checks that the running system declared the access it uses.

### 6.2 Systems

A system is an `ISystem` (or a lambda wrapped by a header-only helper, as with the render graph's lambda pass)
with a descriptor: name, phase, component and resource access, `runBefore`/`runAfter` constraints, an
exclusive flag (runs alone, may change structure immediately) and a main-thread flag. `Update` receives a
context with the world, the system's command buffer, the job system, the version at its last run, and the frame
time.

### 6.3 Phases

| # | Phase | Work | Sync point after |
| --- | --- | --- | --- |
| 1 | `BeginFrame` | time, input, view list, asset-table maintenance | |
| 2 | `PreSimulation` | animation sampling, scripts, simulation input gathering | |
| 3 | `FixedSimulation` | zero or more fixed steps per domain (8.4) | per step if a domain changes structure |
| 4 | `PostSimulation` | scatter results, interpolation | yes |
| 5 | `TransformPropagation` | local to world, by depth level | |
| 6 | `Bounds` | world bounds, chunk bounds | |
| 7 | `RenderExtract` | per view: visibility, draw packets, light and camera arrays into the frame snapshot | yes |
| 8 | `EndFrame` | deferred destruction, version advance, statistics | |

Revision 1's `SceneSync` (drain the journal, bake) and `SceneWriteBack` (mirror mode) have no work left: API
edits are already in the world when the frame starts, and getters read the columns that the systems wrote.
Applications add systems to these phases; new phases are allowed between them by name. An application that
does not run the scheduler calls `SceneGraph::Refresh`, which runs phases 5 and 6.

### 6.4 Scheduler

For each phase the scheduler builds a dependency graph from the declared accesses (a write conflicts with any
other access to the same component or resource) and the explicit constraints. Two conflicting systems without
an ordering constraint are an *ambiguity*: Debug builds report it, and a determinism test fails on it. The graph
is cached until a system is added, removed or enabled.

Execution uses a job system (`IJobSystem` in `donut_engine`, D10): fixed worker threads, work stealing,
dependency counters, `ParallelFor` with a deterministic split. The render graph's parallel recording becomes a
client of the same pool.

### 6.5 Command buffers

Each system gets a command buffer per worker thread. Every command carries a sort key: (phase, system order,
chunk index, row) for commands issued while iterating, or a key the caller supplies. At a sync point the buffers
are merged by key and played back; consecutive moves of entities between the same two archetypes are batched
into one column copy. `CreateEntities` returns placeholder entities that resolve at playback, as Unity's and
Bevy's deferred spawns do.

### 6.6 Observers

`OnAdd`, `OnRemove` and `OnSet` per component, delivered at playback, or at once for an immediate structural
change. They run single-threaded, in playback order and in batches per archetype. Observers may not change
structure directly; they receive a command buffer whose commands are played back before the sync point ends.
Observers maintain the scene graph's leaf vectors (5.5), allocate and free GPU slots, and create and destroy
bodies in simulation engines.

## 7. Render service

### 7.1 Flow

```
World --RenderExtract systems--> RenderSnapshot (RDG frame arena, immutable)
                                     |                        \
                                     v                         v
                              GpuScene upload pass       visibility + draw packets per view
                              (IGpuPass, copy/compute)   (CPU now; GPU culling later)
                                     |                         |
                                     +-----> geometry/lighting IGpuPasses (bindless instance/geometry/material)
```

The snapshot holds what the passes need for one frame as SoA arrays: per visible instance its GPU slot,
geometry range and sort key; per light its `LightConstants`; per view its constants; the render origin. It is
trivially destructible and allocated with `NewFrameData`, so it is released with the frame. Light constants
come from the light objects (`FillLightConstants`, one call per light) and the light entities' `WorldTransform`.

### 7.2 GPU scene

`GpuScene` owns the persistent instance, geometry and material buffers and a stable slot allocator per buffer
(free list; compaction only on request). An observer on `MeshRef` allocates an instance slot (`GpuInstanceSlot`)
and frees it on removal.

Each frame, the upload system walks the chunks whose `WorldTransform`, `MeshRef` or `RenderFlags` version is
newer than the last upload, writes their `InstanceData` rows (layout unchanged, 2.1) into an upload ring, and the
upload pass scatters them into the instance buffer with a compute shader. Before it overwrites a slot's
transform, the scatter kernel copies the old transform into `prevTransform`; slots updated in the previous
frame are visited once more so that their previous transform settles to the current one. That is today's
`PrevTransform` dirty-flag logic, moved to the GPU and limited to what changed.

Geometry and material rows come from the asset tables (4.8) with stable slots, so `firstGeometryIndex` and
`materialIndex` never need a global rewrite.

### 7.3 Visibility and draw packets

Per view: a chunk-level frustum test against `ChunkWorldBounds`, then a row-level test against `WorldBounds`,
over SIMD-friendly columns, in parallel by chunk. Visible geometry instances become draw packets, an SoA of
(64-bit sort key, instance slot, geometry slot, material slot, pass flags), radix-sorted per pass. The key
packs pass, material domain, pipeline state, material, mesh and depth.

`InstancedOpaqueDrawStrategy` and `TransparentDrawStrategy` become adapters that produce `DrawItem`s from
packets, so existing passes keep working; passes migrate to packets one by one. GPU-driven culling and indirect
draws come later; the data they need is already in the GPU scene.

### 7.4 Render graph integration

- The `GpuScene` buffers are persistent and imported with `ImportBuffer` each frame.
- The upload is an `IGpuPass` that writes the instance buffer; geometry passes read it.
- Skinning becomes an `IGpuPass` over a query of `SkinnedMesh` entities whose joints moved. The joint matrices
  come from the `WorldTransform` of the joint nodes, whose entities the instance's `joints` name through their
  node objects. The dispatch is per instance, as today.
- Light and camera arrays travel in the frame blackboard (`FrameData`).

### 7.5 Pipelining

The snapshot is immutable after `RenderExtract`, so the render graph can record frame N while the world runs
frame N+1, as in Bevy's pipelined rendering. The `GpuScene` upload ring is double-buffered for this. It is off by
default and is enabled only after the A/B steps pass. Pipelining requires the scene-graph API rule of 5.6 to
hold against the recording thread too: the snapshot, not the world, is what recording reads.

### 7.6 Render objects in scene data

`Light::shadowMap` and `DirectionalLight::perObjectShadows` put render objects into scene data. With the ECS the
render service owns shadow maps keyed by light entity, and the leaf fields become authoring hints that the
render service turns into `LightShadow { channel, cascade count, resolution }` (D13).

## 8. Simulation service

### 8.1 Domains

A simulation domain is an engine instance behind `ISimulationDomain` (sketch in 9). Its descriptor states the
fixed time step, substeps and step limit per frame, the components it reads (inputs) and writes (outputs) in the
same access terms as a system, where it runs (CPU, graphics queue, compute queue, CUDA) and whether it is
deterministic. The scheduler orders domains against systems from those accesses.

| Call | When | What it does |
| --- | --- | --- |
| `OnEntitiesAdded` / `OnEntitiesRemoved` | at playback or at an immediate structural change, from observers on the domain's components, batched per archetype | create or destroy engine objects; return engine indices, stored in components such as `SimBodyRef { domain, index }` |
| `GatherInputs` | `PreSimulation` | read changed authored inputs (kinematic targets, forces, parameters, teleports) through column views |
| `Step` | `FixedSimulation`, once per fixed step | advance the engine; GPU domains record into the provided command list |
| `ScatterOutputs` | `PostSimulation` | write poses and velocities into the domain's output columns |
| `CaptureState` / `RestoreState` | on request | write or read the engine state together with the world snapshot (11.4) |

The domain's components reach entities in two ways. Leaf types that belong to the domain declare them as
columns (4.11), so attaching such a leaf adds them. Runtime systems can also add them to runtime-only entities.

### 8.2 Column views and batched exchange

The exchange unit is a column view: base pointer, stride, row count, component id and version, per chunk. A
domain gets the views for its inputs and outputs and passes them to batched engine calls: a set-poses call of
the MotrixSim C ABI, PhysX's direct GPU API, or an upload into ethereal-phys buffers. The engine never sees an
entity; it sees index-addressed arrays, plus an index map that the domain maintains in its add/remove callbacks.
Because engine indices are assigned in a defined order (3.3.6), the mapping is deterministic.

### 8.3 GPU-resident simulation

ethereal-phys, SPH and GVDB keep their data in GPU buffers. The world holds handles (`PhysDomainRef`,
`SphFluidRef`, `GvdbVolumeRef`), parameters and the transforms of emitters, colliders and force fields. The
domain's output buffers enter the render graph as imports, and renderers read them directly. Bounds come from the
domain's readback (ethereal-phys already keeps bounds readback slots) with a frame of delay, into `WorldBounds`.

### 8.4 Time

`FixedStepState` holds an accumulator per domain. Each frame, `FixedSimulation` runs `floor(accumulated / dt)`
steps, up to the domain's limit, and stores the remainder fraction. Entities driven by a domain get an
interpolated `WorldTransform` from the last two simulated poses (`SimPose`, `SimPosePrevious`), so rendering is
smooth at any frame rate.

### 8.5 Determinism and differential testing

With rule 3.3.6, a domain sees the same entity order, the same input values and the same engine index
assignment on every run and at every thread count. That is what the MotrixSim work needs to replay one scene
against the original engine and a replacement, and what ethereal-phys's parity tests against FleX need when
they run inside a scene. `CaptureState`/`RestoreState` together with the world snapshot let a test rewind to the
first divergent step.

### 8.6 Other services

Picking and ray queries (a BVH over `WorldBounds`, rebuilt per changed chunk), audio emitters (donut has an
`AudioEngine`) and streaming fit the same pattern: components in, a service that reads columns, results out.
They are not designed here.

## 9. Interface sketch

### 9.1 ECS core

ABI surface in the `include/donut/engine/Ecs*.h` headers (IIDs are generated when the headers are written;
`FRESULT`, `nvrhi::GUID` and `nvrhi::IObject` come from nvrhi core):

```cpp
namespace donut::engine
{
    enum class Entity      : uint64_t { Null = 0 };          // index (low 32) | generation (high 32)
    enum class ComponentId : uint32_t { Invalid = 0xffffffffu };
    enum class SystemId    : uint32_t { Invalid = 0xffffffffu };

    enum class Access : uint8_t { Read, Write };
    enum class TermOp : uint8_t { All, Any, Without, Changed, Added, Enabled, Disabled };
    enum class Phase  : uint8_t { BeginFrame, PreSimulation, FixedSimulation, PostSimulation,
                                  TransformPropagation, Bounds, RenderExtract, EndFrame, Count };

    typedef void (*PFN_ComponentConstruct)(void* dst, uint32_t count);
    typedef void (*PFN_ComponentDestruct)(void* dst, uint32_t count);
    typedef void (*PFN_ComponentRelocate)(void* dst, void* src, uint32_t count);   // move + destroy source
    typedef void (*PFN_ComponentCopy)(void* dst, const void* src, uint32_t count);

    struct FieldDesc { const char* name; uint32_t offset; FieldType type; uint32_t arrayCount; };

    struct ComponentTypeDesc
    {
        nvrhi::GUID uuid;
        const char* name;
        uint32_t size;
        uint32_t alignment;
        ComponentFlags flags;
        uint32_t bufferInlineCapacity;          // Buffer components only
        PFN_ComponentConstruct construct;       // null: zero-fill
        PFN_ComponentDestruct destruct;         // null: trivial
        PFN_ComponentRelocate relocate;         // null: memcpy
        PFN_ComponentCopy copy;                 // null: memcpy
        const FieldDesc* fields;
        uint32_t fieldCount;
    };

    struct QueryTerm { ComponentId component; TermOp op; Access access; };
    struct QueryDesc { const QueryTerm* terms; uint32_t termCount; const char* debugName; };

    // One chunk as a query sees it. Valid until the next sync point.
    struct ChunkView
    {
        const Entity* entities;
        void* const* columns;          // one per data term, in term order; null for tags and absent Any terms
        const uint64_t* enabledMasks;  // one mask array per Enableable term        uint32_t count;
        uint32_t chunkIndex;           // stable within a frame; part of command sort keys
    };

    struct ColumnView { void* base; uint32_t stride; uint32_t count; ComponentId component; uint32_t version; };

    struct IQuery : nvrhi::IObject
    {
        virtual uint32_t GetChunkCount() noexcept = 0;
        virtual uint32_t GetChunks(uint32_t first, uint32_t sinceVersion, ChunkView* views, uint32_t capacity) noexcept = 0;
        virtual uint32_t CountEntities() noexcept = 0;
    };

    struct ICommandBuffer : nvrhi::IObject
    {
        virtual Entity CreateEntity(const ComponentId* components, uint32_t count, uint64_t sortKey) noexcept = 0;
        virtual void DestroyEntity(Entity entity, uint64_t sortKey) noexcept = 0;
        virtual void AddComponent(Entity entity, ComponentId component, const void* value, uint64_t sortKey) noexcept = 0;
        virtual void RemoveComponent(Entity entity, ComponentId component, uint64_t sortKey) noexcept = 0;
        virtual void SetComponent(Entity entity, ComponentId component, const void* value, uint64_t sortKey) noexcept = 0;
        virtual void Instantiate(Entity prefab, uint32_t count, uint64_t sortKey, Entity* outEntities) noexcept = 0;
    };

    struct IWorld : nvrhi::IObject
    {
        virtual nvrhi::FRESULT RegisterComponent(const ComponentTypeDesc& desc, ComponentId& outId) noexcept = 0;
        virtual ComponentId FindComponent(const nvrhi::GUID& uuid) noexcept = 0;

        // Immediate structural changes: outside phases, or from an exclusive system.
        virtual nvrhi::FRESULT CreateEntities(const ComponentId* components, uint32_t componentCount,
                                              uint32_t entityCount, Entity* outEntities) noexcept = 0;
        virtual nvrhi::FRESULT DestroyEntities(const Entity* entities, uint32_t count) noexcept = 0;
        virtual nvrhi::FRESULT AddComponent(Entity entity, ComponentId component, const void* value) noexcept = 0;
        virtual nvrhi::FRESULT RemoveComponent(Entity entity, ComponentId component) noexcept = 0;

        virtual bool IsAlive(Entity entity) noexcept = 0;
        virtual const void* GetComponent(Entity entity, ComponentId component) noexcept = 0;   // null if absent
        virtual void* GetComponentForWrite(Entity entity, ComponentId component) noexcept = 0; // stamps the column
        virtual nvrhi::FRESULT SetEnabled(Entity entity, ComponentId component, bool enabled) noexcept = 0;

        virtual nvrhi::FRESULT CreateQuery(const QueryDesc& desc, IQuery** ppQuery) noexcept = 0;
        virtual nvrhi::FRESULT CreateCommandBuffer(ICommandBuffer** ppBuffer) noexcept = 0;
        virtual nvrhi::FRESULT Playback(ICommandBuffer* const* buffers, uint32_t count) noexcept = 0;

        virtual void* GetResource(const nvrhi::GUID& type) noexcept = 0;
        virtual nvrhi::FRESULT AddObserver(const ObserverDesc& desc, IObserver* observer) noexcept = 0;
        virtual uint32_t GetVersion() noexcept = 0;
        virtual uint32_t GetStructuralVersion() noexcept = 0;
        virtual bool IsInPhase() noexcept = 0;                    // the 5.6 check
        virtual WorldStats& GetStats(WorldStats& retVal) noexcept = 0;
    };

    struct ISystemContext : nvrhi::IObject
    {
        virtual IWorld* GetWorld() noexcept = 0;
        virtual ICommandBuffer* GetCommandBuffer() noexcept = 0;    // this system, this worker thread
        virtual IJobSystem* GetJobSystem() noexcept = 0;
        virtual uint32_t GetLastRunVersion() noexcept = 0;
        virtual const FrameTime& GetFrameTime() noexcept = 0;
    };

    struct ISystem : nvrhi::IObject
    {
        virtual SystemDesc& GetDesc(SystemDesc& retVal) noexcept = 0;
        virtual nvrhi::FRESULT Update(ISystemContext* context) noexcept = 0;
    };

    struct IScheduler : nvrhi::IObject
    {
        virtual nvrhi::FRESULT AddSystem(ISystem* system, SystemId& outId) noexcept = 0;
        virtual nvrhi::FRESULT RemoveSystem(SystemId id) noexcept = 0;
        virtual nvrhi::FRESULT SetSystemEnabled(SystemId id, bool enabled) noexcept = 0;
        virtual nvrhi::FRESULT Build() noexcept = 0;                 // order, validate, report ambiguities
        virtual nvrhi::FRESULT RunPhase(Phase phase) noexcept = 0;
    };

    struct ISimulationContext : nvrhi::IObject
    {
        virtual IWorld* GetWorld() noexcept = 0;
        virtual uint32_t GetColumns(ComponentId component, ColumnView* views, uint32_t capacity) noexcept = 0;
        virtual nvrhi::ICommandList* GetCommandList() noexcept = 0;  // null for CPU domains
        virtual uint64_t GetStepIndex() noexcept = 0;
    };

    struct ISimulationDomain : nvrhi::IObject
    {
        virtual SimulationDomainDesc& GetDesc(SimulationDomainDesc& retVal) noexcept = 0;
        virtual nvrhi::FRESULT OnEntitiesAdded(const EntityBatch& batch, ISimulationContext* context) noexcept = 0;
        virtual nvrhi::FRESULT OnEntitiesRemoved(const EntityBatch& batch, ISimulationContext* context) noexcept = 0;
        virtual nvrhi::FRESULT GatherInputs(ISimulationContext* context) noexcept = 0;
        virtual nvrhi::FRESULT Step(double dt, ISimulationContext* context) noexcept = 0;
        virtual nvrhi::FRESULT ScatterOutputs(ISimulationContext* context) noexcept = 0;
        virtual nvrhi::FRESULT CaptureState(IStateWriter* writer) noexcept = 0;
        virtual nvrhi::FRESULT RestoreState(IStateReader* reader) noexcept = 0;
    };

    nvrhi::FRESULT CreateWorld(const WorldDesc& desc, IWorld** ppWorld) noexcept;
    nvrhi::FRESULT CreateScheduler(IWorld* world, IJobSystem* jobs, IScheduler** ppScheduler) noexcept;
}
```

### 9.2 Scene graph over the world

Module-private C++ in `SceneComponents.h` and `SceneGraph.h` (it uses implementation classes). Only the parts
that change are shown; the public API of 5.7 stays.

```cpp
namespace donut::engine
{
    // The scene graph's components (SceneComponents.h)
    struct SceneNode  { SceneGraphNode* object; };              // strong reference, released by its hook
    struct SceneLinks { Entity firstChild, lastChild, prevSibling, nextSibling; };
    struct Parent     { Entity entity; };
    struct LeafObject { SceneGraphLeaf* object; };              // strong reference, released by its hook
    struct MeshRef    { MeshId mesh; };

    // State of an object that is in no graph: component values keyed by GUID, in their
    // world-independent form (5.3). Owned by the object; destroyed when the object is attached.
    class OrphanRecord;

    // What a leaf class keeps in columns (D19). One static instance per leaf class.
    struct LeafTypeDesc
    {
        nvrhi::GUID classId;                            // NVRHI_CLASS_CLSID of the leaf class
        const ComponentTypeDesc* const* tags;           // this class and its base classes (4.11)
        uint32_t tagCount;
        const ComponentTypeDesc* const* columns;        // state that lives in columns; empty for object-only leaves
        uint32_t columnCount;
    };

    class SceneGraphLeaf : public nvrhi::WeakReferenceSourceImpl<nvrhi::IWeakReferenceSource>
    {
    public:
        // ... existing API unchanged ...
        [[nodiscard]] virtual const LeafTypeDesc& GetTypeDesc() const;   // default: object-only leaf

    protected:
        // Columnar state: the entity's row when attached, the leaf's record otherwise.
        template<typename T> [[nodiscard]] const T* Get() const;
        template<typename T> [[nodiscard]] T* Edit();      // stamps the column version when attached

    private:
        nvrhi::WeakPtr<SceneGraphNode> m_Node;
        OrphanRecord* m_Record = nullptr;
    };

    class SceneGraphNode final : public nvrhi::WeakReferenceSourceImpl<nvrhi::IWeakReferenceSource>
    {
    public:
        // ... existing API, with derived getters returning by value and the Prev*/Dirty members removed ...

    private:
        nvrhi::WeakPtr<SceneGraph> m_Graph;
        Entity m_Entity = Entity::Null;      // valid while attached
        OrphanRecord* m_Record = nullptr;    // valid while in no graph; holds children and leaf
        std::string m_Name;
    };

    class SceneGraph : public nvrhi::WeakReferenceSourceImpl<nvrhi::IWeakReferenceSource>
    {
    public:
        // ... existing API unchanged (5.7) ...
        [[nodiscard]] IWorld* GetWorld() const;                    // one world per graph (D18)
        [[nodiscard]] Entity GetEntity(const SceneGraphNode* node) const;
        [[nodiscard]] SceneGraphNode* GetNode(Entity entity) const; // null for runtime-only entities; no AddRef

    protected:
        virtual void RegisterLeaf(SceneGraphLeaf* leaf);           // still called, from the LeafObject observer
        virtual void UnregisterLeaf(SceneGraphLeaf* leaf);
    };
}
```

`MeshInstance` keeps its public API: `GetMesh()` resolves `MeshRef` through the mesh table when attached and
reads its record otherwise; `GetInstanceIndex()` reads `GpuInstanceSlot`.

## 10. Performance design

### 10.1 Targets

To be calibrated in step E0 on the reference machine; the numbers are the starting proposal.

| Case | Target |
| --- | --- |
| 100k dynamic depth-0 mesh instances: TRS to world, bounds, chunk bounds | < 0.5 ms on 8 workers |
| 1M static instances, nothing changed | < 0.05 ms for `TransformPropagation` and `Bounds` |
| Upload after 10k of 100k instances moved | proportional to the changed chunks; < 0.2 ms CPU |
| Visibility and packet generation, 100k instances, one view | < 1 ms on 8 workers |
| Structural changes: 10k entities moved between two archetypes | < 1 ms |
| Attaching an imported Sponza-sized subgraph | no slower than today's load |
| Scene-graph getter or setter | an entity-table lookup and a column offset; no measurable change in sample frame times |
| Steady state | zero heap allocations per frame |
| Memory per dynamic mesh instance | about 250 B of columns (5.8) |

### 10.2 Measurement

The same protocol as the render graph: alternating rounds, median of run medians, a baseline built from
`main`. Synthetic scenes from a generator (flat instances with a moving fraction; deep hierarchies; skinned
crowds), Sponza, the skinned glTF samples, ethereal-phys's flex scenes and, through the MotrixSim viewer, the
official MotrixSim examples.

### 10.3 Choices driven by cost

- Chunk iteration with no virtual call per entity; component pointers hoisted per chunk.
- Column alignment of 64 bytes; float columns used by culling are separate from the double transform columns.
- Change versions per chunk; no per-entity dirty walks.
- Batched archetype moves at playback and at attach; edge caches for archetype lookup.
- Observers in batches per archetype, not per entity.
- Scene-graph objects cache nothing. Column offsets are cached per archetype, so an API access is an
  entity-table lookup plus two offsets.
- Double-precision transforms only where the authoring and physics semantics need them (D4).

## 11. Correctness and diagnostics

### 11.1 Tests without a device

Unit tests for storage, queries, command playback, observers and the scheduler. A golden corpus: each test scene
is attached and run for N frames, and a hash of the world (entities, archetypes, column contents) is compared
with a stored value, at 1, 2 and 8 workers. An API-sequence test applies a recorded sequence of scene-graph
calls and compares the world with one built directly in its final shape. The existing scene-graph tests
(`tests/src/engine/test_scene_graph_nodes.cpp` with 16 cases, `test_scene_graph_qi.cpp`) must pass unchanged.
They cover the ownership and attach/detach semantics that 5.3 keeps.

### 11.2 A/B against the current path

Old and new node storage cannot run side by side in one process, so A/B is between builds. Step E0 adds a dump
of every node's world transform and bounds per frame for the deterministic test scenes; the baseline build
of `main` records them. The new build must match them bit for bit. Propagation uses the same composition and
multiplication order as `SceneGraph::Refresh`, so the comparison is exact. The instance, geometry and material
buffers must match after slot remapping. Images must match the references (the `ab_compare` tooling of the
render-graph work).

### 11.3 Debug validation

Access checks in queries; ambiguity reports from the scheduler; stale-`Entity` checks; a check that no system
writes a column it declared as read; the check of 5.6 that scene-graph objects do not write while a phase runs;
a check that `GpuMirrored` and simulation-visible components are relocatable.

### 11.4 Inspector, statistics and snapshots

An ImGui inspector built on reflection: archetypes, chunk occupancy, per-system timings, change versions, entity
browser with component editing (edits go through command buffers). A binary world snapshot (chunk columns
copied for relocatable components, entity remapping on load) used by tests, by simulation replay and by
debugging captures. Leaf objects are serialised through their existing `Load`/`Store` paths.

## 12. Migration steps

| Step | Repository | Content | Exit criterion |
| --- | --- | --- | --- |
| E0 | donut, samples | Synthetic scene generator; baseline timings of `SceneGraph::Refresh` and `Scene::RefreshBuffers`; per-frame dumps of world transforms and bounds from the baseline build (11.2); fix the `UnregisterLeaf` defect separately | Baseline and dumps recorded |
| E1 | donut | ECS core in `donut_engine`: registry, entity table, archetypes, chunks, sparse sets, buffers, queries, command buffers, observers, reflection, snapshot | Device-free tests |
| E2 | donut | `IJobSystem`, scheduler, phases, ambiguity detection | Determinism tests at 1/2/8 workers |
| E3 | donut | Scene graph over the world: node objects become handles; transforms, hierarchy links and bounds in columns; orphan records; transform and bounds systems, which `Refresh` runs; `LeafObject` and the leaf observer; `DirtyFlags` and the previous-transform getters removed | Scene-graph tests pass unchanged; world transforms and bounds bit-identical to the E0 dumps; samples build unchanged and give the same images |
| E4 | donut | Asset tables with stable slots; `MeshInstance` state in columns; `GpuScene` with changed-chunk uploads; `Scene::RefreshBuffers` delegates | Buffers equal after remapping; images equal; upload cost proportional to change |
| E5 | donut (`rdg`), samples | Extraction, snapshot, visibility, draw packets, strategy adapters, upload and skinning as `IGpuPass` | Images equal; budgets of 10.1 |
| E6 | ethereal-phys, samples, motphys | Simulation domains: an ethereal-phys domain; `PhysSceneGraph` and `GVDBSceneGraph` move from `RegisterLeaf` overrides to observers and queries; SPH and GVDB leaf columns; MotrixSim domain over its C SDK | Parity tests pass inside scenes; MotrixSim replay deterministic |
| E7 | donut, samples | Runtime-only entities sample at scale; optional pipelining | Budgets of 10.1 at scale |

E3 is the largest step, because it changes where node state lives and there is no mirror to fall back on. Its
safety nets are the unchanged scene-graph tests and the exact comparison with the E0 dumps. If it is too large
to review at once, it splits into transforms and hierarchy first (leaves still in the node object, referenced
from `LeafObject`), then leaf registration.

## 13. Decisions

These are the decisions made in review. Each records the choice, the options it was taken over, and the reason.

### 13.1 Revision 2 (2026-11-18)

**No data bridge.** The scene graph and the ECS are one store, with the scene graph as an API over the world
(section 5). Revision 1's change journal, bakers, write-back, mirror mode and pull-through are removed.
Objects outside any graph keep their state in records until they are attached (5.3, D17).

**D1. Where the core lives.** In `donut_engine`, as flat `Ecs*` files in `include/donut/engine` and
`src/engine`, with no subfolder and no separate target (3.2). The rule that the core names no scene type
stays, enforced by review and an include check. Rejected: a separate `donut_ecs` library.

**D12. Where bakers live: withdrawn.** There are no bakers. D19 replaces it.

**D15. Authority after the migration: withdrawn.** There is no mirror mode; the world is the authority from
step E3 on.

### 13.2 Revision 3 (2026-11-21)

Every open item took its recommendation.

**D2. Storage model.** Archetype chunks as primary storage, plus sparse sets for components flagged `Sparse`
(Bevy). Rejected: archetype chunks only; sparse sets only (EnTT), whose multi-component iteration is linear
only inside groups.

**D3. Entity width.** 64 bits: a 32-bit index and a 32-bit generation (4.1). Rejected: 32 bits with a short
generation (Filament), which wraps in long simulations.

**D4. Transform precision.** Double-precision `WorldTransform` by default, converted to float relative to a
render origin at extraction. An opt-in float-only archetype for very large instance counts is added when a
sample needs it. Rejected: float transforms with integer origin cells per entity.

**D5. Hierarchy propagation.** Depth buckets as a shared component, propagated level by level (4.6). It stays
linear and parallel for wide scenes and costs nothing for entities without a parent. Rejected: per-root
recursion, parallel over roots (Unity); relationship pairs that partition tables by parent (flecs).

**D6. Chunk size.** 16 KiB by default, and 64 KiB for archetypes whose rows exceed 128 bytes, so that a chunk
holds about 128 rows or more (4.3). The dynamic mesh instance row of 5.8 would get only about 64 rows per
16 KiB chunk. Rejected: 16 KiB everywhere; 64 KiB everywhere.

**D7. Assets.** Typed asset tables outside the entity store (4.8). Rejected: assets as entities.

**D8. Render data.** A frame-arena snapshot plus a persistent `GpuScene` (7.1, 7.2). Rejected: a second world
for rendering (Bevy).

**D9. Change detection granularity.** Change versions per chunk and column (4.5). Per-row ticks for components
flagged `RowTracked` are added only if measurement shows chunk granularity is too coarse. Rejected: per-row ticks
for every component (Bevy), which cost a tick per row and a store per write everywhere; `RowTracked` ticks from
the start, before any measurement asks for them.

**D10. Job system.** A new work-stealing `IJobSystem` in `donut_engine`, next to `ThreadPool.h`. The render
graph's parallel recording in `donut_render`, which links `donut_engine`, uses it too. A third-party scheduler
(enkiTS, Taskflow) may later be wrapped behind the interface. Rejected: extending `ThreadPool`; a third-party
scheduler as the interface. Revision 1 put it in `donut_core`; with the core in `donut_engine`, it sits with
`ThreadPool`.

**D11. Shared components for draw batching.** None: draw packets are sorted at extraction (7.3). Rejected:
partitioning chunks by mesh and material, which fragments storage (4.4).

**D13. Render objects in leaves.** After step E5 the render service owns shadow maps, keyed by light entity,
and `Light::shadowMap` and `DirectionalLight::perObjectShadows` become authoring hints (7.6). Until then the
fields stay in the light objects (D16). Rejected: keeping render objects in the leaves.

**D14. Non-trivial components.** Allowed with lifecycle hooks, but never `GpuMirrored` and never handed to
simulation domains as columns (4.2). The scene graph needs them: `SceneNode` and `LeafObject` hold the objects
that the entity owns. Rejected: plain data only, with COM references in side tables keyed by entity.

**D16. Leaf state.** Columns hold node state and the state of leaf types iterated at scale (`MeshInstance`,
simulation leaves). The leaf object stays the home of low-count parameters (lights, cameras, animations,
skinning GPU objects), referenced through `LeafObject` (4.11). A leaf type moves its parameters into columns
when it needs scale, with an API change limited to that type. Rejected: columns and accessors for every leaf
type, a source change in about 35 files including donut's ImGui light editor, which takes field addresses;
property proxies, which keep `light->intensity = x` compiling but break `&light->intensity`.

**D17. State of objects outside a graph.** Orphan records owned by the objects, moved into rows at attach and
back at detach (5.3). Construction stays as it is at the 21 sites, and importers keep working before they
know their target graph; every value moves once per attach. Rejected: creating every node and leaf in a world
(`SceneGraph::CreateNode`, graph-bound leaf factories, an `Orphan` tag), which changes every construction site
and needs a world before an importer has one; a staging world per importer or thread (Unity's
`MoveEntitiesFrom`).

**D18. Graphs per world.** One world per `SceneGraph`. Services attach to a world, and a second graph such as
nv_asteroids' shadow-light graph is small. Rejected: several graphs in one world, partitioned by a shared
`GraphId`.

**D19. How a leaf class declares its columns** (replaces D12). A virtual `GetTypeDesc()` on `SceneGraphLeaf`
that returns a static `LeafTypeDesc` (9.2). The leaf class is the one place that knows its fields. The virtual
is called once per leaf at attach, never per entity in a system, and `SceneGraphLeaf` is module-private, so the
ABI is not affected. Rejected: a registry keyed by leaf class id.

**D20. Hierarchy links.** Intrusive sibling links in `SceneLinks`: O(1) append, detach and next sibling, as
with today's pointers (4.6). Rejected: a contiguous `Children` buffer (Unity, Bevy), with which ordered removal
and `GetNextSibling` become O(children); that hurts wide nodes such as 100k instances under one root.

## 14. References

1. Unity Entities manual: <https://docs.unity3d.com/Packages/com.unity.entities@1.0/manual/index.html>
2. Unity Entities, baking: <https://docs.unity3d.com/Packages/com.unity.entities@1.0/manual/baking.html>
3. Unity Entities Graphics and `BatchRendererGroup`:
   <https://docs.unity3d.com/Packages/com.unity.entities.graphics@1.0/manual/index.html>,
   <https://docs.unity3d.com/Manual/batch-renderer-group.html>
4. Bevy ECS API: <https://docs.rs/bevy_ecs/latest/bevy_ecs/>
5. Bevy release notes 0.14, 0.15, 0.16 (observers and hooks; required components; relationships):
   <https://bevyengine.org/news/>
6. flecs: <https://github.com/SanderMertens/flecs>; relationships manual:
   <https://www.flecs.dev/flecs/md_docs_2Relationships.html>
7. S. Mertens, "Building an ECS" series: <https://ajmmertens.medium.com/>
8. EnTT: <https://github.com/skypjack/entt>
9. M. Caini, "ECS back and forth": <https://skypjack.github.io/2019-02-14-ecs-baf-part-1/>
10. Unreal Engine, Mass Entity overview: <https://dev.epicgames.com/documentation/en-us/unreal-engine/overview-of-mass-entity-in-unreal-engine>
11. NVIDIA Omniverse, USD, Fabric and USDRT: <https://docs.omniverse.nvidia.com/kit/docs/usdrt/latest/docs/usd_fabric_usdrt.html>
12. OpenUSD Hydra: <https://openusd.org/release/api/hd_page_front.html>
13. Filament (`utils/Entity.h`, `TransformManager`, `RenderableManager`): <https://github.com/google/filament>
14. N. Frykholm, "Building a Data-Oriented Entity System" (Bitsquid blog, 2014):
    <https://bitsquid.blogspot.com/2014/08/building-data-oriented-entity-system.html>
15. Unreal Engine 5 source, `FGPUScene` (`Renderer/Private/GPUScene.h`)
16. NVIDIA PhysX 5 SDK documentation, "Direct GPU API"
17. MuJoCo API types, `mjModel` and `mjData`: <https://mujoco.readthedocs.io/en/stable/APIreference/APItypes.html>
18. T. Ford, "Overwatch Gameplay Architecture and Netcode", GDC 2017:
    <https://www.gdcvault.com/play/1024001/-Overwatch-Gameplay-Architecture-and>
19. G. Fiedler, "Fix Your Timestep!": <https://gafferongames.com/post/fix_your_timestep/>
20. M. Acton, "Data-Oriented Design and C++", CppCon 2014
