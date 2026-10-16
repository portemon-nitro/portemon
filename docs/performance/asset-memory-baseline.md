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
