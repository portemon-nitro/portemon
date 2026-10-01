# app Agent Guidance

Read root `AGENTS.md` first. `app` is the interactive LÖVE process shell and owns
Portemon-created product surfaces and tooling above concrete retail-game applications.

## Process and provisioning ownership

- `app/main.lua` and `app/conf.lua` own process callbacks and the interactive LÖVE root.
  `app/src/App.lua` owns launcher state, version selection, ROM file-drop import, cache
  readiness routing, the startup Main Menu, and the current process-exit policy. A future
  save editor is product tooling and belongs here; it should consume reusable save/domain
  libraries rather than import retail application internals.
- The startup Main Menu is selected-version-aware product UX. It may use reusable HGSS
  mechanisms without becoming part of the retail HGSS application.
- `app` may call `romdump` only for the current ROM provisioning/source workflow. Keep ROM
  identity and importer concepts at that boundary; do not leak them into the running-game
  host or reusable runtime mechanisms.
- The shell enters a concrete retail application through `game.hgss.src.HgssGame` and owns
  the returned running-game lifecycle. Retail behavior must use this entry seam rather than
  importing retail internals. An updater, when implemented, belongs here; no updater or
  generic provisioning API is defined by this package.
- `app` may consume reusable libraries admitted by `tests/architecture/module_boundaries_test.lua`;
  this is not permission to import arbitrary packages. Retail application policy belongs in
  `game/<family>`, and the generic running-game host belongs in `game/src`.

## Boundaries and tests

- File drops remain an app concern, including while a running game is active. `Game` has no
  file-drop or ROM-provisioning API.
- Preserve the current quit behavior: a concrete game requests exit through its `Game` host,
  and the app maps that request to process termination.
- App tests cover launcher/options and process-shell composition. Structural dependency
  ownership is enforced by `tests/architecture/module_boundaries_test.lua`; do not add
  documentation wording tests or a game registry to enforce it.
