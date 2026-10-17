-- Production-composed Ilex Forest shrine contract. Boots the real field
-- runtime on MAP_ILEX_FOREST one tile south of the shrine background event
-- (16, 55) facing north, presses Action through the production interaction
-- resolver, and proves the shrine dispatch script runs instead of faulting
-- on its first instruction. The staged Celebi leg then plays the fateful
-- lead branch through the time-travel beat and asserts the Route 22 warp
-- with its script-visible state (VAR_UNK_40FE, friend visibility), while
-- sampling the production screen-fade cover on every tick: the journey
-- must show a visible interval between the cutscene's opening cover and
-- its closing white cover, never a single unbroken white hold. Exact
-- beat/swirl counts and the terminal opaque gate live in the cutscene
-- task unit contract; this scenario only proves the composed ordering
-- reaches the covered warp. The 3D model, camera roll, and motion blur
-- have no presentation owner, so nothing here claims cinematic
-- completeness. The auto-started Route 22 past scene (camera-target ops
-- 102/103) is a separate follow-up and stays outside this contract:
-- fault assertions are scoped to the Ilex member-92 scripts.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local BagSave = require("libs.hgss.src.save.BagSave")
local MartSave = require("libs.hgss.src.save.MartSave")
local Mailbox = require("libs.hgss.src.save.Mailbox")
local PhotoAlbum = require("libs.hgss.src.save.PhotoAlbum")
local FashionCaseState = require("libs.hgss.src.save.FashionCaseState")
local LocalClock = require("game.src.LocalClock")
local CacheFs = require("libs.storage.src.CacheFs")
local MonCache = require("libs.assets.src.MonCache")
local MonCatalog = require("libs.mons.src.MonCatalog")
local ItemCache = require("libs.assets.src.ItemCache")
local ItemCatalog = require("libs.items.src.ItemCatalog")
local FieldFontLoader = require("libs.hgss.src.ui.FieldFontLoader")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local MonFactory = require("libs.mons.src.gen4.MonFactory")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local Party = require("libs.mons.src.Party")
local MonsSave = require("libs.mons.src.MonsSave")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_assets" },
    derivedAssets = {
      "field-runtime",
      "map:117",
      "map-data:117",
      "script-member:92",
      "message-bank:115",
      "map:27",
      "map-data:27",
      "script-member:212",
    },
    tags = { "field", "shrine", "celebi", "acceptance" },
  },
  tests = {},
}

local MAP = "MAP_ILEX_FOREST"
local SHRINE = { fieldX = 16, fieldZ = 56, facing = "north" }
local ROCKETS_BEATEN = FieldScriptSymbols.flagsByName.FLAG_BEAT_RADIO_TOWER_ROCKETS
local FRIEND_HIDDEN = FieldScriptSymbols.flagsByName.FLAG_HIDE_ILEX_FOREST_FRIEND
local PROGRESS_40FE = FieldScriptSymbols.variablesByName.VAR_UNK_40FE

-- One staged party lead through the production mon factory: the same
-- script-gift policy the live service uses, with the fateful marker the
-- shrine's EVENT_CELEBI trigger reads. Level and met details never enter
-- the trigger contract.
local function leadBucket(versionId, species, fateful)
  local cacheFs = CacheFs.forVersion(versionId)
  local monRoot = MonCache.loadCatalog(cacheFs)
  local itemCatalog = ItemCatalog.new(ItemCache.loadCatalog(cacheFs))
  local monCatalog = MonCatalog.new(monRoot, itemCatalog)
  local charmap = assert(FieldFontLoader.load(cacheFs).charmap, "acceptance font carries the production charmap")
  local factory = MonFactory.new({
    catalog = monCatalog,
    rng = Lcrng.new(0xC31EB1),
    charmap = charmap,
    games = HgssMonService.GAMES,
    languages = HgssMonService.LANGUAGES,
    game = versionId,
    language = monRoot.version.language,
  })
  local mon = factory:createScriptGift({
    species = species,
    level = 5,
    profile = { name = "GOLD", gender = 0, trainerId = 1 },
    location = 7,
    date = { year = 2000, month = 1, day = 1 },
  })
  mon.fatefulEncounter = fateful
  local party = Party.new()
  Assert.isTrue(party:add(mon), "the staged lead fits the empty party")
  return MonsSave.capture(party:capture(), Lcrng.new(0x5EED):capture())
end

local function withShrineGame(fn, options)
  options = options or {}
  local clock = LocalClock.new(function()
    return { year = 2000, month = 1, day = 1, hour = 12, minute = 0, second = 0 }
  end)
  local harness = AcceptanceHarness.new({
    gameFactory = function(versionId, map)
      local worldState = FieldEventState.new()
      for _, flag in ipairs(options.flags or {}) do
        worldState:setFlag(flag)
      end
      return {
        saveId = "save-00000001",
        versionId = versionId,
        -- Harness spawns take map-local coordinates (pre origin-offset)
        -- while SHRINE is global: Ilex Forest's origin is (0, 32), and the
        -- shrine side is unreachable on foot from the southern spawn
        -- (a Cut tree seals x=16, z=62), so start on the approach tile.
        location = { mapSymbol = map, fieldX = SHRINE.fieldX, fieldZ = SHRINE.fieldZ - 32, facing = SHRINE.facing },
        playerData = {
          profile = {
            name = "GOLD",
            gender = 0,
            trainerId = 1,
            money = 3000,
            badges = 0,
            nationalDex = false,
            runningShoes = false,
            runningShoesLock = false,
          },
          options = { textSpeed = "fastest", textFrame = 0 },
        },
        fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
        fashionCase = FashionCaseState.empty(),
        playTime = PlayTime.new(),
        worldState = worldState,
        mons = leadBucket(versionId, options.leadSpecies or "CHIKORITA", options.fateful == true),
        bag = BagSave.empty(),
        mart = MartSave.empty(),
        mailbox = Mailbox.new():capture(),
        photoAlbum = PhotoAlbum.new():capture(),
      }
    end,
  })
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = MAP,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true, localClock = clock },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local placed = game:snapshot()
    Assert.equal(placed.player.fieldX, SHRINE.fieldX, "the spawn lands on the shrine approach X")
    Assert.equal(placed.player.fieldZ, SHRINE.fieldZ, "the spawn lands on the shrine approach Z")
    game:face(SHRINE.facing)
    fn(game)
    Assert.equal(game:renderAttempts(), 0, "the shrine flow must stop before GPU rendering")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- Faults raised by the journey scripts (Ilex member 92, Route 22 member
-- 212, Tohjo member 114). The Tohjo Giovanni battle and its post-battle
-- resume (a follower release-next-to-player the engine does not implement
-- yet) stay outside this contract.
local JOURNEY_MEMBERS = { "scr_seq.0092", "scr_seq.0212", "scr_seq.0114" }

local function journeyFaults(game)
  local faults = {}
  for _, record in ipairs(game:recordsNamed("script.error")) do
    local scriptId = record.payload and record.payload.scriptId or ""
    for _, member in ipairs(JOURNEY_MEMBERS) do
      if scriptId:find(member, 1, true) ~= nil then
        faults[#faults + 1] = record
        break
      end
    end
  end
  return faults
end

local function faultDetail(game)
  local faults = journeyFaults(game)
  if faults[1] == nil then
    return "none"
  end
  local payload = faults[1].payload or {}
  return tostring(payload.scriptId) .. "/" .. tostring(payload.code)
end

-- Drive semantic Action edges until the field reaches the named map or a
-- journey script faults. The past scenes use no menus, so holding Action
-- through dialogue and movement is safe. When `cover` is given, every
-- tick also samples the production screen-fade coefficient so the caller
-- can prove the journey showed a visible interval before its covered
-- warp: opaque, then clear, then opaque again. The saves and derived
-- caches stay isolated: the harness boots a per-run save namespace over
-- read-only fixtures, and this driver writes nothing back.
local function driveUntilMap(game, mapSymbol, maxTicks, cover)
  local arrived = nil
  for _ = 1, maxTicks do
    local snapshot = game:snapshot()
    if cover ~= nil then
      local fade = assert(snapshot.screenFade, "the composed runtime owns the screen-fade controller")
      if fade.coefficient == 16 then
        if cover.clearAfterOpaque then
          cover.opaqueAfterClear = true
        end
        cover.opaque = true
      elseif fade.coefficient == 0 then
        if cover.opaque then
          cover.clearAfterOpaque = true
        end
      end
    end
    if snapshot.mapSymbol == mapSymbol then
      arrived = snapshot
      break
    end
    if #journeyFaults(game) > 0 then
      break
    end
    game.runtime:pressAction()
    game:step()
    game.runtime:releaseAction()
  end
  return arrived
end

-- A fresh save carries no Rockets progress, so the shrine dispatch must
-- reach its plain-text fallback: the bike check, the Pichu pass-through,
-- and the Celebi gate all observe non-triggering state, and the shrine
-- message prints and dismisses through normal confirmation.
function T.tests.shrine_answers_its_plain_text_without_faulting()
  withShrineGame(function(game)
    local snapshot = game:pressAction()
    Assert.equal(snapshot.player.fieldX, SHRINE.fieldX, "the Action press never moves the player")
    local interaction = game.lastInteraction or {}
    Assert.equal(
      interaction.kind,
      "background",
      string.format(
        "the shrine resolves as a background event (pos=%d,%d facing=%s map=%s kind=%s)",
        snapshot.player.fieldX,
        snapshot.player.fieldZ,
        tostring(snapshot.player.facing),
        tostring(snapshot.mapSymbol),
        tostring(interaction.kind)
      )
    )
    local scriptId = assert(game.lastInteraction.scriptId, "the shrine background binds a script")
    Assert.isTrue(scriptId:find("scr_seq.0092", 1, true) ~= nil, "the shrine binds the Ilex script member")
    Assert.isTrue(scriptId:find("script_012", 1, true) ~= nil, "the shrine binds its dispatch script")

    local printed = false
    for _ = 1, 480 do
      game:step()
      if #journeyFaults(game) > 0 then
        break
      end
      if game:snapshot().dialogue.modal then
        printed = true
        break
      end
    end
    Assert.equal(
      #journeyFaults(game),
      0,
      "the shrine dispatch must not fault its bike check or gates (got " .. faultDetail(game) .. ")"
    )
    Assert.isTrue(printed, "the plain shrine text must reach its dialogue window")
    game:advanceDialogue()
    local settled = game:snapshot()
    Assert.isFalse(settled.dialogue.modal, "the shrine text must dismiss through normal confirmation")
    Assert.isFalse(settled.fieldLocked, "the plain shrine path must release the field")
  end)
end

-- The staged pre-event state (Rockets beaten, friend hidden, fateful
-- Celebi lead, untouched progress) must take the Celebi branch: the
-- friend appears, the time-travel beat completes, and the field warps to
-- Route 22 with progress set and the friend hidden again. The cover
-- trace must show the field visible between the cutscene's opening
-- cover and its closing white cover; an unbroken white hold from the
-- cutscene start to the warp would fail this ordering. The auto-started
-- past scene stays outside this contract: its principals stand on
-- pocket tiles our generated terrain does not cover yet (see the
-- terrain gap below), so it cannot run to its Tohjo warp here. The
-- absent 3D swirl/model is likewise out of scope: only the fade
-- ordering and the covered warp are asserted.
function T.tests.celebi_branch_warps_to_route_22_with_progress_set()
  withShrineGame(function(game)
    game:pressAction()
    Assert.equal(game.lastInteraction.kind, "background", "the shrine resolves as a background event")

    local cover = {}
    local route22 = driveUntilMap(game, "MAP_ROUTE_22", 20000, cover)
    Assert.equal(
      #journeyFaults(game),
      0,
      "the Celebi branch must not fault through its warp (got " .. faultDetail(game) .. ")"
    )
    Assert.notNil(route22, "the Celebi branch must warp the field to Route 22")
    Assert.isTrue(
      cover.opaqueAfterClear == true,
      "the cutscene must clear its opening cover before closing white for the warp"
    )
    local world = assert(game.runtime.scripts.worldState, "field world state is available")
    Assert.equal(world:getVar(PROGRESS_40FE), 1, "the time travel advances the event progress")
    Assert.isTrue(world:isFlagSet(FRIEND_HIDDEN), "the departure hides the friend again")
  end, { flags = { ROCKETS_BEATEN, FRIEND_HIDDEN }, leadSpecies = "CELEBI", fateful = true })
end

return T
