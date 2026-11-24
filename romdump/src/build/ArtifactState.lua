-- Committed artifact facts for one derived-cache generation. A fact is the
-- cheap, in-memory proof that one canonical job's output is committed for an
-- immutable generation: ordinary warm reuse trusts a current fact without
-- re-reading family payload, while family validators stay authoritative for
-- compilation staging and the explicit manual audit. The controller owns the
-- record map; workers and planners receive a read-only subset carrying the
-- same generation. Records are addressed by the canonical `kind:key` identity
-- and hold sorted dependency and file lists only, never paths to disk.

---@class ArtifactState.Fact
---@field kind string
---@field key string
---@field marker string
---@field dependencies string[] sorted canonical job keys
---@field ownedRoots string[] sorted owned logical roots
---@field sharedPaths string[] sorted shared logical paths
---@field files string[] sorted logical payload paths
---@class ArtifactState
---@field generationId string
---@field records table<string, ArtifactState.Fact>
local ArtifactState = {}

ArtifactState.KINDS = {
  -- Structural world catalog (one world file) and canonical field-cell
  -- index: the planning roots every geometry job resolves against.
  ["world-catalog"] = true,
  ["field-cell-index"] = true,
  -- Coarse bootstrap field families: each job stages its whole bundle
  -- without publishing from workers.
  ["field-camera"] = true,
  ["field-weather"] = true,
  ["field-effects"] = true,
  ["field-emotes"] = true,
  ["field-ui"] = true,
  ["field-entry"] = true,
  ["field-move-cut-in-banner"] = true,
  ["field-font"] = true,
  -- Family-level teleport landing index: one cited spawn-keyed record
  -- for the whole ROM, consumed eagerly by field return planning.
  spawns = true,
  -- Game-start families: intro visuals, the standard-init initializer, the
  -- merged ordinary actor/follower bundle and starter-choice assets.
  intro = true,
  ["new-game-init"] = true,
  actors = true,
  ["starter-choice"] = true,
  -- One staged mon artifact per job: the semantic catalog and the selector
  -- layout each own their payload and marker, each icon/portrait page owns
  -- its own image and marker, and the summary owns only the index,
  -- provenance, and completion.
  ["mon-catalog"] = true,
  -- One staged care catalog: the source breeding tables the Day Care
  -- resolves against.
  ["pokemon-care"] = true,
  ["mon-layout"] = true,
  ["mon-icon-page"] = true,
  ["mon-portrait-page"] = true,
  ["mon-summary"] = true,
  -- One staged item/bag/party artifact per job: the source-independent item
  -- catalog (definitions, pockets, icon atlas with manifest) and the
  -- field-bag/party presentations each own their payload and marker.
  items = true,
  -- The League ending's own bundle: one selector-free artifact carrying the
  -- registration/showcase text banks and the credit roll.
  ending = true,
  ["follower-interactions"] = true,
  mart = true,
  bag = true,
  ["move-icons"] = true,
  ["apricorn-box"] = true,
  party = true,
  pc = true,
  pokegear = true,
  -- Two independently published Easy Chat scopes: the semantic data
  -- catalog (field-runtime prerequisite) and the on-demand editor
  -- presentation manifest. Each owns its exact payload and marker
  -- files, never the shared data directory root, so one scope cannot
  -- erase the other.
  ["easy-chat-data"] = true,
  ["easy-chat"] = true,
  -- Two independently published Pokedex scopes: the semantic data catalog
  -- (field-runtime prerequisite) and the on-demand presentation manifest.
  -- Each owns its exact payload and marker files, never the shared data
  -- directory root, so one scope cannot erase the other.
  ["pokedex-data"] = true,
  pokedex = true,
  summary = true,
  -- One staged battle input artifact per job: move battle facts, trainer
  -- records, and encounter tables each own their payload and marker.
  ["battle-data"] = true,
  trainers = true,
  encounters = true,
  -- One staged battle presentation artifact per job: the shared ordinary
  -- menu/HUD definitions own the global payload and marker, each
  -- demanded trainer picture and ball owns its selector-scoped record and
  -- marker, the evolution bundle owns its own record and marker, and each
  -- demanded persistent scene owns its own composed image and marker.
  ["battle-presentation"] = true,
  ["battle-trainer-picture"] = true,
  ["battle-ball"] = true,
  ["battle-evolution"] = true,
  ["battle-scene"] = true,
  -- One staged battle effect artifact per independently requested key: the
  -- normalized program plus its closed transitive resources.
  ["battle-effect"] = true,
  -- One staged message bank (or the family summary) per job: each bank owns
  -- its payload and marker, the summary owns only the index and completion.
  ["message-bank"] = true,
  ["message-summary"] = true,
  -- One staged audio bank closure (or the catalog, or the family summary)
  -- per job: each bank owns its bank record, its sequence records, and
  -- shared content-addressed samples, the catalog owns the runtime index,
  -- and the summary owns no payload at all. Each current fact is the
  -- closure's whole completion proof.
  ["audio-bank"] = true,
  ["audio-catalog"] = true,
  ["audio-summary"] = true,
  -- One staged script member (or the generation summary) per job: each
  -- nonempty member owns its scripts and marker, the summary owns only the
  -- generation metadata and the active selection.
  ["script-member"] = true,
  ["script-summary"] = true,
  -- One staged field record per supported map, one staged cell per canonical
  -- physical descriptor, and one staged scene per source-resolved map.
  ["map-data"] = true,
  ["field-cell"] = true,
  map = true,
  -- The single producer-private planning job: the worker-compiled source
  -- inventory every generation session and audit schedules against. It owns
  -- no gameplay payload and never reaches runtime code.
  ["source-plan"] = true,
  -- Small, independently generated startup visuals and title scene.
  ["startup-loader"] = true,
  ["startup-title"] = true,
  -- Five independently requestable opening-movie scenes: each numbered
  -- scene owns its own fact, manifest, and asset root, never the movie
  -- as a whole.
  ["opening-scene"] = true,
}

local function checkKind(kind)
  assert(type(kind) == "string" and ArtifactState.KINDS[kind], "unknown artifact kind: " .. tostring(kind))
end

local function isCanonicalInteger(text)
  return text == "0" or text:match("^[1-9][0-9]*$") ~= nil
end

-- Families addressed only as a whole carry the global key; paged and
-- per-member families carry their canonical integer selector, and field
-- cells carry their canonical matrix/index pair and nothing else: a bare
-- integer never addresses a cell. Battle scenes carry their validated
-- semantic background/terrain/time key, never an arbitrary path.
local function checkKey(kind, key)
  assert(type(key) == "string" and key ~= "", "artifact key must be a non-empty string")
  if kind == "pc" then
    assert(key == "global", "pc artifacts require the global key")
    return
  end
  if kind == "startup-loader" then
    assert(key == "global", kind .. " artifacts require the global key")
    return
  end
  if kind == "startup-title" then
    assert(key == "global", kind .. " artifacts require the global key")
    return
  end
  if kind == "opening-scene" then
    assert(type(key) == "string" and key:match("^[1-9][0-9]*$") ~= nil, "invalid artifact key: " .. key)
    local index = tonumber(key)
    assert(index ~= nil and index % 1 == 0 and index >= 1 and index <= 5, "invalid artifact key: " .. key)
    return
  end
  if kind == "pokegear" then
    assert(key == "global", "pokegear artifacts require the global key")
    return
  end
  if kind == "easy-chat-data" or kind == "easy-chat" then
    assert(key == "global", "easy chat artifacts require the global key")
    return
  end
  if kind == "ending" then
    assert(key == "global", "ending artifacts require the global key")
    return
  end
  if kind == "pokedex-data" or kind == "pokedex" then
    assert(key == "global", "pokedex artifacts require the global key")
    return
  end
  if kind == "battle-presentation" then
    assert(key == "global", "battle presentation only has the global job")
    return
  end
  if kind == "battle-trainer-picture" then
    local role, classKey
    if type(key) == "string" then
      role, classKey = key:match("^([a-z]+)%-([A-Z][A-Z0-9_]*)$")
    end
    assert((role == "front" or role == "back") and classKey ~= nil, "invalid battle trainer picture key: " .. key)
    return
  end
  if kind == "battle-ball" then
    assert(type(key) == "string" and key:match("^[A-Z][A-Z0-9_]*$") ~= nil, "invalid battle ball key: " .. key)
    return
  end
  if kind == "battle-evolution" then
    assert(key == "global", "battle evolution only has the global job")
    return
  end
  if kind == "battle-scene" then
    local Sources = require("romdump.src.config.BattlePresentationSources")
    assert(Sources.validateSceneKey(key), "invalid battle scene key: " .. key)
    return
  end
  if kind == "battle-effect" then
    assert(key ~= "" and key:find("/", 1, true) == nil, "invalid battle effect key: " .. key)
    return
  end
  if key == "global" or isCanonicalInteger(key) then
    assert(kind ~= "field-cell" or key:find("-", 1, true) ~= nil, "invalid artifact key for field-cell: " .. key)
    return
  end
  local first, second = key:match("^([0-9]+)-([0-9]+)$")
  local compound = first ~= nil and isCanonicalInteger(first) and isCanonicalInteger(second)
  assert(compound, "invalid artifact key: " .. key)
  assert(kind == "field-cell", "compound artifact key is only valid for field cells: " .. key)
end

---@param kind string
---@param key string
function ArtifactState.validateKey(kind, key)
  checkKind(kind)
  checkKey(kind, key)
end

---@param kind string
---@param key string
---@return string canonical fact identity
function ArtifactState.key(kind, key)
  ArtifactState.validateKey(kind, key)
  return kind .. ":" .. key
end

---@param generationId string
---@return ArtifactState
function ArtifactState.new(generationId)
  assert(type(generationId) == "string" and generationId ~= "", "artifact facts require a generation identity")
  return setmetatable({ generationId = generationId, records = {} }, ArtifactState)
end

---@param facts ArtifactState
---@param kind string
---@param key string
---@return ArtifactState.Fact|nil
function ArtifactState.read(facts, kind, key)
  assert(type(facts) == "table" and type(facts.records) == "table", "artifact fact lookup requires its record map")
  return facts.records[ArtifactState.key(kind, key)]
end

---@param paths unknown
---@param label string
---@return string[]
local function sortedPathList(paths, label)
  assert(type(paths) == "table", "artifact fact " .. label .. " must be a list")
  local seen = {}
  local result = {}
  for _, path in ipairs(paths) do
    assert(type(path) == "string" and path ~= "", "artifact fact " .. label .. " carries a non-string path")
    assert(not seen[path], "artifact fact " .. label .. " repeats a path: " .. path)
    seen[path] = true
    result[#result + 1] = path
  end
  table.sort(result)
  return result
end

-- Validate one candidate success before anything becomes visible: canonical
-- identity, marker, ownership declarations, payload paths, and the transitive
-- dependency closure the controller already committed. The result is a plain
-- fact record; committing it changes only the supplied record map.
---@param result { kind: string, key: string, marker: string, ownedRoots: string[], sharedPaths: string[], entries: { path: string, size: integer }[] }
---@param dependencyKeys string[] canonical job keys the artifact read
---@param facts ArtifactState
---@return ArtifactState.Fact
function ArtifactState.prepareFact(result, dependencyKeys, facts)
  assert(type(result) == "table", "artifact fact result is required")
  assert(type(facts) == "table" and type(facts.records) == "table", "artifact facts require their record map")
  local kind = result.kind
  local key = result.key
  ArtifactState.validateKey(kind, key)
  assert(type(result.marker) == "string" and result.marker ~= "", "artifact fact marker is required")
  assert(type(dependencyKeys) == "table", "artifact fact dependencies must be a list")
  local dependencies = {}
  local seen = {}
  for _, dependency in ipairs(dependencyKeys) do
    assert(type(dependency) == "string" and dependency ~= "", "artifact dependency must be a canonical job key")
    assert(not seen[dependency], "artifact dependency is listed twice: " .. dependency)
    assert(facts.records[dependency] ~= nil, "artifact dependency is not committed for this generation: " .. dependency)
    seen[dependency] = true
    dependencies[#dependencies + 1] = dependency
  end
  table.sort(dependencies)
  local ownedRoots = sortedPathList(result.ownedRoots or {}, "owned roots")
  local sharedPaths = sortedPathList(result.sharedPaths or {}, "shared paths")
  assert(type(result.entries) == "table", "artifact fact entries must be a list")
  local files = {}
  for _, entry in ipairs(result.entries) do
    assert(type(entry) == "table" and type(entry.path) == "string" and entry.path ~= "", "artifact entry is invalid")
    files[#files + 1] = entry.path
  end
  table.sort(files)
  for index = 2, #files do
    assert(files[index] ~= files[index - 1], "artifact entry is listed twice: " .. files[index])
  end
  return {
    kind = kind,
    key = key,
    marker = result.marker,
    dependencies = dependencies,
    ownedRoots = ownedRoots,
    sharedPaths = sharedPaths,
    files = files,
  }
end

-- Insert one already validated record. The caller has proven the closure and
-- this call only fills the record map, so it neither yields nor re-validates.
---@param facts ArtifactState
---@param record ArtifactState.Fact
function ArtifactState.commitFact(facts, record)
  assert(type(facts) == "table" and type(facts.records) == "table", "artifact facts require their record map")
  assert(type(record) == "table", "artifact fact record is required")
  local identity = ArtifactState.key(record.kind, record.key)
  assert(facts.records[identity] == nil, "artifact fact is committed twice: " .. identity)
  facts.records[identity] = record
end

return ArtifactState
