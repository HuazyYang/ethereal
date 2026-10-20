# Mixed RT reference investigation

Status: implementation and focused Windows validation, 2026-10-20. Full project
acceptance remains open; this record does not retire the reference.

Fresh 1024x768, eight-sample Lucy/explosion captures exposed a level-set sampling
error and incomplete hierarchy-entry bias in the shared RT shader. Level sets now
start on the unrounded brick entry, matching `rayLevelSetBrick`; surface/deep
sampling retains the direct-step wavefront. All modes inherit epsilon from global
entry and ancestor descents. Zero gradients are resolved in world space so the
fallback remains camera-facing under nonuniform transforms.

The unchanged legacy level-set image is nearly black because `normalize(0)`
creates NaN attributes, and its nominally zero front offset propagates NaN into
the shading position. A diagnostic CUDA copy changed only:

```cpp
const float3 fhp = frontOfs == 0.f ? hitW :
    hitW + optixTransformVectorFromObjectToWorldSpace(nObj * frontOfs);
```

The diagnostic was compiled with the reference's compute_75, fast-math and OptiX
settings. Its PTX was installed only for the diagnostic capture and restored in
`finally`; retained source files were never changed. It confirms the finite
level-set appearance. It is separate evidence, not an unchanged reference pass.

Initial CUDA image errors in byte values (other APIs are close):

| Mode/reference | Mean RGB | Filtered mean RGB | Filtered volume ROI mean |
| --- | ---: | ---: | ---: |
| Deep/unchanged | 1.1830 | 0.5244 | 1.1457 |
| Trilinear/unchanged | 2.0286 | 0.5281 | 1.1763 |
| Empty-skip/unchanged | 2.0917 | 1.1543 | 4.6808 |
| Level-set/unchanged | 6.8589 | 6.4103 | 33.9670 |
| Level-set/finite-offset diagnostic | 1.8944 | 0.6340 | 1.7786 |

Filtering uses Gaussian sigma four. The fixed ROI is x=[500,880), y=[220,590).
The existing per-pixel RNG, accumulation and half-pixel camera corrections remain
explicit. Empty-skip at 64 samples still has filtered mean error 1.1423; its
remaining difference cannot be described solely as eight-sample noise. CUDA versus
DX12 full-frame means are 0.000087/0.00169/0.07045/0.06872 for the four modes;
secondary-ray boundary decisions can amplify small coordinate differences.
The follow-up below diagnoses the empty-skip difference and defines a matched
fixture without changing the zero-bias application default.

The expanded analytic suite checks unrounded entries, two descent biases,
near-plane clipping, and finite zero-gradient lighting under nonuniform scale.
All three RT backend suites pass. Native DX12/Vulkan validation passes on both
RTX4050 and Radeon780M; CUDA Compute Sanitizer reports zero errors. The 425/320
full matrices predate this shader change and must be rerun at the final checkpoint.

Reproduce captures with the committed `sample-utils/CompareLegacySceneRT.py`.
Local images, logs, diagnostic source/PTX and measurements are in
`build/acceptance/mixed-reference`; the diagnostic driver is
`build/acceptance/diagnose-normal.ps1`. These local artifacts are not packaged.

## Secondary-ray diagnosis and matched fixture

Aligned pixel centers and disabled jitter isolated the original empty-skip
difference. With zero secondary bias, mean RGB error was 0.81935, filtered mean
0.81608 and filtered volume ROI 2.90449, with 4,573 pixels differing by more than
eight. Disabling reflection reduced that count to 3,763. Disabling both reflection
and shadows left only one pixel above eight (mean 0.34861, ROI 0.42200). Keeping
the original secondary rays but using a matched 0.01-world-unit origin bias left
eight pixels above eight (mean 0.35213, ROI 0.40613). This isolates unstable
zero-bias self-intersection decisions rather than a primary traversal mismatch.
Diagnostic shader copies were restored after capture; production shaders did not
change during this investigation.

Both interactive applications now accept `--secondary-bias`, applying the same
nonnegative finite distance to reflection, refraction and shadow material fields.
The default remains zero. The production shaders, normal stochastic sampling and
original camera conventions then pass a matched 1024x768, eight-sample fixture.
Limits were fixed before a fresh holdout capture: mean RGB <= 2.5, Gaussian-sigma-4
mean <= 0.8, fixed volume ROI filtered mean <= 2.5, and cross-API mean <= 0.02.
Fresh holdout CUDA results (DX12/Vulkan are close):

| Mode/reference at bias 0.01 | Mean RGB | Filtered mean | Filtered ROI |
| --- | ---: | ---: | ---: |
| Deep/retained | 1.18338 | 0.52458 | 1.14419 |
| Trilinear/retained | 2.02820 | 0.53004 | 1.18514 |
| Empty-skip/retained | 1.62235 | 0.54116 | 1.26064 |
| Level-set/finite-offset diagnostic | 1.74822 | 0.60685 | 1.62650 |

All twelve backend/mode comparisons and cross-API checks pass. The unchanged
level-set reference is still reported and still differs substantially; it is not
counted as a visual pass. Its specific undefined-normal behavior has the explicit
finite-shading disposition described above. Likewise, zero-bias secondary-ray
boundary decisions are not promised to be bit-identical across hardware.

Reproduce the separate diagnostic with
`tools/capture-gvdb-finite-reference.ps1`, then run the committed comparison tool
with `--secondary-bias 0.01 --finite-levelset-reference <diagnostic PNG> --verify`.
The diagnostic script creates a source copy and restores the retained PTX in
`finally`, with an on-disk recovery copy for interrupted shells. Run it serially
with all other GPU work. Comparison reuse preserves recorded process timings and
rejects a mismatched bias. Results are under `build/acceptance/mixed-biased-holdout`.

The eleven mixed-RT inventory roles now have sample validation through these
matched original assets plus the independent analytic material/geometry suite.
This is fixture-specific acceptance, not universal legacy pixel equivalence.
Linux Vulkan/CUDA and supported real-peer acceptance remain outstanding; no
retained reference is retired.
