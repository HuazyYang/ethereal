# Interactive mixed-scene owned snapshot migration

Status: implemented; focused Windows acceptance recorded, 2026-10-19.

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

## Acceptance

The production scene now serializes its CPU input for public import, explicitly
refreshes scalar aprons, and retains the resulting snapshot as its sole GPU
volume. Metadata and mixed RT bindings refer to that same publication. Original
CPU packed data remains only as input/topology-overlay data, not a GPU renderer.

All15 analytic and asset tests pass across D3D12/Vulkan/CUDA OptiX (16.25 seconds).
They include four shading modes, original equations/controls, malformed-input
rejection, same-device raw snapshot identity, and rendering after the application
scene/temporary owner are destroyed. All12 captures are byte-identical to the
preserved portable reference. Both graphics adapters pass D3D12/Vulkan native
validation; CUDA memcheck reports zero errors. A tests-disabled and CUDA-discovery-
disabled production build renders the real asset with explicit AMD D3D12 native
validation and coverage checks. Evidence: `build/m5-interactive-owned`.

The prior339/339 and256/256 full matrices precede this consumer-only change;
focused acceptance above validates this slice. No broad performance, legacy
visual parity, Linux or reference-retirement completion is claimed. Fluid
ownership and pending deposition/other kernel roles continue.
