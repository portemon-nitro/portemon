-- Closed dispatch of derived-cache family jobs: the one kind/key
-- vocabulary, the fixed size policy, milestone membership, dependency
-- edges, worker execution and readiness validation shared by the
-- generation session, the compiler workers and the common batch client.
-- There is no runtime registration surface; every family resolves through
-- this table's fixed handlers, and every handler reuses its owning domain
-- compiler/writer without duplicating source semantics.

local ArtifactState = require("romdump.src.build.ArtifactState")
local MenuProtocol = require("libs.assets.src.MenuProtocol")
local ArtifactMonJobs = require("romdump.src.build.ArtifactMonJobs")
local ArtifactBattleJobs = require("romdump.src.build.ArtifactBattleJobs")

---@class ArtifactJobs.Job
---@field kind string
---@field key string
---@field generationId string
---@field epoch integer
---@field stageName string
---@field producerFingerprint string|nil
---@field payload table<string, unknown>|nil scalar selectors for the worker

---@class ArtifactJobs.Plans
---@field indexBundle table<string, unknown>|nil FieldCellCompiler.compileIndex bundle
---@field scriptPlan table<string, unknown>|nil ScriptCompiler.plan bundle
---@field audioPlan table<string, unknown>|nil AudioCompiler.plan index and bank closures
---@field presentation table<string, unknown>|nil MonPresentationCompiler.plan bundle
---@field messageBankIds integer[]|nil required message bank ids
---@field audioBankIds integer[]|nil planned audio bank ids
---@field scriptMemberIds integer[]|nil nonempty script member ids
---@field iconPageIds integer[]|nil planned icon page ids
---@field portraitPageIds integer[]|nil planned portrait page ids
---@field mapDataIds integer[]|nil supported field record ids
---@field mapIds integer[]|nil loadable world map ids
---@field mapCellKeys table<integer, string[]>|nil mapId to canonical cell keys
---@field world table<string, unknown>|nil WorldManifest.compileCatalog bundle

local ArtifactJobs = {}

ArtifactJobs.MILESTONE_SCHEMA = "g4-cache-milestone-v1"

local PRIORITY = {
  required = 0,
  near = 10,
  sweep = 100,
}

local MART_AUDIO_SEQUENCES = { "SEQ_SE_DP_SELECT", "SEQ_SE_GS_GEARCANCEL", "SEQ_SE_DP_BAG_004", 1603 }
local PARTY_AUDIO_SEQUENCES = {
  "SEQ_SE_DP_POKELIST_001",
  "SEQ_SE_GS_GEARCANCEL",
  "SEQ_SE_DP_SELECT",
  "SEQ_SE_DP_CUSTOM06",
  "SEQ_SE_DP_KAIFUKU",
}

---@class ArtifactJobs.Descriptor
---@field size string worker lane behind this kind
---@field dependencies (fun(key: string, plans: ArtifactJobs.Plans): { kind: string, key: string }[], boolean)|nil currently known prerequisites plus whether planning prerequisites made the list final; nil means no prerequisite
---@field execute fun(artifact: table<string, unknown>, context: table<string, unknown>, job: ArtifactJobs.Job): string compiler marker for the receipt
---@field validate fun(check: ArtifactJobs.ReadinessCheck): boolean, table<string, unknown>|nil family readiness for the retained receipt marker, plus the validated source plan on source-plan success

---@class ArtifactJobs.ReadinessCheck
---@field cacheFs table<string, unknown>
---@field generationId string
---@field key string
---@field plans ArtifactJobs.Plans
---@field marker string retained receipt marker
---@field childReady fun(childKind: string, childKey: string, ready: fun(marker: string): boolean): boolean
---@field identity table<string, unknown>|nil expected source identity, mandatory for source-plan

-- One closed record per derived job kind: the size class plus the exact
-- dependency, execution and readiness behavior previously repeated across
-- parallel switch chains. Assigned after the family helpers below; every
-- public wrapper resolves through it. There is no registration surface.
---@type table<string, ArtifactJobs.Descriptor>
local DESCRIPTORS

---@param kind string
---@return ArtifactJobs.Descriptor
local function descriptorFor(kind)
  local descriptor = DESCRIPTORS[kind]
  assert(descriptor ~= nil, "unknown artifact kind: " .. tostring(kind))
  return descriptor
end

---@param urgency string
---@return integer
function ArtifactJobs.priorityFor(urgency)
  local priority = PRIORITY[urgency]
  assert(priority ~= nil, "job urgency must be required, near, or sweep: " .. tostring(urgency))
  return priority
end

---@param kind string
---@return string
function ArtifactJobs.sizeClass(kind)
  return descriptorFor(kind).size
end

---@param kind string
---@param key string
---@return string
function ArtifactJobs.jobKey(kind, key)
  ArtifactState.path(kind, key)
  return kind .. ":" .. key
end

local function sortedJobs(jobs)
  table.sort(jobs, function(left, right)
    if left.kind == right.kind then
      return left.key < right.key
    end
    return left.kind < right.kind
  end)
  return jobs
end

---@return { kind: string, key: string }[]
function ArtifactJobs.bootstrapJobs()
  return { { kind = "field-font", key = "global" } }
end

-- One selected walking pair: exactly one hero/follower bundle per request
-- with no source-inventory or audio prerequisite. It decodes directly
-- from the verified dump reader, so its roster is one keyed job.
---@param pairIndex integer
---@return { kind: string, key: string }[]
function ArtifactJobs.startupLoaderJobs(pairIndex)
  assert(
    type(pairIndex) == "number" and pairIndex % 1 == 0 and pairIndex >= 1 and pairIndex <= 32,
    "walking pair index must be an integer 1..32"
  )
  return { { kind = "startup-loader", key = tostring(pairIndex) } }
end

---@param entries string[] fixed kind[:key] members, bare kinds read global
---@return { kind: string, key: string }[]
local function fixedJobs(entries)
  local jobs = {}
  for _, entry in ipairs(entries) do
    local kind, key = entry:match("^([^:]+):?(.*)$")
    assert(kind, "milestone membership entry is malformed: " .. tostring(entry))
    if key == "" then
      key = "global"
    end
    jobs[#jobs + 1] = { kind = kind, key = key }
  end
  return jobs
end

-- The exact semantic audio references the current New Game/Oak path can
-- touch: the standard cry sequence plus every symbolic sequence the Oak
-- timeline and profile flow play, resolved against the adopted normalized
-- audio index. Resolved bank ids are never spelled here.
local NEW_GAME_AUDIO_SEQUENCES = {
  2,
  "SEQ_GS_STARTING",
  "SEQ_GS_STARTING2",
  "SEQ_SE_DP_BOWA2",
  "SEQ_SE_DP_SELECT",
  "SEQ_SE_GS_HERO_SHUKUSHOU",
}
-- Cry playback resolves the species directly as a bank, never through
-- sequence metadata, so the Marill species bank joins independently.
local NEW_GAME_DIRECT_AUDIO_BANKS = { 184 }
local STARTUP_TITLE_AUDIO_SEQUENCES = { "SEQ_GS_POKEMON_THEME", "SEQ_SE_DP_SELECT" }

local NEW_GAME_INTRO_STATIC = {
  { kind = "source-plan", key = "global" },
  { kind = "field-ui", key = "global" },
  { kind = "field-font", key = "global" },
  { kind = "intro", key = "global" },
  { kind = "new-game-init", key = "global" },
  { kind = "mon-catalog", key = "global" },
  { kind = "items", key = "global" },
  { kind = "message-bank", key = "219" },
  { kind = "audio-catalog", key = "global" },
}

---@param audioPlan table<string, unknown>|nil adopted normalized audio membership
---@return { kind: string, key: string }[] roster
---@return boolean complete true once source audio membership resolved the bank closures
function ArtifactJobs.newGameIntroJobs(audioPlan)
  local jobs = {}
  for _, member in ipairs(NEW_GAME_INTRO_STATIC) do
    jobs[#jobs + 1] = { kind = member.kind, key = member.key }
  end
  if audioPlan == nil then
    return sortedJobs(jobs), false
  end
  assert(type(audioPlan) == "table", "intro audio membership requires the adopted audio plan")
  local index = assert(audioPlan.index, "intro audio membership requires the adopted audio index")
  assert(type(index.sequences) == "table", "intro audio membership requires the adopted sequences")
  assert(type(index.sequenceBySymbol) == "table", "intro audio membership requires the adopted sequence symbols")
  local seen = {}
  local function addBank(bankId, reference)
    assert(
      type(bankId) == "number" and bankId % 1 == 0 and bankId >= 0,
      "intro audio reference resolves to no bank: " .. tostring(reference)
    )
    local key = tostring(bankId)
    if not seen[key] then
      seen[key] = true
      jobs[#jobs + 1] = { kind = "audio-bank", key = key }
    end
  end
  for _, reference in ipairs(NEW_GAME_AUDIO_SEQUENCES) do
    local sequenceId = reference
    if type(reference) == "string" then
      sequenceId = index.sequenceBySymbol[reference]
      if sequenceId == nil then
        error("intro audio reference has no adopted sequence: " .. reference, 0)
      end
    end
    local entry = index.sequences[sequenceId]
    if type(entry) ~= "table" then
      error("intro audio reference has no adopted sequence: " .. tostring(reference), 0)
    end
    addBank(entry.bankId, reference)
  end
  for _, bankId in ipairs(NEW_GAME_DIRECT_AUDIO_BANKS) do
    addBank(bankId, bankId)
  end
  return sortedJobs(jobs), true
end

-- The bounded startup title visual: one compiled title scene with no
-- source-inventory or audio prerequisite. Like the loader it decodes
-- directly from the verified dump reader, so its roster is a singleton.
---@return { kind: string, key: string }[]
function ArtifactJobs.startupTitleJobs()
  return { { kind = "startup-title", key = "global" } }
end

-- The optional startup audio closure: the title theme, the menu select
-- effect and the edition legendary cry bank behind the adopted sound
-- index. Before adoption the roster names only its owners and reports
-- incomplete; after adoption it resolves the exact bank closures from
-- the adopted symbols, deduplicated. Bank ids are never spelled here.
---@param audioPlan table<string, unknown>|nil adopted normalized audio membership
---@return { kind: string, key: string }[] roster
---@return boolean complete true once source audio membership resolved the bank closures
function ArtifactJobs.startupAudioJobs(audioPlan)
  local jobs = {
    { kind = "source-plan", key = "global" },
    { kind = "audio-catalog", key = "global" },
  }
  if audioPlan == nil then
    return sortedJobs(jobs), false
  end
  assert(type(audioPlan) == "table", "startup audio membership requires the adopted audio plan")
  local index = assert(audioPlan.index, "startup audio membership requires the adopted audio index")
  assert(type(index.sequences) == "table", "startup audio membership requires the adopted sequences")
  assert(type(index.sequenceBySymbol) == "table", "startup audio membership requires the adopted sequence symbols")
  local seen = {}
  local bankIds = {}
  local function addBank(bankId, reference)
    assert(
      type(bankId) == "number" and bankId % 1 == 0 and bankId >= 0,
      "startup audio reference resolves to no bank: " .. tostring(reference)
    )
    if not seen[bankId] then
      seen[bankId] = true
      bankIds[#bankIds + 1] = bankId
    end
  end
  for _, symbol in ipairs(STARTUP_TITLE_AUDIO_SEQUENCES) do
    local sequenceId = index.sequenceBySymbol[symbol]
    if sequenceId == nil then
      error("startup audio has no adopted sequence: " .. symbol, 0)
    end
    local sequence = index.sequences[sequenceId]
    if type(sequence) ~= "table" then
      error("startup audio has no adopted sequence: " .. symbol, 0)
    end
    addBank(sequence.bankId, symbol)
  end
  local versionId = index.version
  local crySpeciesId = versionId == "heartgold" and 250 or versionId == "soulsilver" and 249 or nil
  assert(crySpeciesId ~= nil, "startup audio index has an unsupported edition")
  addBank(crySpeciesId, "legendary cry")
  table.sort(bankIds)
  for _, bankId in ipairs(bankIds) do
    jobs[#jobs + 1] = { kind = "audio-bank", key = tostring(bankId) }
  end
  return sortedJobs(jobs), true
end

-- The smallest closure that can determine and request a target location:
-- source inventory plus the structural world and cell catalogs. It never
-- enumerates family summaries or per-map/per-bank corpus membership.
local FIELD_PLANNING_JOBS = {
  "source-plan:global",
  "world-catalog:global",
  "field-cell-index:global",
}

-- The static generated services the field runtime consumes eagerly: world
-- and cell catalogs, presentation services, actor/mon/item/bag catalogs,
-- the battle input families (battle facts, trainers, encounters) field
-- boot composes unconditionally, the two protocol menu label banks (Start
-- Menu plus the standard list menu script hosts acquire synchronously),
-- the shared transition/door sound-effect bank (transition exitSound/door
-- symbols live in Lua constant tables no map closure can reach), the audio
-- catalog and the script summary. It never contains intro setup, whole-
-- family summaries, or a per-map/per-bank corpus enumeration.
local FIELD_RUNTIME_JOBS = {
  "world-catalog:global",
  "field-cell-index:global",
  "field-camera:global",
  "field-weather:global",
  "field-effects:global",
  "field-emotes:global",
  "field-ui:global",
  "field-entry:global",
  "field-font:global",
  "actors:global",
  "mon-catalog:global",
  "mon-layout:global",
  "items:global",
  "follower-interactions:global",
  "battle-data:global",
  "trainers:global",
  "encounters:global",
  "bag:global",
  "move-icons:global",
  "apricorn-box:global",
  "party:global",
  "pc:global",
  "pokegear:global",
  "pokedex-data:global",
  "mart:global",
  "summary:global",
  "spawns:global",
  "starter-choice:global",
  "message-bank:" .. tostring(MenuProtocol.START_MENU_MESSAGE_BANK),
  "message-bank:" .. tostring(MenuProtocol.STANDARD_MESSAGE_BANK),
  "message-bank:40",
  "message-bank:265",
  "message-bank:279",
  "audio-bank:750",
  "audio-bank:700",
  "audio-catalog:global",
  "script-summary:global",
}

---@return { kind: string, key: string }[]
function ArtifactJobs.fieldPlanningJobs()
  return sortedJobs(fixedJobs(FIELD_PLANNING_JOBS))
end

---@return { kind: string, key: string }[]
function ArtifactJobs.fieldRuntimeJobs()
  return sortedJobs(fixedJobs(FIELD_RUNTIME_JOBS))
end

---@param kind string
---@param key string
---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string }[] currently known prerequisites
---@return boolean complete true once planning prerequisites are adopted and the list is final
function ArtifactJobs.dependencies(kind, key, plans)
  ArtifactState.path(kind, key)
  assert(type(plans) == "table", "dependency edges require the session plans")
  -- False until the planning prerequisites behind the resolved list are
  -- satisfied and adopted. Callers may record and wake from incomplete
  -- edges but must never dispatch a parent from them, and must never read
  -- nil membership as a known-empty final list.
  local resolve = descriptorFor(kind).dependencies
  if resolve == nil then
    return {}, true
  end
  return resolve(key, plans)
end

local function failArtifact(artifact, failure, traceback)
  local ok, finalizeError = pcall(artifact.finishFailure, artifact, failure, traceback)
  if not ok then
    error(finalizeError, 0)
  end
end

---@param context table<string, unknown>
---@param key string
local function closeFamilySession(context, key)
  local session = context[key]
  if type(session) == "table" and type(session.close) == "function" then
    context[key] = nil
    pcall(session.close, session)
  end
end

---@param context table<string, unknown>
function ArtifactJobs.closeSessions(context)
  assert(type(context) == "table", "worker sessions require a context table")
  closeFamilySession(context, "scriptSession")
  context.scriptPlan = nil
  context.scriptGenerationKey = nil
  closeFamilySession(context, "messageSession")
  closeFamilySession(context, "mapdataSession")
  closeFamilySession(context, "audioSession")
  context.audioSessionKey = nil
end

local function messageSessionFor(context)
  local session = context.messageSession
  if session == nil then
    local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
    local romFs = assert(context.romFs, "message jobs require a source reader")
    session = FieldMessageCompiler.newSession(romFs)
    context.messageSession = session
  end
  return session
end

local function mapdataSessionFor(context)
  local session = context.mapdataSession
  if session == nil then
    local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
    local romFs = assert(context.romFs, "field-data jobs require a source reader")
    session = FieldMapDataCompiler.newSession(romFs)
    context.mapdataSession = session
  end
  return session
end

local function scriptSessionFor(context, generationKey, producerFingerprint)
  if context.scriptGenerationKey ~= generationKey then
    closeFamilySession(context, "scriptSession")
    context.scriptGenerationKey = generationKey
    context.scriptPlan = nil
  end
  local plan = context.scriptPlan
  if plan == nil then
    local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
    local romFs = assert(context.romFs, "script jobs require a source reader")
    plan = ScriptCompiler.plan(romFs, producerFingerprint)
    assert(plan.generationKey == generationKey, "script job generation does not match the source plan")
    context.scriptPlan = plan
  end
  local session = context.scriptSession
  if session == nil then
    local ScriptCompileSession = require("romdump.src.digest.script.ScriptCompileSession")
    local romFs = assert(context.romFs, "script jobs require a source reader")
    session = ScriptCompileSession.new(romFs, plan)
    context.scriptSession = session
  end
  return plan, session
end

---@param compile fun(): table<string, unknown>?, unknown
---@param label string
---@return table<string, unknown>
local function compileOrRaise(compile, label)
  local bundle, failure = compile()
  if bundle == nil then
    error(failure or (label .. " compilation failed"), 0)
  end
  return bundle
end

---@param key string canonical decimal job key
---@param what string key label for diagnostics
---@return integer
local function canonicalKeyId(key, what)
  local id = assert(tonumber(key), what .. " is not canonical")
  assert(type(id) == "number" and id % 1 == 0, what .. " is not canonical")
  return id --[[@as integer]]
end

local function executeWorldCatalog(artifact, context)
  local WorldManifest = require("romdump.src.digest.map.WorldManifest")
  local romFs = assert(context.romFs, "world catalog jobs require a source reader")
  local bundle = WorldManifest.compileCatalog(romFs)
  return WorldManifest.stageCatalog(artifact, bundle)
end

local function executeCellIndex(artifact, context, producer)
  local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
  local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
  local FieldCellCacheWriter = require("romdump.src.digest.field.FieldCellCacheWriter")
  local romFs = assert(context.romFs, "cell index jobs require a source reader")
  local bundle = compileOrRaise(function()
    return FieldCellCompiler.compileIndex(romFs, producer)
  end, "cell index")
  artifact:addOwnedRoot(FieldCellCache.indexPath())
  artifact:addOwnedRoot(FieldCellCache.indexMarkerPath())
  local stage = artifact:stageFs()
  FieldCellCacheWriter.stageIndex(stage, bundle.index)
  stage:write(FieldCellCache.indexMarkerPath(), assert(bundle.indexMarker, "cell index carries no marker"))
  return bundle.indexMarker
end

local function executeFieldFont(artifact, context)
  local Compiler = require("romdump.src.digest.ui.FieldFontCompiler")
  local Writer = require("romdump.src.digest.ui.FieldFontCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs)
  end, "field font")
  return Writer.stage(artifact, bundle)
end

local function executeFieldCamera(artifact, context)
  local Compiler = require("romdump.src.digest.field.FieldCameraCompiler")
  local Writer = require("romdump.src.digest.field.FieldCameraCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs)
  end, "field camera")
  return Writer.stage(artifact, bundle)
end

local function executeStarterChoice(artifact, context)
  local Compiler = require("romdump.src.digest.newgame.StarterChoiceAssetCompiler")
  local Writer = require("romdump.src.digest.newgame.StarterChoiceAssetCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs)
  end, "starter choice")
  return Writer.stage(artifact, bundle)
end

local function executeIntro(artifact, context)
  local Compiler = require("romdump.src.digest.newgame.IntroAssetCompiler")
  local Writer = require("romdump.src.digest.newgame.IntroAssetCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs), nil
  end, "intro assets")
  return Writer.stage(artifact, bundle)
end

local function executeFieldWeather(artifact, context)
  local Compiler = require("romdump.src.digest.field.FieldWeatherCompiler")
  local Writer = require("romdump.src.digest.field.FieldWeatherCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs)
  end, "field weather")
  return Writer.stage(artifact, bundle)
end

local function executeFieldEffects(artifact, context)
  local Compiler = require("romdump.src.digest.field.FieldEntranceIndicatorCompiler")
  local Writer = require("romdump.src.digest.field.FieldEntranceIndicatorCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs), nil
  end, "field effects")
  return Writer.stage(artifact, bundle)
end

local function executeFieldUi(artifact, context)
  local Compiler = require("romdump.src.digest.ui.FieldUiCompiler")
  local Writer = require("romdump.src.digest.ui.FieldUiCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs)
  end, "field ui")
  return Writer.stage(artifact, bundle)
end

local function executeFieldEntry(artifact, context)
  local Compiler = require("romdump.src.digest.ui.FieldEntryAssetCompiler")
  local Writer = require("romdump.src.digest.ui.FieldEntryCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs)
  end, "field entry")
  return Writer.stage(artifact, bundle)
end

local function executeFieldEmotes(artifact, context)
  local Compiler = require("romdump.src.digest.actor.FieldActorEmoteCompiler")
  local Writer = require("romdump.src.digest.actor.FieldActorEmoteCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs), nil
  end, "field emotes")
  return Writer.stage(artifact, bundle)
end

local function executeFollowerInteractions(artifact, context)
  local Compiler = require("romdump.src.digest.field.FollowerInteractionCompiler")
  local Writer = require("romdump.src.digest.field.FollowerInteractionCacheWriter")
  local romFs = assert(context.romFs, "follower interaction jobs require a source reader")
  local bundle = compileOrRaise(function()
    return Compiler.compile(romFs), nil
  end, "follower interactions")
  return Writer.stage(artifact, bundle)
end

local function executeNewGameInit(artifact, context)
  local NewGameInitCompiler = require("romdump.src.digest.newgame.NewGameInitCompiler")
  local NewGameInitCacheWriter = require("romdump.src.digest.newgame.NewGameInitCacheWriter")
  local romFs = assert(context.romFs, "initializer jobs require a source reader")
  local compiled, compileErr = NewGameInitCompiler.compileFromRom(romFs)
  if compiled == nil then
    error(compileErr, 0)
  end
  return NewGameInitCacheWriter.stage(artifact, { artifact = compiled.artifact, marker = compiled.marker })
end

local function executeActors(artifact, context)
  local FieldActorCompiler = require("romdump.src.digest.actor.FieldActorCompiler")
  local FollowingMonVisualCompiler = require("romdump.src.digest.actor.FollowingMonVisualCompiler")
  local FieldActorCacheWriter = require("romdump.src.digest.actor.FieldActorCacheWriter")
  local romFs = assert(context.romFs, "actor jobs require a source reader")
  local actor = compileOrRaise(function()
    return FieldActorCompiler.compile(romFs)
  end, "field actors")
  local follower = compileOrRaise(function()
    return FollowingMonVisualCompiler.compile(romFs)
  end, "follower visuals")
  FollowingMonVisualCompiler.mergeIntoActorBundle(actor, follower)
  return FieldActorCacheWriter.stage(artifact, actor)
end

local function executeItems(artifact, context)
  local ItemCatalogCompiler = require("romdump.src.digest.items.ItemCatalogCompiler")
  local ItemCacheWriter = require("romdump.src.digest.items.ItemCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return ItemCatalogCompiler.compileAll(romFs)
  end, "items")
  return ItemCacheWriter.stage(artifact, bundle)
end

local function executeBag(artifact, context)
  local BagAssetCompiler = require("romdump.src.digest.ui.BagAssetCompiler")
  local BagCacheWriter = require("romdump.src.digest.ui.BagCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return BagAssetCompiler.compile(romFs)
  end, "bag")
  return BagCacheWriter.stage(artifact, bundle)
end

local function executeMoveIcons(artifact, context)
  local MoveIconAssetCompiler = require("romdump.src.digest.ui.MoveIconAssetCompiler")
  local MoveIconCacheWriter = require("romdump.src.digest.ui.MoveIconCacheWriter")
  local romFs = assert(context.romFs, "move icon jobs require a source reader")
  local bundle = compileOrRaise(function()
    return MoveIconAssetCompiler.compile(romFs)
  end, "move icons")
  return MoveIconCacheWriter.stage(artifact, bundle)
end

local function executeApricornBox(artifact, context)
  local ApricornBoxAssetCompiler = require("romdump.src.digest.ui.ApricornBoxAssetCompiler")
  local ApricornBoxCacheWriter = require("romdump.src.digest.ui.ApricornBoxCacheWriter")
  local romFs = assert(context.romFs, "Apricorn Box jobs require a source reader")
  local bundle = compileOrRaise(function()
    return ApricornBoxAssetCompiler.compile(romFs), nil
  end, "Apricorn Box")
  return ApricornBoxCacheWriter.stage(artifact, bundle)
end

local function dependenciesApricornBox(key)
  assert(key == "global", "Apricorn Box family only has the global job")
  return { { kind = "message-bank", key = "21" } }, true
end

local function dependenciesParty(key, plans)
  assert(key == "global", "party family only has the global job")
  local jobs = { { kind = "audio-catalog", key = "global" } }
  local audioPlan = plans.audioPlan
  if audioPlan == nil then
    return sortedJobs(jobs), false
  end
  local index = assert(audioPlan.index, "party audio closure requires the adopted audio index")
  local seen = {}
  for _, reference in ipairs(PARTY_AUDIO_SEQUENCES) do
    local sequenceId = index.sequenceBySymbol[reference]
    if sequenceId ~= nil then
      local sequence =
        assert(index.sequences[sequenceId], "party audio reference has no sequence record: " .. reference)
      local bankId = assert(sequence.bankId, "party audio sequence has no bank: " .. reference)
      if not seen[bankId] then
        seen[bankId] = true
        jobs[#jobs + 1] = { kind = "audio-bank", key = tostring(bankId) }
      end
    end
  end
  return sortedJobs(jobs), true
end

local function dependenciesMart(key, plans)
  assert(key == "global", "mart family only has the global job")
  local jobs = { { kind = "items", key = "global" }, { kind = "audio-catalog", key = "global" } }
  local audioPlan = plans.audioPlan
  if audioPlan == nil then
    return sortedJobs(jobs), false
  end
  local index = assert(audioPlan.index, "mart audio closure requires the adopted audio index")
  local seen = {}
  for _, reference in ipairs(MART_AUDIO_SEQUENCES) do
    local sequenceId = reference
    if type(reference) == "string" then
      sequenceId = index.sequenceBySymbol[reference]
      assert(sequenceId ~= nil, "mart audio reference has no adopted sequence: " .. reference)
    end
    local sequence = assert(index.sequences[sequenceId], "mart audio reference has no sequence record")
    local bankId = assert(sequence.bankId, "mart audio sequence has no bank")
    if not seen[bankId] then
      seen[bankId] = true
      jobs[#jobs + 1] = { kind = "audio-bank", key = tostring(bankId) }
    end
  end
  return sortedJobs(jobs), true
end

local function executeMart(artifact, context)
  local MartAssetCompiler = require("romdump.src.digest.ui.MartAssetCompiler")
  local MartCacheWriter = require("romdump.src.digest.ui.MartCacheWriter")
  local romFs = assert(context.romFs, "mart jobs require a source reader")
  local bundle = compileOrRaise(function()
    return MartAssetCompiler.compile(romFs)
  end, "mart")
  return MartCacheWriter.stage(artifact, bundle)
end

local function executeParty(artifact, context)
  local PartyAssetCompiler = require("romdump.src.digest.ui.PartyAssetCompiler")
  local PartyCacheWriter = require("romdump.src.digest.ui.PartyCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local bundle = compileOrRaise(function()
    return PartyAssetCompiler.compile(romFs)
  end, "party")
  return PartyCacheWriter.stage(artifact, bundle)
end

local function executePc(artifact, context)
  local PcAssetCompiler = require("romdump.src.digest.ui.PcAssetCompiler")
  local PcCacheWriter = require("romdump.src.digest.ui.PcCacheWriter")
  local romFs = assert(context.romFs, "PC jobs require a source reader")
  local bundle = compileOrRaise(function()
    return PcAssetCompiler.compile(romFs)
  end, "PC")
  return PcCacheWriter.stage(artifact, bundle)
end

local function executePokegear(artifact, context)
  local PokegearAssetCompiler = require("romdump.src.digest.ui.PokegearAssetCompiler")
  local PokegearCacheWriter = require("romdump.src.digest.ui.PokegearCacheWriter")
  local romFs = assert(context.romFs, "pokegear jobs require a source reader")
  local versionId = assert(context.versionId, "pokegear jobs require a version")
  local bundle = compileOrRaise(function()
    return PokegearAssetCompiler.compile(romFs, versionId)
  end, "pokegear")
  return PokegearCacheWriter.stage(artifact, bundle)
end

-- The semantic Pokedex data scope is a small field-runtime prerequisite:
-- knowledge and scripts consume its immutable catalog before any browser
-- opens, so it waits only for the resolved mon catalog behind it.
---@param key string
---@return { kind: string, key: string }[], boolean
local function dependenciesPokedexData(key)
  assert(key == "global", "pokedex-data family only has the global job")
  return { { kind = "mon-catalog", key = "global" } }, true
end

local function executePokedexData(artifact, context)
  local MonCache = require("libs.assets.src.MonCache")
  local PokedexCatalogCompiler = require("romdump.src.digest.ui.PokedexCatalogCompiler")
  local PokedexCacheWriter = require("romdump.src.digest.ui.PokedexCacheWriter")
  local romFs = assert(context.romFs, "pokedex-data jobs require a source reader")
  local versionId = assert(context.versionId, "pokedex-data jobs require a version")
  local cacheFs = assert(context.cacheFs, "pokedex-data jobs require a cache filesystem")
  local monCatalog = MonCache.loadCatalog(cacheFs)
  local sink = {}
  local catalog, catalogErr = PokedexCatalogCompiler.compile(romFs, versionId, monCatalog, sink)
  if catalog == nil then
    error(catalogErr, 0)
  end
  assert(type(sink.marker) == "string" and sink.marker ~= "", "pokedex-data bundle carries no marker")
  assert(type(sink.provenance) == "table", "pokedex-data bundle carries no provenance")
  return PokedexCacheWriter.stageData(artifact, {
    marker = sink.marker,
    catalog = catalog,
    assets = {},
    provenance = sink.provenance,
  })
end

-- The Pokedex presentation scope prepares the complete bounded application
-- closure on demand: it waits for data plus the shared mon layout/font
-- and the exact named message banks the fixed text roles resolve through.
---@param key string
---@return { kind: string, key: string }[], boolean
local function dependenciesPokedex(key)
  assert(key == "global", "pokedex family only has the global job")
  local PokedexAssetCompiler = require("romdump.src.digest.ui.PokedexAssetCompiler")
  return PokedexAssetCompiler.presentationDependencies(), true
end

local function executePokedexPresentation(artifact, context)
  local PokedexAssetCompiler = require("romdump.src.digest.ui.PokedexAssetCompiler")
  local PokedexCache = require("libs.assets.src.PokedexCache")
  local PokedexCacheWriter = require("romdump.src.digest.ui.PokedexCacheWriter")
  local romFs = assert(context.romFs, "pokedex jobs require a source reader")
  local versionId = assert(context.versionId, "pokedex jobs require a version")
  local cacheFs = assert(context.cacheFs, "pokedex jobs require a cache filesystem")
  local catalog = PokedexCache.loadCatalog(cacheFs)
  local sink = {}
  local manifest = compileOrRaise(function()
    return PokedexAssetCompiler.compile(romFs, versionId, catalog, sink)
  end, "pokedex")
  return PokedexCacheWriter.stagePresentation(artifact, {
    marker = assert(sink.marker, "pokedex presentation carries no marker"),
    manifest = manifest,
    assets = assert(sink.assets, "pokedex presentation carries no assets"),
    provenance = sink.provenance or {},
  })
end

-- The word-entry closure is statically bounded: the selector reads its
-- own graphics and message members from the dump and reuses the published
-- PC dictionary identities, so the PC family is its only prerequisite.
---@return { kind: string, key: string }[], boolean
local function dependenciesPokegearWordEntry()
  return { { kind = "pc", key = "global" } }, true
end

local function executePokegearWordEntry(artifact, context)
  local PokegearWordEntryCompiler = require("romdump.src.digest.ui.PokegearWordEntryCompiler")
  local PokegearAssetSchema = require("libs.assets.src.PokegearAssetSchema")
  local PokegearCache = require("libs.assets.src.PokegearCache")
  local romFs = assert(context.romFs, "pokegear word-entry jobs require a source reader")
  local versionId = assert(context.versionId, "pokegear word-entry jobs require a version")
  local bundle = compileOrRaise(function()
    return PokegearWordEntryCompiler.compile(romFs, versionId)
  end, "pokegear word entry")
  assert(type(bundle.marker) == "string" and bundle.marker ~= "", "word-entry bundle carries no marker")
  assert(type(bundle.section) == "table", "word-entry bundle carries no section")
  local assets = bundle.assets ~= nil and bundle.assets or bundle.files
  assert(type(assets) == "table", "word-entry bundle carries no assets")
  local validated, schemaErr = PokegearAssetSchema.validateWordEntry(bundle.section)
  if validated == nil then
    error(schemaErr, 0)
  end
  for _, path in ipairs(PokegearCache.wordEntryReferencedPaths(bundle.section)) do
    if assets[path] == nil then
      error("word-entry bundle is missing referenced asset " .. path, 0)
    end
  end
  artifact:addOwnedRoot(PokegearCache.assetDir())
  artifact:addOwnedRoot(PokegearCache.dir())
  local stage = artifact:stageFs()
  local cacheFs = artifact:cacheFs()
  for _, path in ipairs(PokegearCache.wordEntryReferencedPaths(bundle.section)) do
    stage:write(path, assets[path])
  end
  stage:writeLua(PokegearCache.wordEntryManifestPath(), bundle.section)
  stage:writeLua(PokegearCache.wordEntryProvenancePath(), bundle.provenance or {})
  local readback = stage:loadLua(PokegearCache.wordEntryManifestPath())
  local readbackRecord, readbackErr = PokegearAssetSchema.validateWordEntry(readback)
  if readbackRecord == nil then
    error(readbackErr or "word-entry section readback is invalid", 0)
  end
  for _, path in ipairs(PokegearCache.wordEntryReferencedPaths(bundle.section)) do
    if not stage:exists(path, "file") and not cacheFs:exists(path, "file") then
      error("word-entry asset missing after stage: " .. path, 0)
    end
  end
  stage:write(PokegearCache.wordEntryMarkerPath(), bundle.marker)
  return bundle.marker
end

local function dependenciesPc(key)
  assert(key == "global", "PC family only has the global job")
  return sortedJobs({
    { kind = "field-font", key = "global" },
    { kind = "items", key = "global" },
    { kind = "mon-catalog", key = "global" },
  }),
    true
end

---@return { kind: string, key: string }[], boolean
local function dependenciesSummary()
  return { { kind = "mon-catalog", key = "global" }, { kind = "mon-layout", key = "global" } }, true
end

local function executeSummary(artifact, context)
  local MonCache = require("libs.assets.src.MonCache")
  local SummaryAssetCompiler = require("romdump.src.digest.ui.SummaryAssetCompiler")
  local SummaryCacheWriter = require("romdump.src.digest.ui.SummaryCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  local cacheFs = assert(context.cacheFs, "summary jobs require a cache filesystem")
  local catalog = MonCache.loadCatalog(cacheFs)
  local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  local bundle = compileOrRaise(function()
    return SummaryAssetCompiler.compile(romFs, catalog, portraits)
  end, "summary")
  return SummaryCacheWriter.stage(artifact, bundle)
end

local function executeSpawnDestinations(artifact, context)
  local FieldMapDataCompiler = require("romdump.src.digest.field.FieldMapDataCompiler")
  local FieldMapDataCacheWriter = require("romdump.src.digest.field.FieldMapDataCacheWriter")
  local romFs = assert(context.romFs, "coarse jobs require a source reader")
  -- The spawn projection never fails softly: malformed producer data
  -- raises with its cause, so no nil-guarding wrapper applies here.
  local bundle = FieldMapDataCompiler.compileSpawnDestinations(romFs)
  return FieldMapDataCacheWriter.stageSpawnIndex(artifact, bundle)
end

local function executeMessageBank(artifact, context, bankId)
  local FieldMessageCacheWriter = require("romdump.src.digest.ui.FieldMessageCacheWriter")
  local session = messageSessionFor(context)
  local bundle, bankErr = session:compileBank(bankId)
  if bundle == nil then
    error(bankErr, 0)
  end
  return FieldMessageCacheWriter.stageBank(artifact, bundle)
end

local function executeMessageSummary(artifact, context)
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  local FieldMessageCompiler = require("romdump.src.digest.ui.FieldMessageCompiler")
  local FieldMessageCacheWriter = require("romdump.src.digest.ui.FieldMessageCacheWriter")
  local romFs = assert(context.romFs, "message summary jobs require a source reader")
  local cacheFs = assert(context.cacheFs, "message summary jobs require a cache filesystem")
  local index = {
    schema = FieldMessageCache.INDEX_SCHEMA,
    version = romFs:version(),
    bankIds = FieldMessageCompiler.requiredBankIds(),
  }
  local bankMarkers = {}
  for _, bankId in ipairs(index.bankIds) do
    local marker = cacheFs:read(FieldMessageCache.bankMarkerPath(bankId))
    if type(marker) ~= "string" or marker == "" then
      error("message summary misses the staged bank " .. tostring(bankId), 0)
    end
    bankMarkers[bankId] = marker
  end
  return FieldMessageCacheWriter.stageSummary(artifact, index, bankMarkers)
end

--- The borrowed immutable generation source record behind every audio
--- leaf job: resolved once per worker generation through the worker
--- source-plan memo, never re-planned per leaf and never mutated here.
---@param context table<string, unknown>
---@param job { generationId: string, producerFingerprint: string|nil, payload: table<string, unknown> }
---@param operation string
---@return table<string, unknown>
local function generationAudioSource(context, job, operation)
  local producerId = assert(job.producerFingerprint, operation .. " require a producer")
  local payload = job.payload
  local versionId = (type(payload) == "table" and payload.versionId) or context.versionId
  assert(type(versionId) == "string" and versionId ~= "", operation .. " require the version")
  local source, sourceErr = ArtifactJobs.sourcePlanForContext(context, {
    versionId = versionId,
    generationId = assert(job.generationId, operation .. " require a generation"),
    producerId = producerId,
  })
  if source == nil then
    error(sourceErr, 0)
  end
  return source
end

--- The one audio archive session for the worker source generation,
--- selected from the memoized adopted plan like every other family
--- session: version, generation, and producer scope it, the adopted sound
--- identity verifies it, and a changed scope closes it before a new one
--- opens. Decoded waves stay per bank job; the session retains only the
--- immutable archive view and lookup.
---@param context table<string, unknown>
---@param job { generationId: string, producerFingerprint: string|nil, payload: table<string, unknown> }
---@param source table<string, unknown>
---@return table<string, unknown>
local function audioSessionForContext(context, job, source)
  local AudioCompiler = require("romdump.src.digest.audio.AudioCompiler")
  local romFs = assert(context.romFs, "audio bank jobs require a source reader")
  local producerId = assert(job.producerFingerprint, "audio bank jobs require a producer")
  local payload = job.payload
  local versionId = (type(payload) == "table" and payload.versionId) or context.versionId
  assert(type(versionId) == "string" and versionId ~= "", "audio bank jobs require the version")
  local key = versionId
    .. "\0"
    .. assert(job.generationId, "audio bank jobs require a generation")
    .. "\0"
    .. producerId
  local session = context.audioSession
  if type(session) ~= "table" or context.audioSessionKey ~= key then
    closeFamilySession(context, "audioSession")
    context.audioSessionKey = nil
    local audioIdentity = assert(source.audioIdentity, "audio bank jobs require the published sound identity")
    ---@cast audioIdentity table<string, unknown>
    local opened, openErr = AudioCompiler.openSession(romFs, audioIdentity)
    if opened == nil then
      error(assert(openErr), 0)
    end
    session = opened
    context.audioSession = session
    context.audioSessionKey = key
  end
  return session
end

local function executeAudioBank(artifact, context, job, bankId)
  local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")
  local source = generationAudioSource(context, job, "audio bank jobs")
  local audioPlan = assert(source.audioPlan, "audio bank jobs require the published audio membership")
  ---@cast audioPlan table<string, unknown>
  local selected = nil
  for _, bankPlan in ipairs(assert(audioPlan.bankPlans, "audio bank jobs require the published bank closures")) do
    ---@cast bankPlan table<string, unknown>
    if bankPlan.bankId == bankId then
      selected = bankPlan
      break
    end
  end
  if selected == nil then
    error("audio bank " .. tostring(bankId) .. " is not a member of the published audio plan", 0)
  end
  return AudioCacheWriter.stageBank(artifact, audioSessionForContext(context, job, source), selected)
end

local function executeAudioCatalog(artifact, context, job)
  local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")
  local source = generationAudioSource(context, job, "audio catalog jobs")
  local audioPlan = assert(source.audioPlan, "audio catalog jobs require the published audio membership")
  local audioIdentity = assert(source.audioIdentity, "audio catalog jobs require the published sound identity")
  return AudioCacheWriter.stageCatalog(artifact, audioPlan, audioIdentity)
end

local function executeAudioSummary(artifact, context, job)
  local AudioCacheWriter = require("romdump.src.digest.audio.AudioCacheWriter")
  local source = generationAudioSource(context, job, "audio summary jobs")
  local audioPlan = assert(source.audioPlan, "audio summary jobs require the published audio membership")
  return AudioCacheWriter.stageSummary(artifact, audioPlan)
end

local function executeScriptMember(artifact, context, memberId, generationKey, producer)
  local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
  local plan, session = scriptSessionFor(context, generationKey, producer)
  local member, memberErr = session:compileMember(memberId)
  if member == nil then
    error(memberErr, 0)
  end
  return ScriptCacheWriter.stageMember(artifact, plan, member)
end

local function executeScriptSummary(artifact, context, producer)
  local ScriptCompiler = require("romdump.src.digest.script.ScriptCompiler")
  local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
  local romFs = assert(context.romFs, "script summary jobs require a source reader")
  local plan = ScriptCompiler.plan(romFs, producer)
  return ScriptCacheWriter.stageSummary(artifact, plan)
end

local function executeMapData(artifact, context, mapId)
  local FieldMapDataCacheWriter = require("romdump.src.digest.field.FieldMapDataCacheWriter")
  local session = mapdataSessionFor(context)
  local bundle, bundleErr = session:compile(mapId)
  if bundle == nil then
    error(bundleErr or ("map-data record " .. tostring(mapId) .. " is not supported"), 0)
  end
  return FieldMapDataCacheWriter.stage(artifact, bundle)
end

local function executeFieldCell(artifact, context, payload, producer)
  local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
  local FieldCellCompiler = require("romdump.src.digest.field.FieldCellCompiler")
  local FieldCellCacheWriter = require("romdump.src.digest.field.FieldCellCacheWriter")
  local descriptor = {
    matrixMemberId = assert(payload.matrixMemberId, "field-cell jobs require matrixMemberId"),
    index = assert(payload.index, "field-cell jobs require index"),
    x = assert(payload.x, "field-cell jobs require x"),
    z = assert(payload.z, "field-cell jobs require z"),
    mapHeaderId = assert(payload.mapHeaderId, "field-cell jobs require mapHeaderId"),
    altitude = assert(payload.altitude, "field-cell jobs require altitude"),
    landDataMemberId = assert(payload.landDataMemberId, "field-cell jobs require landDataMemberId"),
    areaDataMemberId = assert(payload.areaDataMemberId, "field-cell jobs require areaDataMemberId"),
    file = FieldCellCache.cellPath(payload.matrixMemberId, payload.index),
  }
  local scratch = context.fieldCellScratch or {}
  context.fieldCellScratch = scratch
  scratch.geometryArena = context.geometryArena
  scratch.gxScratch = context.gxScratch
  scratch.terrainScratch = context.terrainScratch
  local romFs = assert(context.romFs, "field-cell jobs require a source reader")
  local compiled = FieldCellCompiler.compileCell(romFs, descriptor, scratch, producer)
  FieldCellCacheWriter.stagePrepared(artifact, descriptor, compiled)
  return compiled.cell.cellMarker
end

local function executeMap(artifact, context, mapId, producer)
  local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
  local MapAssetCompiler = require("romdump.src.digest.map.MapAssetCompiler")
  local MapCacheWriter = require("romdump.src.digest.map.MapCacheWriter")
  local romFs = assert(context.romFs, "map jobs require a source reader")
  local cacheFs = assert(context.cacheFs, "map jobs require a cache filesystem")
  local bundle = compileOrRaise(function()
    return MapAssetCompiler.compile(romFs, mapId, {
      cacheFs = cacheFs,
      fieldCellIndex = FieldCellCache.loadIndex(cacheFs),
      producerFingerprint = producer,
      geometryArena = context.geometryArena,
      gxScratch = context.gxScratch,
      terrainScratch = context.terrainScratch,
    })
  end, "map " .. tostring(mapId))
  MapCacheWriter.stage(artifact, bundle)
  return bundle.marker
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job { generationId: string, producerFingerprint: string|nil }
---@return string compiler marker for the receipt
local function executeSourcePlan(artifact, context, job)
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local romFs = assert(context.romFs, "source inventory jobs require a source reader")
  local versionId = assert(context.versionId, "source inventory jobs require a version")
  local plan = SourcePlan.compile(romFs, {
    versionId = versionId,
    generationId = assert(job.generationId, "source inventory jobs require a generation"),
    producerId = assert(job.producerFingerprint, "source inventory jobs require a producer"),
  })
  return SourcePlan.stage(artifact, plan)
end

---@param artifact table<string, unknown>
---@param job ArtifactJobs.Job
---@param context table<string, unknown>
---@return string compiler marker for the receipt
local function dispatchExecute(artifact, job, context)
  return descriptorFor(job.kind).execute(artifact, context, job)
end

---@param job ArtifactJobs.Job
---@param context table<string, unknown>
---@return { stageName: string, result: table<string, unknown> }
function ArtifactJobs.execute(job, context)
  assert(type(job) == "table", "worker job must be a table")
  assert(type(job.kind) == "string" and job.kind ~= "", "worker job kind is required")
  assert(type(job.key) == "string" and job.key ~= "", "worker job key is required")
  ArtifactState.path(job.kind, job.key)
  assert(context and context.romFs and context.cacheFs, "worker context is incomplete")
  assert(type(job.stageName) == "string", "worker job stage name is required")
  assert(type(job.generationId) == "string" and job.generationId ~= "", "worker job generation is required")
  assert(type(job.epoch) == "number" and job.epoch % 1 == 0, "worker job epoch must be an integer")
  local PreparedArtifact = require("romdump.src.build.PreparedArtifact")
  local artifact = PreparedArtifact.new({
    cacheFs = context.cacheFs,
    generationId = job.generationId,
    epoch = job.epoch,
    kind = job.kind,
    key = job.key,
    jobKey = job.kind .. ":" .. job.key,
    stageName = job.stageName,
  })
  -- Workers arrive through two shapes: the pool forwards scalar selectors
  -- inside payload, while direct execution flattens them beside the job
  -- identity. Merge both into one selector view; explicit top-level fields
  -- win over the payload table.
  local select = {}
  if type(job.payload) == "table" then
    for field, value in pairs(job.payload) do
      select[field] = value
    end
  end
  for field, value in pairs(job) do
    if field ~= "payload" and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
      select[field] = value
    end
  end
  local normalized = {
    kind = job.kind,
    key = job.key,
    generationId = job.generationId,
    producerFingerprint = select.producerFingerprint,
    payload = select,
  }
  local ok, marker = xpcall(function()
    return dispatchExecute(artifact, normalized, context)
  end, function(failure)
    return { failure = failure, traceback = debug.traceback("", 2) }
  end)
  if not ok then
    local info = marker --[[@as { failure: unknown, traceback: string }]]
    failArtifact(artifact, info.failure, info.traceback)
    error(info.failure, 0)
  end
  assert(type(marker) == "string" and marker ~= "", "family execution carries no marker")
  artifact:finishSuccess({ marker = marker })
  return { stageName = job.stageName, result = { marker = marker } }
end

---@param cacheFs table<string, unknown>
---@param generationId string
---@param receiptKind string
---@param receiptKey string
---@return string|nil marker
local function receiptMarker(cacheFs, generationId, receiptKind, receiptKey)
  local receipt = ArtifactState.read(cacheFs, generationId, receiptKind, receiptKey)
  if receipt == nil then
    return nil
  end
  local marker = receipt.marker
  if type(marker) ~= "string" or marker == "" then
    return nil
  end
  return marker
end

---@param cacheFs table<string, unknown>
---@param generationId string
---@param childKind string
---@param childKey string
---@param ready fun(marker: string): boolean
---@return boolean
local function childReady(cacheFs, generationId, childKind, childKey, ready)
  local marker = receiptMarker(cacheFs, generationId, childKind, childKey)
  if marker == nil then
    return false
  end
  return ready(marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateWorldCatalog(check)
  local MapAssetCache = require("libs.assets.src.MapAssetCache")
  return MapAssetCache.isStructuralWorld(check.cacheFs:loadLua(MapAssetCache.worldPath()))
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeFieldCellIndexJob(artifact, context, job)
  return executeCellIndex(artifact, context, assert(job.producerFingerprint, "index jobs require a producer"))
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateFieldCellIndex(check)
  local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
  local cacheFs, marker = check.cacheFs, check.marker
  if cacheFs:read(FieldCellCache.indexMarkerPath()) ~= marker then
    return false
  end
  local indexOk, index = pcall(cacheFs.loadLua, cacheFs, FieldCellCache.indexPath())
  if not indexOk or not FieldCellCache.validateIndex(index) then
    return false
  end
  return true
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateFieldCamera(check)
  local FieldCameraCache = require("libs.assets.src.field.FieldCameraCache")
  return FieldCameraCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateFieldWeather(check)
  local FieldWeatherCache = require("libs.assets.src.field.FieldWeatherCache")
  return FieldWeatherCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateFieldEffects(check)
  local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
  return FieldEffectAssetCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateFieldEmotes(check)
  local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")
  return FieldEmoteAssetCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateFollowerInteractions(check)
  local Cache = require("libs.assets.src.field.FollowerInteractionCache")
  return Cache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateFieldUi(check)
  local FieldUiAssetCache = require("libs.assets.src.field.FieldUiAssetCache")
  return FieldUiAssetCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateFieldEntry(check)
  local FieldEntryAssetCache = require("libs.assets.src.field.FieldEntryAssetCache")
  return FieldEntryAssetCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateFieldFont(check)
  local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
  return FieldFontCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateIntro(check)
  local IntroAssetCache = require("libs.assets.src.newgame.IntroAssetCache")
  return IntroAssetCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateNewGameInit(check)
  local NewGameInitCache = require("libs.assets.src.newgame.NewGameInitCache")
  return NewGameInitCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateActors(check)
  local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
  return FieldActorCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateStarterChoice(check)
  local StarterChoiceAssetCache = require("libs.assets.src.StarterChoiceAssetCache")
  return StarterChoiceAssetCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateItems(check)
  local ItemCache = require("libs.assets.src.ItemCache")
  return ItemCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateBag(check)
  local BagCache = require("libs.assets.src.BagCache")
  return BagCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateMoveIcons(check)
  local MoveIconCache = require("libs.assets.src.MoveIconCache")
  return MoveIconCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateApricornBox(check)
  local ApricornBoxAssetCache = require("libs.assets.src.ApricornBoxAssetCache")
  return ApricornBoxAssetCache.isReady(check.cacheFs, check.marker)
end

local function validateMart(check)
  local MartCache = require("libs.assets.src.MartCache")
  return MartCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateParty(check)
  local PartyCache = require("libs.assets.src.PartyCache")
  return PartyCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validatePc(check)
  local PcCache = require("libs.assets.src.PcCache")
  return PcCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validatePokegear(check)
  local PokegearCache = require("libs.assets.src.PokegearCache")
  return PokegearCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validatePokegearWordEntry(check)
  local PokegearCache = require("libs.assets.src.PokegearCache")
  return PokegearCache.isWordEntryReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validatePokedexData(check)
  local PokedexCache = require("libs.assets.src.PokedexCache")
  return PokedexCache.isDataReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validatePokedex(check)
  local PokedexCache = require("libs.assets.src.PokedexCache")
  return PokedexCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateSummary(check)
  local SummaryCache = require("libs.assets.src.SummaryCache")
  return SummaryCache.isReady(check.cacheFs, check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateSpawnDestinations(check)
  local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
  return FieldMapDataCache.isSpawnIndexReady(check.cacheFs, check.marker)
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeMessageBankJob(artifact, context, job)
  return executeMessageBank(artifact, context, assert(tonumber(job.key), "bank key is not canonical"))
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateMessageBank(check)
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  return FieldMessageCache.isBankReady(check.cacheFs, canonicalKeyId(check.key, "bank key"), check.marker)
end

---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string }[], boolean
local function dependenciesMessageSummary(_, plans)
  local deps = {}
  for _, bankId in ipairs(assert(plans.messageBankIds, "message summary needs the required banks")) do
    deps[#deps + 1] = { kind = "message-bank", key = tostring(bankId) }
  end
  return deps, true
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateMessageSummary(check)
  local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
  local cacheFs, generationId, plans, marker = check.cacheFs, check.generationId, check.plans, check.marker
  if not FieldMessageCache.isReady(cacheFs, marker) then
    return false
  end
  for _, bankId in ipairs(assert(plans.messageBankIds, "message summary needs the required banks")) do
    if
      not childReady(cacheFs, generationId, "message-bank", tostring(bankId), function(childMarker)
        return FieldMessageCache.isBankReady(cacheFs, bankId, childMarker)
      end)
    then
      return false
    end
  end
  return true
end

---@return { kind: string, key: string }[], boolean
local function dependenciesOnSourcePlan()
  return { { kind = "source-plan", key = "global" } }, true
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeAudioBankJob(artifact, context, job)
  return executeAudioBank(artifact, context, job, assert(tonumber(job.key), "bank key is not canonical"))
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateAudioBank(check)
  local AudioCache = require("libs.assets.src.audio.AudioCache")
  return AudioCache.isBankReady(check.cacheFs, canonicalKeyId(check.key, "bank key"), check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateAudioCatalog(check)
  local AudioCache = require("libs.assets.src.audio.AudioCache")
  return AudioCache.isCatalogReady(check.cacheFs, check.marker)
end

---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string }[], boolean
local function dependenciesAudioSummary(_, plans)
  local deps = {
    { kind = "source-plan", key = "global" },
    { kind = "audio-catalog", key = "global" },
  }
  if plans.audioBankIds == nil then
    return deps, false
  end
  for _, bankId in ipairs(plans.audioBankIds) do
    deps[#deps + 1] = { kind = "audio-bank", key = tostring(bankId) }
  end
  return deps, true
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateAudioSummary(check)
  local AudioCache = require("libs.assets.src.audio.AudioCache")
  local cacheFs, generationId, plans, marker = check.cacheFs, check.generationId, check.plans, check.marker
  if not AudioCache.isReady(cacheFs, marker) then
    return false
  end
  for _, bankId in ipairs(assert(plans.audioBankIds, "audio summary needs the bank closures")) do
    if
      not childReady(cacheFs, generationId, "audio-bank", tostring(bankId), function(childMarker)
        return AudioCache.isBankReady(cacheFs, bankId, childMarker)
      end)
    then
      return false
    end
  end
  return true
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeScriptMemberJob(artifact, context, job)
  local payload = job.payload or {}
  return executeScriptMember(
    artifact,
    context,
    assert(payload.memberId, "script member jobs require memberId"),
    assert(payload.generationKey, "script member jobs require generationKey"),
    assert(job.producerFingerprint, "script member jobs require a producer")
  )
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateScriptMember(check)
  local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
  local scriptPlan = assert(check.plans.scriptPlan, "script members need the generation plan")
  local memberId = canonicalKeyId(check.key, "member key")
  local ready, _ = ScriptCacheWriter.isMemberReady(check.cacheFs, scriptPlan, memberId)
  return ready == true
end

---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string }[], boolean
local function dependenciesScriptSummary(_, plans)
  local deps = { { kind = "source-plan", key = "global" } }
  if plans.scriptMemberIds == nil then
    return deps, false
  end
  for _, memberId in ipairs(plans.scriptMemberIds) do
    deps[#deps + 1] = { kind = "script-member", key = tostring(memberId) }
  end
  return deps, true
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeScriptSummaryJob(artifact, context, job)
  return executeScriptSummary(artifact, context, assert(job.producerFingerprint, "summary jobs require a producer"))
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateScriptSummary(check)
  local ScriptCache = require("libs.assets.src.ScriptCache")
  local cacheFs, generationId, plans, marker = check.cacheFs, check.generationId, check.plans, check.marker
  if not ScriptCache.isReady(cacheFs, marker) then
    return false
  end
  local ScriptCacheWriter = require("romdump.src.digest.script.ScriptCacheWriter")
  local scriptPlan = assert(plans.scriptPlan, "script summary needs the generation plan")
  for _, memberId in ipairs(assert(plans.scriptMemberIds, "script summary needs the nonempty members")) do
    if receiptMarker(cacheFs, generationId, "script-member", tostring(memberId)) == nil then
      return false
    end
    local ready, _ = ScriptCacheWriter.isMemberReady(cacheFs, scriptPlan, memberId)
    if not ready then
      return false
    end
  end
  return true
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeMapDataJob(artifact, context, job)
  return executeMapData(artifact, context, assert(tonumber(job.key), "map key is not canonical"))
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateMapData(check)
  local FieldMapDataCache = require("libs.assets.src.field.FieldMapDataCache")
  return FieldMapDataCache.isReady(check.cacheFs, tonumber(check.key), check.marker)
end

---@return { kind: string, key: string }[], boolean
local function dependenciesFieldCell()
  return {
    { kind = "source-plan", key = "global" },
    { kind = "field-cell-index", key = "global" },
  }, true
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeFieldCellJob(artifact, context, job)
  return executeFieldCell(
    artifact,
    context,
    job.payload or {},
    assert(job.producerFingerprint, "cell jobs require a producer")
  )
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateFieldCell(check)
  local FieldCellCache = require("libs.assets.src.field.FieldCellCache")
  local cacheFs, key, plans, marker = check.cacheFs, check.key, check.plans, check.marker
  local matrixMemberId, index = key:match("^([0-9]+)-([0-9]+)$")
  local descriptor = nil
  for _, matrix in ipairs(assert(plans.indexBundle, "cells need the canonical index").index.matrices) do
    if matrix.matrixMemberId == tonumber(matrixMemberId) then
      for _, cell in ipairs(matrix.cells) do
        if cell.index == tonumber(index) then
          descriptor = cell
          break
        end
      end
    end
    if descriptor ~= nil then
      break
    end
  end
  if descriptor == nil then
    return false
  end
  return FieldCellCache.isCellReady(cacheFs, descriptor, marker)
end

---@param key string
---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string }[], boolean
local function dependenciesMap(key, plans)
  local deps = {
    { kind = "source-plan", key = "global" },
    { kind = "world-catalog", key = "global" },
    { kind = "field-cell-index", key = "global" },
  }
  local cellKeys = plans.mapCellKeys and plans.mapCellKeys[tonumber(key)]
  if cellKeys == nil then
    return deps, false
  end
  for _, cellKey in ipairs(cellKeys) do
    deps[#deps + 1] = { kind = "field-cell", key = cellKey }
  end
  return deps, true
end

---@param artifact table<string, unknown>
---@param context table<string, unknown>
---@param job ArtifactJobs.Job
---@return string
local function executeMapJob(artifact, context, job)
  return executeMap(
    artifact,
    context,
    assert(tonumber(job.key), "map key is not canonical"),
    assert(job.producerFingerprint, "map jobs require a producer")
  )
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
local function validateMap(check)
  local MapAssetCache = require("libs.assets.src.MapAssetCache")
  return MapAssetCache.isReady(check.cacheFs, canonicalKeyId(check.key, "map key"), check.marker)
end

---@param check ArtifactJobs.ReadinessCheck
---@return boolean
---@return table<string, unknown>|nil validated source plan on success for immediate adoption
local function validateSourcePlan(check)
  local SourcePlan = require("romdump.src.build.SourcePlan")
  if check.marker ~= SourcePlan.marker(check.generationId) then
    return false
  end
  -- The expected identity always comes from the caller, never from the
  -- record being validated. The full reader is the single authority:
  -- any record it rejects is not ready, exactly once.
  local expected = assert(check.identity, "source-plan validation requires its expected identity")
  local plan, _ = SourcePlan.read(check.cacheFs, expected)
  if plan == nil then
    return false
  end
  return true, plan
end

local function executeStartupLoader(artifact, context, job)
  local compiler = require("romdump.src.digest.startup.StartupVisualCompiler")
  local writer = require("romdump.src.digest.startup.StartupCacheWriter")
  local pairIndex = tonumber(job.key)
  if type(job.payload) == "table" and type(job.payload.pairIndex) == "number" then
    pairIndex = job.payload.pairIndex
  end
  if type(job.pairIndex) == "number" then
    pairIndex = job.pairIndex
  end
  assert(
    type(pairIndex) == "number" and pairIndex % 1 == 0 and pairIndex >= 1 and pairIndex <= 32,
    "startup loader jobs carry their walking pair selection"
  )
  ---@cast pairIndex integer
  local bundle, err = compiler.compile(assert(context.romFs, "startup loader requires a source reader"), pairIndex)
  if bundle == nil then
    error(assert(err), 0)
  end
  return writer.stageLoader(artifact, bundle, job.generationId, pairIndex)
end

local function executeStartupTitle(artifact, context, job)
  local compiler = require("romdump.src.digest.startup.TitleScreenCompiler")
  local writer = require("romdump.src.digest.startup.StartupCacheWriter")
  local romFs = assert(context.romFs, "startup title requires a source reader")
  local edition = assert(context.versionId or romFs:version(), "startup title requires an edition")
  local bundle, err = compiler.compile(romFs, edition)
  if bundle == nil then
    error(assert(err), 0)
  end
  return writer.stageTitle(artifact, bundle, job.generationId)
end

local function validateStartupLoader(check)
  local cache = require("libs.assets.src.StartupAssetCache")
  local pairIndex = tonumber(check.key)
  if pairIndex == nil or pairIndex % 1 ~= 0 or pairIndex < 1 or pairIndex > 32 then
    return false
  end
  ---@cast pairIndex integer
  local bundle = cache.loadWalker(check.cacheFs, pairIndex)
  return type(bundle) == "table" and bundle.generationId == check.generationId
end

local function validateStartupTitle(check)
  local cache = require("libs.assets.src.StartupAssetCache")
  local bundle = cache.loadTitle(check.cacheFs, check.cacheFs.versionId)
  return type(bundle) == "table" and bundle.generationId == check.generationId
end

DESCRIPTORS = {
  -- Planning roots: no prerequisite.
  ["world-catalog"] = {
    size = "normal",
    execute = executeWorldCatalog,
    validate = validateWorldCatalog,
  },
  ["field-cell-index"] = {
    size = "normal",
    execute = executeFieldCellIndexJob,
    validate = validateFieldCellIndex,
  },
  -- Coarse bootstrap field families: no prerequisite.
  ["field-camera"] = {
    size = "normal",
    execute = executeFieldCamera,
    validate = validateFieldCamera,
  },
  ["field-weather"] = {
    size = "normal",
    execute = executeFieldWeather,
    validate = validateFieldWeather,
  },
  ["field-effects"] = {
    size = "normal",
    execute = executeFieldEffects,
    validate = validateFieldEffects,
  },
  ["field-emotes"] = {
    size = "normal",
    execute = executeFieldEmotes,
    validate = validateFieldEmotes,
  },
  ["follower-interactions"] = {
    size = "normal",
    execute = executeFollowerInteractions,
    validate = validateFollowerInteractions,
  },
  ["field-ui"] = {
    size = "normal",
    execute = executeFieldUi,
    validate = validateFieldUi,
  },
  ["field-entry"] = {
    size = "normal",
    execute = executeFieldEntry,
    validate = validateFieldEntry,
  },
  ["field-font"] = {
    size = "heavy",
    execute = executeFieldFont,
    validate = validateFieldFont,
  },
  -- Game-start families: no prerequisite.
  intro = {
    size = "normal",
    execute = executeIntro,
    validate = validateIntro,
  },
  ["new-game-init"] = {
    size = "normal",
    execute = executeNewGameInit,
    validate = validateNewGameInit,
  },
  actors = {
    size = "heavy",
    execute = executeActors,
    validate = validateActors,
  },
  ["starter-choice"] = {
    size = "normal",
    execute = executeStarterChoice,
    validate = validateStarterChoice,
  },
  -- Mon families.
  ["mon-catalog"] = {
    size = "heavy",
    execute = ArtifactMonJobs.executeCatalog,
    validate = ArtifactMonJobs.validateCatalog,
  },
  ["mon-layout"] = {
    size = "heavy",
    dependencies = ArtifactMonJobs.dependenciesLayout,
    execute = ArtifactMonJobs.executeLayout,
    validate = ArtifactMonJobs.validateLayout,
  },
  ["mon-icon-page"] = {
    size = "normal",
    dependencies = ArtifactMonJobs.dependenciesIconPage,
    execute = ArtifactMonJobs.executeIconPage,
    validate = ArtifactMonJobs.validateIconPage,
  },
  ["mon-portrait-page"] = {
    size = "normal",
    dependencies = ArtifactMonJobs.dependenciesPortraitPage,
    execute = ArtifactMonJobs.executePortraitPage,
    validate = ArtifactMonJobs.validatePortraitPage,
  },
  ["mon-summary"] = {
    size = "normal",
    dependencies = ArtifactMonJobs.dependenciesSummary,
    execute = ArtifactMonJobs.executeSummary,
    validate = ArtifactMonJobs.validateSummary,
  },
  -- Item, bag and party presentation: no prerequisite.
  items = {
    size = "normal",
    execute = executeItems,
    validate = validateItems,
  },
  -- Battle input families: semantic projection over the supported dump.
  ["battle-data"] = {
    size = "normal",
    dependencies = ArtifactBattleJobs.dependenciesBattleData,
    execute = ArtifactBattleJobs.executeBattleData,
    validate = ArtifactBattleJobs.validateBattleData,
  },
  trainers = {
    size = "normal",
    dependencies = ArtifactBattleJobs.dependenciesTrainers,
    execute = ArtifactBattleJobs.executeTrainers,
    validate = ArtifactBattleJobs.validateTrainers,
  },
  encounters = {
    size = "normal",
    dependencies = ArtifactBattleJobs.dependenciesEncounters,
    execute = ArtifactBattleJobs.executeEncounters,
    validate = ArtifactBattleJobs.validateEncounters,
  },
  -- Battle presentation: the shared ordinary menu/HUD definitions once,
  -- then one lazily compiled persistent scene per demanded semantic key.
  ["battle-presentation"] = {
    size = "normal",
    execute = ArtifactBattleJobs.executePresentation,
    validate = ArtifactBattleJobs.validatePresentation,
  },
  ["battle-scene"] = {
    size = "normal",
    dependencies = ArtifactBattleJobs.dependenciesScene,
    execute = ArtifactBattleJobs.executeScene,
    validate = ArtifactBattleJobs.validateScene,
  },
  bag = {
    size = "normal",
    execute = executeBag,
    validate = validateBag,
  },
  ["move-icons"] = {
    size = "normal",
    execute = executeMoveIcons,
    validate = validateMoveIcons,
  },
  ["apricorn-box"] = {
    size = "normal",
    dependencies = dependenciesApricornBox,
    execute = executeApricornBox,
    validate = validateApricornBox,
  },
  mart = {
    size = "normal",
    dependencies = dependenciesMart,
    execute = executeMart,
    validate = validateMart,
  },
  party = {
    size = "normal",
    dependencies = dependenciesParty,
    execute = executeParty,
    validate = validateParty,
  },
  pc = {
    size = "normal",
    dependencies = dependenciesPc,
    execute = executePc,
    validate = validatePc,
  },
  pokegear = {
    size = "normal",
    execute = executePokegear,
    validate = validatePokegear,
  },
  -- Single-word entry: the bounded selector closure over the existing
  -- dictionary identities, staged beside the core family.
  ["pokegear-word-entry"] = {
    size = "normal",
    dependencies = dependenciesPokegearWordEntry,
    execute = executePokegearWordEntry,
    validate = validatePokegearWordEntry,
  },
  -- Pokedex scopes: semantic data for field boot plus on-demand
  -- application presentation. Each owns its exact payload and marker
  -- files, so one scope never erases the other.
  ["pokedex-data"] = {
    size = "normal",
    dependencies = dependenciesPokedexData,
    execute = executePokedexData,
    validate = validatePokedexData,
  },
  pokedex = {
    size = "normal",
    dependencies = dependenciesPokedex,
    execute = executePokedexPresentation,
    validate = validatePokedex,
  },
  -- Summary presentation: builds over the current mon catalog and
  -- layout families, never over paged portrait pixels.
  summary = {
    size = "normal",
    dependencies = dependenciesSummary,
    execute = executeSummary,
    validate = validateSummary,
  },
  -- Teleport landing index: one family-level record, no prerequisite.
  spawns = {
    size = "normal",
    execute = executeSpawnDestinations,
    validate = validateSpawnDestinations,
  },
  -- Message banks and summary.
  ["message-bank"] = {
    size = "heavy",
    execute = executeMessageBankJob,
    validate = validateMessageBank,
  },
  ["message-summary"] = {
    size = "normal",
    dependencies = dependenciesMessageSummary,
    execute = executeMessageSummary,
    validate = validateMessageSummary,
  },
  -- Audio banks, catalog and summary.
  ["audio-bank"] = {
    size = "heavy",
    dependencies = dependenciesOnSourcePlan,
    execute = executeAudioBankJob,
    validate = validateAudioBank,
  },
  ["audio-catalog"] = {
    size = "heavy",
    dependencies = dependenciesOnSourcePlan,
    execute = executeAudioCatalog,
    validate = validateAudioCatalog,
  },
  ["audio-summary"] = {
    size = "heavy",
    dependencies = dependenciesAudioSummary,
    execute = executeAudioSummary,
    validate = validateAudioSummary,
  },
  -- Script members and summary.
  ["script-member"] = {
    size = "heavy",
    dependencies = dependenciesOnSourcePlan,
    execute = executeScriptMemberJob,
    validate = validateScriptMember,
  },
  ["script-summary"] = {
    size = "heavy",
    dependencies = dependenciesScriptSummary,
    execute = executeScriptSummaryJob,
    validate = validateScriptSummary,
  },
  -- Field records, cells and scenes.
  ["map-data"] = {
    size = "normal",
    execute = executeMapDataJob,
    validate = validateMapData,
  },
  ["field-cell"] = {
    size = "jumbo",
    dependencies = dependenciesFieldCell,
    execute = executeFieldCellJob,
    validate = validateFieldCell,
  },
  map = {
    size = "jumbo",
    dependencies = dependenciesMap,
    execute = executeMapJob,
    validate = validateMap,
  },
  -- The single worker-compiled source inventory: no prerequisite.
  ["source-plan"] = {
    size = "heavy",
    execute = executeSourcePlan,
    validate = validateSourcePlan,
  },
  -- Startup visuals decode straight from the verified dump reader:
  -- neither enrolls the source inventory nor any audio bank.
  ["startup-loader"] = {
    size = "normal",
    execute = executeStartupLoader,
    validate = validateStartupLoader,
  },
  ["startup-title"] = {
    size = "heavy",
    execute = executeStartupTitle,
    validate = validateStartupTitle,
  },
}

-- The closed behavior table and the accepted vocabulary describe the same
-- set from opposite sides: a kind added or removed on only one side is a
-- programming error, caught here once instead of through a public list.
for kind in pairs(ArtifactState.KINDS) do
  assert(DESCRIPTORS[kind] ~= nil, "artifact kind has no descriptor: " .. tostring(kind))
end
for kind in pairs(DESCRIPTORS) do
  assert(ArtifactState.KINDS[kind] == true, "descriptor names an unknown artifact kind: " .. tostring(kind))
end
---@param cacheFs table<string, unknown>
---@param generationId string
---@param kind string
---@param key string
---@param plans ArtifactJobs.Plans
---@param identity { versionId: string, generationId: string, producerId: string }|nil expected source identity, mandatory for source-plan
---@return boolean
---@return table<string, unknown>|nil validated source plan on source-plan success for immediate adoption
function ArtifactJobs.validate(cacheFs, generationId, kind, key, plans, identity)
  if kind == "source-plan" then
    assert(type(identity) == "table", "source-plan validation requires its expected identity")
    assert(
      type(identity.versionId) == "string" and identity.versionId ~= "",
      "source-plan validation requires the expected version"
    )
    assert(
      type(identity.generationId) == "string" and identity.generationId ~= "",
      "source-plan validation requires the expected generation"
    )
    assert(
      type(identity.producerId) == "string" and identity.producerId ~= "",
      "source-plan validation requires the expected producer"
    )
  end
  ArtifactState.path(kind, key)
  assert(type(plans) == "table", "readiness validation requires the session plans")
  local descriptor = descriptorFor(kind)
  local marker = receiptMarker(cacheFs, generationId, kind, key)
  if marker == nil then
    return false
  end
  local function isChildReady(childKind, childKey, isReady)
    return childReady(cacheFs, generationId, childKind, childKey, isReady)
  end
  local ready, validatedPlan = descriptor.validate({
    cacheFs = cacheFs,
    generationId = generationId,
    key = key,
    plans = plans,
    marker = marker,
    childReady = isChildReady,
    identity = identity,
  })
  if ready ~= true then
    return false
  end
  return true, validatedPlan
end

---@param cacheFs CacheFs
---@param identity { versionId: string, generationId: string, producerId: string }
---@return ArtifactJobs.Plans|nil
---@return string|nil
function ArtifactJobs.publishedPlans(cacheFs, identity)
  assert(cacheFs and cacheFs.read and cacheFs.loadLua, "published plans require a cache filesystem")
  assert(type(identity) == "table", "published plans require the generation identity")
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local plan, planReason = SourcePlan.read(cacheFs, identity)
  if plan == nil then
    return nil, planReason
  end
  local MonCache = require("libs.assets.src.MonCache")
  local catalogOk, catalog = pcall(MonCache.loadCatalog, cacheFs)
  if not catalogOk or type(catalog) ~= "table" then
    return nil, "mon catalog is not published"
  end
  local layoutMarker = cacheFs:read(MonCache.layoutMarkerPath())
  if type(layoutMarker) ~= "string" or layoutMarker == "" then
    return nil, "mon layout is not published"
  end
  local MonCacheWriter = require("romdump.src.digest.mons.MonCacheWriter")
  local layoutReady, layoutReason = MonCacheWriter.isLayoutSourceReady(
    cacheFs,
    assert(identity.generationId, "published plans need a generation"),
    layoutMarker
  )
  if not layoutReady then
    return nil, layoutReason
  end
  local index = cacheFs:loadLua(MonCacheWriter.sourcePlanIndexPath())
  if type(index) ~= "table" then
    return nil, "mon page membership is not published"
  end
  local icons = cacheFs:loadLua(MonCache.iconManifestPath())
  local portraits = cacheFs:loadLua(MonCache.portraitManifestPath())
  if type(icons) ~= "table" or type(portraits) ~= "table" then
    return nil, "mon manifests are not published"
  end
  ---@cast plan table<string, unknown>
  local plans = SourcePlan.project(plan)
  plans.iconPageIds = assert(index.iconPageIds, "published plans need the icon pages")
  plans.portraitPageIds = assert(index.portraitPageIds, "published plans need the portrait pages")
  plans.presentation = { icons = icons, portraits = portraits }
  return plans
end

-- Canonical complete-inventory order behind both the materialized list
-- and the resumable enumerator: the fixed global closure first, then one
-- dynamic family after another in the same sequence. The enumerator
-- yields one logical job per call without building, sorting, or copying
-- the corpus, so interactive sweep can advance a bounded chunk per
-- update; draining it reproduces the complete list below.
-- Aggregate summaries enumerate last: registering one before its leaves
-- would expand the whole leaf family through ordinary dependency edges.
local COMPLETE_TRAIL_SUMMARIES = {
  "mon-summary",
  "message-summary",
  "audio-summary",
  "script-summary",
}

local COMPLETE_STATIC_GLOBALS = {
  "world-catalog",
  "field-cell-index",
  "field-camera",
  "field-weather",
  "field-effects",
  "field-emotes",
  "field-ui",
  "field-entry",
  "field-font",
  "intro",
  "new-game-init",
  "actors",
  "starter-choice",
  "items",
  "follower-interactions",
  "bag",
  "move-icons",
  "apricorn-box",
  "party",
  "pc",
  "pokegear",
  "pokedex-data",
  "pokedex",
  "mart",
  "summary",
  "spawns",
  "mon-catalog",
  "mon-layout",
  "audio-catalog",
  "startup-title",
}

-- Producer-internal generation source-plan memo for compiler-worker
-- context. The worker owns the memo for one VM: it returns the validated
-- record for the worker's current version/generation/producer identity
-- and re-reads through the validating reader whenever that identity
-- changes. The record is borrowed immutable; it carries no ROM handle
-- and never reaches runtime packages. The successful read also caches
-- the one base projection under the same identity, returned third so
-- readiness can reuse it without re-deriving the membership.
---@param context table<string, unknown>
---@param identity { versionId: string, generationId: string, producerId: string }
---@return table<string, unknown>|nil
---@return string|nil
---@return table<string, unknown>|nil
function ArtifactJobs.sourcePlanForContext(context, identity)
  assert(type(context) == "table", "worker source plans require a context table")
  assert(type(identity) == "table", "worker source plans require the generation identity")
  assert(type(identity.versionId) == "string" and identity.versionId ~= "", "worker source plans require the version")
  assert(
    type(identity.generationId) == "string" and identity.generationId ~= "",
    "worker source plans require the generation"
  )
  assert(
    type(identity.producerId) == "string" and identity.producerId ~= "",
    "worker source plans require the producer"
  )
  local memo = context.sourcePlanMemo
  if
    type(memo) == "table"
    and memo.versionId == identity.versionId
    and memo.generationId == identity.generationId
    and memo.producerId == identity.producerId
    and type(memo.plan) == "table"
    and type(memo.basePlans) == "table"
  then
    return memo.plan, nil, memo.basePlans
  end
  local SourcePlan = require("romdump.src.build.SourcePlan")
  local cacheFs = assert(context.cacheFs, "worker source plans require a cache filesystem")
  local plan, reason = SourcePlan.read(cacheFs, identity)
  if plan == nil then
    return nil, reason, nil
  end
  local basePlans = SourcePlan.project(plan)
  context.sourcePlanMemo = {
    versionId = identity.versionId,
    generationId = identity.generationId,
    producerId = identity.producerId,
    plan = plan,
    basePlans = basePlans,
  }
  return plan, nil, basePlans
end

---@param plans ArtifactJobs.Plans
---@return fun(): { kind: string, key: string, jobKey: string }|nil
function ArtifactJobs.completeIterator(plans)
  assert(type(plans) == "table", "complete inventory requires its published plans")
  local messageBankIds = assert(plans.messageBankIds, "complete inventory needs the message banks")
  local audioBankIds = assert(plans.audioBankIds, "complete inventory needs the audio banks")
  local scriptMemberIds = assert(plans.scriptMemberIds, "complete inventory needs the script members")
  local iconPageIds = assert(plans.iconPageIds, "complete inventory needs the icon pages")
  local portraitPageIds = assert(plans.portraitPageIds, "complete inventory needs the portrait pages")
  local mapDataIds = assert(plans.mapDataIds, "complete inventory needs the field records")
  local mapIds = assert(plans.mapIds, "complete inventory needs the world maps")
  local indexBundle = assert(plans.indexBundle, "complete inventory needs the canonical cell index")
  ---@cast indexBundle table<string, unknown>
  local cellIndex = assert(indexBundle.index, "complete inventory needs the canonical cell index")
  ---@cast cellIndex table<string, unknown>
  local matrices = assert(cellIndex.matrices, "complete inventory needs the canonical cell index")
  ---@cast matrices table[]
  local function identify(kind, key)
    return { kind = kind, key = key, jobKey = ArtifactJobs.jobKey(kind, key) }
  end
  local phase = 0
  local position = 1
  local matrixPosition = 1
  local cellPosition = 1
  local function nextComplete()
    while true do
      if phase == 0 then
        phase, position = 1, 1
        return identify("source-plan", "global")
      elseif phase == 1 then
        if position <= #COMPLETE_STATIC_GLOBALS then
          local kind = COMPLETE_STATIC_GLOBALS[position]
          position = position + 1
          return identify(kind, "global")
        end
        phase, position = 2, 1
      elseif phase == 2 then
        if position <= #messageBankIds then
          local bankId = messageBankIds[position]
          position = position + 1
          return identify("message-bank", tostring(bankId))
        end
        phase, position = 3, 1
      elseif phase == 3 then
        if position <= #audioBankIds then
          local bankId = audioBankIds[position]
          position = position + 1
          return identify("audio-bank", tostring(bankId))
        end
        phase, position = 4, 1
      elseif phase == 4 then
        if position <= #scriptMemberIds then
          local memberId = scriptMemberIds[position]
          position = position + 1
          return identify("script-member", tostring(memberId))
        end
        phase, position = 5, 1
      elseif phase == 5 then
        if position <= #iconPageIds then
          local pageId = iconPageIds[position]
          position = position + 1
          return identify("mon-icon-page", tostring(pageId))
        end
        phase, position = 6, 1
      elseif phase == 6 then
        if position <= #portraitPageIds then
          local pageId = portraitPageIds[position]
          position = position + 1
          return identify("mon-portrait-page", tostring(pageId))
        end
        phase, position = 7, 1
      elseif phase == 7 then
        if position <= #mapDataIds then
          local mapId = mapDataIds[position]
          position = position + 1
          return identify("map-data", tostring(mapId))
        end
        phase = 8
      elseif phase == 8 then
        while matrixPosition <= #matrices do
          local cells = matrices[matrixPosition].cells
          if cellPosition <= #cells then
            local descriptor = cells[cellPosition]
            cellPosition = cellPosition + 1
            return identify("field-cell", descriptor.matrixMemberId .. "-" .. descriptor.index)
          end
          matrixPosition = matrixPosition + 1
          cellPosition = 1
        end
        phase, position = 9, 1
      elseif phase == 9 then
        if position <= #mapIds then
          local mapId = mapIds[position]
          position = position + 1
          return identify("map", tostring(mapId))
        end
        phase, position = 10, 1
      elseif phase == 10 then
        -- Aggregate summaries close the enumeration so background
        -- registration meets already-ready leaves instead of expanding
        -- whole families at once. The enumerated set is unchanged; only
        -- the deterministic order moves.
        if position <= #COMPLETE_TRAIL_SUMMARIES then
          local kind = COMPLETE_TRAIL_SUMMARIES[position]
          position = position + 1
          return identify(kind, "global")
        end
        return nil
      else
        return nil
      end
    end
  end
  return nextComplete
end

---@param plans ArtifactJobs.Plans
---@return { kind: string, key: string, jobKey: string }[]
function ArtifactJobs.completeJobs(plans)
  assert(type(plans) == "table", "complete inventory requires its published plans")
  local jobs = {}
  local seen = {}
  local iterate = ArtifactJobs.completeIterator(plans)
  while true do
    local job = iterate()
    if job == nil then
      break
    end
    if not seen[job.jobKey] then
      seen[job.jobKey] = true
      jobs[#jobs + 1] = job
    end
  end
  table.sort(jobs, function(left, right)
    if left.kind == right.kind then
      local leftId, rightId = tonumber(left.key), tonumber(right.key)
      if leftId ~= nil and rightId ~= nil then
        return leftId < rightId
      end
      return left.key < right.key
    end
    return left.kind < right.kind
  end)
  return jobs
end

---@param catalog table<string, unknown> mon semantic catalog with species/forms
---@param actorSpriteIds table<integer, boolean> merged actor index membership
---@return true|nil
---@return string|nil
function ArtifactJobs.checkFollowers(catalog, actorSpriteIds)
  if type(catalog) ~= "table" or type(catalog.species) ~= "table" then
    return nil, "mon catalog carries no species table"
  end
  if type(actorSpriteIds) ~= "table" then
    return nil, "merged actor index is unavailable"
  end
  for speciesKey, species in pairs(catalog.species) do
    if type(species) == "table" and type(species.forms) == "table" then
      for formId, form in pairs(species.forms) do
        if type(form) == "table" and form.follower ~= nil then
          local refs = { form.follower.visualId }
          if form.follower.female ~= nil then
            refs[#refs + 1] = form.follower.female.visualId
          end
          for _, visualId in ipairs(refs) do
            if not actorSpriteIds[visualId] then
              return nil,
                "catalog follower visual " .. tostring(visualId) .. " for " .. tostring(speciesKey) .. "/" .. tostring(
                  formId
                ) .. " is absent from the merged actor index"
            end
          end
        end
      end
    end
  end
  return true
end

return ArtifactJobs
