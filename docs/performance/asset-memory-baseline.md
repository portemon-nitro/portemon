# Retained-session asset memory baseline

This file pins the before-change memory picture for the retained-session
replay: one deterministic harness journey over one derived-cache generation
with attributed snapshots at field, travel, Bag, and return boundaries.
Later representation and ownership changes compare against this trace.

## How to reproduce

Run the focused replay from the repository root:

```sh
scripts/test.sh --filter "asset_memory"
```

The replay boots a fresh save on `MAP_BURNED_TOWER_1F`, waits for field
entry, walks up to three verified-passable adjacent tiles in fixed
preference order, opens the Bag over the retained start menu through the
production inventory service, then closes back to the field. Every leg
captures one snapshot through `tests/support/AssetMemoryTrace.lua`; the
last suite in the filter also asserts the replay stops before GPU
rendering (`renderAttempts() == 0`).

Reference run (acceptance authoring machine):

- Source HEAD: `fcfb76cb`
- Game version: `soulsilver` (user-owned dump, private test cache)
- Derived requirements prepared: `field-runtime`, `map:7`
- Capabilities observed: `derived_assets`, `graphics`, `rom_dump`
- Result: 11 passed, 0 failed, 0 skipped; replay leg ~2s, audio fingerprint legs <0.1s

Renderer identity, GPU image/canvas counts, and texture bytes are captured
per snapshot from the injected graphics namespace when the graphics
capability is present. Without graphics the same fields are recorded as
explicit unavailable markers, never zeros.

## What is measured, and what is not

Each checkpoint stores separate scalar fields per family:

- Lua heap kilobytes, read once per checkpoint (never per frame).
- Audio retained bytes: no public retained-byte counter exists on the
  audio provider yet, so replays record an explicit unavailable marker.
- GPU images, canvases, and texture bytes from the graphics statistics
  query when graphics are present, otherwise an explicit marker.
- Process RSS and peak RSS: sampled only by an external OS sampler while
  the game process runs, attached by timestamp offline. The in-process
  trace never fabricates them and records an explicit marker instead.

Frame times accumulate into 32 fixed five-millisecond buckets plus a
running sum; snapshots live in a 64-entry ring. The observer holds no
per-frame arrays, calls the collector only through the explicit
checkpoint heap read, and refuses non-scalar facts so it can never retain
a live image, sample buffer, or callback.

No pinned numeric baseline is recorded here yet: the replay test asserts
the attribution structure but writes no artifact files, and the manual
hardware pass below has not been run on target hardware. Do not treat
whole-disk census numbers (PNG path counts, theoretical RGBA payload
totals) as live RSS estimates; they are different accounting domains.

## Pre-change fidelity anchors

The replay structure above proves attribution; exact output bytes are
pinned by the suites below, all passing at the reference HEAD. Later
representation and ownership changes compare against these anchors.

PCM storage and mixer streams (synthetic bytes, no ROM; owned by the
retained-session acceptance suite
`tests/acceptance/asset_memory_lifetime_acceptance_test.lua`):

- `audio_retained_bytes_count_unique_sample_keys_once` — distinct
  content keys decode distinct arrays, a repeated key shares its array,
  and retained bytes count unique keys once at two bytes per frame.
- `provider_decoded_pcm_fingerprints_pin_the_pre_change_storage` —
  rolling fingerprints over the exact decoded arrays for a looped
  sample, a one-shot sample, and the reversed-cry copy through the
  production WaveOut reverse path, plus one overlapping two-voice mixer
  render with a determinism double-run.
- `composed_audio_streams_fingerprint_the_pre_change_mix` — exact
  mixer output through the production audio composition for a looping
  music sequence, a finite fanfare, a looping radio sequence on the
  key-split voice, fanfare-over-music, and fanfare-over-radio, with a
  determinism double-run of the music leg.

Behavioral audio ownership (suites that pin the semantics the
fingerprints above assume):

- `libs/hgss/tests/audio/audio_asset_provider_test.lua` — lazy
  memoized loads, shared decoded arrays, exact decoded values.
- `libs/hgss/tests/audio/cry_player_test.lua` — cry pattern routing
  and the reversed-playback sample contract.
- `libs/nds/tests/nitro/sound/voice_mixer_test.lua` — exact
  channel volume, envelope, pitch, pan, and span rendering vectors.
- `tests/acceptance/pokegear_radio_audio_lifetime_acceptance_test.lua`
  — scripted stops, music changes, map entries, battle holds, and
  fanfares around radio through the composed stack.
- `tests/acceptance/game_audio_acceptance_test.lua` — shared core
  and field audio reach the output host with non-silent PCM.

Pixel output (suites that pin current on-screen bytes; the
retained-session replay itself stops before GPU rendering):

- `tests/graphics/asset_preparation_graphics_test.lua` — the real
  worker decodes image payloads to ImageData without touching graphics.
- `tests/graphics/field_state_backdrop_graphics_test.lua` — field
  backdrop pixel goldens.
- `tests/graphics/bag_renderer_graphics_test.lua`,
  `bag_opening_wipe_graphics_test.lua` — Bag visual goldens.
- `tests/graphics/summary_renderer_graphics_test.lua`,
  `summary_production_graphics_test.lua` — Summary visual goldens.
- `tests/graphics/map_renderer_graphics_test.lua` — map scene goldens.

## Manual hardware pass (open)

On target OpenGL hardware, with the same derived-cache generation and the
same scripted travel state:

1. Start an external sampler (OS peak-RSS query and GPU memory readout)
   alongside the game process.
2. Drive the field, Bag, summary, PC, and battle boundaries, holding each
   named state for a fixed idle horizon before capturing.
3. Attach the externally sampled RSS/HWM series to the trace checkpoints
   by monotonic timestamps.
4. Name the artifact with the short source SHA and the renderer slug
   (`asset-memory-baseline-<sha>-<renderer>.json`); record resolution,
   driver version, viewport, and OS beside it.

The summary, portrait, PC, and battle legs need stocked saves and travel
to owned flows, so a fresh-save replay reserves their checkpoint names in
canonical order without fabricating them. Whole-process 1 GiB conformance
is proved by this external RSS/HWM capture, never by texture counters
alone. Software rasterizer timings must not set idle budgets.

## Indefinitely retained resource families (source audit)

Renderer objects are retained separately from their image variants; the
first list stays warm for field life while the second is the
cardinality risk. Owners below are the current production seams at the
reference HEAD.

Field-lifetime renderer objects (kept warm, images counted separately):

- `game/hgss/src/field/FieldPresentationResources.lua` — window, dialogue,
  start menu, and party chrome plus the current item atlas.
- `libs/hgss/src/ui/StartMenuRenderer.lua`, `FieldWindowRenderer.lua`,
  `FieldDialogueRenderer.lua`, `FieldTextRenderer.lua` — fixed chrome.
- `libs/hgss/src/presentation/GpuAssetPool.lua` — scene-lifetime map
  meshes and images; the shared image owner once consumers converge.

Cardinality-growing image state (one entry per encountered variant,
released only on owner disposal unless an idle cap applies):

- `libs/hgss/src/presentation/MonIconAssetProvider.lua` (`_images` by
  page id, cleared on `dispose`) — party icon pages accumulate for the
  whole field session.
- `libs/hgss/src/ui/PcStorageRenderer.lua` (`_images` by visual key,
  cleared on `dispose`) — PC visuals accumulate until disposal.
- `libs/hgss/src/ui/BagRenderer.lua` (`_images` by visual key) — state
  visuals resolved per Bag opening; the constructor realizes the pocket
  visual set eagerly.
- `libs/hgss/src/audio/AudioAssetProvider.lua` (`_samples` memo) —
  decoded sample arrays stay resident for the process lifetime.
- `libs/hgss/src/presentation/FieldActorAssetProvider.lua` — idle
  sprites capped at eight entries with oldest-idle eviction.
- `libs/hgss/src/interaction/FieldMessageProvider.lua` — idle message
  banks capped at four with oldest-idle eviction.

Single-owner or transitional image sites (not retained-session state,
listed so later convergence work can account for them):

- `game/hgss/src/field/FieldBattlePresentation.lua`,
  `SummaryPresentationResources.lua`, `game/hgss/src/newgame/OakIntroComposition.lua`,
  `libs/hgss/src/presentation/ItemIconAssetProvider.lua`,
  `libs/hgss/src/ui/MartRenderer.lua`, `TrainerCardRenderer.lua`,
  `ApricornBoxRenderer.lua`, `FieldSignpostRenderer.lua`,
  `PartyScreenRenderer.lua`, `PhotoAlbumRenderer.lua`,
  `MailboxRenderer.lua`, `YesNoPromptRenderer.lua`,
  `app/src/saveeditor/SaveEditorRenderer.lua`,
  `game/hgss/src/field/FieldState.lua` (overlay icon cache).

Audio PCM today is per-sample Lua integer arrays decoded once per key and
shared across consumers; there is no public retained-byte counter yet.
Texture statistics and process RSS are different accounting domains and
are reported in separate fields for that reason.

## Predicted working-set calibration (appended after idle-budget preloading landed)

Nothing above is modified: the pre-change picture stays pinned, and this
section only records the calibration for the current/near preloading and
idle-budget trim that landed later.

Method: run the same replay with idle retention disabled (zero-idle
control) and take the externally measured process high-water from that run
as `H`. From the replay metadata take `A`, the maximum distinct predicted
idle PCM bytes, and `I`, the maximum distinct predicted physical image
bytes. The combined safety-capped allowance is
`B = max(0, 1 GiB - H - 128 MiB)`; when `A + I > 0` the per-family limits
are `audioLimit = floor(B * A / (A + I))` and `imageLimit = B - audioLimit`,
otherwise both are zero. The split is a conservative admission heuristic,
not a claim that image bytes equal process RSS; the external high-water
gate on target hardware remains decisive.

Host honesty: this host renders in software, so no number below is
presented as target-device calibration. Target-device high-water and
compiled limits stay pending until they are measured on hardware.

Local observations (soulsilver user-owned dump, same derived-cache
generation as the reference run):

- Zero-idle control over the live map-2 closure (audio banks 700 and 702,
  322 distinct sample keys): idle retention disabled, predicted 1,815,056
  bytes, resident 0 bytes, uncovered 1,815,056 bytes. Repeating the round
  reloads instead of retaining (158 reloads after the first pass, 480
  after the second; 644 decode misses total), and each bank call decodes
  its keys independently (3,527,328 payload bytes decoded for 1,815,056
  distinct predicted bytes). The control visibly retains nothing.
- Lua heap observed around the control: about 69,824 KiB before and about
  86,360 KiB after. That is an in-process heap observation, never a
  process high-water.
- Distinct predicted idle PCM for the measured map (`A`): 1,815,056 bytes.
  This is one map's closure, a lower bound for a full-replay maximum, not
  the maximum itself.
- Distinct predicted physical image bytes for the same replay (`I`): not
  measured on this host; no image-byte census was run here.
- Process high-water without idle retention (`H`): not measured on this
  host; no external sampler run and no target-device run exist yet.
  Graphics stayed explicitly unavailable in the control probe, never
  zero-filled.

Resulting limits: the target-device high-water measurement is pending, so
no allowance or per-family limit is compiled from these numbers. The
shipped first-pass defaults are the audio idle budget's compiled 32 MiB
value and the shared image pool's compiled 64 MiB value; both stay pending
target-device calibration and neither is derived from the host numbers
above. If live/pinned usage already exceeds the
whole-process target on the target device, the release gate fails rather
than manufacturing a cache success. Software-rasterizer timings must not
set idle budgets.

## Full-session release comparison (appended for the hardware rollout validation)

Nothing above is modified: the pre-change picture and the calibration
appendix stay pinned, and this section only records the paired warm/cold
harness plus the honest local run for the compact-representation rollout.

Paired protocol (target hardware, still pending): the same scripted
journey at the reference and optimized commits, three warm passes per
image policy (compact and straight representations through the same
owner) plus one cold-cache pass, with identical ROM, viewport/scale,
cache state, and warmness. An external OS sampler overlays process RSS
and high-water joined to trace checkpoints by timestamp; GPU measurement
synchronizes with readback/fence where supported. Release thresholds:
whole-process high-water under 1 GiB with narrower PCM/image/worker/GPU
attribution, first usable frame within one 60 Hz frame of the reference
at matched cache state, 3-run median p95 frame time within 1.05x of the
straight policy and p99 within 1.10x with no repeated >20 ms upload stall
at visible state boundaries, and bit-exact image/audio output across
policies. Software-rasterizer timings never set budgets and never approve
the compact representation; an unmeasured high-water blocks the release
claim instead of passing it.

Local honest run (acceptance authoring machine, software rasterizer):

- Focused suites: `asset_memory` 14 passed, `image_sampling` 5 passed,
  `module_boundaries` 14 passed; 0 failed, 0 skipped throughout.
- The paired-harness test records six warm snapshots (three per image
  policy) plus one cold snapshot with process RSS/high-water as explicit
  unavailable markers, and the release verdict on this host is
  `hardware-pending` with the software-rasterizer reason named. Native
hardware without a measured high-water stays pending; a measured
over-ceiling high-water fails rather than manufacturing success.
- The audio comparison test reproduces the pinned music,
  fanfare-over-music, radio, and fanfare-over-radio mix fingerprints on a
  second independent composition, so the paired image-policy passes share
  one audio baseline.
- The missing-input test proves unknown sample keys and unknown bank
  references raise through the provider error contract and name the
  missing reference instead of rendering silence.
- The paired-capture graphics test renders a three-frame material swap
  under indexed and straight sampling with fog and lighting live, under
  repeat and mirrored-repeat wrapping: every frame matches across
  representations, the swap visibly changes the frame, and returning to
  the first material restores its frame.
- The straight-fallback graphics test draws through the shared sampler
  without consulting the format probe and proves a failed draw restores
  the caller shader and tint before re-raising.

Explicit fallback list (all covered by the suites named in parentheses):

- No indexed-texture support: straight RGBA8 through the same pool and
  sampler, never a second loader (`devices_without_indexed_support_fall_back_to_straight_rgba`).
- Shader/state failure at draw time: caller shader and tint restored,
  error re-raised, nothing adopted
  (`straight_fallback_draws_without_indexed_support_and_restores_state_on_failure`).
- Corrupt disposable derivative: rebuilt off the trusted source while the
  published asset stays untouched (`rebuilt_derivative_replaces_a_corrupted_private_file`,
  `failed_writes_keep_the_previous_valid_derivative`).
- Missing generated source: hard failure without poisoning the pool
  (`missing_sources_fail_without_poisoning_the_pool`; a missing trusted
  PNG or audio sample never becomes silent success).
- Audio read failure: structured provider error naming the missing
  reference (`missing_trusted_audio_inputs_fail_loudly_instead_of_rendering_silence`).

Pointer: the full device/driver identity, the disk-study numbers, and the
explicit pending native-hardware procedure live in
`docs/performance/asset-memory-results.md`.
