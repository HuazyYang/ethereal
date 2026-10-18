# Mixed mesh/volume Slang ray tracing

This is the next implementation contract under the approved Slang-next plan. It is not an implemented-feature claim.

## Purpose and retained behavior

Generalize the legacy `sample-utils/OptixRenderer` into a renderer using only NVRHI ray-tracing interfaces and offline Slang artifacts. `interactive-optix`, `fluid-surface`, and `point-cloud` need transformed meshes and sparse volumes in the same scene. Preserve the material fields, scene-file values, environment map, progressive sampling/reset, and the four volume intersection modes. Retain the legacy implementations until comparison gates pass.

D3D12, Vulkan RT, and CUDA/OptiX execute the same scene shaders. D3D11 reports unavailable ray tracing explicitly; its existing compute volume path remains a separate supported mode. No application code calls native SDKs.

## Host and shader contract

- An SDK-free `SceneMaterial` mirrors the legacy ambient/diffuse/specular, reflection/refraction, light/shadow scatter, biases, environment/checkerboard fields and defaults. Upload an explicitly aligned float4 representation, not the host math struct's incidental packing.
- Meshes contain validated indexed positions/normals. Per-instance metadata selects geometry and material. NVRHI BLAS/TLAS handle transforms, geometry replacement, and topology updates; retained resource handles cover in-flight work.
- Volume descriptors snapshot the portable VolumeInfo and scalar/raw RGBA/topology resource handles, transfer function and marching controls. Share existing GPU resources without host atlas readback. Start with a documented fixed maximum of eight volume bindings, validate the limit, and bind valid defaults to unused array entries. Test artifact/resource-array ABI before depending on it.
- Keep ray payloads ordinary Slang data. Shader records identify hit groups; instance metadata selects resources/materials. Avoid CUDA payload pointers and Vulkan-only addresses.
- Use distinct radiance, shadow, and refraction hit groups where legacy intersection behavior depends on ray purpose. Instance masks distinguish deep volumes, level sets, other surfaces and meshes; continuation rays can exclude deep volumes without reading payloads in an intersection shader.
- Surface and level-set modes retain their respective sign conventions. Empty-space skipping must preserve the visible surface; it is not a different placeholder image. Deep volume color composes over the remaining mesh/surface scene using the documented legacy alpha convention.
- Preserve deterministic per-pixel random state across samples. Sample zero resets accumulation; camera, geometry, material, environment, and resolution changes reset it. Bound recursion and use NVRHI/OptiX stack configuration.

## Gates

1. Compile the shared library for DXIL, SPIR-V, and OptiX; independently test resource arrays, payload and attributes on each backend.
2. Analytic mesh/volume occlusion and continuation, signed transformed level sets, nonuniform normals, multiple materials/instances, shadows, reflection/refraction including total internal reflection, environment lookup and progressive reset.
3. Geometry/topology/transform replacement and resource lifetime tests with native validation and CUDA memory checking.
4. Original explosion/Lucy scene, point-cloud scene file and fluid/ground scene with fixed camera and deterministic sample counts. Compare images across APIs and against the fresh legacy reference, documenting numerical and intentional differences.
5. Integrate all three applications and retain interactive controls, finite-frame screenshots and headless execution. Removing legacy production dependencies follows these gates, not merely successful shader compilation.

## Concrete data layout and compatibility

The first implementation uses eight resource arrays at t16/t24/t32/t40/t48/t56 for scalar, nodes, children, levels, packed color and transfer data. Their independent probe checks distinct array elements and each structured stride on DXIL, SPIR-V and OptiX. Instance and mesh metadata are uint4 records; materials are eight explicitly packed float4 values.

Volume metadata is 160 bytes: VolumeInfo, original steps/extinct/cutoff vectors, threshold (iso/min/max/missing scalar), and resource/mode indices. Deep integration retains the signed Beer coefficient, albedo, nearest transfer lookup and legacy composition. The 272-byte scene constant struct contains the existing camera, sample/scene counts, separate dataset frame and RNG seed, and world-space point-light position; constant storage is padded to 512 bytes.

The fifteen hit groups are mesh/surface/deep/level-set/empty-space modes times radiance/shadow/refraction. The ordinary 32-byte payload includes its own random state; procedural attributes use 20 bytes. A deterministic per-pixel seed replaces legacy shared seed races and platform-dependent srand output. Progressive averaging starts at sample zero and keeps sample one, correcting the old second reset. These are explicit compatibility differences, not pixel identity claims.

Initial geometry replacement and renderer destruction synchronize before releasing BLAS resources because Vulkan TLAS objects do not retain their BLAS inputs. Future asynchronous replacement must retain complete scene generations until completion. These synchronization points do not change the separate depth-map interop path's GPU-only normal-frame ordering.
