-- The League ending and PC Hall of Fame showcase drawn through the real
-- presented field composition: the prepared ending bundle's registration,
-- save-status, credit-roll and The End surfaces plus the recorded showcase
-- pages paint over the live field on a real canvas, while a pending bundle
-- draws nothing and attributes its absence instead of painting partial art.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local EndingAssetCache = require("libs.assets.src.ending.EndingAssetCache")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local FinalizedGameFixture = require("tests.support.FinalizedGameFixture")
local GameClearCoordinator = require("game.hgss.src.ending.GameClearCoordinator")
local GameVersion = require("romdump.src.source.GameVersion")
local GeneratedCacheFixture = require("tests.support.GeneratedCacheFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SelectedAssetRuntimeFixture = require("tests.support.SelectedAssetRuntimeFixture")

local T = {}

local HOF_ROOM = "MAP_POKEMON_LEAGUE_HALL_OF_FAME"
local VAR_HOF_FRAME_ENTRY = assert(FieldScriptSymbols.variablesByName.VAR_TEMP_x4001)

---@return string versionId a ready version whose ending bundle is published
local function readyVersion()
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      local cacheFs = GeneratedCacheFixture.reader(versionId)
      if EndingAssetCache.isReady(cacheFs) then
        return versionId
      end
    end
  end
  error("a ready game dump whose ending bundle is published is required")
end

local function topology()
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 512, height = 384 },
    role = "world",
    touch = false,
  })
end

---@param scope table graphics ownership scope
---@param worldState table? pre-seeded field event state
---@return FieldState state
local function bootHofField(scope, worldState)
  local versionId = readyVersion()
  local cacheFs = GeneratedCacheFixture.reader(versionId)
  local assetRuntime = SelectedAssetRuntimeFixture.new(cacheFs, scope)
  local game = FinalizedGameFixture.build(versionId, {
    location = { mapSymbol = HOF_ROOM, fieldX = 6, fieldZ = 22, facing = "north" },
    worldState = worldState,
  })
  local state = FieldState.new(game, {
    topologyProvider = topology,
    derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
    cacheFs = cacheFs,
    assetRuntime = assetRuntime,
  })
  scope:own({
    release = function()
      state:dispose()
    end,
  })
  return state
end

local function heldWorldState()
  local worldState = FieldEventState.new()
  worldState:setVar(VAR_HOF_FRAME_ENTRY, 1)
  return worldState
end

-- Settles field entry, then gives the clear's two-party through the
-- production mon owner.
---@param state FieldState
local function settleWithParty(state)
  local runtime = assert(state.runtime, "the presented field owns its runtime")
  for _ = 1, 240 do
    if runtime.session.mapEntryStage == nil then
      break
    end
    state:draw()
    state:update(1 / 60)
  end
  Assert.isNil(runtime.session.mapEntryStage, "production field entry settles before the ending")
  local party = assert(runtime.monService, "the presented field owns its mon service")
  Assert.isTrue(
    party:giveMon({ species = "TYPHLOSION", level = 60, form = 0, heldItem = "NONE" }),
    "the recorded party member enters through the production gift operation"
  )
  Assert.isTrue(
    party:giveMon({ species = "PIDGEOT", level = 55, form = 0, heldItem = "NONE" }),
    "the recorded party member enters through the production gift operation"
  )
end

---@param scope table graphics ownership scope
---@param state FieldState
---@return table image data
local function render(scope, state)
  local graphics = love.graphics
  local canvas = scope:own(graphics.newCanvas(512, 384))
  graphics.setCanvas(canvas)
  graphics.clear(0, 0, 0, 0)
  state:draw()
  graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

---@param image table love image data
---@return integer painted pixels outside the clear color
local function paintedPixels(image)
  local painted = 0
  for y = 0, image:getHeight() - 1 do
    for x = 0, image:getWidth() - 1 do
      local red, green, blue, alpha = image:getPixel(x, y)
      if alpha ~= 0 and (red ~= 0 or green ~= 0 or blue ~= 0) then
        painted = painted + 1
      end
    end
  end
  return painted
end

---@param first table love image data
---@param second table love image data
---@return boolean differ
local function differ(first, second)
  assert(first:getWidth() == second:getWidth(), "compared frames share their width")
  assert(first:getHeight() == second:getHeight(), "compared frames share their height")
  for y = 0, first:getHeight() - 1 do
    for x = 0, first:getWidth() - 1 do
      local r1, g1, b1, a1 = first:getPixel(x, y)
      local r2, g2, b2, a2 = second:getPixel(x, y)
      if r1 ~= r2 or g1 ~= g2 or b1 ~= b2 or a1 ~= a2 then
        return true
      end
    end
  end
  return false
end

-- Records every painted text line behind the real renderers while the real
-- GPU still uploads the bundle art.
---@param state FieldState
---@return table recorded
local function recordPaintedText(state)
  local recorded = { text = {} }
  local resources = assert(state.presentationResources, "the presented field owns its resources")
  local textRenderer = assert(resources.textRenderer, "the presented field owns its text renderer")
  local originalDrawText = textRenderer.drawText
  textRenderer.drawText = function(self, text, x, y)
    recorded.text[#recorded.text + 1] = tostring(text)
    return originalDrawText(self, text, x, y)
  end
  return recorded
end

---@param recorded table
---@return string painted text
local function paintedText(recorded)
  return table.concat(recorded.text, "\n")
end

-- The congratulations registration paints the recorded party over the live
-- field once the bundle is admitted.
function T.congratulations_paints_the_registered_party(scope)
  local state = bootHofField(scope, heldWorldState())
  local recorded = recordPaintedText(state)
  settleWithParty(state)
  local runtime = assert(state.runtime, "the presented field owns its runtime")
  local before = render(scope, state)
  -- The production coordinator begin is what script 163 invokes: the
  -- transaction, its readiness demand and the source timeline stay owned.
  runtime.gameClear:begin(0)
  for _ = 1, 240 do
    state:update(1 / 60)
    if runtime.gameClear:phase() == "congratulations" and runtime.endingPresentation:isReady() then
      break
    end
  end
  Assert.isTrue(runtime.endingPresentation:isReady(), "the presented ending admits its bundle")
  local registration = render(scope, state)
  Assert.isTrue(differ(before, registration), "the registration surface covers the live field")
  Assert.isTrue(paintedPixels(registration) > 0, "the registration paints its framed surface")
  local painted = paintedText(recorded)
  Assert.isTrue(painted:find("TYPHLOSION", 1, true) ~= nil, "the registration paints the recorded party")
  Assert.isTrue(painted:find("PIDGEOT", 1, true) ~= nil, "the registration paints every recorded member")
  -- The prepared realization images behind the bundle are real GPU art, not
  -- placeholder paths: every published credit image uploads.
  local bundle = EndingAssetCache.load(GeneratedCacheFixture.reader(readyVersion()))
  local images = 0
  for _, scene in ipairs(bundle.credits.scenes) do
    for _, layer in ipairs({ scene.lower, scene.upper }) do
      local bytes = assert(GeneratedCacheFixture.reader(readyVersion()):read(layer.path))
      local file = assert(love.filesystem.newFileData(bytes, layer.path))
      scope:own(love.graphics.newImage(file))
      images = images + 1
    end
  end
  do
    local bytes = assert(GeneratedCacheFixture.reader(readyVersion()):read(bundle.credits.theEnd.path))
    scope:own(love.graphics.newImage(assert(love.filesystem.newFileData(bytes, bundle.credits.theEnd.path))))
    images = images + 1
  end
  Assert.equal(images, 13, "the roll's six scene pairs and The End upload as real images")
end

-- The credit roll advances its source pages over time; The End follows the
-- completed roll. Both draw through the admitted bundle.
function T.credits_advance_pages_and_reach_the_end(scope)
  local state = bootHofField(scope, heldWorldState())
  local recorded = recordPaintedText(state)
  settleWithParty(state)
  local runtime = assert(state.runtime, "the presented field owns its runtime")
  local presentation = assert(runtime.endingPresentation, "the presented ending owns its presentation")
  local cacheFs = GeneratedCacheFixture.reader(readyVersion())
  presentation:prepare(EndingAssetCache.load(cacheFs))
  local resources = {
    graphics = love.graphics,
    textRenderer = assert(state.presentationResources).textRenderer,
    windowRenderer = assert(state.presentationResources).windowRenderer,
    icons = assert(state.presentationResources).monIconProvider,
    monCatalog = runtime.monCatalog,
    messageProvider = runtime.messageProvider,
    images = {},
    cacheFs = cacheFs,
  }
  local admitted, admitFailure = presentation:admitImages(resources)
  Assert.isTrue(admitted, "credit images admit outside draw: " .. tostring(admitFailure))
  local early = { phase = "credits", timer = 5 }
  presentation:draw(resources, early)
  local later = { phase = "credits", timer = 500 }
  local recordedBefore = #recorded.text
  presentation:draw(resources, later)
  Assert.isTrue(#recorded.text > recordedBefore, "the later roll page paints its own lines")
  local painted = paintedText(recorded)
  Assert.isNil(painted:find("scene ", 1, true), "the roll never paints a diagnostic scene label")
  Assert.isNil(painted:find("bank", 1, true), "the roll paints source text, not bank identities")
  recorded.text = {}
  presentation:draw(resources, { phase = "the_end" })
  Assert.equal(#recorded.text, 0, "The End draws its source art with text layers disabled, not overlaid titles")
end

-- The PC showcase opens over the recorded history and paints the newest
-- record first, then its framed member page, through the admitted bundle
-- and the recorded party's own icons.
function T.pc_showcase_paints_record_pages(scope)
  local state = bootHofField(scope, heldWorldState())
  local recorded = recordPaintedText(state)
  settleWithParty(state)
  local runtime = assert(state.runtime, "the presented field owns its runtime")
  local entry = GameClearCoordinator.buildEntry(
    assert(runtime.monService, "the presented field owns its mon service"),
    { year = 2000, month = 1, day = 1 }
  )
  Assert.isTrue(
    assert(runtime.hallOfFame, "the presented field owns its history"):recordClear(entry),
    "the recorded clear enters through the production history owner"
  )
  local host = assert(runtime.pcApplicationHost, "the presented field owns its PC host")
  local handle = assert(host:open({ app = "hallOfFame" }), "the source Hall of Fame entry opens its child")
  for _ = 1, 240 do
    state:update(1 / 60)
    if host:status() ~= nil and host:status().presentationReady then
      break
    end
  end
  Assert.isTrue(host:status().presentationReady, "the presented showcase admits its bundle and icons")
  recorded.text = {}
  local team = render(scope, state)
  Assert.isTrue(paintedPixels(team) > 0, "the showcase team page paints")
  local painted = paintedText(recorded)
  Assert.isTrue(painted:find("TYPHLOSION", 1, true) ~= nil, "the showcase paints the recorded party species")
  Assert.isTrue(painted:find("PIDGEOT", 1, true) ~= nil, "the showcase paints every recorded member")
  -- The source confirm input opens the framed member page from the team page.
  host:step(handle, { { type = "confirm" } })
  recorded.text = {}
  local member = render(scope, state)
  Assert.isTrue(differ(team, member), "the member page replaces the team page")
  local memberPainted = paintedText(recorded)
  Assert.isTrue(memberPainted:find("GOLD", 1, true) ~= nil, "the member page paints the OT name")
  -- The source cancel input walks back to the team page and closes from it.
  -- The script task takes the close result and closes the host; the test
  -- follows that same production close protocol.
  host:step(handle, { { type = "cancel" } })
  recorded.text = {}
  local backToTeam = render(scope, state)
  Assert.isTrue(differ(member, backToTeam), "cancel walks back to the team page")
  host:step(handle, { { type = "cancel" } })
  local result = host:result(handle)
  Assert.equal(assert(result, "the closed showcase publishes its result").kind, "closed", "the showcase closes")
  host:close(handle)
  Assert.isFalse(host:isActive(), "the source cancel input closes the showcase")
end

-- A pending bundle draws nothing and attributes its absence: no text, no
-- windows, and no partial surface over the live field.
function T.pending_bundle_draws_nothing_and_attributes(scope)
  local state = bootHofField(scope, heldWorldState())
  local recorded = recordPaintedText(state)
  settleWithParty(state)
  local runtime = assert(state.runtime, "the presented field owns its runtime")
  local presentation = assert(runtime.endingPresentation, "the presented ending owns its presentation")
  Assert.isFalse(presentation:isReady(), "the cold presentation owns no sections")
  local field = render(scope, state)
  local resources = {
    graphics = love.graphics,
    textRenderer = assert(state.presentationResources).textRenderer,
    windowRenderer = assert(state.presentationResources).windowRenderer,
    icons = {},
    monCatalog = runtime.monCatalog,
    messageProvider = runtime.messageProvider,
    images = {},
  }
  local ok, err = pcall(presentation.draw, presentation, resources, { phase = "credits", timer = 5 })
  Assert.isFalse(ok, "a pending bundle never paints a partial roll")
  Assert.isTrue(
    tostring(err):find("FIELD_ENDING_ASSET_MISSING", 1, true) ~= nil,
    "the missing bundle attributes its source identity: " .. tostring(err)
  )
  Assert.equal(#recorded.text, 0, "no text is painted before readiness")
  -- The field itself still composes behind the held ending phases.
  Assert.isTrue(paintedPixels(field) > 0, "the live field still draws behind the pending ending")
end

local suite = GraphicsSmoke.suite(T, { tags = { "field", "ending", "hall-of-fame", "credits" } })
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = {
  "field-runtime",
  "audio-bank:700",
  "audio-bank:702",
  "audio-bank:709",
  -- The Hall of Fame room's field music (SEQ_GS_CHAMPROAD, sequence 1085)
  -- closes in bank 710.
  "audio-bank:710",
  "ending:global",
  "pc:global",
  "map:306",
  "map-data:306",
  "message-bank:528",
  -- The ending bundle records its own message-bank numbers (180/181/440)
  -- as lenient provenance hashes; those banks are not independently
  -- preparable, so the presenter falls back to their source identities.
  "message-bank:40",
  "mon-catalog:global",
  "mon-layout:global",
  "mon-icon-page:20",
  "mon-icon-page:29",
}
return suite
