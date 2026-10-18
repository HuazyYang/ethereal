# M5 3d-print ownership checkpoint

Status: consumer ownership implemented and validated on Windows, 2026-10-19. Public mesh voxelization remains outstanding; the mega project remains in progress.

Samples `7b2d555` removes persistent PackedVolume/SlangVolume/typed-atlas ownership from 3d-print. Completed dense classification selects public host leaf masks. A fresh public volume publishes initial scalar storage and the public resample operator maps dense source coordinates into signed world coordinates, including aprons. The visible snapshot changes only after both queue-ordered submissions succeed. The raw snapshot viewer handles the original viewing modes/inset; topology overlays read public nodes. See the [sample contract](../../ethereal-samples/src/gvdb_samples/samples/3d-print/README.md).

The portable mesh binning/solid voxelizer and its explicit dense classification readback are retained. This is consumer ownership acceptance, not public voxelizer acceptance. CPU dense data remains for classification/verification; no duplicate GPU volume is retained. Preparation failure preserves visible state; submitted device failures cannot be rolled back. Publication means recording, not completion.

## Verification

- Affected raw-view/resample/print regressions pass **20/20 in 11.62 seconds** and graphics-only **15/15 in 8.58 seconds**. Logs/JUnit: `build/m5-owned-print/affected-tests.log`, `graphics-tests.log`, XML in each build directory. All three print builds pass, including tests-disabled/CUDA-discovery-disabled production.
- Analytic cube tests preserve all dense classifications, leaf32/apron34 layout, signed node/map/world bounds, every atlas/apron value and exact section pixels at zero/negative origins. New cases verify invalid voxel-size rejection preserves the visible snapshot identity/configuration and retained snapshot bytes remain unchanged after valid rebuild.
- Lucy retains **47 leaves, 56,839 surface and 131,750 interior voxels**. The complete leaf-origin set matches an independent partition of occupied dense voxels.
- Both explicitly selected graphics adapters pass analytic and Lucy native validation on D3D11/D3D12/Vulkan; bounded two-frame topology windows pass each API. Logs: `build/m5-owned-print/{dx11,dx12,vk}-adapter{0,1}-native-{analytic,lucy}.log` and `*-native-window.log`. Adapter mappings are corroborated by the downsample checkpoint logs.
- Analytic and Lucy CUDA Compute Sanitizer runs report **zero errors**: `cuda-{analytic,lucy}-memcheck.log`.
- All four Lucy captures exactly match preserved previous-portable images. The tests-disabled production run exactly matches explicit AMD DX11: `image-comparison.json`, `production-{configure,build,run}.log`.

These are affected-slice results. The last complete matrices remain **329/329 in 200.11 seconds** and **248/248 in 161.61 seconds** from the immediately preceding resample checkpoint; they precede this print migration. No retained sources are removed. The 100-entry inventory remains 28 owned-validated, 12 sample-validated, 30 portable-foundation, 24 partial and 6 pending roles.

## Next public operator

The mesh voxelizer needs a device-only, multi-phase public contract. Preparation copies/validates vertices, flat triangle indices, transforms, finite grid bounds, classification values and output format, with explicit work/allocation budgets. The first caller recording counts triangle/bin references and copies counts for explicit caller submission/wait. Completed counts validate overflow and size the following stage; checked prefix offsets are metadata preparation, not an implicit GPU wait. A separate authenticated recording scatters triangles and classifies the dense grid. The caller again submits/waits before CPU result access; retained device buffers support subsequent GPU consumers. No phase implicitly submits/waits or changes an existing volume owner.

Implementation must freeze the arithmetic/rounding and triangle-boundary contract, check all artifact bindings/constant layouts, retain ticket/device resources independently of factory lifetime, and test malformed descriptors, empty meshes, packed R8 tails, all three existing output formats, budgets/overflow, stale/foreign/repeated tickets and release lifetimes. Independent closed-mesh/boundary fixtures and Lucy, both graphics adapters, CUDA memory checking, static/shared installed consumers and tests-disabled production are acceptance gates before promoting voxelization inventory roles.

Scatter, weighted ushort gather, remaining consumer ownership, Linux, supported native multi-GPU interop, broader interactive/reference/performance acceptance and reference retirement also remain open.
