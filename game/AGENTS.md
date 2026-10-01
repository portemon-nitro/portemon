# game Agent Guidance

Read root `AGENTS.md` first. `game/` is the retail-game layer. Its `src/` subtree is the thin,
game-agnostic running-game host and adapters; `game/<family>/` contains concrete retail-game
application reproduction and composition.

## Composition boundary

- `game/src/Game.lua` owns state replacement, update/draw and input forwarding, drawable-size
  reconciliation, exit notification, and exactly-once state disposal for one running game.
- `game/src/WindowConfig.lua`, `LocalClock.lua`, and `audio/LoveAudioSink.lua` own reusable
  host concerns that are not HGSS product policy. Repository-root reads belong to
  `libs/storage`.
- `game/src` must not import `app`, `game/hgss`, `libs/hgss`, `libs/nds`, or `romdump`.
  Concrete HGSS retail composition belongs in `game/hgss`; reusable HGSS mechanisms belong
  in `libs/hgss`.
- Portemon-created launcher, startup Main Menu, and future product tooling do not belong in
  `game`; they belong in `app`. `game/<family>` owns retail-game screens and observable
  application behavior, including when presented through Portemon's host.

## Application boundary

- A concrete `game/<family>` package creates a `Game` host and installs its retail states and
  services. `game/hgss` creates that host for HGSS. Keep
  `FieldSession` a field-simulation mechanism rather than treating it as a game entry point.
- Do not introduce a plugin registry, generic Gen-IV package, or hypothetical second-game
  interface. A second concrete game with a proven common lifecycle is the evidence needed to
  revisit this boundary.

## User-visible behavior

- Changes to production composition, persistence, transitions, scripts, ROM-derived gameplay,
  or other user-visible flows use the `acceptance-testing` skill before implementation.
- Keep semantic input/actions at the game boundary; do not bind domain behavior to incidental
  device events when the input layer already owns normalization.
- Preserve user saves across generated-cache rebuild/removal. See
  `.agents/docs/defensive-patterns.md`.

## Public/mod-facing APIs

- A mod-facing API is deliberate product surface. Add only the operations a current gameplay
  or modding requirement needs; do not mirror internals or add forwarding hooks for later.
- Keep game-specific APIs semantic. Source IDs/offsets/member paths are not runtime/mod API
  vocabulary unless a concrete feature establishes them as semantic identity.

## Tests

- Unit/component tests cover the host lifecycle and adapter contracts in `game/tests`; the
  concrete HGSS application tests live under `game/hgss/tests`.
- Acceptance exercises the real HGSS application and field composition where wiring or
  user-visible sequencing is the contract.
- Do not add production optionality just because a fake omits a required engine collaborator.
