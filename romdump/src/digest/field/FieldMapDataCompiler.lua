-- Compiles one semantic HGSS map's binary zone-event member into the normalized
-- lightweight field-map cache schema, plus the field-audio policy: the canonical
-- day/night music references with the frozen flag-driven overrides and surfing
-- traversal override, and the semantic soundplate records resolved from the
-- map's land BGS payload through the frozen soundplate table.

local Errors = require("libs.errors.src.Errors")
local ZoneEvents = require("romdump.src.digest.map.ZoneEvents")
local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
local MapCatalog = require("romdump.src.digest.map.MapCatalog")
local AreaData = require("romdump.src.digest.map.AreaData")
local HgssFieldLighting = require("romdump.src.digest.field.HgssFieldLighting")
local HgssFieldLightProfile = require("romdump.src.digest.field.HgssFieldLightProfile")
local HgssFieldEdgeColors = require("romdump.src.digest.field.HgssFieldEdgeColors")
local HgssFieldFog = require("romdump.src.digest.field.HgssFieldFog")
local MapAnalysis = require("romdump.src.digest.map.MapAnalysis")
local MapMatrix = require("romdump.src.digest.map.MapMatrix")
local LandData = require("romdump.src.digest.map.LandData")
local HgssSoundplate = require("romdump.src.digest.field.HgssSoundplate")
local Hashing = require("romdump.src.digest.Hashing")
local fieldAudio = require("romdump.src.reference.hgss.field_audio")
local ScriptHeader = require("romdump.src.digest.script.ScriptHeader")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")
local HgssObjectMovement = require("romdump.src.digest.field.HgssObjectMovement")
local FieldMoveSources = require("romdump.src.config.FieldMoveSources")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")

local FieldMapDataCompiler = {}

local STANDARD_SCRIPTS = SourceCatalog.catalog()

-- The retail zone-event format uses 0xFFFF as a second unbound script
-- marker. Generated field data uses zero as its single no-script value so
-- runtime binding and interaction audits do not need to interpret ROM data.
--
-- A raw event script id in a std-script sentinel range (`src/script_manager.c`
-- `sScriptBankMapping`, e.g. item balls, apricorn trees) addresses a global
-- scr_seq member unrelated to this map's own scriptsMemberId. Canonicalizing
-- it to its public `common.<name>` id here means runtime interaction binding
-- never derives a script identity from a raw source number for these events,
-- and never needs the decomp-derived std-script catalog to resolve one.
local NO_SCRIPT_ID = 0xFFFF

---@param decoded table<string, unknown> decoded zone-event member
local function normalizeUnboundScripts(decoded)
  for _, events in ipairs({ decoded.backgroundEvents, decoded.objectEvents, decoded.coordinateEvents }) do
    for _, event in ipairs(events) do
      if event.scriptId == NO_SCRIPT_ID then
        event.scriptId = 0
      elseif STANDARD_SCRIPTS.namesById[event.scriptId] ~= nil then
        event.scriptId = SourceCatalog.commonPublicId(STANDARD_SCRIPTS, event.scriptId)
      end
    end
  end
end

---@param event table<string, unknown>
---@param map table<string, unknown>
---@param index integer
---@return table<string, unknown>
local function semanticObjectEvent(event, map, index)
  local ok, movementType = pcall(HgssObjectMovement.semanticType, event.movement)
  if not ok then
    Errors.raise("FIELD_MAP_UNKNOWN_OBJECT_MOVEMENT", "object event has an invalid movement selector", {
      mapId = map.id,
      mapSymbol = map.symbol,
      objectEventIndex = index - 1,
      objectEventId = event.objectEventId,
      movement = event.movement,
    })
  end
  local object = {}
  for key, value in pairs(event) do
    if key ~= "movement" then
      object[key] = value
    end
  end
  object.movementType = movementType
  -- The facing-actor obstacle kind, decorated only where a verified source
  -- identity proves it; unproven actors carry no kind and fail obstacle
  -- checks loudly instead of guessing.
  local obstacleKind = FieldMoveSources.obstacleKindForSprite(event.spriteId)
  if obstacleKind ~= nil then
    object.obstacleKind = obstacleKind
  end
  return object
end

---@param objectEvents table[]
---@param map table<string, unknown>
---@return table[]
local function semanticObjectEvents(objectEvents, map)
  local objects = {}
  for index, event in ipairs(objectEvents) do
    objects[index] = semanticObjectEvent(event, map, index)
  end
  return objects
end

-- Whether the source weather id marks a dark Flash-usable cave.
---@param weatherId integer
---@return boolean
local function isFlashWeather(weatherId)
  for _, id in ipairs(FieldMoveSources.FLASH_WEATHER_IDS) do
    if weatherId == id then
      return true
    end
  end
  return false
end

-- The semantic field-use policy for one map, projected from frozen source
-- header facts: Fly/Escape Rope permissions ride the header flags,
-- Teleport follows the outdoor transition environment, Flash follows the
-- dark-cave weather ids plus the explicit Alph chamber exception, Dig and
-- Escape Rope need the cave environment with escape permission, and the
-- Union/Colosseum exclusion plus the Ice Path B2F exception ride explicit
-- symbol sets. Runtime checks read this record; they never branch on map
-- ids or infer permission from map type.
---@param map table<string, unknown>
---@param environment string
---@return table<string, unknown>
local function fieldUsePolicy(map, environment)
  local alphChamber = map.symbol == FieldMoveSources.ALPH_FLASH_SYMBOL
  return {
    flyAllowed = map.flyAllowed == true,
    teleportAllowed = environment == "outdoors",
    escapeAllowed = map.escapeRopeAllowed == true,
    flashUsable = isFlashWeather(map.weather) or alphChamber,
    alphChamber = alphChamber,
    icePathB2F = map.symbol == FieldMoveSources.ICE_PATH_B2F_SYMBOL,
    cave = environment == "cave",
    unionOrColosseum = FieldMoveSources.UNION_COLOSSEUM_SYMBOLS[map.symbol] == true,
  }
end

-- These catalog entries are source-header placeholders without field-data
-- members. Direct compilation remains strict, while the complete producer
-- omits records that have no field data to publish.
local NON_FIELD_MAP_SYMBOLS = {
  MAP_NOTHING = true,
  MAP_UNDERGROUND = true,
}

-- The source-defined eligibility for lightweight field records: every map
-- header except the two placeholder symbols carries field data. Pure catalog
-- membership, no source reads and no compilation, so controllers can decide
-- membership without opening the dump. Direct compilation of an unsupported
-- header stays strict; only aggregate enumeration skips them.
---@return integer[] ascending unique supported map ids
function FieldMapDataCompiler.supportedMapIds()
  local ids = {}
  local seen = {}
  for map in MapCatalog.all() do
    if not NON_FIELD_MAP_SYMBOLS[map.symbol] and not seen[map.id] then
      seen[map.id] = true
      ids[#ids + 1] = map.id
    end
  end
  table.sort(ids)
  return ids
end

local TRANSITION_ENVIRONMENT_BY_MAP_TYPE = {
  CAVE = "cave",
  CITY_TOWN = "outdoors",
  ROUTE = "outdoors",
  INTERIOR = "building",
  POKEMON_CENTER = "building",
}

---@param map table<string, unknown>
---@return string
local function transitionEnvironment(map)
  local environment = TRANSITION_ENVIRONMENT_BY_MAP_TYPE[map.mapType]
  if not environment then
    Errors.raise(
      "FIELD_MAP_UNKNOWN_MAP_TYPE",
      "map header has no transition environment mapping",
      { mapId = map.id, mapSymbol = map.symbol, mapType = map.mapType }
    )
  end
  return environment
end

-- The canonical audio sequence reference of a map-header music suffix: the
-- frozen catalog carries the SDAT symbol without its class prefix, and the
-- generated record carries the full reference so runtime field-music policy
-- never decorates symbols.
---@param suffix string
---@return string
local function canonicalSequence(suffix)
  return "SEQ_" .. suffix
end

-- The disable flag a soundplate carries on a given map, read from the frozen
-- sound reference's own disableWhen rule (HGSS field_control.c
-- FieldSystem_SoundplateIsActive): a map-scoped rule applies only on its named
-- map, an unscoped rule on every map that carries the sound. A plate whose
-- reference carries no rule is never disabled.
---@param ref table<string, unknown>
---@param mapSymbol string
---@return integer|nil
local function disabledWhenFlag(ref, mapSymbol)
  local rule = ref.disableWhen
  if rule ~= nil and (rule.map == nil or rule.map == mapSymbol) then
    return rule.flagId
  end
  return nil
end

-- The ordered source flag-music rules that apply to this map (the frozen
-- sys_flags.c table, in source order), as {flagId, sequence} records.
---@param mapSymbol string
---@return table<string, unknown>
local function flagOverridesFor(mapSymbol)
  local overrides = {}
  for _, rule in ipairs(fieldAudio.flagMusicOverrides) do
    if rule.map == mapSymbol then
      overrides[#overrides + 1] = { flagId = rule.flagId, sequence = rule.sequence }
    end
  end
  return overrides
end

-- The source traversal override, copied per record so the generated asset
-- never aliases the frozen producer table: an in-process consumer of one
-- bundle must not be able to mutate the shared reference for later compiles.
---@return table<string, unknown>
local function traversalOverridesFor()
  local overrides = {}
  for _, rule in ipairs(fieldAudio.traversalOverrides) do
    overrides[#overrides + 1] = {
      traversal = rule.traversal,
      sequence = rule.sequence,
      unlessFlagId = rule.unlessFlagId,
    }
  end
  return overrides
end

-- The source sSoundplateVolume far/mid/close triple has three entries; a
-- plate whose volumeIndex is 0..2 emits the BGM duck / ambient moves, while
-- higher indices select/play with no volume move (the source's
-- GF_SndHandleMoveVolume calls are guarded).
local VOLUME_INDEX_TARGETS = 3

-- The semantic record for one decoded soundplate: the raw soundplateSoundID
-- never reaches the runtime asset, only the frozen sound-table facts, the BGM
-- duck / ambient targets derived from the volume index (levels above two emit
-- no volume moves, matching the source's guarded GF_SndHandleMoveVolume), and
-- the disable flag the reference's own rule scopes to this map.
---@param record table<string, unknown>
---@param ref table<string, unknown>
---@param mapSymbol string
---@return table<string, unknown>
local function semanticSoundplate(record, ref, mapSymbol)
  local plate = {
    x = record.x,
    z = record.z,
    xBounds = record.xBounds,
    zBounds = record.zBounds,
    sequence = ref.sequence,
    useFieldMusicBank = ref.useFieldMusicBank,
  }
  if record.volumeIndex < VOLUME_INDEX_TARGETS then
    plate.bgmTarget = fieldAudio.bgmDuckTargets[record.volumeIndex + 1]
    plate.ambientTarget = ref.ambientLevels[record.volumeIndex + 1]
  end
  plate.disabledWhenFlag = disabledWhenFlag(ref, mapSymbol)
  return plate
end

local function must(value, err)
  if value == nil then
    error(err)
  end
  return value
end

local function loadSource(romFs, sha1hex)
  sha1hex = sha1hex or Hashing.sha1hex
  local archiveInfo = romFs:resolvedNarc("zone_events")
  if not archiveInfo then
    Errors.raise("ROMFS_NARC_UNRESOLVED", "zone_events NARC is unavailable", { name = "zone_events" })
  end
  local archiveBytes = must(romFs:read(archiveInfo.fileId))
  local archive = must(romFs:openNarc("zone_events"))
  return {
    archive = archive,
    archiveInfo = archiveInfo,
    archiveSha1 = sha1hex(archiveBytes),
  }
end

local function loadHeaderSource(romFs, sha1hex)
  local archiveInfo = romFs:resolvedNarc("field_script_headers")
  if not archiveInfo then
    Errors.raise("ROMFS_NARC_UNRESOLVED", "field_script_headers NARC is unavailable", { name = "field_script_headers" })
  end
  local archiveBytes = must(romFs:read(archiveInfo.fileId))
  return {
    archive = must(romFs:openNarc("field_script_headers")),
    archiveInfo = archiveInfo,
    archiveSha1 = sha1hex(archiveBytes),
  }
end

-- The engine's SoundplateStruct is the whole land BGS block (field_control.c):
-- the 0x1234 signature bytes and a u16 record byte count precede the 8-byte
-- records, so the struct header is the BGS block header, not part of the
-- payload LandData exposes.
---@param land table<string, unknown>
---@return string
local function bgsBlock(land)
  local payload = land.bgs.payload
  local size = #payload
  return string.char(
    land.bgs.signature % 256,
    math.floor(land.bgs.signature / 256) % 256,
    size % 256,
    math.floor(size / 256) % 256
  ) .. payload
end

-- The map's soundplates and the land/matrix source sha1s. Maps the matrix
-- cannot render (the default header filler and the unused headers) carry no
-- land payload and emit an empty soundplates array, exactly like maps whose
-- land BGS payload is empty.
---@param map table<string, unknown>
---@param sha1hex fun(data: string): string
---@param romFs RomFs
---@return table<string, unknown> plates, table<string, unknown> audioSource { matrixMemberSha1, landDataMemberId?, landDataMemberSha1? }
local function compileSoundplates(romFs, map, sha1hex)
  local matrixNarc = must(romFs:openNarc("map_matrices"))
  local matrixBytes = must(matrixNarc:readMember(map.matrixMemberId)) --[[@as string]]
  local matrix = must(MapMatrix.decode(matrixBytes, map.id))
  local analysis = MapAnalysis.analyzeRecord(map, matrix)
  if analysis.status ~= "resolved" then
    return {}, { matrixMemberSha1 = sha1hex(matrixBytes) }
  end

  local landNarc = must(romFs:openNarc("land_data"))
  local landBytes = must(landNarc:readMember(analysis.landDataMemberId)) --[[@as string]]
  local land = must(LandData.decode(landBytes, {
    mapId = map.id,
    alias = "land_data",
    memberId = analysis.landDataMemberId,
  }))
  local plates = {}
  if #land.bgs.payload > 0 then
    local records = must(HgssSoundplate.decode(bgsBlock(land), {
      mapId = map.id,
      memberId = analysis.landDataMemberId,
    }))
    ---@cast records table[]
    for index, record in ipairs(records) do
      local ref = fieldAudio.soundplates[record.soundplateSoundID + 1]
      if not ref then
        Errors.raise(
          "FIELD_MAP_UNKNOWN_SOUNDPLATE_SOUND",
          "land soundplate references unknown sound id " .. record.soundplateSoundID,
          { mapId = map.id, recordIndex = index - 1, soundplateSoundID = record.soundplateSoundID }
        )
      end
      local soundReference = assert(ref)
      plates[index] = semanticSoundplate(record, soundReference, map.symbol)
    end
  end
  return plates,
    {
      matrixMemberSha1 = sha1hex(matrixBytes),
      landDataMemberId = analysis.landDataMemberId,
      landDataMemberSha1 = sha1hex(landBytes),
    }
end

-- The normalized renderer environment for one map, resolved through the
-- same area/light/fog helpers as visual scene compilation: the map's area
-- record selects the field-light profile, whose parsed records become the
-- lighting, while edge colors and the base fog derive from the area light
-- pattern and the catalog weather. Returns the environment plus its source
-- provenance. Emits no geometry.
---@param romFs RomFs
---@param map table<string, unknown>
---@param sha1hex fun(data: string): string
---@return table<string, unknown> environment, table<string, unknown> provenance
local function compileRenderEnvironment(romFs, map, sha1hex)
  local areaNarc = must(romFs:openNarc("area_data"))
  local areaBytes = must(areaNarc:readMember(map.areaDataMemberId))
  local area = must(AreaData.decode(areaBytes, { alias = "area_data", memberId = map.areaDataMemberId }))
  local selectedLight = HgssFieldLighting.resolve(area.lightTypeRaw, false)
  local lightBytes =
    assert(romFs:readSourcePath(selectedLight.sourcePath), "missing field-light profile: " .. selectedLight.sourcePath)
  local lightProfile = assert(HgssFieldLightProfile.parse(lightBytes, { sourcePath = selectedLight.sourcePath }))
  return {
    lighting = { records = lightProfile.records },
    edgeColors = HgssFieldEdgeColors.tableForAreaLightPattern(area.lightTypeRaw),
    weatherId = map.weather,
    fog = HgssFieldFog.runtimePreset(HgssFieldFog.resolve(map.weather)),
  }, {
    areaDataMemberId = map.areaDataMemberId,
    areaDataMemberSha1 = sha1hex(areaBytes),
    fieldLightSourcePath = selectedLight.sourcePath,
    fieldLightSourceSha1 = sha1hex(lightBytes),
  }
end

local BATTLE_BACKGROUNDS = {}
for _, background in ipairs(BattlePresentationCache.BACKGROUNDS) do
  BATTLE_BACKGROUNDS[background] = true
end

-- The semantic battle background backing presented-battle scene selection:
-- the frozen catalog fact lowered to the runtime scene key the
-- presentation cache inventories. An unmapped fact fails the compile
-- instead of guessing a scene.
---@param map table<string, unknown>
---@return string semantic battle background key
local function battleBackgroundFor(map)
  local source = map.battleBackground
  assert(type(source) == "string" and source ~= "", "map catalog names its battle background")
  local key = source:lower()
  assert(BATTLE_BACKGROUNDS[key], "map battle background has no runtime scene key: " .. tostring(source))
  return key
end

-- The wild encounter table member backing committed-step encounter
-- selection: the frozen catalog fact carried verbatim so the runtime
-- resolves the map's own table instead of mistaking its map identity for
-- one. Maps without encounters carry the source no-table member id.
---@param map table<string, unknown>
---@return integer wild encounter table member identity
local function encounterMemberFor(map)
  local source = map.wildEncounterMemberId
  assert(
    type(source) == "number" and source % 1 == 0 and source >= 0 and source <= 255,
    "map catalog names its wild encounter table member"
  )
  return source
end

local function compileMap(romFs, map, source, headerSource, sha1hex, hashLua)
  local memberBytes = must(source.archive:readMember(map.eventMemberId))
  local decoded = must(ZoneEvents.decode(memberBytes, {
    mapId = map.id,
    eventMemberId = map.eventMemberId,
    source = "fielddata_eventdata_zone_event",
  }))
  normalizeUnboundScripts(decoded)

  local memberSha1 = sha1hex(memberBytes)
  local soundplates, audioSource = compileSoundplates(romFs, map, sha1hex)
  local renderEnvironment, environmentSource = compileRenderEnvironment(romFs, map, sha1hex)
  local headerBytes = must(headerSource.archive:readMember(map.scriptHeaderMemberId)) --[[@as string]]
  local initScripts = must(ScriptHeader.parse(headerBytes, {
    mapId = map.id,
    memberId = map.scriptHeaderMemberId,
    scriptBankId = map.scriptsMemberId,
  }))
  local dependencies = {
    cacheFormat = FieldMapDataCache.FORMAT,
    mapCatalogVersion = MapCatalog.VERSION,
    versionRomSha1 = romFs:metadata().sha1,
    eventNarc = {
      symbol = source.archiveInfo.symbol,
      alias = source.archiveInfo.alias,
      narcId = source.archiveInfo.narcId,
      fileId = source.archiveInfo.fileId,
      path = source.archiveInfo.path,
      sha1 = source.archiveSha1,
    },
    eventMemberId = map.eventMemberId,
    eventMemberSha1 = memberSha1,
    scriptHeaderMemberId = map.scriptHeaderMemberId,
    scriptHeaderMemberSha1 = sha1hex(headerBytes),
    scriptHeaderNarc = {
      symbol = headerSource.archiveInfo.symbol,
      alias = headerSource.archiveInfo.alias,
      narcId = headerSource.archiveInfo.narcId,
      fileId = headerSource.archiveInfo.fileId,
      path = headerSource.archiveInfo.path,
      sha1 = headerSource.archiveSha1,
    },
    -- The map-matrix and land members the audio policy derives from: the
    -- matrix cell picks the land member, whose BGS payload carries the
    -- soundplates. Source identity lives only in this dependency record.
    matrixMemberSha1 = audioSource.matrixMemberSha1,
    landDataMemberId = audioSource.landDataMemberId,
    landDataMemberSha1 = audioSource.landDataMemberSha1,
    -- The area and field-light sources the render environment derives
    -- from: a source change must invalidate the map record. Normalized
    -- results live on the field payload; raw source facts live only here.
    areaDataMemberId = environmentSource.areaDataMemberId,
    areaDataMemberSha1 = environmentSource.areaDataMemberSha1,
    fieldLightSourcePath = environmentSource.fieldLightSourcePath,
    fieldLightSourceSha1 = environmentSource.fieldLightSourceSha1,
  }
  local environment = transitionEnvironment(map)
  local field = {
    schema = FieldMapDataCache.FIELD_SCHEMA,
    mapId = map.id,
    mapSymbol = map.symbol,
    cameraType = map.cameraType,
    transitionEnvironment = environment,
    -- The semantic field-use policy (badge-gated move permissions,
    -- traversal allowances, and source exceptions) projected from the
    -- frozen header facts above; see fieldUsePolicy.
    fieldUse = fieldUsePolicy(map, environment),
    -- Map-header message/script associations (src/data/map_headers.h via the
    -- frozen catalog). Runtime code must never branch on map IDs to choose a
    -- bank; it reads these fields.
    messageBankId = map.messageMemberId,
    scriptBankId = map.scriptsMemberId,
    initScripts = initScripts,
    -- The map-header day/night music references (the frozen catalog's
    -- dayMusic/nightMusic, emitted as canonical audio sequence references);
    -- the field-music policy selects the day or night branch at runtime from
    -- this generated record, then applies the ordered flag overrides for this
    -- map and the source surfing traversal override (higher precedence than a
    -- persisted field-music override, before the map-header music unless the
    -- suppressing flag is set).
    music = {
      day = canonicalSequence(map.dayMusic),
      night = canonicalSequence(map.nightMusic),
      flagOverrides = flagOverridesFor(map.symbol),
      traversalOverrides = traversalOverridesFor(),
    },
    events = {
      background = decoded.backgroundEvents,
      objects = semanticObjectEvents(decoded.objectEvents, map),
      warps = decoded.warps,
      coordinates = decoded.coordinateEvents,
    },
    -- The semantic battle background backing presented-battle scene
    -- selection, lowered from the frozen catalog fact to the runtime scene
    -- key. Runtime code never branches on map IDs to choose a scene; it
    -- reads this field.
    battleBackground = battleBackgroundFor(map),
    -- The wild encounter table member backing committed-step encounter
    -- selection. Runtime code never mistakes its map identity for the
    -- table member; it reads this field.
    wildEncounterMemberId = encounterMemberFor(map),
    soundplates = soundplates,
    -- The normalized renderer environment (lighting, edge colors, base
    -- weather, base fog) so logical maps stay drawable without a visual
    -- scene. Runtime weather owns a mutable copy; this record is immutable.
    renderEnvironment = renderEnvironment,
  }
  local marker = FieldMapDataCache.marker(romFs:metadata().sha1, map.id, hashLua(dependencies))
  return { mapId = map.id, field = field, dependencies = dependencies, marker = marker }
end

local function _compile(romFs, idOrSymbol, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compile requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  return compileMap(
    romFs,
    MapCatalog.require(idOrSymbol),
    loadSource(romFs, sha1hex),
    loadHeaderSource(romFs, sha1hex),
    sha1hex,
    hashLua
  )
end

function FieldMapDataCompiler.compile(romFs, idOrSymbol, sha1hex, hashLua)
  local ok, result = pcall(_compile, romFs, idOrSymbol, sha1hex, hashLua)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

-- A worker-private source session: immutable archive identity and handles
-- are loaded once, then each map compiles through the same single-map unit
-- and its bundle is owned by the caller (the session retains no per-map
-- state). Close is idempotent; a closed session compiles nothing. The
-- session never publishes; staging stays with the cache writer.
---@class FieldMapDataCompiler.Session
---@field compile function
---@field close function
---@param romFs RomFs
---@param sha1hex? fun(data: string): string
---@param hashLua? fun(value: unknown): string
---@return FieldMapDataCompiler.Session session with compile(idOrSymbol) and close()
function FieldMapDataCompiler.newSession(romFs, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "session requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  local source = loadSource(romFs, sha1hex)
  local headerSource = loadHeaderSource(romFs, sha1hex)
  local closed = false
  local session = {}
  ---@param idOrSymbol string|integer
  ---@return table<string, unknown>|nil bundle
  ---@return table<string, unknown>|nil failure
  function session:compile(idOrSymbol)
    if closed then
      return nil
    end
    local ok, result = pcall(function()
      return compileMap(romFs, MapCatalog.require(idOrSymbol), source, headerSource, sha1hex, hashLua)
    end)
    if ok then
      return result
    end
    if Errors.is(result) then
      return nil, result
    end
    error(result, 0)
  end
  function session:close()
    closed = true
  end
  return session
end

function FieldMapDataCompiler.compileAll(romFs, sha1hex, hashLua)
  assert(romFs and romFs.read and romFs.openNarc and romFs.resolvedNarc, "compileAll requires a RomFs-shaped object")
  sha1hex = sha1hex or Hashing.sha1hex
  hashLua = hashLua or Hashing.hashLua
  local session = nil
  local ok, result = pcall(function()
    session = FieldMapDataCompiler.newSession(romFs, sha1hex, hashLua)
    local bundles = {}
    for _, mapId in ipairs(FieldMapDataCompiler.supportedMapIds()) do
      bundles[#bundles + 1] = assert(session:compile(mapId))
    end
    return bundles
  end)
  if session ~= nil then
    session:close()
  end
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

-- The teleport landing index: cited spawn-keyed outdoor arrivals
-- projected from the producer source facts into the family-level
-- generated record, alongside the interior death destinations and the
-- setter-written special records. Needs no ROM read: the entries are
-- frozen source data, so the only failure is a malformed producer table.
-- The marker binds the ROM identity and the content hash like every
-- family bundle.
function FieldMapDataCompiler.compileSpawnDestinations(romFs, hashLua)
  assert(romFs and type(romFs.metadata) == "function", "spawn destinations need the ROM identity for their marker")
  hashLua = hashLua or Hashing.hashLua
  local spawns = {}
  for key, entry in pairs(FieldMoveSources.SPAWN_DESTINATIONS) do
    assert(type(key) == "string" and key ~= "", "spawn destinations key on spawn names")
    assert(type(entry) == "table", "spawn destinations carry records")
    assert(type(entry.map) == "string" and entry.map ~= "", "spawn destinations name a map")
    assert(
      type(entry.fieldX) == "number" and entry.fieldX % 1 == 0 and entry.fieldX >= 0,
      "spawn destinations carry tiles"
    )
    assert(
      type(entry.fieldZ) == "number" and entry.fieldZ % 1 == 0 and entry.fieldZ >= 0,
      "spawn destinations carry tiles"
    )
    spawns[key] = { map = entry.map, fieldX = entry.fieldX, fieldZ = entry.fieldZ }
  end
  local blackoutSpawns = {}
  for key, entry in pairs(FieldMoveSources.BLACKOUT_DESTINATIONS) do
    assert(type(key) == "string" and key ~= "", "blackout destinations key on spawn names")
    assert(type(entry) == "table", "blackout destinations carry records")
    assert(type(entry.map) == "string" and entry.map ~= "", "blackout destinations name a map")
    assert(type(entry.fieldX) == "number" and entry.fieldX % 1 == 0 and entry.fieldX >= 0, "blackout x is a tile")
    assert(type(entry.fieldZ) == "number" and entry.fieldZ % 1 == 0 and entry.fieldZ >= 0, "blackout z is a tile")
    assert(entry.facing == "north", "retail death destinations face north")
    blackoutSpawns[key] = { map = entry.map, fieldX = entry.fieldX, fieldZ = entry.fieldZ, facing = entry.facing }
  end
  local specialSpawns = {}
  for key, entry in pairs(FieldMoveSources.SPECIAL_SPAWN_DESTINATIONS) do
    assert(type(key) == "string" and key ~= "", "special destinations key on spawn names")
    assert(type(entry) == "table", "special destinations carry records")
    assert(type(entry.map) == "string" and entry.map ~= "", "special destinations name a map")
    assert(type(entry.fieldX) == "number" and entry.fieldX % 1 == 0 and entry.fieldX >= 0, "special x is a tile")
    assert(type(entry.fieldZ) == "number" and entry.fieldZ % 1 == 0 and entry.fieldZ >= 0, "special z is a tile")
    assert(entry.warpId == -1, "special destinations carry the unset warp id")
    assert(entry.direction == "south", "special destinations use the standard arrival facing")
    specialSpawns[key] = {
      map = entry.map,
      fieldX = entry.fieldX,
      fieldZ = entry.fieldZ,
      warpId = entry.warpId,
      direction = entry.direction,
    }
  end
  local index = {
    schema = FieldMapDataCache.SPAWN_INDEX_SCHEMA,
    spawns = spawns,
    blackoutSpawns = blackoutSpawns,
    specialSpawns = specialSpawns,
  }
  assert(FieldMapDataCache.hasSpawnDestinations(index.spawns), "compiled spawn destinations satisfy the family record")
  assert(
    FieldMapDataCache.hasBlackoutDestinations(index.blackoutSpawns),
    "compiled blackout destinations satisfy the family record"
  )
  assert(
    FieldMapDataCache.hasSpecialSpawnDestinations(index.specialSpawns),
    "compiled special destinations satisfy the family record"
  )
  local metadata = romFs:metadata()
  assert(type(metadata) == "table" and type(metadata.sha1) == "string", "spawn marker needs the ROM sha")
  local marker = FieldMapDataCache.spawnIndexMarker(
    metadata.sha1,
    hashLua({ spawns = spawns, blackoutSpawns = blackoutSpawns, specialSpawns = specialSpawns })
  )
  return { index = index, marker = marker }
end

return FieldMapDataCompiler
