# 0002. `query_cast` replaces `dynamic_cast` in donut and the samples

- Status: Accepted
- Date: 2026-10-10

## Context

[nvrhi ADR 0006](../../ethereal-nvrhi/doc/adr/0006-no-rtti-queryinterface-casts.md) removed RTTI from NVRHI
and converted every `dynamic_cast` on NVRHI-created objects to `QueryInterface`. It deliberately kept the
casts on classes that donut and the samples define and instantiate with RTTI on:

- the scene graph leaves (`SceneGraph.cpp`, `GltfImporter.cpp`, `SceneImporterImpl.cpp`,
  `DrawStrategy.cpp`, `Camera.cpp`; in the samples `DDGISample.cpp`, `VXGISample.cpp`,
  `VoxelShadingPass.cpp`, `GVDBScene.cpp`, `SPHFluidScene.cpp`);
- the audio effects (`AudioEngine.cpp`, `Xaudio2Effect`, `Xaudio2Effect3D`).

That left two mechanisms for the same question ("is this object a `T`?"), and it kept a trap: a leaf class
that moves into an RTTI-off module, or is created by NVRHI code, makes the cast undefined. The user decided
to drop the exception: no `dynamic_cast` remains in the aggregate's own code.

## Decision

**`donut::query_cast<T>(U*)`** (`ethereal-donut/include/donut/core/query_cast.h`) is the only downcast of
nvrhi objects. It calls `QueryInterface(uuid_of<T>(), nullptr)` and, on success, returns
`static_cast<T*>(object)`; it returns null for a null or non-matching object, as `dynamic_cast` did.

- The query passes no pointer, so it adds no reference. The hot loops (`SceneGraph::RegisterLeaf`, the draw
  strategies' per-leaf test) pay one table walk and no atomic operation. The caller's reference to the
  object keeps the result valid, as before.
- `T` must derive from `U` non-virtually (`static_assert`; a virtual base would not compile in the
  `static_cast`).

**Every class that is cast to has a class ID and an explicit table** (nvrhi ADR 0007):

```cpp
NVRHI_CLASS_CLSID(Light, "...")
class Light : public SceneGraphLeaf
{
public:
    NVRHI_DECLARE_UUID_TRAITS(Light)
    NVRHI_BEGIN_INTERFACE_TABLE_INLINE(Light)
    NVRHI_IMPLEMENTS_INTERFACE(nvrhi::IWeakReferenceSource)   // first entry, as in the parent's table
    NVRHI_IMPLEMENTS_CLASS(Light)
    NVRHI_END_INTERFACE_TABLE()
```

A class derived from another class that has a class ID adds `NVRHI_IMPLEMENTS_ROUTE_PARENT(Parent)`, so
that a `DirectionalLight` still answers `Light`'s class ID and `query_cast<Light>` accepts it, like the
`dynamic_cast` it replaces. `Xaudio2Effect` and `Xaudio2Effect3D` are structs and use `NVRHI_SCLSID`.

| Repository | Classes with a class ID |
| --- | --- |
| donut | `SceneGraphLeaf`, `Effect`, `MeshInstance`, `SkinnedMeshInstance`, `SkinnedMeshReference`, `SceneCamera`, `PerspectiveCamera`, `OrthographicCamera`, `Light`, `DirectionalLight`, `SpotLight`, `PointLight`, `SceneGraphAnimation`, `Xaudio2Effect`, `Xaudio2Effect3D` |
| samples | `SPHFluidInstance`, `GVDBVolumeInstance` |

The two base classes (`SceneGraphLeaf`, `Effect`) have an ID too, although nothing casts to them yet, so
that the chain is complete: every class in the hierarchy answers its own ID, and every class below a base
lists `NVRHI_IMPLEMENTS_ROUTE_PARENT(Parent)`, direct children of `SceneGraphLeaf` included (the sample
leaves route to `SceneGraphLeaf`). These classes used `NVRHI_INHERIT_INTERFACE_TABLE()` before; it is
replaced by the table above.

`ethereal-donut/tests/src/engine/test_scene_graph_qi.cpp` checks the chain for every leaf class: it
answers the class IDs of itself and of its bases (`std::is_base_of`), refuses all others, through
`query_cast` and through `QueryInterface` with a pointer, and leaves the reference count unchanged.
`Xaudio2Effect` is private to `AudioEngine.cpp` and is not covered by it.

## Consequences

### Positive

- One mechanism for type questions across nvrhi, donut and the samples. The scene graph can move to
  RTTI-off modules, and leaf classes can be created by code that has no RTTI.
- A forgotten class ID is a compile error: `query_cast<T>` needs `uuid_of<T>()`, and an unspecialized
  `NvrhiUUIDTraits` does not compile (MSVC and GCC).

### Negative

- Each class that is cast to costs a GUID, a forward declaration and a five-line table; a new leaf class in
  a consumer that wants to be found by type must write them. A leaf class that is never cast to still
  uses `NVRHI_INHERIT_INTERFACE_TABLE()`.
- A subclass of a leaf (`class MyLight : public PointLight` with `NVRHI_INHERIT_INTERFACE_TABLE()`)
  answers its bases but has no ID of its own; `query_cast<MyLight>` does not compile until it gets one.

### Risks

- A table that forgets `NVRHI_IMPLEMENTS_ROUTE_PARENT(Parent)` makes `query_cast<Parent>` return null for
  the derived class, silently. The test above catches it for the donut leaves; a new leaf class in a
  consumer needs its own check.
- `query_cast` answers from the class ID table, not from the C++ type: a class that lists another class's ID
  would pass the test and be downcast wrongly. Tables list their own ID and their parents' only.

## Alternatives considered

- **Keep `dynamic_cast` where RTTI is on** (the state after nvrhi ADR 0006). Rejected by the user: two
  mechanisms, and the cast is undefined as soon as the object crosses into an RTTI-off module.
- **`QueryInterface` with `NVRHI_IID_PPV_ARGS` at every site.** Rejected: the 44 sites would each declare an
  `AutoPtr`, take and drop a reference, and check an `FRESULT`; the hot loops would pay two atomic
  operations per leaf. `query_cast` keeps the sites as short as the casts they replace.
- **A virtual type tag on `SceneGraphLeaf`** (`GetLeafType()`). Rejected for the reasons of nvrhi ADR 0006:
  a second identity system next to IIDs and class IDs, and it does not extend to consumer classes.

## References

- Files: `ethereal-donut/include/donut/core/query_cast.h`, `ethereal-donut/include/donut/engine/SceneGraph.h`,
  `ethereal-donut/src/engine/AudioEngine.cpp`, `ethereal-samples/src/gvdb_samples/gvdb/GVDBScene.h`,
  `ethereal-samples/src/gvdb_samples/sph_fluid_pool/SPHFluidScene.h`.
- Updates the "Consumers" section of
  [nvrhi ADR 0006](../../ethereal-nvrhi/doc/adr/0006-no-rtti-queryinterface-casts.md), whose "Kept" list
  (scene graph casts, `AudioEngine.cpp`) no longer holds.
- Related: [nvrhi ADR 0007](../../ethereal-nvrhi/doc/adr/0007-explicit-queryinterface-tables.md).
