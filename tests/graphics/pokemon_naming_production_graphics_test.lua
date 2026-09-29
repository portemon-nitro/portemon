-- Renders the retail Elm starter naming flow through FieldState's production
-- runtime and presentation ownership.

local Assert = require("tests.support.Assert")
local BagSave = require("libs.hgss.src.save.BagSave")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldMovement = require("tests.acceptance.support.FieldMovement")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldState = require("game.hgss.src.field.FieldState")
local FakeAudioOutput = require("tests.acceptance.support.FakeAudioOutput")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MonBucket = require("tests.support.MonBucket")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {}

local LAB = "MAP_NEW_BARK_ELMS_LAB_1F"
local FIXED_DT = 1 / 30
local PREVENT_ESCAPE = FieldScriptSymbols.flagsByName.FLAG_ELMS_LAB_PREVENT_PLAYER_ESCAPE

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  Assert.isTrue(#versions > 0, "a ready ROM-derived cache is required")
  return versions
end

local function newGame(versionId)
  return {
    saveId = "save-00000001",
    versionId = versionId,
    location = { mapSymbol = LAB, fieldX = 4, fieldZ = 13, facing = "north" },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0 },
      options = { textSpeed = "fastest", textFrame = 0 },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = MonBucket.emptyForVersion(versionId),
    bag = BagSave.empty(),
  }
end

local function step(state)
  state:update(FIXED_DT)
  if state.runtime.session.mapEntryStage == "await_presentation" then
    state:draw()
  end
end

local function advanceUntil(state, label, predicate, bound)
  for _ = 1, bound do
    if predicate() then
      return
    end
    step(state)
  end
  local runtime = state.runtime
  error(
    "timed out waiting for "
      .. label
      .. " (mapEntryStage="
      .. tostring(runtime and runtime.session.mapEntryStage)
      .. ", map="
      .. tostring(runtime and runtime.runtimeMap and runtime.runtimeMap.mapSymbol)
      .. ", error="
      .. tostring(runtime and runtime.errorText)
      .. ")",
    0
  )
end

local function moveOne(state, direction)
  local runtime = assert(state.runtime)
  if runtime.player.facing ~= direction then
    runtime.player:turn(direction)
  end
  runtime:press(direction)
  step(state)
  runtime:release(direction)
  advanceUntil(state, "production movement to settle", function()
    return runtime.player.motion == "idle"
  end, 120)
end

local function moveTo(state, target)
  local game = { runtime = assert(state.runtime) }
  for _ = 1, 12 do
    local route, boundary = FieldMovement.route(game, target)
    if route ~= nil then
      for _, edge in ipairs(route) do
        moveOne(state, edge.direction)
      end
      return true
    end
    if boundary == nil then
      return false
    end
    for _, edge in ipairs(boundary.route) do
      moveOne(state, edge.direction)
    end
    moveOne(state, boundary.direction)
  end
  error("production movement did not reach " .. target.fieldX .. ":" .. target.fieldZ, 0)
end

local function advanceStory(state, bound)
  local runtime = assert(state.runtime)
  for _ = 1, bound do
    if runtime.errorText then
      error("retail Elm script faulted: " .. runtime.errorText, 0)
    end
    if runtime.dialogue:status().modal then
      runtime:pressAction()
      step(state)
      runtime:releaseAction()
    else
      step(state)
    end
  end
end

local function interactionAt(runtime)
  local player = runtime.player
  local intent = runtime.interactionResolver:resolve({
    runtimeMap = runtime.runtimeMap,
    fieldX = player.fieldX,
    fieldZ = player.fieldZ,
    surfaceId = player.surfaceId,
    worldY = player.worldY,
    facing = player.facing,
    tick = runtime.session.tick + 1,
  })
  local hit = intent and runtime.scripts.client:resolve(intent)
  return hit and hit.trigger.scriptId
end

local function face(state, direction)
  local runtime = assert(state.runtime)
  advanceUntil(state, "player movement to settle before facing", function()
    return runtime.player.motion == "idle"
  end, 120)
  runtime.player:turn(direction)
end

local function triggerScript(state, scriptId, targets)
  local runtime = assert(state.runtime)
  local seen = {}
  local neighbors = {
    { x = 0, z = -1, facing = "south" },
    { x = 0, z = 1, facing = "north" },
    { x = -1, z = 0, facing = "east" },
    { x = 1, z = 0, facing = "west" },
  }
  for _, target in ipairs(targets) do
    local positions = {}
    if target.interactionTile then
      positions[1] = { tile = target.tile }
    else
      for _, neighbor in ipairs(neighbors) do
        positions[#positions + 1] = {
          tile = { fieldX = target.tile.fieldX + neighbor.x, fieldZ = target.tile.fieldZ + neighbor.z },
          facing = neighbor.facing,
        }
      end
    end
    for _, position in ipairs(positions) do
      if moveTo(state, position.tile) then
        for _, direction in ipairs({ "north", "south", "east", "west" }) do
          face(state, position.facing or direction)
          local resolvedScriptId = interactionAt(runtime)
          seen[#seen + 1] = tostring(resolvedScriptId)
          if resolvedScriptId == scriptId then
            runtime:pressAction()
            step(state)
            runtime:releaseAction()
            return
          end
        end
      end
    end
  end
  error("retail interaction " .. scriptId .. " was not reachable: " .. table.concat(seen, ","), 0)
end

local function activeActors(runtime)
  local actors = {}
  for _, actor in ipairs(runtime.actors:actorsOf(runtime.runtimeMap.mapId)) do
    local position = actor:getFieldPosition()
    if actor.actorId:find("player", 1, true) == nil then
      actors[#actors + 1] = { tile = { fieldX = position.fieldX, fieldZ = position.fieldZ }, actor = actor }
    end
  end
  table.sort(actors, function(first, second)
    return first.actor.actorId < second.actor.actorId
  end)
  return actors
end

local function reachNaming(state, observeContextChoice)
  local runtime = assert(state.runtime)
  local firstModal
  advanceUntil(state, "lab map entry", function()
    return runtime.session.mapEntryStage == nil
  end, 240)

  -- Complete the real welcome trigger so Elm's source dispatcher and the
  -- counter's source starter script own their normal prerequisites.
  moveTo(state, { fieldX = 4, fieldZ = 10 })
  advanceStory(state, 1200)
  Assert.isTrue(runtime.scripts.worldState:isFlagSet(PREVENT_ESCAPE), "the retail welcome scene completed")
  triggerScript(state, "vanilla.hgss.scr_seq.0843.script_000", activeActors(runtime))
  advanceStory(state, 1500)

  -- The table's background interaction is a generated coordinate event.
  triggerScript(state, "vanilla.hgss.scr_seq.0843.script_012", {
    { tile = { fieldX = 8, fieldZ = 5 }, interactionTile = true },
    { tile = { fieldX = 7, fieldZ = 4 }, interactionTile = true },
    { tile = { fieldX = 9, fieldZ = 4 }, interactionTile = true },
    { tile = { fieldX = 8, fieldZ = 3 }, interactionTile = true },
  })
  for _ = 1, 9000 do
    if runtime.errorText then
      error("retail starter script faulted: " .. runtime.errorText, 0)
    end
    if runtime.pokemonNaming:isActive() then
      return
    end
    local contextChoice = runtime.contextChoiceProvider
    if contextChoice and contextChoice:isActive() then
      if observeContextChoice then
        observeContextChoice(contextChoice:status())
        observeContextChoice = nil
        Assert.isTrue(contextChoice:isActive(), "the real Elm choice waits for a fresh confirmation")
      end
      runtime:pressAction()
      step(state)
      runtime:releaseAction()
    elseif runtime.dialogue:status().modal or (runtime.starterChoice and runtime.starterChoice:isActive()) then
      if firstModal == nil then
        firstModal = runtime.dialogue:status()
      end
      runtime:pressAction()
      step(state)
      runtime:releaseAction()
    else
      step(state)
    end
  end
  local starter = runtime.starterChoice
  local scheduler = runtime.scripts.scheduler
  local tasks = scheduler:tasks()
  local activeTask = tasks[1]
  local lastInput = scheduler:currentInput()
  error(
    "retail starter script did not open the nickname screen (foreground="
      .. tostring(scheduler:foregroundScriptId())
      .. ", choice="
      .. tostring(starter and starter:isActive())
      .. ", presentationReady="
      .. tostring(starter and starter:isPresentationReady())
      .. ", dialogue="
      .. tostring(runtime.dialogue:status().modal)
      .. ", dialogState="
      .. tostring(runtime.dialogue:status().state)
      .. ", waiting="
      .. tostring(runtime.dialogue:status().waiting)
      .. ", boundary="
      .. tostring(runtime.dialogue:status().continuationKind)
      .. ", revealed="
      .. tostring(runtime.dialogue:status().revealedGlyphs)
      .. "/"
      .. tostring(runtime.dialogue:status().pageGlyphCount)
      .. ", firstState="
      .. tostring(firstModal and firstModal.state)
      .. ", choiceHost="
      .. tostring(runtime.contextChoiceProvider and runtime.contextChoiceProvider:isActive())
      .. ", player="
      .. tostring(runtime.player.fieldX)
      .. ":"
      .. tostring(runtime.player.fieldZ)
      .. ", taskCount="
      .. tostring(#scheduler:tasks())
      .. ", taskType="
      .. tostring(activeTask and activeTask.taskType)
      .. ", taskPhase="
      .. tostring(activeTask and activeTask.state and activeTask.state.phase)
      .. ", lastAction="
      .. tostring(lastInput and lastInput.pressedAction)
      .. ", lastUiConfirm="
      .. tostring(lastInput and lastInput.uiEvents and #lastInput.uiEvents)
      .. ", error="
      .. tostring(runtime.errorText)
      .. ")",
    0
  )
end

local function pressNamingInput(state, input)
  local runtime = assert(state.runtime)
  if input == "cancel" then
    runtime:pressCancel()
    step(state)
    runtime:releaseCancel()
  else
    runtime:press(input)
    step(state)
    runtime:release(input)
  end
end

local function submitAtOk(state)
  local runtime = assert(state.runtime)
  for _ = 1, 6 do
    local status = assert(runtime.pokemonNaming:status(), "the retail naming task remains active")
    if status.snapshot.cursor.row == 1 then
      break
    end
    pressNamingInput(state, "north")
  end
  local status = assert(runtime.pokemonNaming:status(), "the retail naming task remains active")
  Assert.equal(status.snapshot.cursor.row, 1, "navigation reaches the naming home row")

  for _ = 1, 6 do
    status = assert(runtime.pokemonNaming:status(), "the retail naming task remains active")
    if status.snapshot.cursor.controlId == "ok" then
      break
    end
    pressNamingInput(state, "east")
  end
  status = assert(runtime.pokemonNaming:status(), "the retail naming task remains active")
  Assert.equal(status.snapshot.cursor.controlId, "ok", "navigation reaches the naming OK control")
  runtime:pressAction()
  step(state)
  runtime:releaseAction()
  advanceUntil(state, "retail naming task to close", function()
    return not runtime.pokemonNaming:isActive()
  end, 120)
end

local function renderPixels(scope, state, canvas)
  local graphics = love.graphics
  graphics.setCanvas(canvas)
  graphics.clear(0, 0, 0, 0)
  state:draw()
  graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function regionChanged(first, second, placement, logical)
  local scale = assert(placement.scale)
  local origin = assert(placement.origin)
  local left = math.floor(origin.x + logical.x * scale)
  local top = math.floor(origin.y + logical.y * scale)
  local right = math.ceil(origin.x + (logical.x + logical.width) * scale)
  local bottom = math.ceil(origin.y + (logical.y + logical.height) * scale)
  for y = top, bottom - 1 do
    for x = left, right - 1 do
      local firstRed, firstGreen, firstBlue, firstAlpha = first:getPixel(x, y)
      local secondRed, secondGreen, secondBlue, secondAlpha = second:getPixel(x, y)
      if firstRed ~= secondRed or firstGreen ~= secondGreen or firstBlue ~= secondBlue or firstAlpha ~= secondAlpha then
        return true
      end
    end
  end
  return false
end

local function assertPixelsChangedInsideFrame(image, comparison, frame)
  for y = math.max(0, frame.y), math.min(image:getHeight(), frame.y + frame.height) - 1 do
    for x = math.max(0, frame.x), math.min(image:getWidth(), frame.x + frame.width) - 1 do
      local red, green, blue, alpha = image:getPixel(x, y)
      local otherRed, otherGreen, otherBlue, otherAlpha = comparison:getPixel(x, y)
      if red ~= otherRed or green ~= otherGreen or blue ~= otherBlue or alpha ~= otherAlpha then
        return
      end
    end
  end
  Assert.fail("the real Elm choice must change canvas pixels inside its production frame")
end

local function verifyVersion(scope, versionId)
  local audioOutput = FakeAudioOutput.new()
  local state = assert(FieldState.new(newGame(versionId), {
    audioOutput = { audio = audioOutput.audio, sound = audioOutput.sound },
    derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
  }))
  scope:own({
    release = function()
      state:dispose()
    end,
  })
  local runtime = assert(state.runtime)
  local yesNoRenderer = assert(state.presentationResources.yesNoRenderer)
  local originalLayout = yesNoRenderer.layout
  local contextChoiceLayout
  local contextChoiceStatus
  yesNoRenderer.layout = function(self, status, ...)
    contextChoiceStatus = status
    contextChoiceLayout = originalLayout(self, status, ...)
    return contextChoiceLayout
  end
  local width, height = love.graphics.getDimensions()
  local contextCanvas = scope:own(love.graphics.newCanvas(width, height))
  local contextChoiceObservations = 0
  reachNaming(state, function(providerStatus)
    contextChoiceObservations = contextChoiceObservations + 1
    Assert.equal(providerStatus.state, "active", "the real Elm script owns an active contextual choice")
    Assert.equal(providerStatus.selected, 0, "the real Elm prompt initially selects Yes")

    local originalDraw = yesNoRenderer.draw
    yesNoRenderer.draw = function() end
    local withoutChoice = renderPixels(scope, state, contextCanvas)
    yesNoRenderer.draw = originalDraw
    local withChoice = renderPixels(scope, state, contextCanvas)

    Assert.notNil(contextChoiceLayout, "the active Elm choice reaches FieldYesNoRenderer")
    local layout = assert(contextChoiceLayout)
    Assert.equal(contextChoiceStatus.active, true, "the renderer receives an active choice")
    local options = runtime.scripts.dialogueHost:yesNoOptions()
    Assert.equal(contextChoiceStatus.yesText, options.yesText, "the Elm choice uses localized Yes text")
    Assert.equal(contextChoiceStatus.noText, options.noText, "the Elm choice uses localized No text")
    Assert.equal(contextChoiceStatus.frameIndex, options.frameIndex, "the Elm choice uses the player frame")
    assertPixelsChangedInsideFrame(withChoice, withoutChoice, assert(layout.placement).frame)
  end)
  yesNoRenderer.layout = originalLayout
  Assert.equal(contextChoiceObservations, 1, "the real Elm starter question is observed before confirmation")
  Assert.isFalse(
    runtime.contextChoiceProvider:isActive(),
    "only after the rendered choice is confirmed does the real script continue"
  )

  local status = assert(state.runtime.pokemonNaming:status(), "the retail script owns an active naming session")
  Assert.equal(status.snapshot.subject.kind, "pokemon", "the task publishes the selected mon as naming subject")
  Assert.notNil(status.snapshot.subject.iconKey, "the naming subject resolves through the real mon icon contract")
  Assert.equal(
    status.snapshot.presentation.subjectTick,
    0,
    "opening the real naming task preserves presentation tick 0"
  )
  advanceUntil(state, "naming subject icon preparation", function()
    return state._namingPresentationReady
  end, 120)
  local preparedStatus = assert(runtime.pokemonNaming:status(), "the naming task remains active after preparation")
  Assert.equal(
    preparedStatus.snapshot.presentation.subjectTick,
    0,
    "presentation stays at tick 0 until its first frame can be drawn"
  )

  local imageAcquisitions, quadAcquisitions, cacheReads = 0, 0, 0
  local namingDrawImages, namingDrawQuads, namingDrawReads = 0, 0, 0
  local graphics = love.graphics
  local originalNewImage, originalNewQuad = graphics.newImage, graphics.newQuad
  local cacheFs = assert(state.presentationResources.cacheFs, "field presentation owns the cache filesystem")
  local originalRead = cacheFs.read
  local namingRenderer = state.presentationResources:pokemonNamingRenderer()
  local originalNamingDraw = namingRenderer.draw
  local namingManifest = namingRenderer.naming
  local markerRecords = assert(namingManifest.pokemonGenderMarkers)
  local markerImages = {}
  for _, gender in ipairs({ "male", "female" }) do
    local marker = assert(markerRecords[gender])
    local frame = assert(marker.frames[1])
    markerImages[assert(namingRenderer.images["atlas:" .. frame.asset])] = gender
  end
  local observedSubjectParts = {}
  ---@type { x: number, y: number, gender: string }?
  local observedMarker = nil
  local failures = {}
  local originalDrawSubject = assert(namingRenderer.drawSubject)
  namingRenderer.drawSubject = function(hostGraphics, subject, placement)
    observedSubjectParts[#observedSubjectParts + 1] = {
      x = placement.x,
      y = placement.y,
      frameIndex = placement.frameIndex,
    }
    return originalDrawSubject(hostGraphics, subject, placement)
  end
  local originalGraphicsDraw = graphics.draw
  graphics.draw = function(image, quad, x, y, ...)
    local gender = markerImages[image]
    if gender ~= nil then
      assert(type(x) == "number", "gender marker draws use numeric x coordinates")
      assert(type(y) == "number", "gender marker draws use numeric y coordinates")
      observedMarker = { x = x, y = y, gender = gender }
    end
    originalGraphicsDraw(image, quad, x, y, ...)
  end
  local subjectChanged, slotChanged = false, false
  graphics.newImage = function(...)
    imageAcquisitions = imageAcquisitions + 1
    return originalNewImage(...)
  end
  graphics.newQuad = function(...)
    quadAcquisitions = quadAcquisitions + 1
    return originalNewQuad(...)
  end
  cacheFs.read = function(self, ...)
    cacheReads = cacheReads + 1
    return originalRead(self, ...)
  end
  local canvas = scope:own(graphics.newCanvas(width, height))
  namingRenderer.draw = function(self, ...)
    local imagesBefore, quadsBefore, readsBefore = imageAcquisitions, quadAcquisitions, cacheReads
    originalNamingDraw(self, ...)
    namingDrawImages = namingDrawImages + imageAcquisitions - imagesBefore
    namingDrawQuads = namingDrawQuads + quadAcquisitions - quadsBefore
    namingDrawReads = namingDrawReads + cacheReads - readsBefore
  end
  local function renderNamingFrame(expectedTick, expectedFrameIdx)
    local current = assert(runtime.pokemonNaming:status(), "the retail naming task remains active")
    local presentation = current.snapshot.presentation
    Assert.equal(presentation.subjectTick, expectedTick, "field updates advance naming presentation at 60 Hz")
    Assert.equal(presentation.cursorTick, expectedTick, "cursor presentation shares the 60 Hz clock")
    Assert.equal(presentation.entrySlotTick, expectedTick, "slot presentation shares the 60 Hz clock")

    observedSubjectParts = {}
    observedMarker = nil
    local image = renderPixels(scope, state, canvas)
    local subject = namingManifest.pokemonSubject
    local frame = assert(subject.frames[expectedFrameIdx], "the expected semantic subject frame exists")
    Assert.equal(#frame.parts, 1, "the v19 subject frame contains one visible semantic icon part")
    Assert.equal(#observedSubjectParts, #frame.parts, "production draws each visible semantic subject part once")
    for index, part in ipairs(observedSubjectParts) do
      local sourcePart = frame.parts[index]
      Assert.equal(part.frameIndex, sourcePart.iconFrame, "production uses the semantic mon icon frame selector")
      Assert.equal(part.x, subject.anchor.x + sourcePart.offset.x, "production uses the semantic horizontal placement")
      Assert.equal(part.y, subject.anchor.y + sourcePart.offset.y, "production uses the semantic vertical placement")
    end

    if status.snapshot.subject.gender == "genderless" then
      Assert.isNil(observedMarker, "genderless Pokemon do not draw a gender marker")
    else
      local marker = assert(observedMarker, "gendered Pokemon draw a gender marker")
      Assert.equal(marker.gender, status.snapshot.subject.gender)
      Assert.equal(marker.x, markerRecords.anchor.x)
      Assert.equal(marker.y, markerRecords.anchor.y)
    end
    return image
  end

  local ok, err = xpcall(function()
    local subjectBefore = renderNamingFrame(0, 1)
    local selectedBefore = subjectBefore
    for _ = 1, 10 do
      step(state)
    end
    local secondFrame = renderNamingFrame(20, 2)
    step(state)
    local slotFrame = renderNamingFrame(22, 2)
    step(state)
    local loopedFrame = renderNamingFrame(24, 1)

    -- The modal surface is opaque over the sampled subject/slot regions, so
    -- compare its source-logical bounds through the production pane transform.
    local placement = assert(status.presentation.panes[1].placement)
    subjectChanged = regionChanged(subjectBefore, secondFrame, placement, { x = 24, y = 8, width = 32, height = 32 })
    slotChanged = regionChanged(selectedBefore, slotFrame, placement, { x = 80, y = 39, width = 16, height = 16 })
    Assert.isFalse(
      regionChanged(subjectBefore, loopedFrame, placement, { x = 24, y = 8, width = 32, height = 32 }),
      "sequence 50 returns to its first source frame after the loop"
    )
  end, debug.traceback)
  graphics.newImage, graphics.newQuad = originalNewImage, originalNewQuad
  graphics.draw = originalGraphicsDraw
  cacheFs.read = originalRead
  namingRenderer.draw = originalNamingDraw
  namingRenderer.drawSubject = originalDrawSubject
  if not ok then
    error(err, 0)
  end
  if not subjectChanged then
    failures[#failures + 1] = "subject pixels do not advance at source bounds"
  end
  if not slotChanged then
    failures[#failures + 1] = "selected slot pixels do not advance at source bounds"
  end
  if cacheReads ~= 0 then
    failures[#failures + 1] = "draw read " .. cacheReads .. " generated files"
  end
  if imageAcquisitions ~= 0 then
    failures[#failures + 1] = "draw created " .. imageAcquisitions .. " images"
  end
  if quadAcquisitions ~= 0 then
    failures[#failures + 1] = "draw created " .. quadAcquisitions .. " quads"
  end
  local failureText = table.concat(failures, "; ")
  Assert.equal(failureText, "", "production naming graphics contract: " .. failureText)

  -- Confirm a changed nickname through the production naming input mapper,
  -- then wait for the source script to commit it through the live mon service.
  pressNamingInput(state, "south")
  local namingStatus = assert(runtime.pokemonNaming:status(), "the retail naming task remains active")
  Assert.equal(namingStatus.snapshot.grid[3][1].glyph, "K")
  runtime:pressAction()
  step(state)
  runtime:releaseAction()
  Assert.equal(state.runtime.pokemonNaming:status().text, "K", "the active task accepts the selected glyph")
  submitAtOk(state)
  local scheduler = runtime.scripts.scheduler
  local nicknameTask
  for _, task in ipairs(scheduler:tasks()) do
    if task.taskType == "pokemon_nickname_input" then
      nicknameTask = task
    end
  end
  Assert.equal(runtime.pokemonNaming:isActive(), false, "the retail nickname task closed its naming host")
  Assert.notNil(nicknameTask, "the scheduler retains the completed retail nickname task result")
  Assert.equal(nicknameTask.status, "completed", "the retail nickname task completed")
  Assert.equal(nicknameTask.result, 0, "the retail task reports changed input")
  Assert.isTrue(nicknameTask.state.closed, "the completed retail task released its naming host")
  Assert.equal(
    runtime.monService:partyMon(0).nickname,
    "K",
    "the retail script result commits the changed nickname through the live mon service"
  )
end

function T.retail_nickname_modal_draws_from_prepared_field_resources(scope)
  for _, versionId in ipairs(readyVersions()) do
    verifyVersion(scope, versionId)
  end
end

local suite = GraphicsSmoke.suite(T, {
  capabilities = { "graphics", "rom_dump", "derived_assets" },
  tags = { "field", "naming", "starter" },
})
suite.metadata.derivedAssets = { "field-runtime", "map:61" }
return suite
