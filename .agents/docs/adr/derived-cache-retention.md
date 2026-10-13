# ADR: Retain the full derived cache; the user's ROM stays outside managed storage

**Status:** Accepted
**Date:** 2026-10-13
**Scope:** Derived-cache lifetime, managed-storage contents, and user-ROM ownership.

## Context

The derived cache exists so play never waits on compilation: an authorized
background sweep warms the whole corpus after first play, urgent misses
preempt it, and teleports land on ready assets. The corpus is large, mobile
flash is constrained, and the obvious relief valve is eviction (quotas, LRU,
lazy-only warming). Separately, the compiler needs the original cartridge,
and the obvious convenience is keeping an extracted copy inside managed
storage so the source is always at hand.

Both conveniences trade away properties players feel directly: eviction
reintroduces loading pauses on content the sweep already warmed, and battery
churn from recompiling what was discarded; a managed source copy duplicates
up to 128 MiB per installation, confuses ownership of a file the user
supplied, and risks copyrighted bytes ending up where only project-owned
derived data belongs.

## Decision

- The complete derived corpus is retained indefinitely once warmed. There is
  no cache cap, runtime eviction, or sweep disabling, including on mobile.
  Storage pressure is answered with compact physical encoding of derived
  files, never by discarding ready assets.
- The user's original ROM file is the sole durable source of truth and is
  never copied, moved, repackaged, or deleted by the project. Managed
  storage keeps only a small per-version binding (location, canonical
  identity, selected archive member) plus validated identity, never source
  bytes. Sources that cannot be reopened later are usable in memory for the
  current session and ask for reselection only on a later compilation miss.
- A matching completion receipt authorizes reuse of derived assets without
  revalidation, ROM access, or decompression of anything but the requested
  payload. Superseded outputs are retired only with proof: owned roots move
  atomically with receipt-last publication, and shared content-addressed
  files are reclaimed only after a complete current generation proves every
  reference while no reader or worker is active.

## Alternatives considered

- Quota/LRU eviction with on-demand rebuild: rejected; it trades bounded
  flash for unbounded latency and battery cost on exactly the paths (map
  travel, menu opens) the warm cache exists to keep instant.
- Lazy-only warming on constrained devices: rejected for the same reason;
  the first-visit cost lands on every new area instead of once up front.
- Managed extracted source tree or compressed source pack: rejected; it
  duplicates the user's file inside project storage, grows every install,
  and weakens the rule that managed storage holds only project-owned
  derived data, small metadata, saves, and mods.
- Persistent source file handles across restarts on mobile sandboxes:
  rejected as invented platform API; the ephemeral-source binding states
  the limit honestly instead.

## Consequences

- Install footprint is dominated by compact derived assets, saves, and
  bounded staging; peak runtime memory stays within the mobile budget by
  sharing one immutable source buffer across compiler workers only while
  source-dependent work remains, then releasing it.
- Installations predating this layout migrate derived bytes in place and
  drop the extracted tree only when the remaining cache stays playable or
  a matching source is verified; otherwise the old tree is retained and
  the user is asked for the ROM when compilation actually needs it.
- Jobs compiled before per-job shared proofs existed stay playable but
  hold their orphaned shared files until a natural full rebuild proves
  the references; no forced redigestion manufactures proofs.

## Revisit when

- Measured peak memory on the target mobile configuration exceeds the
  budget with evidence that source sharing or decode batching cannot close
  the gap; or
- a supported platform offers a real persistent user-file access primitive,
  in which case only the ephemeral-source rule is revisited, not retention.
