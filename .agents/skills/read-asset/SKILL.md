---
name: read-asset
description: Inspect Portemon Nitro's local generated HGSS asset cache, including Lua manifests, textures, meshes, collision data, and audio. Use when an agent needs to locate, inspect, or compare compiled cache files; prepare missing or stale derived assets; or read physically compressed cache payloads without interpreting the PDC1 envelope by hand.
---

# Read Asset

Inspect **derived** cache files through the owning cache reader, not by opening physical bytes directly. This skill does not extract the retail ROM or change the runtime asset contract.

## Workflow

1. From the repository root, identify the **version** (`heartgold` or `soulsilver`), **owning job** (`kind:key`), and **cache-relative file path**. Find paths in `libs/assets/src/*Cache.lua` (or a manifest) and job names in `romdump/src/build/ArtifactState.lua` and `romdump/src/build/ArtifactJobs.lua`. Do not guess a job from a similarly named directory: shared files, page jobs, and global manifests have distinct owners.
2. If the file path is not yet known, prepare the job and list a narrow directory:
   ```sh
   .agents/skills/read-asset/scripts/read-asset.sh --version heartgold --require easy-chat:global --list data/generated/easy-chat
   ```
3. Prepare and materialize the requested **logical** bytes into a unique ignored working directory:
   ```sh
   .agents/skills/read-asset/scripts/read-asset.sh --version heartgold --require easy-chat:global --path data/generated/easy-chat/manifest.lua
   ```
   The command prints `decoded_file=...`, `bytes=...`, and `sha1=...`. Read that file with ordinary text, image, binary, or audio inspection tools. For another example, `--require map:7 --path data/generated/maps/0007/collision.g4collision` targets a map-scoped collision file (verify the map ID and owning job before running).
4. If no ROM has been registered, add `--rom-source tmp/<your-supported-rom>.nds` to **validate and register** that user-owned file before preparing the job. Never copy the ROM or derived copyrighted files into the repository, tests, or skill bundle.
5. If a current receipt exists but the payload itself is damaged, or you deliberately need to repeat compilation, add `--rebuild`. Do not use `--rebuild` for ordinary staleness: the producer's development identity and job receipts already handle changed compilers.

## Contracts and boundaries

- The helper always runs `romdump --prepare-cache --dev --version ... --require kind:key`. That command owns job prerequisites, missing-file compilation, source selection, and current producer/contract identity. It does **not** build the complete corpus. Do not substitute `scripts/buildcache.sh` for a targeted read.
- The second, windowless LÖVE process uses `CacheFs:read` for exactly the requested version-relative path. This verifies and unwraps the canonical `PDC1` envelope (zlib for `.lua`/`.pcm16le`, LZ4 for `.g4mesh`/`.g4collision`); unwrapped files, including PNG, pass through unchanged. Corrupt envelopes are errors, not raw output.
- A successful job receipt does **not** guarantee that an arbitrary `--path` belongs to that job. If the requested file is absent, check the correct owner and path instead of suppressing the error. Likewise, `--list` lists a directory **after** preparation but does not prove the directory's files are all owned by that job.
- Generated `.lua` is a serialized data file; inspect its text, and do not execute it just to view it. For `.png`, open the decoded file as an image. For `.g4mesh`/`.g4collision`, use the project codecs in `libs/assets` for semantic parsing, or `xxd` for a byte-level check. `.pcm16le` is raw PCM; consult the audio bank metadata for its sample rate and channels before wrapping it as WAV.
- Output lives under ignored `.agents/tmp/read-asset.*`; clean it up after the investigation. The helper honors `PORTEMON_SAVE_DIR` via the standard `scripts/lib/dev.sh`/`scripts/lib/love.sh` setup; never hardcode `$HOME/.cache` or use a test runner's isolated cache as the product cache.
- A missing or inaccessible registered ROM is a real prerequisite failure when compilation is needed. Report it; do not fall back to a stale generation or fabricate a decoded asset. For original ROM NARC members, use `romdump`'s ROM/discovery tooling instead of this **derived-cache** reader.
