-- Controller coverage for the battle screen through the real runtime:
-- mode walking with reentrant edges, source identity maps, empty and
-- unusable slots with their reasons, narration acknowledgement
-- consumption, input-key rules, per-case overrides, the selection arrow
-- cycle, screen-level draw restoration, and sealed projected fragments.
-- Synthetic fixtures only.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local BattleScreenInterface = require("game.hgss.src.battle.BattleScreenInterface")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local HgssBagService = require("libs.hgss.src.items.HgssBagService")
local ItemFixture = require("libs.items.tests.item_fixture")
local Lcrng = require("libs.mons.src.gen4.Lcrng")
local MonsSave = require("libs.mons.src.MonsSave")
local Party = require("libs.mons.src.Party")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}
local TICK = 1 / 30

local STATE_MODULE = "game.hgss.src.battle.BattleScreenState"
local MODEL_MODULE = "game.hgss.src.battle.BattlePresentationModel"
local RUNTIME_MODULE = "game.hgss.src.battle.BattleRuntime"
local SCENARIO_FACTORY_MODULE = "libs.hgss.src.battle.HgssBattleScenarioFactory"
local BattlePresentationManifestFixture = require("tests.support.BattlePresentationManifestFixture")

local function battleManifest()
  return BattlePresentationManifestFixture.manifest()
end
-- Bar patches name component-relative source tiles: recorded bar tiles
-- below subtract the staged component base beside the icon tiles.
local COMPONENT_BASE = battleManifest().hud.player.componentBase

local function fakeImageWidth(image)
  return image.width
end

local function fakeImageHeight(image)
  return image.height
end

local function fakeImageDimensions(image)
  return image.width, image.height
end

local function fakeImageSetFilter() end

local function fakeDrawable(key, width, height)
  local hudImage = key:match("^hud:") ~= nil
  return {
    handle = key,
    width = width or (hudImage and 1648 or 80),
    height = height or (hudImage and 8 or 80),
    getWidth = fakeImageWidth,
    getHeight = fakeImageHeight,
    getDimensions = fakeImageDimensions,
    setFilter = fakeImageSetFilter,
  }
end

---@param species string
---@param level integer
---@param seed integer
---@return table full mon-domain record with a single known move
local function foeRecord(species, level, seed)
  local catalog = CatalogFixture.makeCatalog()
  local factory = CatalogFixture.makeFactory(seed, catalog)
  local record = factory:createNormal(CatalogFixture.normalRequest({ species = species, level = level }))
  record.moves = { { move = "TACKLE", pp = 35, ppUps = 0 } }
  return record
end

---@return table live party owner holding the described pair
local function makeParty(leadSpec, reserveSpec, leadPp, extraLeadMove)
  local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
  local catalog = CatalogFixture.makeCatalog()
  local owner = HgssMonService.new({
    catalog = catalog,
    bucket = MonsSave.capture(Party.new():capture(), Lcrng.new(0x22222222):capture()),
    profile = CatalogFixture.profile(),
    game = "heartgold",
    language = "english",
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    items = CatalogFixture.ITEMS,
    balls = CatalogFixture.BALLS,
    mapSection = 7,
    date = CatalogFixture.metDate(),
  })
  for index, member in ipairs({ leadSpec, reserveSpec }) do
    local factory = CatalogFixture.makeFactory(member.seed, catalog)
    local req = { species = member.species, level = member.level }
    if member.ability ~= nil then
      req.ability = member.ability
    end
    local record = factory:createNormal(CatalogFixture.normalRequest(req))
    local pp = 35
    if index == 1 and leadPp ~= nil then
      pp = leadPp
    end
    record.moves = { { move = "TACKLE", pp = pp, ppUps = 0 } }
    if index == 1 and extraLeadMove ~= nil then
      record.moves[2] = extraLeadMove
    end
    Assert.isTrue(owner:addMon(record), "the command path needs its live party member")
  end
  return owner
end

---@return table dual-surface display facts
local function dualMeasurement()
  return {
    width = 256,
    height = 384,
    topology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, touch = false, role = "world" },
      { id = "lower", rect = { x = 0, y = 192, width = 256, height = 192 }, touch = true, role = "auxiliary" },
      "battle-screen-command-test:dual"
    ),
    pixelRatio = 1,
    signature = "battle-screen-command-test:dual",
  }
end

---@return table caller-owned single-surface display facts for compact layout checks
local function compactMeasurement()
  return {
    width = 256,
    height = 192,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = 256, height = 192 },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "battle-screen-command-test:compact",
  }
end

---@return table recording text boundary with drawn content
local function recordingText()
  local text = { draws = {} }
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = tostring(content), x = x, y = y }
  end
  function text.drawTextForRole(role, content, x, y, colors)
    text.draws[#text.draws + 1] = { role = role, content = tostring(content), x = x, y = y, colors = colors }
  end
  function text.measureForRole(_, content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  return text
end

---@param opts table? rig options: leadPp, overrides, seed
---@return table live rig with the runtime, screen, and submit log
local function openRig(opts)
  opts = opts or {}
  local BattleRuntime = require(RUNTIME_MODULE)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local holder = {}
  local rig = { submits = {}, measurement = opts.measurement or dualMeasurement(), text = recordingText() }
  rig.windows = { calls = {} }
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  rig.audio = { plays = {} }
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
    return true
  end
  rig.assets = { hold = {}, images = {}, prepared = {}, released = {} }
  function rig.assets.prepare(demand)
    rig.assets.prepared[#rig.assets.prepared + 1] = demand
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images[key] == nil then
      local isTypeIcon = key:match("^battle:move%-type%-icon:") ~= nil
      local width = isTypeIcon and 64 or key == "shadow" and 64 or 80
      local height = isTypeIcon and 16 or key == "shadow" and 64 or 80
      rig.assets.images[key] = {
        handle = key,
        width = width,
        height = height,
        getWidth = fakeImageWidth,
        getHeight = fakeImageHeight,
        getDimensions = function()
          return width, height
        end,
        setFilter = fakeImageSetFilter,
      }
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" },
    opts.leadPp,
    opts.extraLeadMove
  )
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local launchId = opts.launchId or "launch-screen-command"
  local launch = {
    id = launchId,
    kind = "wild",
    payload = {
      attemptId = launchId .. "-attempt",
      species = "EEVEE",
      form = 0,
      level = 4,
      personality = 1,
      ability = "RUN_AWAY",
    },
  }
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launchId .. "-attempt", mon = foeRecord("EEVEE", 20, 0x5EED0002) },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = opts.manifest or battleManifest(),
    model = Model,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return holder.battle:submit(reply)
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
    overrides = opts.overrides,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  holder.battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = rig.port,
    seed = opts.seed or 0x12345678,
  })
  rig.battle = holder.battle
  rig.party = party
  function rig.pump(ticks, dt)
    for _ = 1, ticks or 1 do
      rig.battle:update()
      rig.screen:updateFixed(dt or TICK)
    end
  end
  return rig
end

---@param rig table live screen rig under test driving
---@param mode string awaited controller mode under test driving
---@return table the screen status once the mode is reached
local function driveToMode(rig, mode)
  for _ = 1, 600 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the battle screen failed while driving to " .. mode .. ": " .. tostring(status.error), 0)
    end
    if status.mode == mode and (mode ~= "command" and mode ~= "moves" or rig.screen:view().menuInputEnabled) then
      return status
    end
  end
  error("the battle screen never reached " .. mode, 0)
end

function T.screen_exposes_health_task_progress_and_completion_to_controller_owners()
  local rig = openRig()
  local key = "health:activation-1:hit-1"
  rig.screen:startHealthGaugeTask(key, { maximum = 64, current = 48, delta = 32, amount = 1, sideType = 0 })
  Assert.isTrue(rig.screen:gaugeTaskActive(key), "the controller can observe its native gauge task as active")
  Assert.equal(rig.screen:gaugeTaskValue(key), 48, "the first frame begins at the event-time checkpoint")
  local initial = rig.screen:gaugeTaskPatchTiles(key, 0)
  Assert.equal(#initial, 6, "the task exports all source health tile writes")
  Assert.deepEqual(
    { initial[1].tile, initial[1].sourceTile },
    { 97, 10 },
    "initial health patches use the source side span"
  )
  Assert.deepEqual(
    rig.screen:_snapshot().gaugePatchTiles[0].health[1],
    initial[1],
    "the screen snapshot sends task character writes to the production renderer"
  )
  rig.screen:updateFixed(TICK)

  Assert.equal(rig.screen:gaugeTaskValue(key), 47, "one accepted source tick advances the health task once")
  for _ = 1, 31 do
    rig.screen:updateFixed(TICK)
  end
  Assert.equal(rig.screen:gaugeTaskValue(key), 16, "the task reaches its supplied hit checkpoint")
  Assert.isFalse(rig.screen:gaugeTaskActive(key), "the task exposes its source completion gate")
  rig.screen:completeGaugeTask(key)
  Assert.isNil(
    rig.screen:_snapshot().gaugePatchTiles[0],
    "completion removes the task override after its endpoint was observed"
  )
  rig.screen:dispose()
end

function T.transient_effect_picture_flows_through_screen_snapshot_and_picture_pass()
  local rig = openRig()
  local effect = rig.screen:allocateEffect("animation-picture")
  local applied = rig.screen:setEffectPicture(effect.id, {
    assetKey = "effect:staged-overlay",
    selector = "PIKACHU/0/male/plain/front",
    centerX = 128,
    centerY = 92,
    zCenter = -120,
    width = 32,
    height = 24,
    alpha = 0.75,
  })
  Assert.isTrue(applied, "the staged selector is available before the effect becomes visible")

  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local function draw()
    local graphics = FakeGraphics.new({})
    BattleRenderer.drawPane({
      graphics = graphics,
      text = rig.text,
      windows = rig.windows,
      assets = rig.screen._assets,
      doublesHud = rig.screen._manifest.hud.doubles,
      frameKey = rig.screen._assets:frameKey(),
      sceneImageKey = rig.screen._assets:sceneImage(),
    }, rig.screen:_snapshot(), "detail")
    return graphics
  end

  local first = draw()
  Assert.equal(
    rig.screen:_snapshot().effectInstances[1].sourceKey,
    "animation-picture",
    "the immutable screen view retains the source route key"
  )
  local effectDraw = nil
  for _, entry in ipairs(first.draws) do
    if entry.meshTexture ~= nil and entry.meshTexture.handle == "effect:staged-overlay" then
      effectDraw = entry
    end
  end
  Assert.isTrue(effectDraw ~= nil, "an allocated staged effect reaches the native picture pass")
  Assert.equal(effectDraw.color[4], 0.75, "the transient effect alpha reaches the picture mesh")

  rig.screen:updateFixed(TICK)
  Assert.equal(rig.screen:_snapshot().effectInstances[1].age, 1, "the screen snapshot exposes source-ticked effect age")
  local demandedSelector = false
  for _, selector in ipairs(rig.assets.prepared[#rig.assets.prepared].pages) do
    demandedSelector = demandedSelector or selector == "PIKACHU/0/male/plain/front"
  end
  Assert.isTrue(demandedSelector, "the changed effect selector enters the launch resource demand before rendering")
  local movedApplied = rig.screen:setEffectPicture(effect.id, {
    assetKey = "effect:staged-overlay",
    selector = "PIKACHU/0/male/plain/front",
    centerX = 136,
    centerY = 92,
    zCenter = -120,
    width = 32,
    height = 24,
    alpha = 0.75,
  })
  Assert.isTrue(movedApplied, "source-ticked effect updates retain their ready staged resource")
  local moved = draw()
  local movedDraw = nil
  for _, entry in ipairs(moved.draws) do
    if entry.meshTexture ~= nil and entry.meshTexture.handle == "effect:staged-overlay" then
      movedDraw = entry
    end
  end
  Assert.equal(
    movedDraw.meshVertices[1][1] - effectDraw.meshVertices[1][1],
    8,
    "source updates move the staged effect mesh"
  )
  local resolveDrawable = rig.assets.drawable
  rig.assets.drawable = function(key)
    if key == "effect:pending-replacement" then
      return nil
    end
    return resolveDrawable(key)
  end
  local replaced = rig.screen:setEffectPicture(effect.id, {
    assetKey = "effect:pending-replacement",
    selector = "PIKACHU/0/male/plain/front",
    centerX = 180,
    centerY = 92,
    zCenter = -100,
    width = 32,
    height = 24,
    alpha = 1,
  })
  Assert.isFalse(replaced, "an unavailable replacement remains pending")
  Assert.equal(
    rig.screen:_snapshot().effectInstances[1].picture.assetKey,
    "effect:staged-overlay",
    "a pending replacement preserves the last-good staged picture"
  )
  rig.assets.drawable = resolveDrawable
  rig.screen:releaseEffect(effect.id)
  local released = draw()
  for _, entry in ipairs(released.draws) do
    Assert.isFalse(
      entry.meshTexture ~= nil and entry.meshTexture.handle == "effect:staged-overlay",
      "released effects leave the production picture pass"
    )
  end
  rig.screen:dispose()
  rig.screen:dispose()
  Assert.equal(
    rig.assets.released["effect:staged-overlay"],
    1,
    "screen teardown releases the staged effect drawable exactly once"
  )
end

function T.form_picture_state_expands_the_owned_portrait_asset_demand()
  local rig = openRig()
  local battler = {
    combatant = 1,
    activation = "transform-1",
    side = 1,
    position = 0,
    visible = true,
    portraitSelector = "LEAD/0/male/plain/back",
  }
  rig.screen:startPictureEntry(battler, 8)
  rig.screen:applyPictureState(battler, {
    portraitSelector = "EEVEE/f0/male/plain/front",
    substitute = true,
  })
  rig.screen:updateFixed(TICK)
  local pages = rig.assets.prepared[#rig.assets.prepared].pages
  local found = false
  for _, selector in ipairs(pages) do
    if selector == "EEVEE/f0/male/plain/front" then
      found = true
    end
  end
  Assert.isTrue(found, "form visual changes add their exact portrait selector to the owned demand")
  Assert.deepEqual(
    rig.screen:restorePictureState(battler),
    { portraitSelector = "LEAD/0/male/plain/back" },
    "form restoration returns the original activation selector"
  )
  rig.screen:dispose()
end

---@param rig table live screen rig under test driving
---@param request table open request under projection
---@return table the enabled kernel struggle option for the acting lead
local function struggleOptionFor(rig, request)
  local options, optionsErr = rig.battle:decisionOptions(request.requestId)
  Assert.notNil(options, "the runtime projects options for the open request: " .. tostring(optionsErr))
  local addressed = assert(request.actors[1], "the open request addresses its lead")
  local entries = assert(options.actors, "the projection addresses its actors")
  for _, entry in ipairs(entries) do
    if
      type(entry) == "table"
      and entry.combatant == addressed.combatant
      and entry.activation == addressed.activation
    then
      local struggle = nil
      for _, choice in ipairs(entry.choices) do
        if type(choice) == "table" and choice.role == "move" and type(choice.id) == "string" then
          if choice.id == "move:struggle" then
            struggle = choice
          else
            Assert.isFalse(choice.enabled == true, "no ordinary move stays usable beside the struggle")
          end
        end
      end
      Assert.notNil(struggle, "the kernel projects its struggle option")
      Assert.isTrue(struggle.enabled == true, "the projected struggle stays enabled")
      return struggle --[[@as table<string, unknown>]]
    end
  end
  error("the open request has no projected actor entry", 0)
end

---@param struggle table enabled kernel struggle option under projection
---@return table the exact native fragment a direct struggle seals without a picker
local function expectedDirectFragment(struggle)
  local enabled = {}
  if type(struggle.targets) == "table" then
    for _, variant in ipairs(struggle.targets) do
      if type(variant) == "table" and variant.enabled == true then
        enabled[#enabled + 1] = variant
      end
    end
  end
  Assert.isTrue(#enabled <= 1, "the spent single holds at most one struggle recipient")
  if #enabled == 1 then
    return enabled[1].choice
  end
  return struggle.choice
end

-- Command walking stays on one request: Fight opens moves, cancel
-- returns, reentrant confirms seal exactly one reply, and stale edges in
-- waiting seal nothing.
function T.command_walking_with_reentrant_edges_seals_once()
  local rig = openRig({})
  driveToMode(rig, "command")
  assert(rig.screen:status().request ~= nil, "the prompt mirrors its request")
  rig.screen:input({ { type = "confirm" } })
  driveToMode(rig, "moves")
  Assert.equal(rig.screen:status().mode, "moves", "confirming Fight opens move selection")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "confirming the known slot submits")
  Assert.equal(#rig.submits, 1, "exactly one reply reaches the runtime")
  rig.screen:input({ { type = "confirm" } })
  rig.screen:input({ { type = "confirm" } })
  rig.pump(2)
  Assert.equal(#rig.submits, 1, "reentrant confirms while waiting seal nothing more")
  Assert.isNil(rig.screen:status().request, "the answered request is no longer mirrored as open")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- A second confirmation delivered in the same input batch cannot cross
-- the native transition into the move menu and seal a choice that was
-- not visible when the batch began.
function T.command_transition_does_not_consume_a_second_confirmation()
  local rig = openRig({ launchId = "launch-screen-transition-gate" })
  driveToMode(rig, "command")
  rig.screen:input({ { type = "confirm" }, { type = "confirm" } })
  rig.pump(1)
  Assert.notNil(rig.screen:status().request, "the same input batch keeps the decision open")
  Assert.equal(#rig.submits, 0, "the same input batch cannot seal an unseen move")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- The native button feedback task moves its text two pixels upward while
-- pressed. This checks the production screen's recorded text boundary
-- against the source task's visible pressed frame.
function T.pressed_command_label_uses_the_native_feedback_offset()
  local rig = openRig({ launchId = "launch-native-pressed-command-label" })
  driveToMode(rig, "command")
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:feedback", x = 128, y = 275 } })
  rig.screen:updateFixed(TICK)
  rig.text.draws = {}
  rig.screen:draw({ graphics = FakeGraphics.new({}) })
  local fight = nil
  for _, entry in ipairs(rig.text.draws) do
    if entry.content == "FIGHT" then
      fight = entry
      break
    end
  end
  Assert.notNil(fight, "the pressed command keeps its native label visible")
  Assert.equal(
    fight.y,
    81,
    "the source pressed task moves the command label up two pixels from y=83 (observed " .. tostring(fight.y) .. ")"
  )
  rig.screen:dispose()
  rig.battle:dispose()
end

function T.picture_form_apply_and_restore_reaches_the_production_compositor()
  local manifest = battleManifest()
  local rig = openRig({ manifest = manifest, launchId = "launch-picture-form-composition" })
  driveToMode(rig, "command")
  local initial = rig.screen:_snapshot()
  local changedBattler = nil
  local unrelatedBattler = nil
  for _, battler in ipairs(initial.battlers) do
    if battler.visible ~= false and battler.active ~= false and type(battler.activation) == "number" then
      if battler.side == 1 then
        changedBattler = battler
      elseif battler.side == 2 then
        unrelatedBattler = battler
      end
    end
  end
  Assert.isTrue(
    changedBattler ~= nil and unrelatedBattler ~= nil,
    "the composed scene has independent live activations"
  )

  local function installPortrait(selector, sourceHeight, firstFrame, xOffset)
    local species, form, gender, variant, facing = selector:match("^([A-Z0-9_]+)/f(%d+)/([a-z]+)/([a-z]+)/([a-z]+)$")
    if species == nil then
      species, form, gender, variant = selector:match("^([A-Z0-9_]+)/f(%d+)/([a-z]+)/([a-z]+)$")
      facing = "front"
    end
    Assert.isTrue(
      species ~= nil and (facing == "front" or facing == "back"),
      "test portrait uses a canonical source selector: " .. tostring(selector)
    )
    local key = "pokemon/" .. species .. "/form-" .. form .. "/" .. gender .. "/" .. facing
    local steps = {}
    steps[1] = { next = firstFrame, duration = 4, xOffset = xOffset, auxiliary = 0 }
    steps[2] = { next = -1, duration = 0, xOffset = 0, auxiliary = 0 }
    for index = 3, 10 do
      steps[index] = { next = 0, duration = 0, xOffset = 0, auxiliary = 0 }
    end
    manifest.pictures.selectors[key] = {
      species = species,
      form = tonumber(form),
      gender = gender,
      facing = facing,
      attributes = key,
    }
    manifest.pictures.attributes[key] = { height = sourceHeight, animation = { steps = steps } }
    local function frame(handle)
      return {
        handle = handle,
        getDimensions = function()
          return 80, 80
        end,
      }
    end
    rig.assets.images["mon:" .. selector] = {
      frames = { frame(selector .. "/frame-0"), frame(selector .. "/frame-1") },
    }
  end

  installPortrait(changedBattler.portraitSelector, 2, 0, 0)
  installPortrait(unrelatedBattler.portraitSelector, 4, 0, 0)
  local changedSelector = "EEVEE/f1/male/plain/front"
  installPortrait(changedSelector, 9, 1, 5)
  local before = rig.screen:_snapshot()
  initial = before
  changedBattler = nil
  unrelatedBattler = nil
  for _, battler in ipairs(before.battlers) do
    if battler.visible ~= false and battler.active ~= false and type(battler.activation) == "number" then
      if battler.side == 1 then
        changedBattler = battler
      elseif battler.side == 2 then
        unrelatedBattler = battler
      end
    end
  end
  local originalSelector = assert(changedBattler).portraitSelector
  local unrelatedSelector = assert(unrelatedBattler).portraitSelector
  changedBattler.shadowSize = 1
  changedBattler.shadowVisible = true
  changedBattler.shadowAffine = false
  changedBattler.shadowHeight = 0
  local originalPictureFrame = changedBattler.pictureFrame

  local BattleRenderer = require("game.hgss.src.battle.BattleRenderer")
  local function drawSnapshot(snapshot, graphics)
    BattleRenderer.drawPane({
      graphics = graphics,
      text = rig.text,
      windows = rig.windows,
      assets = rig.screen._assets,
      doublesHud = manifest.hud.doubles,
      frameKey = rig.screen._assets:frameKey(),
      sceneImageKey = rig.screen._assets:sceneImage(),
    }, snapshot, "detail")
  end
  local function pictureDraw(graphics, handle)
    for _, draw in ipairs(graphics.draws) do
      if draw.meshTexture ~= nil and draw.meshTexture.handle == handle then
        return draw
      end
    end
    error("the production picture pass draws " .. handle, 0)
  end

  local beforeGraphics = FakeGraphics.new({})
  drawSnapshot(initial, beforeGraphics)
  local originalFrame = rig.assets.images["mon:" .. originalSelector].frames[originalPictureFrame + 1]
  local unrelatedFrame = rig.assets.images["mon:" .. unrelatedSelector].frames[1]
  local beforeChangedDraw = pictureDraw(beforeGraphics, originalFrame.handle)
  local beforeUnrelatedDraw = pictureDraw(beforeGraphics, unrelatedFrame.handle)

  rig.screen:applyPictureState(changedBattler, {
    portraitSelector = changedSelector,
    rotationX = 0x1000,
    rotationY = 0x2000,
    rotationZ = 0x3000,
    affineMode = true,
    affineWidth = 0x180,
    affineHeight = 0x80,
    pictureTint = { r = 0.5, g = 1, b = 0.25, a = 0.75 },
    polygonAlpha = 15,
    shadowSize = 2,
    shadowAffine = true,
    shadowHeight = 3,
    shadowTint = { r = 1, g = 0.5, b = 0.25, a = 1 },
  })
  local transformed = rig.screen:_snapshot()
  local transformedBattler = nil
  for _, battler in ipairs(transformed.battlers) do
    if battler.combatant == changedBattler.combatant and battler.activation == changedBattler.activation then
      transformedBattler = battler
    end
  end
  Assert.isTrue(transformedBattler ~= nil, "the transformed activation remains in the screen snapshot")
  Assert.equal(
    transformedBattler.pictureFrame,
    1,
    "the form selector executes its authored frame: "
      .. tostring(transformedBattler.pictureFrame)
      .. ", height "
      .. tostring(transformedBattler.sourceHeight)
  )
  Assert.equal(transformedBattler.sourceHeight, 9, "the form selector loads its own source height")
  Assert.equal(transformedBattler.portraitSelector, changedSelector, "the scene snapshot carries the applied selector")
  local transformedGraphics = FakeGraphics.new({})
  drawSnapshot(transformed, transformedGraphics)
  local transformedFrame = rig.assets.images["mon:" .. changedSelector].frames[2]
  local transformedDraw = pictureDraw(transformedGraphics, transformedFrame.handle)
  local unchangedDraw = pictureDraw(transformedGraphics, unrelatedFrame.handle)
  local firstBefore, firstAfter = beforeChangedDraw.meshVertices[1], transformedDraw.meshVertices[1]
  Assert.isTrue(
    firstBefore[1] ~= firstAfter[1] or firstBefore[2] ~= firstAfter[2] or firstBefore[3] ~= firstAfter[3],
    "authored affine changes alter the production picture vertices"
  )
  Assert.deepEqual(
    transformedDraw.color,
    { 0.5, 1, 0.25, 15 / 31 * 0.75 },
    "picture palette tint and native polygon alpha reach the mesh"
  )
  local transformedUnrelated = nil
  for _, battler in ipairs(transformed.battlers) do
    if battler.combatant == unrelatedBattler.combatant and battler.activation == unrelatedBattler.activation then
      transformedUnrelated = battler
    end
  end
  Assert.equal(
    transformedUnrelated.portraitSelector,
    unrelatedBattler.portraitSelector,
    "the unrelated activation keeps its source selector"
  )
  Assert.equal(
    transformedUnrelated.pictureFrame,
    unrelatedBattler.pictureFrame,
    "the unrelated source frame is unchanged"
  )
  Assert.deepEqual(unchangedDraw.color, beforeUnrelatedDraw.color, "the unrelated picture palette is unchanged")
  local shadowDraw = nil
  for _, draw in ipairs(transformedGraphics.draws) do
    if draw.meshTexture ~= nil and draw.meshTexture.handle == "shadow" then
      shadowDraw = draw
    end
  end
  Assert.isTrue(shadowDraw ~= nil, "the transformed native shadow reaches the same picture pass")
  Assert.deepEqual(
    shadowDraw.color,
    { 1, 0.5, 0.25, 15 / 31 },
    "the native shadow palette and polygon alpha reach its mesh"
  )

  local restoredPictureState = rig.screen:restorePictureState(changedBattler)
  Assert.equal(restoredPictureState.shadowSize, 1, "the activation snapshot includes its native shadow size")
  local restored = rig.screen:_snapshot()
  local restoredBattler = nil
  for _, battler in ipairs(restored.battlers) do
    if battler.combatant == changedBattler.combatant and battler.activation == changedBattler.activation then
      restoredBattler = battler
    end
  end
  Assert.equal(
    restoredBattler.portraitSelector,
    originalSelector,
    "restore reinstates the activation's original selector"
  )
  Assert.equal(restoredBattler.pictureFrame, originalPictureFrame, "restore resumes its source frame")
  Assert.equal(restoredBattler.sourceHeight, 2, "restore reinstates the original selector height")
  Assert.equal(restoredBattler.shadowSize, 1, "restore reinstates the source shadow size")
  Assert.equal(restoredBattler.shadowVisible, true, "restore reinstates source shadow visibility")
  local restoredGraphics = FakeGraphics.new({})
  drawSnapshot(restored, restoredGraphics)
  local restoredFrame = rig.assets.images["mon:" .. originalSelector].frames[restoredBattler.pictureFrame + 1]
  local restoredDraw = pictureDraw(restoredGraphics, restoredFrame.handle)
  Assert.deepEqual(
    restoredDraw.meshVertices,
    beforeChangedDraw.meshVertices,
    "restored picture geometry matches the original"
  )
  Assert.equal(
    rig.screen:_snapshot().battlers[1].portraitSelector,
    restored.battlers[1].portraitSelector,
    "restoring one activation leaves the unrelated snapshot unchanged"
  )
  local restoredShadow = nil
  for _, draw in ipairs(restoredGraphics.draws) do
    if draw.meshTexture ~= nil and draw.meshTexture.handle == "shadow" then
      restoredShadow = draw
    end
  end
  Assert.isTrue(restoredShadow ~= nil, "restoring the mon retains its source shadow resource")
  local originalShadow = nil
  for _, draw in ipairs(beforeGraphics.draws) do
    if draw.meshTexture ~= nil and draw.meshTexture.handle == "shadow" then
      originalShadow = draw
    end
  end
  Assert.isTrue(originalShadow ~= nil, "the original appearance carries its source shadow")
  Assert.deepEqual(
    restoredShadow.color,
    originalShadow.color,
    "restoring the mon restores its shadow palette and alpha"
  )
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Keyboard navigation follows the native touch topology across
-- commands and the two-by-two move table into cancel and back.
function T.navigation_follows_the_native_topology()
  local rig = openRig({})
  driveToMode(rig, "command")
  Assert.equal(rig.screen:view().selection, "fight", "the prompt rests on the first command")
  rig.screen:input({ { type = "navigate", direction = "right" } })
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "fight", "the wide top command keeps horizontal edges")
  rig.screen:input({ { type = "navigate", direction = "down" } })
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "run", "down from the top reaches the bottom middle")
  rig.screen:input({ { type = "navigate", direction = "left" } })
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "bag", "left from the middle reaches the lower left")
  rig.screen:input({ { type = "navigate", direction = "up" } })
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "fight", "up returns to the top command")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  rig.screen:input({ { type = "navigate", direction = "down" } })
  rig.pump(1)
  rig.screen:input({ { type = "navigate", direction = "down" } })
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "cancel", "down through the table reaches cancel")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "command", "confirming cancel returns to command")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- A genuinely spent move set keeps its slot with the kernel reason and
-- refuses without spending the turn, while the kernel struggle entry
-- stays reachable beside the native slots.
function T.spent_slots_refuse_with_their_reason()
  local rig = openRig({ leadPp = 0, launchId = "launch-screen-spent-local" })
  driveToMode(rig, "command")
  local request = assert(rig.screen:status().request, "the prompt mirrors its request")
  local struggle = struggleOptionFor(rig, request)
  local expected = expectedDirectFragment(struggle)
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(
    rig.screen:status().mode,
    "awaiting_resolution",
    "Fight completes the spent turn through the projected struggle"
  )
  Assert.equal(#rig.submits, 1, "the completed turn submits exactly one reply")
  local sealed = assert(rig.submits[1], "the spent reply is recorded")
  Assert.deepEqual(sealed.choices[1], expected, "the sealed fragment keeps the projected struggle")
  Assert.isNil(rig.screen:status().request, "the answered request is no longer mirrored as open")
  rig.screen:dispose()
  rig.battle:dispose()
end

local openSealingScreen ---@type fun(launchId: string, specs: table[], requestId: integer): table

-- Paired pointer focus then confirmation seals the focused move once:
-- the first complete press on a new slot only moves focus, the second
-- matched press seals the exact projected fragment, and a later orphan
-- release seals nothing more.
function T.paired_second_tap_seals_the_focused_move_once()
  local rig = openSealingScreen("launch-paired-confirm-local", {
    {
      id = "move:0",
      slot = 0,
      move = "TACKLE",
      name = "Tackle",
      pp = 35,
      maxPp = 35,
      target = { kind = "position", position = 2 },
    },
    {
      id = "move:1",
      slot = 1,
      move = "GROWL",
      name = "Growl",
      pp = 40,
      maxPp = 40,
      target = { kind = "position", position = 2 },
    },
  }, 9010)
  rig.screen:input({ { type = "confirm" } })
  driveToMode(rig, "moves")
  Assert.equal(rig.screen:status().mode, "moves", "Fight opens move selection")
  Assert.equal(rig.screen:view().selection, "move:0", "move selection rests on the first slot")
  local x, y = 192, 236
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:focus", x = x, y = y } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:focus", x = x, y = y } })
  rig.pump(1)
  Assert.equal(rig.screen:view().selection, "move:1", "the first tap focuses the new slot")
  Assert.equal(#rig.submits, 0, "the first tap seals nothing")
  local request = assert(rig.screen:status().request, "the prompt mirrors its request")
  local projected = rig.expectedById["move:1"]
  Assert.notNil(projected, "the focused slot carries its projected fragment")
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:seal", x = x, y = y } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:seal", x = x, y = y } })
  rig.pump(1)
  Assert.equal(#rig.submits, 1, "the second matched tap seals once")
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "the sealed move waits for resolution")
  local sealed = assert(rig.submits[1], "the sealed reply is recorded")
  Assert.equal(sealed.requestId, request.requestId, "the reply answers the open request")
  Assert.equal(sealed.epoch, request.epoch, "the reply carries the open epoch")
  Assert.equal(sealed.controller, request.controller, "the reply carries the open controller")
  Assert.deepEqual(sealed.choices[1], projected, "the sealed fragment keeps its actor and target")
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:orphan", x = x, y = y } })
  rig.pump(1)
  Assert.equal(#rig.submits, 1, "an orphan release seals nothing more")
  rig.screen:dispose()
end

---@param launchId string owning launch identity under test driving
---@param specs table[] projected move specs with id, move, name, pp, maxPp, and target under test driving
---@param requestId integer synthetic request identity under test driving
---@return table live screen-only rig with an accepting submit boundary
function openSealingScreen(launchId, specs, requestId)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local rig = { submits = {}, measurement = dualMeasurement(), text = recordingText() }
  rig.windows = { calls = {} }
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  rig.audio = { plays = {} }
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
    return true
  end
  rig.assets = { hold = {}, images = {}, prepared = {}, released = {} }
  function rig.assets.prepare(demand)
    rig.assets.prepared[#rig.assets.prepared + 1] = demand
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images[key] == nil then
      rig.assets.images[key] = fakeDrawable(key)
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = battleManifest(),
    model = Model,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return true
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  function rig.pump(ticks, dt)
    for _ = 1, ticks or 1 do
      rig.screen:updateFixed(dt or TICK)
    end
  end
  local BattleProtocol = require("libs.battle.src.BattleProtocol")
  local offered = {}
  rig.expectedById = {}
  for _, spec in ipairs(specs) do
    local choice = {
      actor = { combatant = 1, activation = 1 },
      kind = "attack",
      payload = { moveSlot = spec.slot, target = spec.target },
    }
    BattleProtocol.validateTarget(spec.target)
    BattleProtocol.validateChoice(choice, "action")
    local offeredChoice = {
      id = spec.id,
      role = "move",
      display = { move = spec.move, name = spec.name, pp = spec.pp, maxPp = spec.maxPp },
      enabled = spec.enabled ~= false,
      choice = choice,
    } --[[@as table<string, unknown>]]
    if spec.reason ~= nil then
      offeredChoice.reason = spec.reason
    end
    offered[#offered + 1] = offeredChoice
    rig.expectedById[spec.id] = choice
  end
  local actors = {
    {
      combatant = 1,
      activation = 1,
      kind = "action",
      choices = offered,
    },
  }
  local decision = {
    requestId = requestId,
    epoch = 1,
    controller = "player",
    kind = "action",
    actors = actors,
  }
  decision.options = {
    requestId = requestId,
    epoch = 1,
    controller = "player",
    kind = "action",
    actors = actors,
  }
  local function ownRecord()
    return {
      combatant = 1,
      participant = 1,
      side = 1,
      controller = "player",
      active = true,
      hp = 52,
      maxHp = 52,
      species = "EEVEE",
      form = 0,
      name = "LEAD",
      level = 20,
      selector = "back",
      moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
    }
  end
  local function foeRecordEntry()
    return {
      combatant = 3,
      participant = 3,
      side = 2,
      controller = "wild",
      active = true,
      hp = 57,
      maxHp = 57,
      species = "EEVEE",
      form = 0,
      name = "FOE",
      level = 20,
      selector = "front",
    }
  end
  rig.expectedChoice = rig.expectedById[specs[1].id]
  rig.port.present({
    launchId = launchId,
    packetId = 4242,
    events = {},
    before = { own = { ownRecord() }, foes = { foeRecordEntry() } },
    after = { own = { ownRecord() }, foes = { foeRecordEntry() } },
    request = decision,
    result = nil,
  })
  for _ = 1, 600 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the sealing screen failed while driving to command: " .. tostring(status.error), 0)
    end
    if
      status.mode == "command"
      and rig.screen:view().menuInputEnabled
      and status.request ~= nil
      and status.request.requestId == requestId
    then
      return rig
    end
  end
  error("the sealing screen never reached its command decision", 0)
  return rig
end

-- A Fight with no usable move refuses with the kernel reason instead
-- of opening a dead move list: the decision stays open, nothing
-- seals, and repeating Fight still seals nothing.
function T.fight_with_no_usable_move_refuses_without_spending()
  local rig = openSealingScreen("launch-screen-spent-fight-local", {
    {
      id = "move:0",
      slot = 0,
      move = "TACKLE",
      name = "Tackle",
      pp = 0,
      maxPp = 35,
      enabled = false,
      reason = "no_pp",
      target = { kind = "position", position = 2 },
    },
    {
      id = "move:1",
      slot = 1,
      move = "GROWL",
      name = "Growl",
      pp = 0,
      maxPp = 40,
      enabled = false,
      reason = "no_pp",
      target = { kind = "position", position = 2 },
    },
  }, 9021)
  local request = assert(rig.screen:status().request, "the prompt mirrors its request")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "command", "Fight with no usable move stays on the command decision")
  Assert.equal(#rig.submits, 0, "the refusal spends no turn")
  Assert.equal(rig.screen:status().request.requestId, request.requestId, "the refusal keeps the same request open")
  Assert.equal(rig.screen:view().message, "no_pp", "the refusal repeats the kernel reason")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "command", "a repeated Fight still stays on the command decision")
  Assert.equal(#rig.submits, 0, "a repeated Fight still seals nothing")
  Assert.equal(rig.screen:status().request.requestId, request.requestId, "a repeated Fight keeps the same request open")
  rig.screen:dispose()
end

-- The settled command root keeps its framed select prompt: the
-- top-screen narration names the acting lead while the command menu
-- stays open over it, so the view never goes chrome-only mid-decision.
function T.command_root_keeps_the_framed_select_prompt()
  local rig = openRig({})
  driveToMode(rig, "command")
  Assert.equal(
    rig.screen:view().message,
    "What will EEVEE do?",
    "the settled command root keeps the framed select prompt"
  )
  rig.screen:dispose()
  rig.battle:dispose()
end

-- A command actor with no displayed battler still fails loudly: the
-- resolver never invents a fallback actor, so a genuinely dangling
-- entry trips the integer-slot binding instead of painting over
-- corrupt display facts.
function T.dangling_command_actor_still_trips_the_slot_assert()
  local rig = openRig({})
  driveToMode(rig, "command")
  rig.screen._request.actors[1].combatant = 999
  rig.screen._menuGateTicks = 1
  local ok, err = pcall(function()
    return rig.screen:_snapshot()
  end)
  Assert.isFalse(ok, "the dangling actor never resolves into a snapshot")
  Assert.isTrue(
    tostring(err):find("integer source battle slot", 1, true) ~= nil,
    "the failure names the slot binding: " .. tostring(err)
  )
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Complete projected intents seal unchanged: side-wide and field-wide
-- fragments never open a picker and never rewrite their target.
function T.projected_side_and_field_targets_seal_unchanged()
  local side = openSealingScreen("launch-sealed-side-local", {
    {
      id = "move:0",
      slot = 0,
      move = "TACKLE",
      name = "Tackle",
      pp = 35,
      maxPp = 35,
      target = { kind = "side", side = 2 },
    },
  }, 9001)
  side.screen:input({ { type = "confirm" } })
  driveToMode(side, "moves")
  Assert.equal(side.screen:status().mode, "moves", "Fight opens move selection for the side intent")
  side.screen:input({ { type = "confirm" } })
  side.pump(1)
  Assert.equal(#side.submits, 1, "the side intent seals without a picker")
  Assert.isTrue(side.screen:status().mode ~= "target", "the side intent never opens target selection")
  local sideSealed = assert(side.submits[1], "the side reply is recorded")
  Assert.deepEqual(sideSealed.choices[1], side.expectedChoice, "the side fragment keeps its target")
  side.screen:dispose()
  local field = openSealingScreen("launch-sealed-field-local", {
    { id = "move:0", slot = 0, move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35, target = { kind = "field" } },
  }, 9002)
  field.screen:input({ { type = "confirm" } })
  driveToMode(field, "moves")
  Assert.equal(field.screen:status().mode, "moves", "Fight opens move selection for the field intent")
  field.screen:input({ { type = "pointer_down", pointerId = "touch:field", x = 64, y = 237 } })
  field.screen:input({ { type = "pointer_up", pointerId = "touch:field", x = 64, y = 237 } })
  field.pump(1)
  Assert.equal(#field.submits, 1, "touch on the focused slot seals the field intent")
  Assert.isTrue(field.screen:status().mode ~= "target", "the field intent never opens target selection")
  local fieldSealed = assert(field.submits[1], "the field reply is recorded")
  Assert.deepEqual(fieldSealed.choices[1], field.expectedChoice, "the field fragment keeps its target")
  field.screen:dispose()
end

-- Overlong labels never escape their regions: narration and menu text
-- truncate through the borrowed measure service.
function T.long_labels_truncate_inside_their_regions()
  local rig = openRig({})
  driveToMode(rig, "command")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  local graphics = FakeGraphics.new({})
  rig.screen:draw({ graphics = graphics })
  for _, drawn in ipairs(rig.text.draws) do
    Assert.isTrue(#drawn.content <= 30, "drawn labels stay inside their regions: " .. drawn.content)
  end
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Narration consumes its acknowledgement edges: confirming during the
-- opening never submits and never exposes the prompt early.
function T.opening_narration_consumes_its_edges()
  local rig = openRig({ launchId = "launch-screen-narration-local" })
  local opened = false
  for _ = 1, 60 do
    rig.pump(1)
    local mode = rig.screen:status().mode
    if mode == "intro" or mode == "narration" then
      opened = true
      break
    end
  end
  Assert.isTrue(opened, "the opening plays its cues first")
  rig.screen:input({ { type = "confirm" } })
  rig.screen:input({ { type = "confirm" } })
  rig.pump(2)
  Assert.equal(#rig.submits, 0, "narration edges never submit")
  driveToMode(rig, "command")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Outside presses change nothing and dismiss nothing; the input key
-- stays stable across redraws and turns on semantic changes.
function T.outside_presses_change_nothing_and_keys_track_semantics()
  local rig = openRig({})
  driveToMode(rig, "command")
  local key = assert(rig.screen:status().presentation, "the prompt carries its plan").inputKey
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:9", x = 10, y = 10 } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:9", x = 10, y = 10 } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "command", "outside presses keep the decision")
  Assert.equal(#rig.submits, 0, "outside presses seal nothing")
  Assert.equal(rig.screen:status().presentation.inputKey, key, "redraws keep the input identity")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.isTrue(rig.screen:status().presentation.inputKey ~= key, "semantic changes turn the input key")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- A per-case resolver override replaces the whole paired plan and an
-- unknown override key fails the screen explicitly instead of half
-- resolving.
function T.case_overrides_replace_plans_and_bad_keys_fail()
  local defaults = BattleScreenInterface.defaults()
  local seen = {}
  local custom = {}
  for key, resolver in pairs(defaults) do
    custom[key] = function(context, view)
      seen[#seen + 1] = key
      local plan = resolver(context, view)
      plan.content.overrideTag = "local-probe"
      return plan
    end
  end
  local rig = openRig({ overrides = { cases = custom }, launchId = "launch-screen-override-local" })
  driveToMode(rig, "command")
  Assert.isTrue(#seen > 0, "the per-case override resolves")
  Assert.equal(rig.screen:status().presentation.content.overrideTag, "local-probe", "the override plan publishes")
  rig.screen:dispose()
  rig.battle:dispose()
  local sad =
    openRig({ overrides = { cases = { noSuchCase = function() end } }, launchId = "launch-screen-badkey-local" })
  sad.pump(2)
  Assert.equal(sad.screen:status().mode, "failed", "an unknown override key fails explicitly")
  sad.screen:dispose()
  sad.battle:dispose()
end

-- The selection arrow traverses its cycle finitely: drawing across many
-- ticks cycles with a fixed period and never hangs on the zero-time
-- entry.
function T.arrow_cycles_with_a_fixed_period()
  local rig = openRig({})
  driveToMode(rig, "command")
  local shapes = {}
  for _ = 1, 40 do
    rig.pump(1)
    local graphics = FakeGraphics.new({})
    rig.screen:draw({ graphics = graphics })
    local parts = {}
    for _, entry in ipairs(graphics.draws) do
      parts[#parts + 1] = tostring(entry.x) .. "," .. tostring(entry.y)
    end
    shapes[#shapes + 1] = table.concat(parts, "|")
  end
  Assert.equal(shapes[1], shapes[35], "the arrow cycle repeats with its authored period")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Screen drawing restores borrowed graphics state exactly.
function T.screen_draw_restores_borrowed_state()
  local rig = openRig({})
  driveToMode(rig, "command")
  local graphics = FakeGraphics.new({})
  local function state()
    local r, g, b, a = graphics.getColor()
    return {
      color = { r, g, b, a },
      canvas = graphics.getCanvas(),
      shader = graphics.getShader(),
      blend = graphics.getBlendMode(),
      scissor = graphics.getScissor(),
      depth = graphics:pushDepth(),
    }
  end
  local before = state()
  rig.screen:draw({ graphics = graphics })
  Assert.deepEqual(state(), before, "the screen draw restores borrowed graphics state exactly")
  Assert.isTrue(#graphics.draws > 0, "the screen draw reaches the recording boundary")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Direct native-pane harness: synthetic snapshots through the real battle
-- renderer with minting asset stubs and a recording text boundary, so
-- composite anchors, cell quads, and dynamic wording pin exactly.
local RENDERER_MODULE = "game.hgss.src.battle.BattleRenderer"

---@param overrides table? snapshot fields replacing the healthy defaults
---@return table internal semantic snapshot under drawing
local function nativeView(overrides)
  local view = {
    mode = "command",
    selection = "fight",
    armed = nil,
    requestId = 7,
    message = "",
    messageId = 1,
    battlers = {
      {
        combatant = 1,
        side = 1,
        hp = 30,
        maxHp = 30,
        visible = true,
        name = "LEAD",
        level = 9,
        exp = 120,
        condition = "burn",
        shakeDx = 0,
      },
      {
        combatant = 2,
        side = 2,
        hp = 12,
        maxHp = 12,
        visible = true,
        name = "FOE",
        level = 3,
        exp = nil,
        condition = nil,
        shakeDx = 0,
      },
    },
    commands = {
      { id = "fight", enabled = true },
      { id = "bag", enabled = true },
      { id = "pokemon", enabled = true },
      { id = "run", enabled = true },
    },
    moves = {
      { slot = 0, name = "TACKLE", pp = 35, maxPp = 35, moveType = "NORMAL", enabled = true },
      { slot = 1, name = "GROWL", pp = 40, maxPp = 40, moveType = "NORMAL", enabled = true },
    },
    partyRoster = {
      { slot = 0, hp = 30, maxHp = 30 },
      { slot = 1, hp = 0, maxHp = 28 },
    },
    foeCount = 2,
    arrowFrame = 1,
    hudPatchSpans = battleManifest().hud.patchSpans,
    childIntent = nil,
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      view[key] = value
    end
  end
  return view
end

---@param paneId string drawn pane identity
---@param view table internal semantic snapshot under drawing
---@param layout string? interaction layout under drawing
---@param held string[]? artwork keys reporting unavailable
---@return table graphics, text, and window records behind one draw
local function drawNativePane(paneId, view, layout, held, doublesHud)
  local BattleRenderer = require(RENDERER_MODULE)
  local graphics = FakeGraphics.new({})
  local text = recordingText()
  local windows = { calls = {} }
  function windows.drawWindow(box, frameKey, background)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  local missing = {}
  local pictureRecords = {}
  for _, key in ipairs(held or {}) do
    missing[key] = true
  end
  local drawView = {}
  for key, value in pairs(view) do
    drawView[key] = value
  end
  drawView.effectInstances = drawView.effectInstances or {}
  local manifest = battleManifest()
  drawView.slotGeometry = manifest.battlefield.slots
  drawView.hudSections = { player = manifest.hud.player, enemy = manifest.hud.enemy }
  drawView.gaugeFamilies = {
    player = manifest.hud.partyGauges[2],
    enemy = manifest.hud.partyGauges[1],
  }
  drawView.menuLayers = view.menuLayers
    or {
      command = manifest.menus.command.screens,
      moves = manifest.menus.moves.screens,
      target = manifest.menus.target.screens,
      twoOption = manifest.menus.twoOption.screens,
    }
  drawView.hudSections.player.componentBase = 128
  drawView.hudSections.enemy.componentBase = 128
  drawView.hudPatchSpans = manifest.hud.patchSpans
  local resources = {
    graphics = graphics,
    text = text,
    windows = windows,
    assets = {
      drawable = function(_, key)
        if missing[key] then
          return nil
        end
        local width = key == "gauges:player" and 512 or key == "gauges:enemy" and 128 or nil
        return fakeDrawable(key, width, 8)
      end,
      renderPictures = function(_, _, pictures)
        pictureRecords = pictures
        return { handle = "picture-pass" }
      end,
    },
    frameKey = "default",
    sceneImageKey = "scene:test",
    doublesHud = doublesHud or manifest.hud.doubles,
  }
  local content = {}
  for _, section in pairs(resources.doublesHud) do
    section.componentBase = 128
  end
  if paneId == "interaction" then
    content = { layout = layout or "command" }
  end
  BattleRenderer.drawPane(resources, drawView, paneId, content)
  return { graphics = graphics, text = text, windows = windows, pictures = pictureRecords }
end

---@param pictures table[] rendered source picture records
---@param handle string staged drawable identity
---@return table[] matching source picture records
local function pictureRecordsOf(pictures, handle)
  local found = {}
  for _, record in ipairs(pictures) do
    if type(record.image) == "table" and record.image.handle == handle then
      found[#found + 1] = record
    end
  end
  return found
end

---@param graphics table recording graphics boundary under inspection
---@param handle string artwork identity under inspection
---@return table[] draws carrying that artwork identity, in draw order
local function drawsOf(graphics, handle)
  local found = {}
  for _, entry in ipairs(graphics.draws) do
    if type(entry.image) == "table" and entry.image.handle == handle then
      found[#found + 1] = entry
    end
  end
  return found
end

-- Bar tiles patch the mapped source tile origin of their own strip:
-- 8-pixel quads across the 48-pixel bar row. Cell objects sample
-- cell-bank tiles at their own compiled offsets, so the draw position
-- tells bar tiles apart where the sampled index cannot.
local BAR_ORIGINS = {
  ["hud:enemy-left"] = { y = 20, ranges = { { 56, 104 } } },
  ["hud:enemy-right"] = { y = 49, ranges = { { 50, 98 } } },
  ["hud:player-left"] = { y = 103, ranges = { { 192, 240 } } },
  ["hud:player-right"] = { y = 132, ranges = { { 198, 246 } } },
  ["hud:enemy"] = { y = 40, ranges = { { 50, 98 } } },
  ["hud:player"] = { y = 116, ranges = { { 200, 248 } } },
}

---@param handle string staged strip identity under inspection
---@param entry table recorded draw under inspection
---@return boolean true while the draw patches its strip bar row
local function isBarTile(handle, entry)
  local quad = entry.quad --[[@as table?]]
  if type(quad) ~= "table" or quad.w ~= 8 or quad.h ~= 8 then
    return false
  end
  local origin = BAR_ORIGINS[handle]
  if origin == nil then
    return false
  end
  if entry.y ~= origin.y then
    return false
  end
  for _, range in ipairs(origin.ranges) do
    if entry.x >= range[1] and entry.x < range[2] then
      return true
    end
  end
  return false
end

---@param text table recording text boundary under inspection
---@param content string drawn wording under inspection
---@param x number drawn horizontal origin under inspection
---@param y number drawn vertical origin under inspection
---@return boolean true when the exact wording draws at the anchor
local function textAt(text, content, x, y)
  for _, entry in ipairs(text.draws) do
    if entry.content == content and entry.x == x and entry.y == y then
      return true
    end
  end
  return false
end

function T.native_health_box_bounds_long_names_and_neighbor_fields()
  local view = nativeView()
  view.battlers[1].name = "LONGNICKNAMEBEYONDNATIVEWIDTH"
  local drawn = drawNativePane("detail", view, nil, {})
  local name = nil
  local level = nil
  for _, entry in ipairs(drawn.text.draws) do
    if entry.y == 92 and entry.x == 144 then
      name = entry.content
    elseif entry.content == "Lv9" then
      level = entry
    end
  end
  Assert.isTrue(type(name) == "string", "the health box draws its long nickname")
  Assert.isTrue(8 * #name <= 88, "the measured nickname fits the authored 88-pixel name span")
  Assert.isFalse(name == "LONGNICKNAMEBEYONDNATIVEWIDTH", "the native name span clips excess nickname glyphs")
  Assert.isTrue(level ~= nil and level.x == 144 and level.y == 104, "level keeps its adjacent native field anchor")

  local manifest = battleManifest()
  local section = manifest.hud.player
  local cell = section.cells[section.animation.frames[1].cell + 1]
  local statusPatches =
    require("libs.hgss.src.presentation.BattleScene").hudIconPatchTiles(manifest.hud.patchSpans, 0, "burn", nil, nil)
  local statusLeft = math.huge
  local statusRight = -math.huge
  local statusY = nil
  for _, patch in ipairs(statusPatches) do
    for _, object in ipairs(cell.objs) do
      local columns = object.width / 8
      local offset = patch.tile - object.tile
      if offset >= 0 and offset < columns * object.height / 8 then
        local x = 144 + object.x + offset % columns * 8
        local y = 92 + object.y + math.floor(offset / columns) * 8
        statusLeft = math.min(statusLeft, x)
        statusRight = math.max(statusRight, x + 8)
        statusY = y
        break
      end
    end
  end
  Assert.isTrue(statusLeft < statusRight and type(statusY) == "number", "status art resolves to native cell tiles")
  Assert.isTrue(statusRight <= 144, "the native status span ends before the nickname span begins")
  Assert.isTrue(statusY == 92, "status art stays on its source row beside the nickname")
  Assert.isTrue(level.x == 144 and level.y == 104, "the level occupies its separate source row")
end

-- The HUD composites draw at their anchors with the compiled local
-- offsets: two 64x64 objects each, banded into 8-pixel quads over the
-- staged strip row. The enemy anchor stays unclamped offscreen.
function T.native_hud_composites_draw_at_anchors_with_compiled_offsets()
  local drawn = drawNativePane("detail", nativeView({ arrowFrame = 0 }), nil, {})
  -- Cell bands share their strip with the bar tiles, so the composite
  -- geometry reads the banded object draws while the tiles patch after.
  local function bands(graphics, handle)
    local found = {}
    for _, entry in ipairs(drawsOf(graphics, handle)) do
      if #found < 16 then
        found[#found + 1] = entry
      end
    end
    return found
  end
  local player = bands(drawn.graphics, "hud:player")
  Assert.equal(#player, 16, "the player composite draws eight rows for each source object")
  Assert.equal(player[1].x, 128, "the player composite starts at anchor.x-64")
  Assert.equal(player[1].y, 84, "the player composite starts at anchor.y-32")
  Assert.equal(player[1].quad.x, 0, "the player composite opens its first tile")
  Assert.equal(player[1].quad.w, 64, "the player object preserves its 64-pixel source row")
  Assert.equal(player[1].quad.imgW, 1648, "the player quads reference the staged strip width")
  Assert.equal(player[8].y, 140, "the player first object bands cover 64 pixels")
  Assert.equal(player[9].x, 192, "the player second object starts at anchor.x")
  Assert.equal(player[9].y, 84, "the player second object shares the row")
  Assert.equal(player[9].quad.x, 512, "the player second object opens tile 64")
  local enemy = bands(drawn.graphics, "hud:enemy")
  Assert.equal(#enemy, 16, "the enemy composite draws eight rows for each source object")
  Assert.equal(enemy[1].x, -6, "the enemy composite starts offscreen unclamped")
  Assert.equal(enemy[1].y, 8, "the enemy composite starts at anchor.y-28")
  Assert.equal(enemy[1].quad.x, 0, "the enemy composite opens its first tile")
  Assert.equal(enemy[9].x, 58, "the enemy second object starts at anchor.x")
  Assert.equal(enemy[9].y, 8, "the enemy second object shares the row")
  Assert.equal(enemy[9].quad.x, 512, "the enemy second object opens tile 64")
end

-- Dynamic HUD content sits in the composite geometry: names, levels, and
-- conditions on both sides, numeric health on the player side only, and
-- tile bars per side. Foe numbers and experience totals never print.
function T.native_hud_dynamic_content_uses_composite_geometry()
  local drawn = drawNativePane("detail", nativeView({ arrowFrame = 0 }), nil, {})
  Assert.isTrue(textAt(drawn.text, "LEAD", 144, 92), "the player name keeps its anchor")
  Assert.isTrue(textAt(drawn.text, "Lv9", 144, 104), "the player level keeps its anchor")
  Assert.isFalse(textAt(drawn.text, "30/30", 144, 116), "the player renders native HP digit tiles")
  for _, entry in ipairs(drawn.text.draws) do
    Assert.isFalse(entry.content == "120", "the player never prints its experience total")
  end
  Assert.isFalse(textAt(drawn.text, "burn", 176, 104), "the player renders native status icon tiles")
  Assert.isTrue(textAt(drawn.text, "FOE", 8, 16), "the foe name keeps its anchor")
  Assert.isTrue(textAt(drawn.text, "Lv3", 8, 28), "the foe level keeps its anchor")
  for _, entry in ipairs(drawn.text.draws) do
    Assert.isFalse(entry.content == "12/12", "the foe prints no numeric health")
  end
  Assert.equal(#drawn.graphics.rectangles, 0, "health bars never use painted rectangles")
  local tiles = {}
  for _, entry in ipairs(drawn.graphics.draws) do
    if
      type(entry.image) == "table"
      and type(entry.image.handle) == "string"
      and (entry.image.handle == "hud:player" or entry.image.handle == "hud:enemy")
      and type(entry.quad) == "table"
      and entry.quad.w == 8
      and entry.quad.h == 8
      and isBarTile(entry.image.handle --[[@as string]], entry)
    then
      tiles[#tiles + 1] = entry.image.handle .. ":" .. tostring(math.floor(entry.quad.x / 8) - COMPONENT_BASE)
    end
  end
  table.sort(tiles)
  -- Full health on both sides fills every tile from the green base.
  Assert.deepEqual(tiles, {
    "hud:enemy:10",
    "hud:enemy:10",
    "hud:enemy:10",
    "hud:enemy:10",
    "hud:enemy:10",
    "hud:enemy:10",
    "hud:player:10",
    "hud:player:10",
    "hud:player:10",
    "hud:player:10",
    "hud:player:10",
    "hud:player:10",
  }, "both full sides fill their tile bars from the green base")
end

function T.native_health_box_icons_follow_side_and_encounter_visibility()
  local function sourceTiles(handle, battleKind, playerGender)
    local view = nativeView({ battleKind = battleKind })
    view.battlers[1].condition = "poison"
    view.battlers[1].gender = playerGender or "female"
    view.battlers[1].caught = true
    view.battlers[2].condition = "burn"
    view.battlers[2].gender = "male"
    view.battlers[2].caught = true
    local drawn = drawNativePane("detail", view, nil, {})
    local tiles = {}
    for _, entry in ipairs(drawsOf(drawn.graphics, handle)) do
      if type(entry.quad) == "table" and entry.quad.w == 8 and entry.quad.h == 8 then
        local tile = math.floor(entry.quad.x / 8)
        if tile >= 128 then
          tiles[tile] = true
        end
      end
    end
    return tiles, drawn
  end

  local playerTiles, wildDraw = sourceTiles("hud:player", "wild")
  for _, tile in ipairs({ 172, 173, 174, 188, 189, 200, 201 }) do
    Assert.isTrue(playerTiles[tile], "player native status/gender patch includes component tile " .. tostring(tile))
  end
  Assert.isFalse(playerTiles[187], "the caught marker is absent from the player health box")

  local genderlessTiles = sourceTiles("hud:player", "wild", "genderless")
  for _, tile in ipairs({ 192, 193, 204, 205 }) do
    Assert.isTrue(genderlessTiles[tile], "genderless player uses its native marker component tile " .. tostring(tile))
  end
  Assert.isFalse(genderlessTiles[200], "genderless player does not use the female marker")
  Assert.isFalse(genderlessTiles[202], "genderless player does not use the male marker")

  local wildFoeTiles = sourceTiles("hud:enemy", "wild")
  for _, tile in ipairs({ 169, 170, 171, 190, 191, 202, 203, 187 }) do
    Assert.isTrue(
      wildFoeTiles[tile],
      "wild foe native status/gender/caught patch includes component tile " .. tostring(tile)
    )
  end
  Assert.isFalse(
    textAt(wildDraw.text, "30/30", 144, 116),
    "player HP remains native clipped text inside its source span"
  )

  local trainerFoeTiles = sourceTiles("hud:enemy", "trainer")
  Assert.isFalse(trainerFoeTiles[187], "trainer battles suppress the native caught marker")
  for _, tile in ipairs({ 169, 170, 171, 190, 191, 202, 203 }) do
    Assert.isTrue(trainerFoeTiles[tile], "trainer enemy keeps visible status/gender tile " .. tostring(tile))
  end
end

-- Missing strips draw nothing and never substitute: held keys skip their
-- composites while the wording and bars still draw.
function T.native_missing_art_draws_nothing()
  local drawn = drawNativePane("detail", nativeView({ arrowFrame = 3 }), nil, { "hud:player", "hud:enemy", "arrow" })
  Assert.equal(#drawsOf(drawn.graphics, "hud:player"), 0, "the held player strip draws nothing")
  Assert.equal(#drawsOf(drawn.graphics, "hud:enemy"), 0, "the held enemy strip draws nothing")
  Assert.equal(#drawsOf(drawn.graphics, "arrow"), 0, "the held arrow draws nothing")
  Assert.isTrue(textAt(drawn.text, "LEAD", 144, 92), "held art keeps the player wording")
  Assert.isTrue(textAt(drawn.text, "FOE", 8, 16), "held art keeps the foe wording")
end

-- The arrow draws its authored cells: the zero-time opening cell draws
-- nothing, every other cell bands its objects over the arrow strip, and
-- unknown frames draw nothing.
function T.native_arrow_draws_authored_cells_with_bounded_zero_advance()
  local zero = drawNativePane("detail", nativeView({ arrowFrame = 0 }), nil, {})
  Assert.equal(#drawsOf(zero.graphics, "arrow"), 0, "the zero-time cell draws nothing")
  local first = drawNativePane("detail", nativeView({ arrowFrame = 1 }), nil, {})
  local one = drawsOf(first.graphics, "arrow")
  Assert.equal(#one, 2, "the first cell bands its one object")
  Assert.equal(one[1].x, 112, "the arrow sits left of the player anchor")
  Assert.equal(one[1].y, 106, "the arrow shares the player anchor row")
  Assert.equal(one[1].quad.x, 0, "the first cell opens tile 0")
  Assert.equal(one[1].quad.imgW, 208, "the arrow quads reference the staged strip width")
  Assert.equal(one[2].quad.x, 16, "the first cell bands row-major")
  local third = drawNativePane("detail", nativeView({ arrowFrame = 3 }), nil, {})
  local three = drawsOf(third.graphics, "arrow")
  Assert.equal(#three, 4, "the third cell bands its two objects")
  Assert.equal(three[1].x, 104, "the wider cells reach further left")
  Assert.equal(three[1].quad.x, 32, "the third cell opens tile 4")
  Assert.equal(three[3].x, 120, "the second object abuts the first")
  Assert.equal(three[3].quad.x, 48, "the second object opens tile 6")
  Assert.equal(three[3].quad.w, 8, "the second object keeps its narrow width")
  local fifth = drawNativePane("detail", nativeView({ arrowFrame = 5 }), nil, {})
  local five = drawsOf(fifth.graphics, "arrow")
  Assert.equal(#five, 4, "the final cell bands its two objects")
  Assert.equal(five[1].quad.x, 80, "the final cell opens tile 10")
  Assert.equal(five[3].quad.x, 96, "the final narrow object opens tile 12")
  for _, frame in ipairs({ -1, 6 }) do
    local stray = drawNativePane("detail", nativeView({ arrowFrame = frame }), nil, {})
    Assert.equal(#drawsOf(stray.graphics, "arrow"), 0, "frame " .. frame .. " draws no arrow")
  end
  local missing = nativeView({})
  missing.arrowFrame = nil
  local silent = drawNativePane("detail", missing, nil, {})
  Assert.equal(#drawsOf(silent.graphics, "arrow"), 0, "a missing frame draws no arrow")
end

-- The live selection clock traverses the authored cells with their
-- authored counts: every displayed cell carries art, the order cycles
-- 1 through 5 with a 34-tick period, and the zero-time entry never
-- displays or hangs the cycle.
function T.native_arrow_cycles_through_authored_cells()
  local rig = openRig({})
  driveToMode(rig, "command")
  Assert.equal(rig.screen:status().presentation.panes[1].id, "detail", "the dual display owns the detail pane")
  local cellOfQuadX = { [0] = 1, [16] = 2, [32] = 3, [56] = 4, [80] = 5 }
  local counts = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0 }
  local order = {}
  local displayed = 0
  for _ = 1, 68 do
    rig.pump(1)
    local graphics = FakeGraphics.new({})
    rig.screen:draw({ graphics = graphics })
    local bands = drawsOf(graphics, "arrow")
    if #bands > 0 then
      Assert.isTrue(#bands == 2 or #bands == 4, "every displayed arrow cell carries art")
      local cell = cellOfQuadX[bands[1].quad.x]
      Assert.notNil(cell, "every arrow band opens an authored tile")
      counts[cell] = counts[cell] + 1
      displayed = displayed + 1
      if order[#order] ~= cell then
        order[#order + 1] = cell
      end
    end
  end
  Assert.equal(displayed, 68, "the zero-time opening cell does not count as visible: " .. tostring(displayed))
  Assert.deepEqual(counts, { [1] = 8, [2] = 8, [3] = 8, [4] = 32, [5] = 12 }, "two periods hold the authored counts")
  for index = 2, #order do
    Assert.equal(order[index], order[index - 1] % 5 + 1, "the cells cycle in authored order")
  end
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Party gauges draw source cells by roster visibility: the committed
-- battle roster behind the player row, the revealed foe count behind
-- the enemy row. Unrevealed foes keep the absent cell.
function T.native_gauges_use_source_cells_by_roster_visibility()
  local drawn = drawNativePane("interaction", nativeView({}), "command", {})
  local player = drawsOf(drawn.graphics, "gauges:player")
  Assert.equal(#player, 24, "the source 32px player objects use four tile rows per cell")
  Assert.equal(player[1].x, -4, "the source player object offset is preserved")
  Assert.equal(player[1].y, -3, "the source player object offset is preserved vertically")
  Assert.equal(player[1].quad.x, 128, "the healthy lead selects source cell two")
  Assert.equal(player[1].quad.w, 32, "the player row uses the native 32px source family")
  Assert.equal(player[1].quad.imgW, 512, "the player cell references its own staged source strip")
  Assert.equal(player[5].quad.x, 256, "the fainted reserve selects source cell three")
  Assert.equal(player[9].quad.x, 0, "the empty slots keep source cell one")
  Assert.equal(player[9].x, 34, "the third slot keeps its source pitch and cell offset")
  local enemy = drawsOf(drawn.graphics, "gauges:enemy")
  Assert.equal(#enemy, 12, "the enemy row bands six cells")
  Assert.equal(enemy[1].x, 238, "the source opponent object offset is preserved")
  Assert.equal(enemy[1].y, 1, "the opponent row keeps its source anchor")
  Assert.equal(enemy[1].quad.x, 32, "the revealed foe selects its source cell")
  Assert.equal(enemy[1].quad.w, 16, "the opponent row uses the native 16px source family")
  Assert.equal(enemy[1].quad.imgW, 128, "the opponent cell references its own staged source strip")
  Assert.equal(enemy[3].quad.x, 32, "the second foe selects its source cell")
  Assert.equal(enemy[5].quad.x, 0, "unrevealed foes keep the absent cell")
end

function T.native_menu_draws_generated_layers_in_priority_order()
  local drawn = drawNativePane(
    "interaction",
    nativeView({
      menuLayers = {
        command = {
          { image = "screen-1", plane = 0, priority = 3 },
          { image = "screen-2", plane = 2, priority = 3 },
          { image = "screen-3", plane = 1, priority = 2 },
        },
      },
    }),
    "command",
    {}
  )
  local menuOrder = {}
  for _, entry in ipairs(drawn.graphics.draws) do
    local key = type(entry.image) == "table" and entry.image.handle or nil
    if type(key) == "string" and key:match("^menu:command:screen:") then
      menuOrder[#menuOrder + 1] = key
    end
  end
  Assert.deepEqual(
    menuOrder,
    { "menu:command:screen:2", "menu:command:screen:1", "menu:command:screen:3" },
    "generated command layers draw by source priority, with physical plane order for ties"
  )
end

function T.native_menu_selection_draws_its_generated_tilemap_patch()
  for _, state in ipairs({ "selected", "pressed" }) do
    local view = nativeView({
      selection = "fight",
      armed = state == "pressed" and { id = "fight", scope = "command" } or nil,
      menuLayers = {
        command = {
          {
            image = "screen-1",
            plane = 1,
            priority = 2,
            feedback = {
              fight = {
                selected = { x = 16, y = 32, width = 224, height = 96 },
                pressed = { x = 16, y = 32, width = 224, height = 96 },
              },
            },
          },
        },
      },
    })
    local drawn = drawNativePane("interaction", view, "command", {})
    local menuDraws = {}
    for _, entry in ipairs(drawn.graphics.draws) do
      local key = type(entry.image) == "table" and entry.image.handle or nil
      if type(key) == "string" and (key:match("^menu:command:screen:") or key:match("^menu:command:feedback:")) then
        menuDraws[#menuDraws + 1] = key
      end
    end
    Assert.deepEqual(
      menuDraws,
      { "menu:command:screen:1", "menu:command:feedback:fight:" .. state },
      "the focused command draws its generated " .. state .. " tilemap patch above the source layer"
    )
  end
end

-- The live roster behind the real battle selects the same cells: the
-- two standing party members light their slots while the rest stay
-- absent, and the single revealed foe lights only its own slot.
function T.native_gauges_follow_the_live_roster()
  local rig = openRig({})
  driveToMode(rig, "command")
  Assert.equal(rig.screen:status().presentation.panes[2].id, "interaction", "the dual display owns interaction")
  local graphics = FakeGraphics.new({})
  rig.screen:draw({ graphics = graphics })
  local player = drawsOf(graphics, "gauges:player")
  Assert.equal(#player, 24, "the live player row draws six native 32px source cells")
  Assert.equal(player[1].quad.x, 128, "the live lead selects its source cell")
  Assert.equal(player[1].quad.w, 32, "the live player row uses the native family")
  Assert.equal(player[5].quad.x, 128, "the live reserve selects its source cell")
  Assert.equal(player[9].quad.x, 0, "the live empty slots keep their absent cell")
  local enemy = drawsOf(graphics, "gauges:enemy")
  Assert.equal(#enemy, 12, "the live enemy row bands six cells")
  Assert.equal(enemy[1].quad.x, 32, "the live foe selects its source cell")
  Assert.equal(enemy[3].quad.x, 0, "unrevealed live foes keep the absent cell")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Gauge source geometry belongs to a detached screen snapshot: a renderer
-- consumer cannot mutate the generated manifest used by later snapshots.
function T.gauge_families_are_detached_per_snapshot()
  local rig = openRig({})
  local first = rig.screen:_snapshot()
  Assert.equal(first.gaugeFamilies.player.cells[2].objs[1].width, 32, "the snapshot exposes the native player family")
  Assert.equal(first.gaugeFamilies.enemy.cells[2].objs[1].width, 16, "the snapshot exposes the native opponent family")
  first.gaugeFamilies.player.cells[2].objs[1].width = 16
  local nextSnapshot = rig.screen:_snapshot()
  Assert.equal(
    nextSnapshot.gaugeFamilies.player.cells[2].objs[1].width,
    32,
    "mutating a delivered snapshot cannot change the staged source geometry"
  )
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Move facts sit at their compiled anchors: names keep the two-by-two
-- anchors, types sit left on the lower row, and PP splits into current
-- and max fields. The merged single string never draws.
function T.native_move_facts_use_compiled_type_and_split_pp_anchors()
  local rig = openRig({})
  driveToMode(rig, "command")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "Fight opens move selection")
  local moves = assert(rig.screen:view().moves, "the move facts stay listed")
  local first = nil
  for _, move in ipairs(moves) do
    if move.slot == 0 then
      first = move
    end
  end
  first = assert(first, "the first slot stays listed")
  local graphics = FakeGraphics.new({})
  rig.screen:draw({ graphics = graphics })
  local text = rig.text
  Assert.isTrue(textAt(text, first.name, 64, 45), "the first move name keeps its anchor: " .. tostring(first.name))
  local firstNameDraw = nil
  for _, entry in ipairs(text.draws) do
    if entry.content == first.name and entry.x == 64 and entry.y == 45 then
      firstNameDraw = entry
    end
  end
  Assert.equal(firstNameDraw.role, "menu", "move facts use the generated menu font role")
  Assert.deepEqual(
    firstNameDraw.colors,
    { foreground = 7, shadow = 8, background = 9 },
    "move names use the source text color slots"
  )
  Assert.isFalse(textAt(text, first.moveType, 32, 61), "the source type sprite is not replaced by a text label")
  local typeIcon = nil
  for _, entry in ipairs(graphics.draws) do
    local handle = type(entry.image) == "table" and entry.image.handle or nil
    if handle == "battle:move-type-icon:" .. tostring(first.moveType):lower() then
      typeIcon = entry
    end
  end
  Assert.notNil(typeIcon, "the source type sprite is drawn for the occupied move slot")
  Assert.equal(typeIcon.x, 0, "the 64px type sprite centers on its source X coordinate")
  Assert.equal(typeIcon.y, 53, "the 16px type sprite centers on its source Y coordinate")
  local typeAnchors = {
    { x = 32, y = 61 },
    { x = 160, y = 60 },
    { x = 32, y = 124 },
    { x = 160, y = 123 },
  }
  for _, move in ipairs(moves) do
    if type(move.moveType) == "string" then
      local anchor = typeAnchors[move.slot + 1]
      local key = "battle:move-type-icon:" .. move.moveType:lower()
      local matchingDraw = nil
      for _, entry in ipairs(graphics.draws) do
        local handle = type(entry.image) == "table" and entry.image.handle or nil
        if handle == key then
          local expectedX = anchor.x - math.floor(entry.image:getWidth() / 2)
          local expectedY = anchor.y - math.floor(entry.image:getHeight() / 2)
          if entry.x == expectedX and entry.y == expectedY then
            matchingDraw = entry
            break
          end
        end
      end
      Assert.notNil(matchingDraw, "every typed move slot draws its source icon at slot " .. tostring(move.slot))
    end
  end
  Assert.isTrue(textAt(text, tostring(first.pp), 59, 61), "the PP current keeps its field: " .. tostring(first.pp))
  local ppDraw = nil
  for _, entry in ipairs(text.draws) do
    if entry.content == tostring(first.pp) and entry.x == 59 and entry.y == 61 then
      ppDraw = entry
    end
  end
  Assert.deepEqual(
    ppDraw.colors,
    { foreground = 1, shadow = 2, background = 0 },
    "full PP uses the source normal PP color slots"
  )
  Assert.isTrue(
    textAt(text, "/" .. tostring(first.maxPp), 76, 61),
    "the PP max keeps its field: " .. tostring(first.maxPp)
  )
  for _, entry in ipairs(text.draws) do
    Assert.isNil(
      tostring(entry.content):match("^PP %d+/%d+$"),
      "the merged PP string never draws: " .. tostring(entry.content)
    )
  end
  rig.screen:dispose()
  rig.battle:dispose()
end

function T.native_narration_uses_its_source_font_role()
  local drawn = drawNativePane("detail", nativeView({ message = "SOURCE MESSAGE" }), nil, {})
  local narration = nil
  for _, entry in ipairs(drawn.text.draws) do
    if entry.content == "SOURCE MESSAGE" then
      narration = entry
      break
    end
  end
  Assert.equal(narration.role, "narration", "battle narration uses the generated narration font role")
end

-- Zero PP stays visible at its own native fields, remains disabled, and
-- does not become an activatable move.
function T.native_zero_pp_move_keeps_its_disabled_facts()
  local rig = openRig({
    leadPp = 0,
    extraLeadMove = { move = "GROWL", pp = 40, ppUps = 0 },
    launchId = "launch-zero-pp-facts",
  })
  driveToMode(rig, "command")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "Fight opens the move list with zero PP")
  local move = nil
  for _, candidate in ipairs(assert(rig.screen:view().moves, "the move facts stay listed")) do
    if candidate.slot == 0 then
      move = candidate
      break
    end
  end
  move = assert(move, "the zero-PP slot stays listed")
  Assert.equal(move.pp, 0, "the exhausted slot exposes zero current PP")
  Assert.isFalse(move.enabled, "the exhausted slot is disabled")
  local text = rig.text
  rig.screen:draw({ graphics = FakeGraphics.new({}) })
  Assert.isTrue(textAt(text, "0", 59, 61), "the zero current PP remains in its native field")
  Assert.isTrue(textAt(text, "/35", 76, 61), "the exhausted move keeps its maximum PP field")
  local zeroPp = nil
  for _, entry in ipairs(text.draws) do
    if entry.content == "0" and entry.x == 59 and entry.y == 61 then
      zeroPp = entry
      break
    end
  end
  Assert.deepEqual(
    zeroPp.colors,
    { foreground = 7, shadow = 8, background = 0 },
    "the exhausted move uses the native disabled PP palette"
  )
  rig.screen:input({ { type = "navigate", direction = "left" } })
  Assert.equal(rig.screen:view().selection, "move:0", "the test focuses the disabled zero-PP slot")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(#rig.submits, 0, "confirm cannot seal the exhausted move")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- The arrow shows only while a decision is open: leaving the selection
-- hides it while the composites and gauges keep drawing.
function T.native_arrow_hides_outside_selection_modes()
  local rig = openRig({})
  driveToMode(rig, "command")
  while rig.screen:view().arrowFrame == 0 do
    rig.pump(1)
  end
  local shown = FakeGraphics.new({})
  rig.screen:draw({ graphics = shown })
  Assert.equal(
    rig.screen:status().mode,
    "command",
    "drawing retains command mode: " .. tostring(rig.screen:status().error)
  )
  Assert.notNil(rig.assets.images.arrow, "the detail renderer resolves the staged arrow")
  Assert.isTrue(#drawsOf(shown, "arrow") > 0, "the command root shows the arrow")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "moves", "Fight opens move selection")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "awaiting_resolution", "confirming the known slot submits")
  local settled = FakeGraphics.new({})
  rig.screen:draw({ graphics = settled })
  Assert.equal(#drawsOf(settled, "arrow"), 0, "the submitted decision hides the arrow")
  Assert.isTrue(#drawsOf(settled, "hud:player") > 0, "the submitted decision keeps its composite")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- A rejecting cue sink fails the screen with context instead of escaping
-- as a host error: the send-out cry never reaches an interactive
-- decision, the failure names the launch and the cue role, nothing
-- commits, and later ticks replay nothing.
function T.rejecting_cue_sink_fails_the_screen_with_context()
  local rig = openRig({ launchId = "launch-cue-failure" })
  local dispatches = 0
  rig.audio.play = function(_)
    dispatches = dispatches + 1
    error("injected cue fault", 0)
  end
  local failed = nil
  for _ = 1, 600 do
    local settled, settleErr = pcall(function()
      rig.pump(1)
    end)
    Assert.isTrue(settled, "cue audio never escapes as a host error: " .. tostring(settleErr))
    local status = rig.screen:status()
    if status.mode == "failed" then
      failed = status
      break
    end
  end
  Assert.notNil(failed, "the rejecting sink fails the screen")
  local context = tostring(failed.error)
  Assert.isTrue(context:find("launch-cue-failure", 1, true) ~= nil, "the failure names its launch: " .. context)
  Assert.isTrue(context:find("cry:EEVEE", 1, true) ~= nil, "the failure names its cue role: " .. context)
  Assert.isTrue(dispatches >= 1, "the faulty cue was dispatched before failing")
  Assert.equal(#rig.submits, 0, "no decision commits behind a failed cue")
  for _ = 1, 30 do
    local settled, settleErr = pcall(function()
      rig.pump(1)
    end)
    Assert.isTrue(settled, "later ticks stay controlled: " .. tostring(settleErr))
  end
  Assert.equal(dispatches, 1, "a failed screen replays no cue")
  Assert.isTrue(rig.screen:status().mode ~= "command", "the faulty cue never reaches an interactive decision")
  rig.screen:dispose()
  rig.battle:dispose()
end

-- Terminal narration holds for an explicit acknowledgment: hundreds of
-- ticks without input keep the readable outcome and refuse leave and
-- readiness, while one real confirm after the reveal releases exactly
-- once through the normal return.
---@param launchId string owning launch identity under test driving
---@return table live rig with a weak foe for a quick terminal route
local function openWeakTerminalRig(launchId)
  local BattleRuntime = require(RUNTIME_MODULE)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local holder = {}
  local rig = { submits = {}, measurement = dualMeasurement(), text = recordingText() }
  rig.windows = { calls = {} }
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  rig.audio = { plays = {} }
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
    return true
  end
  rig.assets = { hold = {}, images = {}, prepared = {}, released = {} }
  function rig.assets.prepare(demand)
    rig.assets.prepared[#rig.assets.prepared + 1] = demand
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images[key] == nil then
      rig.assets.images[key] = fakeDrawable(key)
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local party = makeParty(
    { species = "EEVEE", level = 20, seed = 0x33333333 },
    { species = "EEVEE", level = 5, seed = 0x44444444, ability = "RUN_AWAY" }
  )
  local bag = HgssBagService.new({ catalog = ItemFixture.makeCatalog() })
  local launch = {
    id = launchId,
    kind = "wild",
    payload = {
      attemptId = launchId .. "-attempt",
      species = "EEVEE",
      form = 0,
      level = 4,
      personality = 1,
      ability = "RUN_AWAY",
    },
  }
  local ScenarioFactory = require(SCENARIO_FACTORY_MODULE)
  local scenario = ScenarioFactory.fromEncounter(
    { attemptId = launchId .. "-attempt", mon = foeRecord("EEVEE", 4, 0x5EED0002) },
    { party = party, bag = bag, player = { trainerId = 99, trainerName = "MINT", language = "french" } }
  )
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = battleManifest(),
    model = Model,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return holder.battle:submit(reply)
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  holder.battle = BattleRuntime.new({
    request = launch,
    scenario = scenario,
    party = party,
    bag = bag,
    presentation = rig.port,
    seed = 0x12345678,
  })
  rig.battle = holder.battle
  rig.party = party
  function rig.pump(ticks, dt)
    for _ = 1, ticks or 1 do
      rig.battle:update()
      rig.screen:updateFixed(dt or TICK)
    end
  end
  return rig
end

function T.terminal_narration_holds_until_an_explicit_acknowledgment()
  local rig = openWeakTerminalRig("launch-terminal-hold-local")
  local reached = false
  for _ = 1, 40 do
    for _ = 1, 600 do
      rig.pump(1)
      local status = rig.screen:status()
      if status.mode == "failed" then
        error("the terminal route failed: " .. tostring(status.error), 0)
      end
      if status.mode == "outcome" then
        reached = true
        break
      end
      if status.mode == "command" and status.request ~= nil then
        break
      end
      if rig.battle:status().phase == "complete" or rig.battle:status().phase == "failed" then
        break
      end
    end
    if rig.screen:status().mode == "outcome" then
      reached = true
      break
    end
    if rig.battle:status().phase == "complete" or rig.battle:status().phase == "failed" then
      break
    end
    if rig.screen:status().mode == "command" then
      rig.screen:input({ { type = "confirm" } })
      rig.pump(1)
      if rig.screen:status().mode == "moves" then
        rig.screen:input({ { type = "confirm" } })
        rig.pump(1)
      end
    elseif rig.screen:status().mode == "child" then
      error("the weak-foe terminal route never opens a child", 0)
    end
  end
  Assert.isTrue(reached, "the winning route presents its terminal narration")
  local shown = assert(rig.screen:view().message, "the terminal page stays readable")
  Assert.isTrue(shown ~= "", "the terminal page stays readable without input")
  for _ = 1, 600 do
    rig.pump(1)
  end
  Assert.equal(rig.screen:status().mode, "outcome", "hundreds of ticks without input keep the outcome")
  local held = assert(rig.screen:view().message, "the held outcome stays readable")
  Assert.isTrue(held ~= "", "the held outcome stays readable without input")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "leave refuses before the final acknowledgment")
  Assert.isFalse(rig.port.ready(), "readiness waits for the final acknowledgment")
  Assert.isTrue(rig.battle:status().phase ~= "complete", "the runtime does not return before acknowledgment")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  for _ = 1, 120 do
    rig.pump(1)
  end
  Assert.isTrue(rig.port.leave({ kind = "wild" }), "one explicit acknowledgment releases the terminal page")
  Assert.isTrue(rig.port.ready(), "the acknowledged outcome settles")
  for _ = 1, 120 do
    rig.pump(1)
  end
  Assert.equal(rig.battle:status().phase, "complete", "the acknowledged battle returns through its normal phase")
  local sealed = #rig.submits
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(#rig.submits, sealed, "a repeated edge after the terminal ack seals nothing more")
  rig.screen:dispose()
  rig.battle:dispose()
end

---@param launchId string owning launch identity under test driving
---@return table live screen-only rig holding a two-page terminal narration
local function openLongOutcomeRig(launchId)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local rig = { submits = {}, measurement = dualMeasurement(), text = recordingText() }
  rig.windows = { calls = {} }
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  rig.audio = { plays = {} }
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
    return true
  end
  rig.assets = { hold = {}, images = {}, prepared = {}, released = {} }
  function rig.assets.prepare(demand)
    rig.assets.prepared[#rig.assets.prepared + 1] = demand
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images[key] == nil then
      rig.assets.images[key] = fakeDrawable(key)
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = battleManifest(),
    model = Model,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return true
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  })
  rig.screen = screen
  rig.port = screen:presentationPort()
  function rig.pump(ticks, dt)
    for _ = 1, ticks or 1 do
      rig.screen:updateFixed(dt or TICK)
    end
  end
  local foeName = string.rep("FOE ", 20)
  local function ownRecord()
    return {
      combatant = 1,
      participant = 1,
      side = 1,
      controller = "player",
      active = true,
      hp = 52,
      maxHp = 52,
      species = "EEVEE",
      form = 0,
      name = "LEAD",
      level = 20,
      selector = "back",
      moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
    }
  end
  local function foeEntry()
    return {
      combatant = 3,
      participant = 3,
      side = 2,
      controller = "wild",
      active = true,
      hp = 57,
      maxHp = 57,
      species = "EEVEE",
      form = 0,
      name = foeName,
      level = 20,
      selector = "front",
    }
  end
  rig.port.present({
    launchId = launchId,
    packetId = 1,
    events = {},
    before = { own = { ownRecord() }, foes = { foeEntry() } },
    after = { own = { ownRecord() }, foes = { foeEntry() } },
    request = nil,
    result = { word = "win" },
  })
  return rig
end

-- A two-page terminal narration consumes one edge per stage: an early
-- edge only finishes the running reveal, the next edge turns the page,
-- and only the final revealed page acknowledges without spilling into
-- another decision.
function T.multipage_terminal_acknowledgment_consumes_each_edge_once()
  local rig = openLongOutcomeRig("launch-outcome-pages-local")
  local reached = false
  for _ = 1, 1200 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the paged outcome failed: " .. tostring(status.error), 0)
    end
    if status.mode == "outcome" then
      reached = true
      break
    end
  end
  Assert.isTrue(reached, "the long terminal narration reaches its outcome")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "outcome", "an early edge keeps the outcome")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "an early accelerate never releases")
  Assert.isFalse(rig.port.ready(), "an early accelerate never settles")
  Assert.equal(#rig.submits, 0, "an early accelerate seals nothing")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "outcome", "a page turn keeps the outcome")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "a page turn never releases")
  Assert.isFalse(rig.port.ready(), "a page turn never settles")
  Assert.equal(#rig.submits, 0, "a page turn seals nothing")
  for _ = 1, 300 do
    rig.pump(1)
  end
  Assert.equal(rig.screen:status().mode, "outcome", "the final page holds before its acknowledgment")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "the final page holds before its acknowledgment")
  Assert.isFalse(rig.port.ready(), "the final page stays unsettled before its acknowledgment")
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  for _ = 1, 120 do
    rig.pump(1)
  end
  Assert.isTrue(rig.port.leave({ kind = "wild" }), "the final acknowledgment releases the outcome")
  Assert.isTrue(rig.port.ready(), "the final acknowledgment settles")
  local sealed = #rig.submits
  rig.screen:input({ { type = "confirm" } })
  rig.pump(1)
  Assert.equal(#rig.submits, sealed, "a repeated edge after the final ack seals nothing more")
  Assert.equal(rig.screen:status().mode, "outcome", "a repeated edge never leaves the outcome")
  rig.screen:dispose()
end

-- Matched dialogue taps advance the terminal page through the real input
-- boundary, while a foreign pointer release cannot acknowledge it.
function T.matched_dialogue_taps_acknowledge_the_terminal_page()
  local rig = openLongOutcomeRig("launch-outcome-tap-local")
  local reached = false
  for _ = 1, 1200 do
    rig.pump(1)
    local status = rig.screen:status()
    if status.mode == "failed" then
      error("the tapped outcome failed: " .. tostring(status.error), 0)
    end
    if status.mode == "outcome" then
      reached = true
      break
    end
  end
  Assert.isTrue(reached, "the long terminal narration reaches its outcome")
  local function tap(id, downX, downY, upX, upY)
    rig.screen:input({ { type = "pointer_down", pointerId = id, x = downX, y = downY } })
    rig.screen:input({ { type = "pointer_up", pointerId = id, x = upX, y = upY } })
    rig.pump(1)
  end
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:tap-orphan", x = 128, y = 288 } })
  rig.pump(1)
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "a release with no press never releases")
  Assert.isFalse(rig.port.ready(), "a release with no press never settles")
  tap("touch:tap-early", 128, 288, 128, 288)
  Assert.equal(rig.screen:status().mode, "outcome", "an early tap keeps the outcome")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "an early tap only accelerates")
  Assert.isFalse(rig.port.ready(), "an early tap never settles")
  tap("touch:tap-turn", 128, 288, 128, 288)
  Assert.equal(rig.screen:status().mode, "outcome", "a page-turn tap keeps the outcome")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "a page-turn tap never releases")
  for _ = 1, 300 do
    rig.pump(1)
  end
  Assert.equal(rig.screen:status().mode, "outcome", "the final page holds before its pointer input")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "the final page holds before its pointer input")
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:A", x = 128, y = 288 } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:B", x = 128, y = 288 } })
  rig.pump(1)
  Assert.equal(rig.screen:status().mode, "outcome", "a foreign pointer cannot acknowledge the final page")
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "a foreign pointer never releases the outcome")
  Assert.isFalse(rig.port.ready(), "a foreign pointer never settles the battle")
  -- ApplicationPresentation retains A's capture after dropping B's up.
  -- Release A outside the pane to cancel that capture before fresh taps.
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:A", x = 300, y = 300 } })
  rig.screen:input({ { type = "pointer_down", pointerId = "touch:tap-drag", x = 128, y = 288 } })
  rig.screen:input({ { type = "pointer_up", pointerId = "touch:tap-drag", x = 300, y = 300 } })
  rig.pump(1)
  Assert.isFalse(rig.port.leave({ kind = "wild" }), "a release dragged off the pane never acknowledges")
  tap("touch:tap-final", 128, 288, 128, 288)
  for _ = 1, 120 do
    rig.pump(1)
  end
  Assert.isTrue(rig.port.leave({ kind = "wild" }), "the final matched tap acknowledges the outcome")
  Assert.isTrue(rig.port.ready(), "the tapped acknowledgment settles")
  Assert.equal(#rig.submits, 0, "dialogue taps seal no decision")
  rig.screen:dispose()
end

---@param launchId string owning launch identity under test driving
---@param speed string? launch narration pace under test driving, nil for the established default
---@return table screen-only rig paced by its launch option
local function openPacedScreen(launchId, speed)
  local BattleScreenState = require(STATE_MODULE)
  local Model = require(MODEL_MODULE)
  local rig = { submits = {}, measurement = dualMeasurement(), text = recordingText() }
  rig.windows = { calls = {} }
  function rig.windows.drawWindow(box, frameKey, background)
    rig.windows.calls[#rig.windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  rig.audio = { plays = {} }
  function rig.audio.play(name)
    rig.audio.plays[#rig.audio.plays + 1] = name
    return true
  end
  rig.assets = { hold = {}, images = {}, prepared = {}, released = {} }
  function rig.assets.prepare(demand)
    rig.assets.prepared[#rig.assets.prepared + 1] = demand
    return true
  end
  function rig.assets.drawable(key)
    if rig.assets.images[key] == nil then
      rig.assets.images[key] = fakeDrawable(key)
    end
    return rig.assets.images[key]
  end
  function rig.assets.release(key)
    rig.assets.released[key] = (rig.assets.released[key] or 0) + 1
  end
  local options = {
    launchId = launchId,
    manifest = battleManifest(),
    model = Model,
    submit = function(reply)
      rig.submits[#rig.submits + 1] = reply
      return true
    end,
    measureDisplay = function()
      return rig.measurement
    end,
    assets = rig.assets,
    text = rig.text,
    windows = rig.windows,
    audio = rig.audio,
  }
  if speed ~= nil then
    options.textSpeed = speed
  end
  local screen = BattleScreenState.new(options)
  rig.screen = screen
  rig.port = screen:presentationPort()
  function rig.pump(ticks, dt)
    for _ = 1, ticks or 1 do
      rig.screen:updateFixed(dt or TICK)
    end
  end
  local function ownRecord()
    return {
      combatant = 1,
      participant = 1,
      side = 1,
      controller = "player",
      active = true,
      hp = 52,
      maxHp = 52,
      species = "EEVEE",
      form = 0,
      name = "LEAD",
      level = 20,
      selector = "back",
      moves = { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } },
    }
  end
  local function foeRecordEntry()
    return {
      combatant = 3,
      participant = 3,
      side = 2,
      controller = "wild",
      active = true,
      hp = 57,
      maxHp = 57,
      species = "EEVEE",
      form = 0,
      name = "FOE",
      level = 20,
      selector = "front",
    }
  end
  rig.port.present({
    launchId = launchId,
    packetId = 4242,
    events = {},
    before = { own = { ownRecord() }, foes = { foeRecordEntry() } },
    after = { own = { ownRecord() }, foes = { foeRecordEntry() } },
    request = nil,
    result = nil,
  })
  return rig
end

-- Each launch keeps its own narration pace: an unhurried and a hurried
-- screen reveal different prefixes after the same ticks, acceleration
-- still takes two deliberate edges, batched ticks match single ticks,
-- an unknown pace fails, and omitting the pace keeps the middle
-- cadence.
function T.launches_keep_their_own_narration_pace_and_edges()
  local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
  local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
  local function glyphCount(shown)
    local total = 0
    for _ in Utf8Glyphs.iter(shown) do
      total = total + 1
    end
    return total
  end
  local slow = openPacedScreen("launch-paced-slow-local", "slow")
  local quickest = openPacedScreen("launch-paced-quickest-local", "fastest")
  slow.pump(2)
  quickest.pump(2)
  Assert.equal(glyphCount(slow.screen:view().message), 1, "the unhurried launch shows one glyph after two ticks")
  Assert.equal(glyphCount(quickest.screen:view().message), 4, "the hurried launch shows four glyphs after two ticks")
  local badOk, _ = pcall(openPacedScreen, "launch-paced-bad-local", "warp")
  Assert.isFalse(badOk, "an unknown launch pace fails instead of guessing")
  local plain = openPacedScreen("launch-paced-plain-local", nil)
  plain.pump(5)
  Assert.equal(glyphCount(plain.screen:view().message), 2, "omitting the launch pace keeps the middle cadence")
  local narration = BattleTimeline.new({ sound = function(_) end, textSpeed = "slow" })
  narration:announce("ABCDEFGHIJKLMNOPQRST", true)
  narration:update(TICK, function(_)
    return true
  end)
  local consumed, finished = narration:ack()
  Assert.isTrue(consumed, "an edge during the reveal is consumed by the page")
  Assert.isFalse(finished, "finishing the reveal never acknowledges the final page on the same edge")
  Assert.equal(glyphCount(narration:message()), 20, "the edge completes the running page")
  narration:update(TICK, function(_)
    return true
  end)
  Assert.equal(glyphCount(narration:message()), 20, "later ticks never collapse an accelerated page")
  local consumedAgain, finishedFinally = narration:ack()
  Assert.isTrue(consumedAgain, "the final page consumes its own edge")
  Assert.isTrue(finishedFinally, "a second deliberate edge acknowledges the revealed final page")
  local single = BattleTimeline.new({ sound = function(_) end, textSpeed = "slow" })
  single:announce("ABCDEFGHIJKLMNOPQRST", false)
  -- Equal accepted source time either way: one whole update carries four source ticks.
  single:update(4 / 30, function(_)
    return true
  end)
  local batched = BattleTimeline.new({ sound = function(_) end, textSpeed = "slow" })
  batched:announce("ABCDEFGHIJKLMNOPQRST", false)
  for _ = 1, 4 do
    batched:update(TICK, function(_)
      return true
    end)
  end
  Assert.equal(single:message(), batched:message(), "batched ticks reveal the same glyphs as single ticks")
  slow.screen:dispose()
  quickest.screen:dispose()
  plain.screen:dispose()
end

-- An all-power-spent lead finishes its turn through Fight alone: the
-- projected struggle seals directly on both layouts through key and
-- pointer edges, the round advances, and no fifth cell is ever
-- addressed along the way.
function T.exhausted_lead_finishes_through_fight_without_a_fifth_cell()
  local layouts = {
    { name = "dual", makeMeasurement = dualMeasurement, fight = { x = 128, y = 276 } },
    { name = "compact", makeMeasurement = compactMeasurement, fight = { x = 152, y = 154 } },
  }
  for _, layout in ipairs(layouts) do
    local keyRig = openRig({
      leadPp = 0,
      launchId = "launch-exhausted-key-" .. layout.name,
      measurement = layout.makeMeasurement(),
    })
    driveToMode(keyRig, "command")
    local request = assert(keyRig.screen:status().request, "the prompt mirrors its request (" .. layout.name .. ")")
    local expected = expectedDirectFragment(struggleOptionFor(keyRig, request))
    keyRig.screen:input({ { type = "confirm" } })
    keyRig.pump(1)
    Assert.equal(
      keyRig.screen:status().mode,
      "awaiting_resolution",
      "confirming Fight seals the struggle without opening moves (" .. layout.name .. ")"
    )
    Assert.equal(#keyRig.submits, 1, "the struggle seals exactly one reply (" .. layout.name .. ")")
    local sealed = assert(keyRig.submits[1], "the struggle reply is recorded (" .. layout.name .. ")")
    Assert.deepEqual(
      sealed.choices[1],
      expected,
      "the sealed fragment keeps the projected struggle (" .. layout.name .. ")"
    )
    Assert.isNil(
      keyRig.screen:status().request,
      "the answered request is no longer mirrored as open (" .. layout.name .. ")"
    )
    keyRig.screen:dispose()
    keyRig.battle:dispose()
    local touchRig = openRig({
      leadPp = 0,
      launchId = "launch-exhausted-touch-" .. layout.name,
      measurement = layout.makeMeasurement(),
    })
    driveToMode(touchRig, "command")
    local touchRequest =
      assert(touchRig.screen:status().request, "the touch prompt mirrors its request (" .. layout.name .. ")")
    local touchExpected = expectedDirectFragment(struggleOptionFor(touchRig, touchRequest))
    touchRig.screen:input({
      { type = "pointer_down", pointerId = "touch:fight", x = layout.fight.x, y = layout.fight.y },
    })
    touchRig.screen:input({
      { type = "pointer_up", pointerId = "touch:fight", x = layout.fight.x, y = layout.fight.y },
    })
    touchRig.pump(1)
    Assert.equal(
      touchRig.screen:status().mode,
      "awaiting_resolution",
      "tapping Fight seals the struggle without opening moves (" .. layout.name .. ")"
    )
    Assert.equal(#touchRig.submits, 1, "the tapped struggle seals exactly one reply (" .. layout.name .. ")")
    local touchSealed = assert(touchRig.submits[1], "the tapped reply is recorded (" .. layout.name .. ")")
    Assert.deepEqual(
      touchSealed.choices[1],
      touchExpected,
      "the tapped fragment keeps the projected struggle (" .. layout.name .. ")"
    )
    touchRig.screen:dispose()
    touchRig.battle:dispose()
  end
end

-- Doubled native snapshots keep opaque slot identities in view order:
-- the renderer sorts within each side, so the first sorted slot of a
-- side owns that side's left row whatever the view order. Positions
-- below are deliberately non-sequential to prove no hardcoded numbering.
---@param overrides table? snapshot overrides under test
---@return table doubled detail snapshot with two live battlers per side
local function doublesDetailView(overrides)
  local view = {
    hudPatchSpans = battleManifest().hud.patchSpans,
    mode = "command",
    arrowFrame = 1,
    actor = { combatant = 5, index = 1, total = 2 },
    battlers = {
      {
        combatant = 11,
        side = 1,
        position = 12,
        activation = 101,
        active = true,
        visible = true,
        name = "ALLY-B",
        level = 9,
        hp = 35,
        maxHp = 35,
        exp = 8100,
        portraitSelector = "SHINX/f0/male/plain/back",
        shakeDx = 0,
      },
      {
        combatant = 5,
        side = 1,
        position = 5,
        activation = 100,
        active = true,
        visible = true,
        name = "ALLY-A",
        level = 8,
        hp = 40,
        maxHp = 40,
        exp = 8000,
        portraitSelector = "STARLY/f0/male/plain/back",
        shakeDx = 0,
      },
      {
        combatant = 30,
        side = 2,
        position = 30,
        activation = 103,
        active = true,
        visible = true,
        name = "FOE-B",
        level = 5,
        hp = 30,
        maxHp = 30,
        portraitSelector = "PICHU/f0/male/plain/front",
        shakeDx = 0,
      },
      {
        combatant = 8,
        side = 2,
        position = 8,
        activation = 102,
        active = true,
        visible = true,
        name = "FOE-A",
        level = 4,
        hp = 45,
        maxHp = 45,
        portraitSelector = "BIDOOF/f0/male/plain/front",
        shakeDx = 0,
      },
    },
  }
  if overrides ~= nil then
    for key, value in pairs(overrides) do
      view[key] = value
    end
  end
  return view
end

---@param graphics table recording graphics boundary under inspection
---@param handle string artwork identity under inspection
---@return table? first draw carrying that artwork identity, nil when never drawn
local function firstDrawOf(graphics, handle)
  local found = drawsOf(graphics, handle)
  return found[1]
end

function T.doubles_missing_source_section_fails_without_singles_substitute()
  local sections = {
    playerLeft = {
      cells = {
        {
          objs = {
            {
              tile = 3,
              width = 8,
              height = 8,
              x = -5,
              y = -7,
              flipH = false,
              flipV = false,
              palette = 0,
              affine = false,
              disabled = false,
              mosaic = false,
              objMode = "normal",
              colorMode = "16-color",
            },
          },
        },
      },
      animation = { frames = { { cell = 0 } } },
    },
    playerRight = {
      cells = {
        {
          objs = {
            {
              tile = 7,
              width = 16,
              height = 8,
              x = -9,
              y = -11,
              flipH = false,
              flipV = false,
              palette = 0,
              affine = false,
              disabled = false,
              mosaic = false,
              objMode = "normal",
              colorMode = "16-color",
            },
          },
        },
      },
      animation = { frames = { { cell = 0 } } },
    },
    enemyLeft = {
      cells = {
        {
          objs = {
            {
              tile = 11,
              width = 8,
              height = 16,
              x = -13,
              y = -17,
              flipH = false,
              flipV = false,
              palette = 0,
              affine = false,
              disabled = false,
              mosaic = false,
              objMode = "normal",
              colorMode = "16-color",
            },
          },
        },
      },
      animation = { frames = { { cell = 0 } } },
    },
  }
  local ok, drawn = pcall(drawNativePane, "detail", doublesDetailView(), nil, {}, sections)
  Assert.isFalse(ok, "a missing required enemy-right source section fails the doubled draw")
  if ok then
    Assert.equal(#drawsOf(drawn.graphics, "hud:player"), 0, "a missing source section never substitutes singles art")
    Assert.equal(#drawsOf(drawn.graphics, "hud:enemy"), 0, "a missing source section never substitutes singles art")
  end
end

-- Doubled portraits settle at the sourced centers: the source table
-- gives center-style anchors for nominal 80x80 pictures, so each
-- top-left origin sits one half picture (40 pixels) left and above
-- its center. The first sorted slot of a side owns that side's left
-- row: the enemy left row sits screen-right of the enemy right row,
-- exactly as the source table lays it out.
function T.doubled_portraits_settle_at_the_sourced_centers()
  local drawn = drawNativePane("detail", doublesDetailView(), nil, {})
  local expected = {
    ["mon:STARLY/f0/male/plain/back"] = { x = 40, y = 112 },
    ["mon:SHINX/f0/male/plain/back"] = { x = 80, y = 120 },
    ["mon:BIDOOF/f0/male/plain/front"] = { x = 216, y = 50 },
    ["mon:PICHU/f0/male/plain/front"] = { x = 176, y = 42 },
  }
  for handle, origin in pairs(expected) do
    local found = pictureRecordsOf(drawn.pictures, handle)
    Assert.equal(#found, 1, "the " .. handle .. " picture draws exactly once")
    Assert.equal(found[1].centerX, origin.x, "the " .. handle .. " picture keeps its settled column")
    Assert.equal(found[1].centerY, origin.y, "the " .. handle .. " picture keeps its settled row")
  end
  local foeLeft = assert(pictureRecordsOf(drawn.pictures, "mon:BIDOOF/f0/male/plain/front")[1])
  local foeRight = assert(pictureRecordsOf(drawn.pictures, "mon:PICHU/f0/male/plain/front")[1])
  Assert.isTrue(
    foeLeft.centerX > foeRight.centerX,
    "the first sorted foe slot sits screen-right of its partner, as the source rows lay out"
  )
end

-- Doubled health boxes use their dedicated staged families at the
-- sourced anchors: each side-ordered slot draws its own strip with the
-- unmodified object templates, and every dynamic row follows its own
-- anchor through the single-battle template offsets.
function T.doubled_health_boxes_use_each_role_source_cell_and_default_fields()
  local drawn = drawNativePane("detail", doublesDetailView(), nil, {})
  -- Bar tiles share their strip with the cell bands, so the source
  -- object geometry reads the banded draws while the tiles patch after.
  local function bands(graphics, handle)
    local found = {}
    for _, entry in ipairs(drawsOf(graphics, handle)) do
      if #found < 16 then
        found[#found + 1] = entry
      end
    end
    return found
  end
  local rows = {
    ["hud:player-left"] = { slot = 3, xOffset = -64, yOffset = -32 },
    ["hud:player-right"] = { slot = 4, xOffset = -64, yOffset = -32 },
    ["hud:enemy-left"] = { slot = 5, xOffset = -64, yOffset = -28 },
    ["hud:enemy-right"] = { slot = 6, xOffset = -64, yOffset = -28 },
  }
  for artKey, expected in pairs(rows) do
    local cellBands = bands(drawn.graphics, artKey)
    Assert.equal(#cellBands, 16, "the " .. artKey .. " draws eight rows for each source object")
    local row = battleManifest().battlefield.slots[expected.slot]
    Assert.equal(cellBands[1].quad.x, 0, "the " .. artKey .. " opens its source tile zero")
    Assert.equal(cellBands[1].x, row.hudX + expected.xOffset, "the " .. artKey .. " applies its source x offset")
    Assert.equal(cellBands[1].y, row.hudY + expected.yOffset, "the " .. artKey .. " applies its source y offset")
    Assert.equal(cellBands[1].quad.w, 64, "the " .. artKey .. " preserves the source object width")
    Assert.equal(cellBands[1].quad.imgW, 1648, "the " .. artKey .. " quads reference the staged strip width")
  end
  Assert.equal(#drawsOf(drawn.graphics, "hud:player"), 0, "no doubled ally shares the single-battle strip")
  Assert.equal(#drawsOf(drawn.graphics, "hud:enemy"), 0, "no doubled foe shares the single-battle strip")
  Assert.isTrue(textAt(drawn.text, "ALLY-A", 144, 88), "the left ally names its own row")
  Assert.isTrue(textAt(drawn.text, "Lv8", 224, 91), "the left ally level uses its mapped source patch")
  Assert.isFalse(textAt(drawn.text, "40/40", 144, 103), "default doubled HUD omits numeric player health")
  Assert.isFalse(textAt(drawn.text, "8000", 192, 103), "default doubled HUD omits player experience")
  Assert.isTrue(textAt(drawn.text, "ALLY-B", 150, 117), "the right ally names its own row")
  Assert.isTrue(textAt(drawn.text, "Lv9", 230, 120), "the right ally level uses its mapped source patch")
  Assert.isFalse(textAt(drawn.text, "35/35", 150, 141), "default doubled HUD omits numeric health for every ally")
  Assert.isTrue(textAt(drawn.text, "FOE-A", 14, 4), "the left foe names its own row")
  Assert.isTrue(textAt(drawn.text, "Lv4", 88, 4), "the left foe level uses its mapped source patch")
  Assert.isTrue(textAt(drawn.text, "FOE-B", 8, 33), "the right foe names its own row")
  Assert.isTrue(textAt(drawn.text, "Lv5", 82, 33), "the right foe level uses its mapped source patch")
  local tiles = {}
  for _, entry in ipairs(drawn.graphics.draws) do
    if
      type(entry.image) == "table"
      and type(entry.image.handle) == "string"
      and entry.image.handle:sub(1, 4) == "hud:"
      and isBarTile(entry.image.handle --[[@as string]], entry)
    then
      local handle = entry.image.handle --[[@as string]]
      tiles[handle] = tiles[handle] or {}
      tiles[handle][#tiles[handle] + 1] = {
        x = entry.x,
        y = entry.y,
        tile = math.floor(entry.quad.x / 8) - COMPONENT_BASE,
      }
    end
  end
  -- Full health on every slot fills each bar from the green base at its
  -- mapped source tile origin.
  for handle, origin in pairs(BAR_ORIGINS) do
    if handle:find("%-left$") or handle:find("%-right$") then
      local sampled = assert(tiles[handle], "the " .. handle .. " bar draws its tiles")
      Assert.equal(#sampled, 6, "the " .. handle .. " bar fills every tile")
      local fills = {}
      for _, tile in ipairs(sampled) do
        Assert.equal(tile.y, origin.y, "the " .. handle .. " tiles keep their mapped source tile row")
        local insideSourceSpan = false
        for _, range in ipairs(origin.ranges) do
          insideSourceSpan = insideSourceSpan or tile.x >= range[1] and tile.x < range[2]
        end
        Assert.isTrue(insideSourceSpan, "the " .. handle .. " tiles span their mapped source tile origins")
        fills[#fills + 1] = tile.tile
      end
      table.sort(fills)
      Assert.deepEqual(fills, { 10, 10, 10, 10, 10, 10 }, "the " .. handle .. " fills from the source base")
    end
  end
end

function T.doubled_health_bars_follow_each_slot_without_numeric_or_experience_labels()
  local view = doublesDetailView()
  local health = {
    [8] = { 25, 100 },
    [30] = { 1, 100 },
    [5] = { 40, 40 },
    [11] = { 0, 100 },
  }
  for _, battler in ipairs(view.battlers) do
    local values = health[battler.combatant]
    battler.hp = values[1]
    battler.maxHp = values[2]
    if battler.combatant == 8 then
      battler.condition = "poison"
    end
  end
  local first = drawNativePane("detail", view, nil, {})
  -- Bar tiles key by their mapped source tile row; each row owns its
  -- slot quantization independent of the other slots.
  local function tilesByOrigin(drawn)
    local grouped = {}
    for _, entry in ipairs(drawn.graphics.draws) do
      if
        type(entry.image) == "table"
        and type(entry.image.handle) == "string"
        and entry.image.handle:sub(1, 4) == "hud:"
        and isBarTile(entry.image.handle --[[@as string]], entry)
      then
        local key = tostring(entry.x) .. ":" .. tostring(entry.y)
        grouped[key] = grouped[key] or {}
        grouped[key][#grouped[key] + 1] = math.floor(entry.quad.x / 8) - COMPONENT_BASE
      end
    end
    local rows = {}
    for key, sampled in pairs(grouped) do
      local x, y = key:match("^([^:]+):([^:]+)$")
      local row = tostring(y)
      rows[row] = rows[row] or { x = tonumber(x), tiles = {} }
      for _, tile in ipairs(sampled) do
        rows[row].tiles[#rows[row].tiles + 1] = tile
      end
      if tonumber(x) < rows[row].x then
        rows[row].x = tonumber(x)
      end
    end
    for _, row in pairs(rows) do
      table.sort(row.tiles)
    end
    return rows
  end
  local firstTiles = tilesByOrigin(first)
  Assert.deepEqual(
    firstTiles["20"].tiles,
    { 15, 19 },
    "the left foe slot quantizes its quarter health to yellow partial tiles"
  )
  Assert.equal(firstTiles["20"].x, 56, "the left foe tiles keep their mapped source tile origin")
  Assert.deepEqual(firstTiles["49"].tiles, { 21 }, "the right foe slot keeps its minimum visible red tile")
  Assert.equal(firstTiles["49"].x, 50, "the right foe tiles keep their mapped source tile origin")
  Assert.deepEqual(
    firstTiles["103"].tiles,
    { 10, 10, 10, 10, 10, 10 },
    "the full left ally fills its tiles from the green base"
  )
  Assert.equal(firstTiles["103"].x, 192, "the left ally tiles keep their mapped source tile origin")
  Assert.isTrue(firstTiles["132"] == nil, "the empty right ally draws no bar tiles")
  local foeStatusIcon = false
  for _, entry in ipairs(first.graphics.draws) do
    if
      type(entry.image) == "table"
      and entry.image.handle == "hud:enemy-left"
      and type(entry.quad) == "table"
      and entry.quad.x >= 128 * 8
    then
      foeStatusIcon = true
    end
  end
  Assert.isTrue(foeStatusIcon, "a supported foe condition selects native status component tiles")
  for _, entry in ipairs(first.text.draws) do
    Assert.isNil(entry.content:match("%d+/%d+"), "native doubles do not show numeric current/max HP")
    Assert.isFalse(entry.content == "8000" or entry.content == "8100", "native doubles do not show player EXP")
  end

  for _, battler in ipairs(view.battlers) do
    if battler.combatant == 5 then
      battler.hp = 1
    end
  end
  local changed = drawNativePane("detail", view, nil, {})
  local changedTiles = tilesByOrigin(changed)
  Assert.deepEqual(changedTiles["103"].tiles, { 21 }, "only the changed ally bar follows its new HP")
  for key, row in pairs(firstTiles) do
    if key ~= "103" then
      Assert.deepEqual(changedTiles[key].tiles, row.tiles, "row " .. key .. " retains its independent tiles")
      Assert.equal(changedTiles[key].x, row.x, "row " .. key .. " retains its mapped origin")
    end
  end
end

function T.doubled_player_health_box_switches_between_native_gauge_and_number_cells()
  local view = doublesDetailView()
  view.battlers[2].healthBoxMode = "numbers"
  local drawn = drawNativePane("detail", view, nil, {})
  local leftGaugeTiles = {}
  local leftModeTiles = {}
  for _, entry in ipairs(drawsOf(drawn.graphics, "hud:player-left")) do
    if type(entry.quad) == "table" and entry.quad.w == 8 and entry.quad.h == 8 then
      local tile = math.floor(entry.quad.x / 8)
      if entry.y == 103 and entry.x >= 176 and entry.x < 256 then
        if tile < 128 then
          leftGaugeTiles[#leftGaugeTiles + 1] = tile
        else
          leftModeTiles[#leftModeTiles + 1] = tile
        end
      end
    end
  end
  Assert.deepEqual(leftGaugeTiles, {}, "number mode does not keep drawing the health gauge row")
  Assert.isTrue(textAt(drawn.text, "40", 200, 103), "number mode prints the current HP inside its source span")
  Assert.isTrue(textAt(drawn.text, "40", 224, 103), "number mode prints the maximum HP inside its source span")
  table.sort(leftModeTiles)
  Assert.deepEqual(leftModeTiles, { 197, 198, 199 }, "number mode patches the three native source cell components")

  local partnerTiles = {}
  for _, entry in ipairs(drawsOf(drawn.graphics, "hud:player-right")) do
    if isBarTile("hud:player-right", entry) then
      partnerTiles[#partnerTiles + 1] = math.floor(entry.quad.x / 8) - COMPONENT_BASE
    end
  end
  table.sort(partnerTiles)
  Assert.deepEqual(
    partnerTiles,
    { 10, 10, 10, 10, 10, 10 },
    "the unrelated partner remains in native gauge mode"
  )
end

function T.doubled_enemy_caught_markers_follow_wild_and_trainer_visibility()
  local function drawnFor(battleKind)
    local view = doublesDetailView({ battleKind = battleKind })
    for _, battler in ipairs(view.battlers) do
      if battler.side == 2 then
        battler.caught = true
      end
    end
    return drawNativePane("detail", view, nil, {})
  end
  local wild = drawnFor("wild")
  local trainer = drawnFor("trainer")
  local function hasCaughtMark(drawn)
    for _, art in ipairs({ "hud:enemy-left", "hud:enemy-right" }) do
      for _, entry in ipairs(drawsOf(drawn.graphics, art)) do
        if type(entry.quad) == "table" and entry.quad.x == 187 * 8 then
          return true
        end
      end
    end
    return false
  end
  Assert.isTrue(hasCaughtMark(wild), "double wild foes display the native caught marker")
  Assert.isFalse(hasCaughtMark(trainer), "double trainer foes suppress the native caught marker")
end

-- The doubled selection arrow follows the acting partner: its column
-- sits one horizontal arrow offset left of the acting health-box
-- anchor, derived at draw time instead of hardcoded.
function T.doubled_arrow_follows_the_acting_partner_health_box()
  local leftActing =
    drawNativePane("detail", doublesDetailView({ actor = { combatant = 5, index = 1, total = 2 } }), nil, {})
  local leftBands = drawsOf(leftActing.graphics, "arrow")
  Assert.equal(#leftBands, 2, "the acting left partner shows the arrow")
  Assert.equal(leftBands[1].x, 112, "the arrow sits one offset left of the left anchor")
  Assert.equal(leftBands[1].y, 95, "the arrow shares the left anchor row")
  local rightActing =
    drawNativePane("detail", doublesDetailView({ actor = { combatant = 11, index = 2, total = 2 } }), nil, {})
  local rightBands = drawsOf(rightActing.graphics, "arrow")
  Assert.equal(#rightBands, 2, "the acting right partner shows the arrow")
  Assert.equal(rightBands[1].x, 118, "the arrow sits one offset left of the right anchor")
  Assert.equal(rightBands[1].y, 124, "the arrow shares the right anchor row")
end

function T.doubled_arrow_keeps_the_right_slot_when_left_partner_hides()
  local view = doublesDetailView({ actor = { combatant = 11, index = 2, total = 2 } })
  for _, battler in ipairs(view.battlers) do
    if battler.combatant == 5 then
      battler.visible = false
    end
  end
  local drawn = drawNativePane("detail", view, nil, {})
  local bands = drawsOf(drawn.graphics, "arrow")
  Assert.equal(#bands, 2, "the acting right partner retains the arrow")
  Assert.equal(bands[1].x, 118, "the arrow remains anchored to the right slot after the left hides")
  Assert.equal(bands[1].y, 124, "the arrow remains on the right slot row after the left hides")
end

-- A single battle keeps its established anchors while its lead hides
-- mid-switch: the visible foe never slides onto a doubles row before
-- the replacement reveals.
function T.hidden_singles_lead_keeps_singles_anchors_mid_switch()
  local hidden = nativeView({
    battlers = {
      {
        combatant = 1,
        side = 1,
        position = 1,
        activation = 11,
        active = true,
        visible = false,
        name = "LEAD",
        level = 9,
        hp = 30,
        maxHp = 30,
        exp = 120,
        condition = nil,
        portraitSelector = "EEVEE/f0/male/plain/back",
        shakeDx = 0,
      },
      {
        combatant = 2,
        side = 2,
        position = 2,
        activation = 12,
        active = true,
        visible = true,
        name = "FOE",
        level = 3,
        hp = 12,
        maxHp = 12,
        exp = nil,
        condition = nil,
        portraitSelector = "EEVEE/f0/male/plain/front",
        shakeDx = 0,
      },
    },
  })
  local drawn = drawNativePane("detail", hidden, nil, {})
  local foe = pictureRecordsOf(drawn.pictures, "mon:EEVEE/f0/male/plain/front")
  Assert.equal(#foe, 1, "the visible foe still draws exactly once")
  Assert.equal(foe[1].centerX, 192, "the foe keeps its native column mid-switch")
  Assert.equal(foe[1].centerY, 50, "the foe keeps its native row mid-switch")
  Assert.equal(#pictureRecordsOf(drawn.pictures, "mon:EEVEE/f0/male/plain/back"), 0, "the hidden lead draws nothing")
  Assert.equal(#drawsOf(drawn.graphics, "hud:enemy-left"), 0, "no doubles strip draws in a single battle")
  Assert.equal(#drawsOf(drawn.graphics, "hud:player-left"), 0, "no doubles strip draws in a single battle")
  Assert.isTrue(#drawsOf(drawn.graphics, "hud:enemy") > 0, "the singles foe strip still draws")
end

-- A doubles survivor keeps its canonical row while its partner hides
-- mid-transition: the remaining slot never reindexes onto the hidden
-- neighbor's row.
function T.doubles_survivor_keeps_its_row_while_partner_hides()
  local gapped = doublesDetailView()
  for _, battler in ipairs(gapped.battlers) do
    if battler.combatant == 8 then
      battler.visible = false
    end
  end
  local drawn = drawNativePane("detail", gapped, nil, {})
  local survivor = pictureRecordsOf(drawn.pictures, "mon:PICHU/f0/male/plain/front")
  Assert.equal(#survivor, 1, "the surviving foe still draws exactly once")
  Assert.equal(survivor[1].centerX, 176, "the survivor keeps its right column while its partner hides")
  Assert.equal(survivor[1].centerY, 42, "the survivor keeps its right row while its partner hides")
  local hidden = pictureRecordsOf(drawn.pictures, "mon:BIDOOF/f0/male/plain/front")
  Assert.equal(#hidden, 0, "the hidden partner draws nothing")
  local allyLeft = pictureRecordsOf(drawn.pictures, "mon:STARLY/f0/male/plain/back")
  Assert.equal(#allyLeft, 1, "the undisturbed ally still draws exactly once")
  Assert.equal(allyLeft[1].centerX, 40, "the undisturbed ally keeps its settled column")
  Assert.equal(allyLeft[1].centerY, 112, "the undisturbed ally keeps its settled row")
end

return { tests = T }
