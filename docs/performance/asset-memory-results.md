# Compact asset residency: memory, fidelity, and storage results

This document records the end-to-end memory/native-GPU comparison and the
disk read/decode study for the compact asset residency work: packed audio
PCM, one shared image owner with compact/straight representations,
predicted current/near preloading, and bounded idle trimming. It reports
what was measured on the authoring machine, names exactly what is still
pending on native hardware, and never presents software-rasterizer numbers
as device calibration.

## Host honesty

The authoring machine renders in software (llvmpipe under LÖVE 11.5) and
has no external process sampler attached. Consequences, stated plainly:

- The indexed-texture format probe answers *supported* even here, so the
  paired indexed/straight comparisons below execute rather than skip. That
  proves pixel exactness across representations, not hardware frame times:
  llvmpipe timings must not approve the compact representation and must not
  set idle budgets. No llvmpipe result is ranked against hardware.
- Whole-process high-water was not measured here. The 1 GiB release
  comparison is recorded below as an explicit pending procedure with exact
  reproduction steps, never as a pass.
- Game versions exercised: soulsilver for the focused suites (user-owned
  dump through the private test cache), heartgold derived files for the
  disk study sample. No ROM bytes, personal paths, or commercial data
  appear in this document.

## Pinned host identity (this machine)

- CPU/renderer: `love.graphics.getRendererInfo()` reports name `OpenGL`,
  version `4.6 (Core Profile) Mesa 26.1.8`, vendor `Mesa`, device
  `llvmpipe (LLVM 22.1.8, 256 bits)` — software rasterization, not a
  native GPU. LÖVE 11.5, `SDL_VIDEODRIVER=offscreen` (the test runner
  default).
- Capability probe: `love.graphics.getImageFormats()` answers `r8=true`,
  `rgba8=true` even on this software device, so the paired
  indexed/straight comparisons execute here. That exercises pixel
  exactness only; frame-time approval stays gated on native hardware
  and no timing from this host sets budgets.

## Local evidence (measured on the authoring machine)

Focused suites, all green with no skips:

- `asset_memory` — 14 passed: the retained-session replay with attributed
  checkpoints, the bounded-tracer structure proofs, the unique-key PCM
  census, the pre-change storage and mix fingerprints, plus three new
  release-comparison tests (paired warm/cold harness with explicit
  process-memory markers and a `hardware-pending` verdict on this host;
  second-composition audio reproduction of every pinned mix fingerprint;
  loud failure on unknown sample keys and bank references).
- `image_sampling` — 5 passed: indexed/straight 2D draws match across
  repeat, mirrored-repeat, and clamp wraps with caller state restored;
  indexed/straight map frames match with fog and lighting live; the new
  paired-capture test matches a three-frame material swap across
  representations under repeat and mirrored-repeat wraps with swap
  liveness proved (changed frame, restored frame); the new fallback test
  draws straight RGBA8 through the shared sampler without consulting the
  format probe and restores caller shader and tint across a failed draw.
- `module_boundaries` — 14 passed: the production dependency direction
  still holds after the test/doc/support-only change.

Audio exactness: music, fanfare-over-music, radio, and
fanfare-over-radio mixer streams reproduce their pinned fingerprints
bit-identically on a second independent composition, so the paired
image-policy passes share one audio baseline and any future drift fails
in the comparison before it can be mistaken for an image-policy effect.

Image exactness: indexed and straight frames match byte-for-byte across
map rendering, non-identity UV transforms, 2D alpha, transparent RGB with
non-zero channels, fractional alpha, repeat/mirror wrapping, fog and
lighting stages, and animated material swaps. A device without
indexed-texture support prepares the same pixels as straight RGBA8
through the same pool (`devices_without_indexed_support_fall_back_to_straight_rgba`).

## Attribution domains (kept separate, never merged)

Payload model, physically resident VRAM, CPU-side retained data, Lua GC
memory, process RSS and high-water, temporary worker/queueing peak, and
mapped ROM source buffers are different accounting domains. The trace
stores each family in its own scalar field with explicit unavailable
markers; no checkpoint merges families into a combined total, and texture
counters are never equated with process memory. Per-domain local status:

- Derivative payload model: measured on derived-only samples (30 map
  textures model 27,792 bytes vs 107,520 raw; 3 large images model
  147,544 bytes vs 589,824 raw — roughly one quarter of raw RGBA).
- Resident VRAM (`love.graphics.getStats().texturememory`): observed
  through the trace harness where graphics is available; never reported
  as process memory on its own.
- LÖVE CPU-side retained data: worker payload ownership and pool byte
  counters account payload bytes per owner; the suites prove the
  counters move with publish/evict rather than leaking.
- Lua GC heap: about 69,824 KiB before and about 86,360 KiB after the
  zero-idle control round (in-process heap observation recorded with
  the calibration appendix, never a process high-water).
- Process RSS and high-water: unmeasured on this host — every paired
  snapshot carries explicit unavailable markers, and the release
  verdict stays pending until an external sampler captures them.
- Temporary worker/queue peak: background-queue pending/ready counts and
  high-water payload bytes are traced per checkpoint; GPU realization
  stays bounded to one image pair per owner update.
- Mapped ROM source buffers: none — the study reads already-generated
  PNG files, never opens the user ROM, and the runtime loads evicted
  assets from the complete derived cache.

The suites above prove the structure; only the pending external capture
below can prove the whole-process ceiling.

## Disk read/decode study (derived files only)

Opt-in diagnostic: `luajit scripts/perf/asset-disk-io-study.lua
<derived-png-dir> [max-files]`. It reads already-generated PNG files,
parses the stored-block stream with an independent read-only decoder,
verifies the Adler checksum, classifies the private-derivative byte model
(index bytes plus palette bytes at or under 256 exact colors, else
straight RGBA), optionally re-encodes through the production writer to
verify identical bytes, and measures one conventional zlib pass over the
same raw bytes when a system zlib is available. It never writes into the
sample directory, never opens the user ROM, and never mutates the
production cache, writer, or pipeline. A file it cannot parse fails the
run loudly instead of being averaged away.

Two honest samples from the private test cache (heartgold derived output):

- 30 map textures (1–16 KiB each): stored file bytes 110,408; raw decoded
  RGBA 107,520; derivative model 27,792 (all 30 fit the indexed shape at
  1–16 exact colors); conventional zlib 5,407 in ~1.3 ms. Cold file reads
  ~0.02–0.06 ms each, warm re-reads ~0.01 ms, decode ~0.02–0.45 ms,
  classification ~0.01–0.12 ms. Writer re-encode identical for 30/30.
- 3 choice-screen images (192 KiB each): stored 590,649; raw 589,824;
  derivative model 147,544 (all indexed, 3–13 exact colors); conventional
  zlib 5,447 in a few ms (3–7 ms across repeated runs on this host).
  Writer re-encode identical for 3/3.

Reading: conventional compression wins on *disk* bytes for these small
flat textures, while the derivative model wins on *resident* bytes (roughly
one quarter of raw RGBA here) — and disk size is not live memory. The
retained-cache policy keeps every derived file regardless; there is no
disk LRU and no writer migration in this change. A scoped writer change
would need its own evidence-backed proposal pinned to current code, not a
rider on this validation. If justified later, the study script above is
the instrument to re-run.

## Predicted working-set counters (validated, not yet calibrated)

The prediction path reports three byte/counter families per epoch:
distinct predicted bytes, admitted (ready) bytes, and the
predicted-but-unadmitted gap. Local validation, all green with no skips:

- `game/hgss/tests/field_prediction_preload_test.lua` — 5 passed:
  near sounds and images rest in RAM before first use, new predictions
  supersede stale audio work without dropping live sound, idle trim
  evicts only unleased work and reports pinned overflow, over-cap
  predictions report their gap without churn or demand failures, and
  explicit-limit budget trim keeps predicted work while evicting idle.
- Zero-idle control from the calibration appendix (live map-2 closure,
  audio banks 700 and 702, 322 distinct sample keys): predicted
  1,815,056 bytes, resident 0 bytes, uncovered 1,815,056 bytes — the
  control visibly retains nothing and each bank call decodes its keys
  independently (3,527,328 payload bytes decoded for 1,815,056 distinct
  predicted bytes).

Counter validation is therefore demonstrated; budget calibration is not:
`H` (target-device high-water without idle retention) is unmeasured,
`A` has only the single-map 1,815,056-byte lower bound rather than a
full-replay maximum, and `I` (predicted physical image bytes) is
unmeasured on this host. No allowance or per-family limit is compiled
from these numbers.

## Supported fallbacks (every one covered by a named suite)

- No indexed-texture support: straight RGBA8 through the same pool and
  sampler, never a second loader
  (`libs/hgss/tests/presentation/image_asset_pool_test.lua` ::
  `devices_without_indexed_support_fall_back_to_straight_rgba`).
- Shader/state failure at draw time: caller shader and tint restored,
  error re-raised, nothing adopted
  (`tests/graphics/image_sampling_graphics_test.lua` ::
  `straight_fallback_draws_without_indexed_support_and_restores_state_on_failure`).
- Corrupt disposable derivative: rebuilt off the trusted source while the
  published asset stays untouched; failed writes keep the previous valid
  derivative
  (`libs/assets/tests/image/runtime_image_cache_test.lua` ::
  `rebuilt_derivative_replaces_a_corrupted_private_file`,
  `failed_writes_keep_the_previous_valid_derivative`).
- Missing generated source: hard failure without poisoning the pool — a
  missing trusted PNG never becomes silent success
  (`libs/hgss/tests/presentation/image_asset_pool_test.lua` ::
  `missing_sources_fail_without_poisoning_the_pool`).
- Audio read failure: structured provider error naming the missing
  reference instead of rendering silence
  (`tests/acceptance/asset_memory_lifetime_acceptance_test.lua` ::
  `missing_trusted_audio_inputs_fail_loudly_instead_of_rendering_silence`).

## Pending native-hardware release procedure (not run here)

On a native hardware-accelerated OpenGL device, with the same user-owned
ROM, identical scripted journey, fixed viewport/scale, and matched cache
state and warmness at both commits:

1. Attach an external sampler (OS peak-RSS query and GPU memory readout)
   alongside the game process for the whole session.
2. Run three warm passes per image policy (compact, then forced straight
   through the same owner) plus one cold-cache pass, covering first-use
   Oak-to-bedroom, Bag on field start and across pocket switches,
   Summary/PC on selected mons, battle entry, and warp transitions.
3. Synchronize GPU measurement with readback/fence where supported; hold
   each named state for a fixed idle horizon before capturing; join the
   external RSS/high-water series to trace checkpoints by timestamp.
4. Compare: whole-process high-water under 1 GiB; narrower
   PCM/image/worker/GPU attribution than the reference; first usable
   menu/battle/field frame within one 60 Hz frame of the reference;
   3-run median p95 frame time within 1.05x of straight and p99 within
   1.10x with no repeated >20 ms upload stall at visible state
   boundaries; bit-exact image/audio output across policies.
5. Calibrate idle budgets from the measured control run: with idle
   retention disabled, take the externally measured process high-water as
   `H`, the maximum distinct predicted idle PCM bytes as `A`, and the
   maximum distinct predicted physical image bytes as `I`; the combined
   safety-capped allowance is `B = max(0, 1 GiB - H - 128 MiB)`, split
   `audioLimit = floor(B * A / (A + I))` and `imageLimit = B - audioLimit`
   when `A + I > 0`, else both zero. The split is a conservative admission
   heuristic, not a claim that image bytes equal process RSS; the external
   high-water comparison stays decisive.

Calibration status: `H` unmeasured (no target-device run yet); `A` has a
single-map lower bound of 1,815,056 bytes from the software-host control,
not a full-replay maximum; `I` unmeasured on this host. No allowance or
per-family limit is derived from these host numbers: shipped first-pass
defaults are audio 32 MiB and image 64 MiB (both pending target-device
calibration). If live/pinned usage already
exceeds the whole-process target on the target device, the release
comparison fails rather than manufacturing a cache success.

## Verdicts

- Fidelity (image + audio + fallback list): demonstrated on the authoring
  machine by the suites above.
- Predicted working-set counters (predicted/admitted/uncovered): validated
  by the prediction suite and the zero-idle control; device calibration
  of the idle budgets stays pending with the hardware run.
- Disk study: measured; no migration warranted from this data alone.
- Native memory ceiling, frame-time comparison, and budget calibration:
  HARDWARE-PENDING under the procedure above. Failing or unavailable
  hardware measurement blocks the compact-representation rollout and the
  memory-budget release claim; the portable straight path ships through
  the same owner in the meantime.
