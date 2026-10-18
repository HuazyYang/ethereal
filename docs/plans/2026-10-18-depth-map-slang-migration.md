# Depth-map migration to Slang and public NVRHI interop

Status: Implemented and validated, 2026-10-18. The execution record below documents the completed slice and measured legacy image comparison.

This is the depth-map acceptance slice of the [Slang project plan](2026-10-18-ethereal-nvrhi-slang-support.md). It uses the new [graphics export contract](../../ethereal-nvrhi/docs/graphics-interop.md). The output must retain the actual Lucy mesh, explosion volume, controls, transforms, transfer function and mesh/volume composition. A synthetic fixture supplements that scene for testing.

## Reference behavior

Sources are `ethereal-samples/src/gvdb_samples/samples/depth-map/main.cpp`, `samples/sample-utils/{ObjMesh.cpp,SampleTypes.cpp,VolRenderer.cpp,shaders/Simple.hlsl,shaders/FullScreen.hlsl,kernels/GVDBRaycast.cuh,kernels/GVDBRaycast.cu}`, relative to `src/gvdb_samples` after the first path.

- Mesh: `lucy.obj`, vertex positions multiplied by 100, identity model transform. Preserve the loader's area-weighted fallback normals, snorm8 normal quantization/decode, and two-sided normals flipped toward the eye. Raster RGB is ambient 0.1 plus diffuse 0.5 times the clamped normal/light dot product; the declared specular constant is unused.
- Volume: channel zero of `explosion.vbx`, refreshed apron. The sample overrides the VBX file transform. In row-vector order, index-to-world is `translation(-125,-160,-125) * scale(0.5) * rotationZYX(volumeAngles) * translation(volumeTranslation)`, with initial translation `(0,0,-25)` and zero angles. Do not apply the serialized VBX transform a second time.
- Camera: orbit angles `(-40,20,0)`, target zero, distance 400; horizontal FOV 50 degrees converted to vertical by aspect; near/far 0.1/1000. Light orbit `(299,57.3,0)`, target zero, distance 500. Keep left orbit/middle pan/right distance and Shift light controls, plus volume translation/rotation controls.
- Raster: triangle list, no culling, ordinary non-reversed D3D-style 0..1 depth, LessEqual comparison. RGBA8_UNORM mesh color, R32_FLOAT second color attachment containing interpolated clip-z divided by clip-w, D24S8 depth attachment. Clear color `(0.1,0.2,0.4,1)` and both depth values to 1. Image coordinates start at the top left on every backend.
- Volume rays: transform camera origin by world-to-index; transform the world near-plane ray by the inverse linear transform and normalize in index space. Sample pixel centers. March step is 0.5 index units, sampling on the global `ceil(entry/step)*step` wavefront, with the legacy 0.001 brick-entry epsilon and empty-brick skipping. Preserve the reference's 256-iteration limits where they affect a compatibility fixture.
- Transfer: allocate 16,384 float4 entries. Piecewise linear ranges are 0..0.1 transparent; 0.1..0.5 yellow alpha 0.1 to red alpha 0.3; 0.5..0.75 red alpha 0.3 to gray 0.2 alpha 0.1; 0.75..1 gray 0.2 alpha 0.1 to gray 0.1 alpha 0.3. Fill each range using the reference floor-index/exclusive-end rule. Lookup uses integer truncation of `saturate((density-0.1)/0.5)*16300`, not generic interpolated transfer sampling. Ignore density below 0.005. Per-step transmittance is `exp(-transferAlpha*0.5)`; albedo is 1, terminate below transmittance 0.005.

Three reference quirks must be explicit in compatibility tests:

1. The linearized depth is view-space Z: `near*far/(far-depth*(far-near))`. Legacy clipping divides it by the length of the index ray transformed to world space. This misses the perspective cosine away from the center pixel. Preserve this as the initial compatibility mode. A separately named exact mode can compute `linearZ/dot(indexDirection*indexToWorldLinear,cameraForward)` or unproject the depth and project onto the index ray; cover off-axis pixels and nonuniform scale before changing the default.
2. The displayed depth-bias slider writes `scn.bias`, but the volume/depth kernels never read it. Preserve the compatibility behavior and label it honestly, or introduce an explicit exact-mode bias measured in documented index units. Do not silently change image behavior by applying the previous default value 1.
3. The accumulated volume RGB is already premultiplied by sample opacity. The reference then computes `volumeRGB = lerp(background, accumulatedRGB, opacity)`, quantizes RGBA to bytes, and finally computes `lerp(meshRGB, volumeRGB, opacity)` in the full-screen pass. Retain these two alpha operations in compatibility mode; replacing them with conventional premultiplied-over changes the image.

## Resource and queue contract

The application uses `IDevice`/`ICommandList`, `IShaderProgram`, `IGraphicsInteropDevice`, `IExternalMemory` and CUDA's existing `IInteropDevice`.

| Resource | Graphics representation | CUDA binding |
| --- | --- | --- |
| Polygon color | Ordinary RGBA8_UNORM render target/SRV | None |
| Hardware depth | Ordinary D24S8 depth attachment | None |
| Projected depth | Shared R32_FLOAT 2D render target/SRV | Imported `Texture2D<float>`, integer-coordinate Load |
| Volume image | Shared R32_UINT 2D UAV/SRV, packed RGBA8 | Imported `RWTexture2D<uint>` |
| Volume topology/atlas/transfer/parameters | CUDA-local ordinary NVRHI buffers | Structured/raw buffers and constant buffer |

Use the texture creation flags returned by `queryRoute().textureSharingFlags`, GPU-only committed/dedicated allocations, one mip, one layer, one sample, and `keepInitialState=false` on shared textures. R32_UINT preserves byte quantization and already has a validated sharing path on all three APIs. It avoids relying on CUDA normalized texture stores. The graphics composite shader loads and unpacks that pixel. Read depth directly from the imported texture; the legacy intermediate texture-to-linear-buffer copy is unnecessary.

After construction/import, retain resources, export owners, fences, pipeline and binding sets in the pass. Complete initialization uploads before the first frame. For frame k, using one monotonically increasing shared timeline:

1. Graphics owns both shared textures. Rasterize the mesh; release depth and output as the final graphics uses; submit and signal `2*k+1`.
2. The CUDA command list records wait `2*k+1`, writes parameters, dispatches the depth-clipped Slang kernel, and signals `2*k+2`; submit it.
3. Graphics enqueues wait `2*k+2`. Record acquire of depth as RenderTarget for its next use and output as ShaderResource. Composite mesh color with unpacked output and present. Both textures are graphics-owned again for the next frame.

Do not use `ComputeRuntime::flush` in this frame chain: it host-waits. A sample renderer should record its prepared `IShaderProgram` pipeline/bindings into an existing open list. `SlangVolume` getters already expose atlas/nodes/children/levels; its upload/apron helpers can be used at initialization. Per-frame GPU work needs no staging copy or CPU fence wait. Resize/reload may wait for both devices, release old exports/imports, and rebuild matching-size targets/bindings. A ring of resource pairs is a later performance improvement, not required for correctness.

## Backend and adapter selection

Use `-dx11`, `-dx12` or `-vk` for raster/composition; `--compute-api cuda` is the first supported cross-API mode. Add `--cuda-device N` and `--graphics-adapter N`, separate from presentation choice. Create the explicitly selected CUDA device, obtain its public adapter identity, and select a matching enumerated graphics adapter by UUID/LUID unless the graphics index was supplied. Validate the actual created devices using `queryRoute`. A mismatch, unsupported shared format or missing native timeline capability returns an actionable unsupported result; do not stage through the host or silently choose another route.

- D3D11: supported on the validated Windows same-adapter route using unkeyed NT 2D textures (`Shared_NTHandleUnkeyed`) and D3D11.4 timeline fences. It needs no shared buffers or keyed mutexes. Existing `Shared_NTHandle` keeps its keyed-mutex semantics. The public exporter rejects KMT textures after a reproducible odd-dimension mapping fault; lower-level native KMT imports remain available.
- D3D12: supported using shared committed textures, shared timeline fences and public COMMON release/acquire handling.
- Vulkan: supported using shared dedicated images, external timeline semaphores and public GENERAL/EXTERNAL ownership transfer. Enable platform external-memory and external-semaphore extensions before device creation. Windows is validated; Linux fd execution still requires its own run.
- Cross-physical-adapter graphics sharing is currently explicitly unsupported. CUDA has no raster/presentation path, so a bare `-cuda` is not an alternative to selecting a graphics API.

## Implementation order and acceptance

1. Preserve the original main as `legacy-main.cpp`. Extract or reuse GPU-independent OBJ parsing/normal preparation and camera/transform math without linking the legacy gp runtime into the migrated target. Continue using the standalone VBX loader and `SlangVolume`.
2. Add Slang mesh raster and composition stages reproducing Simple/FullScreen behavior. Compile DXBC/DXIL/SPIR-V artifacts. Add a dedicated depth-clipping compute stage using the shared depth/output textures and packed volume data; compile PTX and optionally graphics compute targets for diagnostic same-API comparison. Keep its parameter layout separate from the stable generic 224-byte `RaycastParameters`.
3. Add a renderer that prepares resources once and records each frame into ordinary NVRHI lists with the queue sequence above. Integrate the actual Lucy/explosion scene, original controls, resize and screenshot/headless paths.
4. Add deterministic headless tests on each graphics-to-CUDA route: rasterized occluder before/inside/behind a constant sparse volume, empty depth, center/off-axis pixels, translated/rotated/nonuniformly-scaled instances, near/far edges, resize/reimport and multiple frames without host waits. Verify raster R32_FLOAT attachment import and image row orientation explicitly. For compatibility compare the documented discrete integration/composition formula; for exact depth compare analytic unprojection, not the legacy depth approximation.
5. Run actual `lucy.obj`/`explosion.vbx` fixed-camera screenshots and compare the preserved legacy target where its environment is available. Record nonzero mesh/volume coverage, occlusion changes and tolerant cross-backend image differences. Run native DX11/DX12/Vulkan validation, CUDA Compute Sanitizer and resource-lifetime teardown checks. The existing integer-texture round-trip tests establish the API route; they do not establish depth-map visual parity.

## Execution record

- Migrated `main.cpp`, `DepthMap.cpp/.h`, Slang raster/composition and clipping kernels, analytic fixtures, and conditional CMake are implemented. `legacy-main.cpp` remains the fallback. The default cross-API mode, adapter selection, original scene/transforms, mouse controls, resize, screenshots, same-graphics compute and explicit exact-depth mode are available.
- All 12 depth-map CTests pass: analytic 21-case fixtures and Lucy/explosion asset validation on D3D11/D3D12/Vulkan, each with CUDA and same-graphics compute. Three public interop 65x33 tests also pass. Native graphics validation passes all three CUDA depth-map routes and all three public interop routes.
- CUDA Compute Sanitizer reports zero errors for all six runs: three depth-map analytic routes and three public interop routes.
- Vulkan needed `VkPhysicalDeviceDepthClipEnableFeaturesEXT` queried and enabled when the extension is requested. This preserves the original NVRHI raster default (`depthClipEnable=false`), including near/far depth-clamped geometry while the projected-depth MRT still stores its unclamped value.
- Fresh 65x33 D3D11 KMT mappings faulted on independent texture fetch and surface store kernels. Allocation-size padding, alternate array flags and one-layer mapping did not fix them. Unkeyed NT resources using the same GPU timeline protocol pass all analytic cases. The new explicit flag keeps existing keyed-resource semantics intact; public route capabilities now supply the required texture flags.
- Captured preserved legacy DX12/CUDA and migrated DX12/CUDA at 1024x768, default camera/scene. Mean absolute RGB difference: 0.0057119/255 over the full image; 0.080548/255 over the union of foreground pixels. Maximum channel difference 57; 0.157038% of pixels differ by more than 1 and 0.0204722% by more than 8. These are measured tolerant parity results, not bit identity. Captures: `build/depth-map-legacy.png`, `build/depth-map-new.png`; source baseline built separately with portable GVDB disabled.
- The 1024x768 migrated asset check sees 15476 mesh pixels, 43549 volume pixels and 9732 pixels with measurable clipping. No regular-frame host staging or CPU wait is added.

Validation logs are under aggregate `build/depth-map-nt-tests.log`, `depth-map-validation-*.log`, `interop-nt-validation-*.log`, and `depth-map-memcheck-*.log`/`interop-nt-memcheck-*.log`. Remaining hardware scope: Linux file-descriptor paths and physical cross-adapter routes require separate hardware runs; cross-adapter graphics sharing continues to return unsupported.
