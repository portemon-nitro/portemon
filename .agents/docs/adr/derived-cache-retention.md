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
  current session and block the next incomplete-cache boot until the
  matching ROM is supplied again; a current complete cache boots offline
  without the file.
- A compiled asset becomes usable when its immutable bytes are installed in
  the selected generation's resident store, not when they reach disk. One
  background writer periodically saves a standard ZIP snapshot of the
  committed bytes and completion facts; gameplay never waits for it, and it
  is never read back during play. The next boot hydrates that snapshot into
  resident bytes before anything is ready, so a complete matching snapshot
  boots offline and a partial one is reused while the rest is compiled.
- A snapshot is a rebuildable convenience, not a durable record: a failed
  write, a failed rotation, or a damaged archive falls back to rebuild from
  the verified source. Nothing in normal play re-reads, re-hashes, or
  semantically audits a written snapshot, and no per-asset completion file
  proves anything separately from the bytes it describes. Resident bytes
  are dropped with the selection that owns them; the persisted snapshot is
  replaced whole, never patched, and an explicit cache clear is the only
  thing that removes it.
- Resident bytes are the authoritative copy while a version is selected, so
  the retention decision is now about memory as well as flash: compact base
  entries are retained in full for the live generation, and the RAM trade-off
  is accepted because the alternative is reopening storage on read paths the
  cache exists to keep off disk.

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

- Install footprint is dominated by one snapshot archive plus saves and
  bounded staging; peak runtime memory stays within the mobile budget by
  sharing one immutable source buffer across compiler workers only while
  source-dependent work remains, then releasing it, and by keeping the base
  cache's compact bytes as the only full-corpus resident copy.
- A snapshot that reaches disk is trusted until the next boot parses it; a
  crash between write and replacement leaves the previous snapshot (or its
  backup) recoverable, and no write makes play wait for a durability
  acknowledgment.
- Installations predating this layout are not migrated or deleted by the
  project: the developer removes old pre-release cache roots by hand once.
  Existing saves and mods are never deleted, and no legacy extracted tree
  is converted or retired automatically.
- No background collector, retention ledger, or per-job reference proof
  exists: a superseded generation's snapshot is replaced whole at the next
  successful write, and shared bytes inside the resident store live exactly
  as long as the generation that owns them, which is accepted.

## Revisit when

- Measured peak memory on the target mobile configuration exceeds the
  budget with evidence that source sharing or decode batching cannot close
  the gap; or
- a supported platform offers a real persistent user-file access primitive,
  in which case only the ephemeral-source rule is revisited, not retention.
