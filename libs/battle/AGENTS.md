# libs/battle Agent Guidance

Read root `AGENTS.md` first. `libs/battle` owns the frozen executable battle
binding set: typed behavior, action, effect, format, and ruleset bindings
plus session-scoped effectiveness charts. It is pure Lua with no LÖVE,
source ROM, game, presentation, or native-byte decoding knowledge.

## Boundary

- Production modules under `libs/battle/src` may depend only on
  `libs.battle` itself, ordered composition from `libs.content`, the mon and
  item domains `libs.mons` and `libs.items`, and the source-independent
  foundations `libs.codec`, `libs.errors`, and `libs.math`.
- They must not import `libs.nds`, `libs.script`, `libs.hgss`, `libs.ui`,
  `libs.assets`, `game`, `app`, `romdump`, or `love`.
- Species, move, ability, and item records are never duplicated here; this
  package binds behavior identities to semantic keys and reads data records
  through their catalog owners.

## Contracts

- Behavior kinds stay separate with per-kind validation; duplicates and
  absent required fields fail loudly with structured errors naming both
  owners. Programming invariants use `assert`.
- Behavior definitions stay symbolic until the session layer resolves them:
  freezing validates shapes without loading implementation modules and
  without serializing functions.
- `BattleContent` is frozen per game instance. Lookups return detached
  copies; separate compositions never share chart or binding state.
- Charts resolve every directed pair with exact integer rationals. Unknown
  types, unknown pairs, and unknown rulesets fail explicitly; there is no
  neutral fallback and no mutable process-global chart.
- Contribution order decides registration precedence only. It never controls
  mechanics timing, which the session layer owns.
