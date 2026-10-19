# Interactive mixed-scene owned snapshot migration

Status: authorized implementation continuation, 2026-10-19.

Replace the interactive-optix application's legacy SlangVolume allocation with a
public serializer/import publication and explicit public apron refresh. Retain
its CPU VBX input/analytic fixtures and use the existing synchronous sample I/O
helper, which records, submits and waits visibly outside the public core. Pass
the retained snapshot directly to the mixed RT renderer's raw scalar path. Scene
controls, transforms, materials, camera, transfer and progressive sampling stay
unchanged. The viewer receives snapshot metadata; no legacy GPU volume remains.

Verify original analytic equations and control tests, raw snapshot/device identity,
malformed input rejection and retained publication lifetime. Compare all four
rendering modes against preserved portable captures on D3D12/Vulkan/CUDA OptiX,
run native validation on both graphics adapters and CUDA memory checking, and
check production configuration without tests or CUDA discovery. Keep broader
legacy visual/performance and external platform gates explicit.
