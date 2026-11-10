-- Battle presentation worker registration over the real dump: the two
-- kinds live in the closed job table, scene keys validate, and scene
-- demands resolve to the staged global. Assertions are readiness
-- relationships and key rules, never catalog snapshots.
--
-- This suite deliberately declares no derived assets and executes
-- nothing: requesting battle-presentation:global or a battle-scene key
-- as a bare prepare requirement hangs the batch session (the global's
-- dependencies need the adopted audio plan, but bare kind:key
-- requirements never demand the source inventory, so planning waits
-- forever). Requirement sets that also pull a source-plan edge (the
-- graphics suites through their portrait pages) prepare fine, and every
-- such preparation executes these jobs, so a broken execute still fails
-- the run at prepare time. The execute path itself is covered by
-- romdump/tests/cache_builder_test.lua.

local Assert = require("tests.support.Assert")
local ArtifactJobs = require("romdump.src.build.ArtifactJobs")
local ArtifactState = require("romdump.src.build.ArtifactState")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

function T.kinds_sizes_and_keys_follow_the_closed_dispatch()
  Assert.isTrue(ArtifactState.KINDS["battle-presentation"] == true, "the global kind is registered")
  Assert.isTrue(ArtifactState.KINDS["battle-scene"] == true, "the scene kind is registered")
  Assert.equal(ArtifactJobs.sizeClass("battle-presentation"), "normal", "the global job has its lane")
  Assert.equal(ArtifactJobs.sizeClass("battle-scene"), "normal", "scene jobs have their lane")
  Assert.equal(
    ArtifactJobs.jobKey("battle-scene", "general/grass/day"),
    "battle-scene:general/grass/day",
    "scene job keys carry the semantic key"
  )
  Assert.equal(
    ArtifactState.path("battle-scene", "general/grass/day"),
    "data/generated/jobs/battle-scene/general/grass/day.lua",
    "scene receipts nest under their kind"
  )
end

function T.scene_keys_validate_while_effect_backgrounds_do_not()
  local ok = pcall(ArtifactState.path, "battle-scene", "general/grass/day")
  Assert.isTrue(ok, "an ordinary scene key resolves to a receipt path")
  local effectOk = pcall(ArtifactState.path, "battle-scene", "effect/flash/day")
  Assert.isFalse(effectOk, "an effect background never resolves to a receipt path")
  local globalOk = pcall(ArtifactState.path, "battle-presentation", "other")
  Assert.isFalse(globalOk, "the global family carries no other key")
end

function T.scene_demands_resolve_to_the_staged_global()
  local dependencies, complete = ArtifactJobs.dependencies("battle-scene", "general/grass/day", {})
  Assert.isTrue(complete, "scene dependencies resolve without adopted plans")
  Assert.deepEqual(dependencies, { { kind = "battle-presentation", key = "global" } }, "scenes build on the global")
end

-- Provider gate: one worker execution proves the split. A global build opens
-- no trainer, ball-particle, or evolution source archive, reads no ball
-- sprite member from the shared scene archive and no evolution font
-- palette member, stages no detached record section, and never compiles
-- an audio bank; a front: trainer request and a ball: request each stage
-- exactly one safe-keyed leaf receipt plus its marker, marker last, and
-- each staged leaf reports ready. Archive and member identities come from
-- the source config, never from hardcoded snapshots.
function T.global_build_keeps_detached_families_behind_safe_keyed_leaf_receipts(romFs, versionId)
  local Sources = require("romdump.src.config.BattlePresentationSources")
  local BattleJobs = require("romdump.src.build.ArtifactBattleJobs")
  local BattleCache = require("libs.assets.src.battle.BattlePresentationCache")
  local BattleSchema = require("libs.assets.src.battle.BattlePresentationSchema")

  local opens = {}
  local memberReads = {}
  local countingRomFs = {}
  function countingRomFs:version()
    return romFs:version()
  end
  function countingRomFs:metadata()
    return romFs:metadata()
  end
  function countingRomFs:readOverlay(cpu, overlayId)
    return romFs:readOverlay(cpu, overlayId)
  end
  function countingRomFs:openNarc(symbol)
    opens[symbol] = (opens[symbol] or 0) + 1
    local archive = romFs:openNarc(symbol)
    Assert.notNil(archive, "the counted reader opens " .. tostring(symbol))
    local counted = {}
    function counted:readMember(memberId)
      local key = symbol .. ":" .. tostring(memberId)
      memberReads[key] = (memberReads[key] or 0) + 1
      return archive:readMember(memberId)
    end
    function counted:memberCount()
      return archive:memberCount()
    end
    return counted
  end

  local audioModule = "romdump.src.digest.audio.AudioCompiler"
  local realAudio = require(audioModule)
  local compileBankCalls = 0
  local countingAudio = {}
  setmetatable(countingAudio, { __index = realAudio })
  function countingAudio.compileBank(...)
    compileBankCalls = compileBankCalls + 1
    return realAudio.compileBank(...)
  end
  package.loaded[audioModule] = countingAudio

  local function newStage()
    local stage = { files = {}, owned = {}, order = {} }
    stage.artifact = {
      stageFs = function()
        return {
          write = function(_, path, bytes)
            stage.files[path] = bytes
            stage.order[#stage.order + 1] = path
          end,
          writeLua = function(_, path, value)
            stage.files[path] = value
            stage.order[#stage.order + 1] = path
          end,
        }
      end,
      addOwnedRoot = function(_, path)
        stage.owned[path] = true
      end,
    }
    return stage
  end

  local gateOk, gateErr = pcall(function()
    local context = { romFs = countingRomFs, versionId = versionId }

    local globalStage = newStage()
    local globalMarker =
      BattleJobs.executePresentation(globalStage.artifact, context, { generationId = "provider-gate", key = "global" })
    Assert.isTrue(type(globalMarker) == "string" and globalMarker ~= "", "the global worker returns its marker")
    local detachedArchives = {
      Sources.TRAINER_PICTURES.frontArchive,
      Sources.TRAINER_PICTURES.backArchive,
      Sources.BALL_PARTICLES.archive,
      Sources.EVOLUTION_PARTICLES.archiveSymbol,
      Sources.EVOLUTION_GRAPHICS.main.archiveSymbol,
      Sources.EVOLUTION_GRAPHICS.main.paletteArchiveSymbol,
      Sources.EVOLUTION_GRAPHICS.sub.archiveSymbol,
      Sources.EVOLUTION_GRAPHICS.menu.archiveSymbol,
      Sources.EVOLUTION_GRAPHICS.cursor.archiveSymbol,
    }
    for _, symbol in ipairs(detachedArchives) do
      Assert.isNil(opens[symbol], "the global build never opens the detached archive " .. tostring(symbol))
    end
    for _, entry in pairs(Sources.BALL_PICTURES.entries) do
      for _, memberId in ipairs({ entry.animationMember, entry.cellMember, entry.characterMember, entry.paletteMember }) do
        Assert.isNil(
          memberReads[Sources.SCENE_NARC .. ":" .. tostring(memberId)],
          "the global build never decodes ball member " .. tostring(memberId)
        )
      end
    end
    local evolutionFont = Sources.EVOLUTION_MENU_TEXT_PALETTE
    Assert.isNil(
      memberReads[evolutionFont.archiveSymbol .. ":" .. tostring(evolutionFont.memberId)],
      "the global build never reads the evolution menu text palette"
    )
    Assert.equal(compileBankCalls, 0, "the global build compiles no audio bank")

    local manifest = globalStage.files[BattleCache.manifestPath()]
    Assert.isTrue(type(manifest) == "table", "the global worker stages its manifest")
    Assert.isNil(manifest.trainerPictures, "the core stages no trainer picture section")
    Assert.isNil(manifest.battleBalls, "the core stages no ball section")
    Assert.isNil(manifest.evolutionParticles, "the core stages no evolution particle section")
    Assert.isNil(manifest.evolutionGraphics, "the core stages no evolution graphics section")
    Assert.isNil(manifest.sequenceClosures, "the core stages no audio bank closures")
    local introMusic = manifest.audioRoles ~= nil and manifest.audioRoles.introMusic or nil
    Assert.isTrue(type(introMusic) == "table", "the core keeps its semantic music routes")
    Assert.isNil(introMusic.sequenceClosures, "music routes stay semantic without bank closures")
    for path in pairs(globalStage.owned) do
      Assert.isNil(path:find("trainer-pictures", 1, true), "the global owns no trainer leaf root: " .. tostring(path))
      Assert.isNil(path:find("/balls/", 1, true), "the global owns no ball leaf root: " .. tostring(path))
      Assert.isNil(path:find("/evolution/", 1, true), "the global owns no evolution leaf root: " .. tostring(path))
    end
    Assert.equal(globalStage.order[#globalStage.order], BattleCache.markerPath(), "the global marker publishes last")

    local function checkSingleLeafReceipt(kind, key, selector, recordPath, markerPath, expectedSchema, readyCheck)
      local stage = newStage()
      local execute = kind == "battle-trainer-picture" and BattleJobs.executeTrainerPicture or BattleJobs.executeBall
      local marker = execute(stage.artifact, context, { generationId = "provider-gate", key = key })
      Assert.isTrue(type(marker) == "string" and marker ~= "", "the " .. selector .. " worker returns its marker")
      Assert.equal(
        ArtifactState.path(kind, key),
        "data/generated/jobs/" .. kind .. "/" .. key .. ".lua",
        "the " .. selector .. " receipt nests under its safe key"
      )
      local record = stage.files[recordPath]
      Assert.isTrue(type(record) == "table", "one " .. selector .. " request stages one leaf receipt")
      Assert.equal(record.selector, selector, "the leaf receipt names its exact selector")
      Assert.equal(record.schema, expectedSchema, "the leaf receipt carries its schema")
      Assert.isTrue(
        type(stage.files[markerPath]) == "string",
        "one " .. selector .. " request stages one completion marker"
      )
      local stagedCount = 0
      for path, _ in pairs(stage.files) do
        stagedCount = stagedCount + 1
        if path ~= recordPath and path ~= markerPath then
          -- Particle textures spell the item stem lowercase
          -- (battle-ball-particles-poke_ball-seal-0.png); the match stays
          -- per-selector by deriving the stem from the safe key.
          Assert.notNil(
            path:lower():find(key:lower(), 1, true),
            "every extra staged file stays under the selector-owned prefix: " .. tostring(path)
          )
        end
      end
      Assert.isTrue(stagedCount >= 3, "the leaf stages its receipt, marker, and owned images")
      local ownedCount = 0
      for path, _ in pairs(stage.owned) do
        ownedCount = ownedCount + 1
        Assert.notNil(stage.files[path], "every owned leaf root is staged: " .. tostring(path))
      end
      Assert.equal(ownedCount, stagedCount, "the leaf owns exactly what it stages")
      Assert.equal(stage.order[#stage.order], markerPath, "the " .. selector .. " marker publishes last")
      local cacheFs = {
        read = function(_, path)
          return stage.files[path]
        end,
        loadLua = function(_, path)
          return stage.files[path]
        end,
      }
      Assert.isTrue(readyCheck(cacheFs, marker) == true, "the staged " .. selector .. " leaf reports ready")
    end

    local trainerSelector = "front:YOUNGSTER"
    checkSingleLeafReceipt(
      "battle-trainer-picture",
      "front-YOUNGSTER",
      trainerSelector,
      BattleCache.trainerPicturePath(trainerSelector),
      BattleCache.trainerPictureMarkerPath(trainerSelector),
      BattleSchema.TRAINER_PICTURE_SCHEMA,
      function(cacheFs, marker)
        return BattleCache.isTrainerPictureReady(cacheFs, trainerSelector, marker)
      end
    )
    local ballSelector = "ball:POKE_BALL"
    checkSingleLeafReceipt(
      "battle-ball",
      "POKE_BALL",
      ballSelector,
      BattleCache.ballPath(ballSelector),
      BattleCache.ballMarkerPath(ballSelector),
      BattleSchema.BALL_SCHEMA,
      function(cacheFs, marker)
        return BattleCache.isBallReady(cacheFs, ballSelector, marker)
      end
    )
  end)
  package.loaded[audioModule] = realAudio
  if not gateOk then
    error(gateErr, 0)
  end
end

return RomSuite.fromFacts(T)
