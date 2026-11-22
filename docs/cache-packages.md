# Mod asset packages

A mod asset package is a ZIP file of already compiled generated assets that
replaces selected files of the installed generated cache for one game version.
Packages are read-only, they never join the base cache or its snapshot, and
their payloads stay on disk until something in the game actually asks for that
logical path.

## Where packages live

Packages are user-managed files inside the LÖVE save directory, under the
selected game version:

```text
mods/<versionId>/load-order.lua
mods/<versionId>/one.zip
mods/<versionId>/two.zip
```

`<versionId>` is the selected version's directory name (`heartgold` or
`soulsilver`), the same directory the generated cache lives under. The runtime
never rewrites these files and never downloads anything.

## The ordered load list

`load-order.lua` is an optional Lua data file. It returns a dense array of ZIP
basenames, lowest priority first:

```lua
return { "one.zip", "two.zip" }
```

- Missing file and `return {}` both mean "no packages": the game runs on the
  base cache alone and reads no package byte.
- Later entries win. In the example above, `two.zip` decides the content of a
  logical path both packages carry, and `one.zip` decides every other path it
  names.
- Basenames are matched against `mods/<versionId>/`; absolute paths, `..`,
  backslashes, and separators are rejected.
- A missing, unreadable, or malformed load list is an error, not an empty
  selection. A basename that names no ZIP is an error too.

## The package manifest

Every package carries `mod.lua` at its root. It returns exactly this record:

```lua
return {
  schema = "portemon-mod-v1",
  id = "example-textures",
  revision = "1",
  versionId = "<the installed version>",
  assetRevision = 0, -- use the installed value, not the placeholder
  scriptApi = 0,     -- use the installed value, not the placeholder
  files = {
    { path = "assets/generated/example/thing.png", size = 1234 },
  },
}
```

- `schema` is always `portemon-mod-v1`.
- `id` is 1–64 characters of lowercase letters, digits, `.`, `_`, or `-`, and
  must start with a letter or digit. It is unique across the selected set.
- `revision` is your own 1–128 byte printable marker. It is not a checksum or a
  signature; it only distinguishes your own builds in diagnostics.
- `versionId`, `assetRevision`, and `scriptApi` must equal the values the
  installed cache was built with. The producer build and the ROM digest are not
  compared: packages target the generated asset contract, not a particular dump.
- `files` is a dense array of `{ path, size }` records, sorted by `path`, with no
  duplicates. `size` is the uncompressed byte length of that member.

The manifest is read as data in an empty environment: it cannot `require`,
touch `love`, perform I/O, or run code at load time.

### Reading the identity values

A selection whose manifest does not match reports the field it compared with
both the expected and the supplied values, for example
`assetRevision expected 19, supplied 18`. Use that diagnostic to fill the
manifest in; it is the installed identity, not a constant of the format.

### Valid member paths

Members must be normalized forward-slash relative names strictly below the two
generated roots:

```text
data/generated/...
assets/generated/...
```

Absolute paths, drive letters, backslashes, empty or `.`/`..` components, and
control characters are rejected. Paths that are base cache completion facts are
refused even though they live below a generated root: `data/generated/jobs/`,
`data/generated/build.lua`, `data/generated/complete.lua`,
`data/generated/first-play.lua`, and the retired milestone markers such as
`data/generated/bootstrap.lua` or `data/generated/startup-title.lua`. A package
cannot claim that the base cache is complete or finished compiling something.

Every listed member must exist in the ZIP as an ordinary file whose uncompressed
size equals the declared `size`. Opening a package checks this from directory
metadata only, so a listing mismatch fails before anything reaches the game.

The package is read through LÖVE's ZIP mount, which does not expose two entries
with the same name inside one archive. Duplicate member names therefore cannot
be detected at selection: build packages with unique member names. A listed
member is still checked against its declared size and decoded by its stated
format when it is used.

## Laziness

Selecting a package reads only its `mod.lua` and directory metadata. No payload
is decompressed or loaded at start-up, and no payload is loaded because the
manifest lists it:

- A logical path a package names is read from that package the first time a
  consumer needs it, and the bytes are then retained through the same shared
  residency budget the base cache uses, until nothing holds them.
- Extra members the manifest does not list are invisible; they are never used
  and cannot add executable code.
- Logical paths no package names keep coming from the installed base cache,
  which is not copied.

Very large assets are supported the same way: they are read on demand, may
exceed the idle residency budget while in use, and are released again when
nothing holds them.

## Size and count limits

These bounds keep start-up metadata work small. They are metadata limits, not
payload limits:

| Limit | Value |
|---|---|
| Load list file | 64 KiB |
| Selected packages | 64 |
| Package basename | 128 bytes |
| Manifest file | 4 MiB |
| Manifest entries | 65,534 |
| One member's declared size | 0 – 2,147,483,647 bytes |

## Failures

Package problems are reported with the file, the package id or basename, and
the logical path involved. They never fall back to the base cache entry at the
same path, and they never repair, rewrite, or delete the base cache:

- A load list that cannot be read or does not fit its shape fails the selection.
- A missing ZIP, a failed mount, a malformed manifest, a duplicate package id,
  or an undeclared/mismatched member fails the selection before the game starts.
- A selected member whose bytes the expected format rejects fails at the
  consumer that asked for it, naming the selected source. The base asset at that
  path is not substituted.

Removing the entry from `load-order.lua` (or the file itself) and restarting
returns the game to the base assets. A broken package cannot corrupt saves,
because the runtime never writes gameplay data from package content.

## Restart requirement

The load list and the selected ZIPs are read once per selection. Changing,
replacing, or reordering packages while the game runs is not supported: there
is no watcher and no hot reload. Quit and start the game after changing the
selection.

## Supported content

A package replaces files at the logical paths the installed cache already
uses, so it must supply the same generated formats:

- serialized Lua data (manifests, script resources, per-map metadata),
- PNG images,
- native texture and draw banks (`.g4tx`, `.g4gx`),
- meshes (`.g4mesh`) and collision data (`.g4collision`),
- compact message banks (`.g4msg`),
- packed PCM samples (`.pcm16le`) with their bank and sample metadata.

There is no second codec and no custom format support: a payload is decoded by
the same reader the base cache uses, with the same bounds checks. Cross-file
references remain yours to keep coherent; a package must supply a consistent
set, and a missing or contradictory companion file surfaces as a normal runtime
failure rather than being repaired automatically.

These are compiled formats. Replacing a file with a differently shaped payload
does not work, and a higher-resolution image or larger sample still needs the
metadata that describes it (dimensions, frames, bank and sample records) in the
same generated format. A filename swap alone is not enough.

Some of these formats are binary. Text editors cannot show them meaningfully;
use the project's format-aware inspection tooling (or the runtime decoder it
wraps) when you need to read the content of an extracted member, for example the
human-readable export of a compact message bank.

## Script precedence

Generated scripts are read through the same selected reader as every other
generated asset, so a package replaces the generated script layer. The order
stays:

1. built-in library modules,
2. generated scripts, including package replacements,
3. curated repository overrides, which still win,
4. the sealed registry.

A package cannot install new Lua modules, plugins, or code that runs at load
time; only listed generated asset paths are reachable, and a package adds no
`require` route.

## A minimal package

Two files, plus the load list:

```text
mods/soulsilver/load-order.lua
mods/soulsilver/example.zip
  mod.lua
  assets/generated/example/thing.png
```

`mod.lua`:

```lua
return {
  schema = "portemon-mod-v1",
  id = "example",
  revision = "1",
  versionId = "soulsilver", -- the selected version
  assetRevision = 0,        -- placeholder: the installed value
  scriptApi = 0,            -- placeholder: the installed value
  files = {
    { path = "assets/generated/example/thing.png", size = 91 }, -- the member's real byte length
  },
}
```

Build the ZIP with ordinary ZIP tooling from a directory that already contains
`mod.lua` and the members at their logical paths, and make sure the archive
stores normalized forward-slash names:

```sh
cd /path/to/package-root
zip -r example.zip mod.lua assets
```

Then point the load list at it:

```lua
return { "example.zip" }
```

Every value in this example is synthetic; replace the identity fields with the
values your installed cache reports.
