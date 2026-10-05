-- Production FieldState composition for adapted field Yes/No presentation.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldRuntime = require("game.hgss.src.field.FieldRuntime")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldStatePresentationFixture = require("tests.support.FieldStatePresentationFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local PixelScale = require("libs.ui.src.PixelScale")
local PlayTime = require("libs.hgss.src.save.PlayTime")
local AcceptanceScriptFs = require("tests.acceptance.support.AcceptanceScriptFs")
local AcceptanceScripts = require("tests.acceptance.support.AcceptanceScripts")
local RepoFs = require("libs.storage.src.RepoFs")
local RomImporter = require("romdump.src.source.RomImporter")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}

local MESSAGE_YES_NO_SCRIPT = "acceptance.field_yes_no_message"

local function freshGame(versionId)
  return {
    saveId = "save-00000001",
    versionId = versionId,
    location = { mapSymbol = "MAP_NEW_BARK", fieldX = 10, fieldZ = 10, facing = "south" },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000, badges = 0, nationalDex = false },
      options = { textSpeed = "fastest", textFrame = 1 },
    },
    fieldTravel = { lastHealSpawn = "SPAWN_NEW_BARK" },
    playTime = PlayTime.new(),
    worldState = FieldEventState.new(),
    mons = require("tests.support.MonBucket").emptyForVersion(versionId),
    bag = require("libs.hgss.src.save.BagSave").empty(),
    mart = require("libs.hgss.src.save.MartSave").empty(),
  }
end

local function readyVersion()
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      return versionId
    end
  end
  error("a ready game dump and derived cache are required")
end

local function topology(width, height, safeRect)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    safeRect = safeRect,
    role = "world",
    touch = false,
  })
end

local function openScriptDialogue(state)
  local host = assert(state.runtime.scripts.dialogueHost)
  host:startPrint("msg.hgss.0542.00034", {}, {})
  for _ = 1, 600 do
    if host:printProgress().done then
      break
    end
    host:advance({})
  end
  Assert.isTrue(host:printProgress().done, "the script-owned message printer must finish")
  Assert.isTrue(state.runtime.dialogue:isModal(), "the script-owned dialogue must remain open")
  return host
end

local function openScriptDialogueAndChoice(state)
  local host = openScriptDialogue(state)
  host:askYesNo(assert(assert(state.runtime).session).tick)
  Assert.notNil(host:yesNoPresentation(), "the script-owned choice must be active")
end

local function render(scope, state, width, height)
  local graphics = love.graphics
  local canvas = scope:own(graphics.newCanvas(width, height))
  graphics.setCanvas(canvas)
  graphics.clear(0, 0, 0, 0)
  state:draw()
  graphics.setCanvas()
  return scope:own(canvas:newImageData())
end

local function fieldStateWithAcceptanceScripts()
  local originalNew = FieldRuntime.new
  FieldRuntime.new = function(game, options)
    local runtimeOptions = {}
    for key, value in pairs(options or {}) do
      runtimeOptions[key] = value
    end
    runtimeOptions.overrideFs =
      AcceptanceScriptFs.new(RepoFs.new(love.filesystem.getSourceBaseDirectory()), AcceptanceScripts)
    return originalNew(game, runtimeOptions)
  end
  local ok, stateOrError = xpcall(function()
    return FieldState.new(freshGame(readyVersion()), {
      derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
    })
  end, debug.traceback)
  FieldRuntime.new = originalNew
  if not ok then
    error(stateOrError, 0)
  end
  return stateOrError
end

local function startMessageYesNoScript(state)
  local runtime = assert(state.runtime)
  local scripts = assert(runtime.scripts)
  local composed = assert(scripts.composition:effective(MESSAGE_YES_NO_SCRIPT), "acceptance script is composed")
  local instanceId = scripts.scheduler:startInteraction(
    { kind = "acceptance", scriptId = MESSAGE_YES_NO_SCRIPT },
    composed,
    assert(runtime.session).tick,
    true
  )
  Assert.notNil(instanceId, "message-bearing fixture starts through the production scheduler")
end

local function advanceUntil(state, predicate, label)
  for _ = 1, 480 do
    if predicate() then
      return
    end
    state:update(1 / 60)
  end
  Assert.isTrue(predicate(), label)
end

local function assertChangedPixelsInsideFrame(image, comparison, frame)
  local left = math.max(0, frame.x)
  local top = math.max(0, frame.y)
  local right = math.min(image:getWidth(), frame.x + frame.width)
  local bottom = math.min(image:getHeight(), frame.y + frame.height)
  for y = top, bottom - 1 do
    for x = left, right - 1 do
      local red, green, blue, alpha = image:getPixel(x, y)
      local otherRed, otherGreen, otherBlue, otherAlpha = comparison:getPixel(x, y)
      if red ~= otherRed or green ~= otherGreen or blue ~= otherBlue or alpha ~= otherAlpha then
        return
      end
    end
  end
  Assert.fail("the scheduler-owned Yes/No frame must change pixels inside its production frame bounds")
end

local function assertContextChoiceComposition(scope, width, height, safeRect, dualDisplay)
  local originalGetDimensions = love.graphics.getDimensions
  rawset(love.graphics, "getDimensions", function()
    return width, height
  end)
  local state
  local resolvedLayout
  local resolvedStatus
  local resolvedInputs
  local ok, err = xpcall(function()
    local topologyProvider
    if dualDisplay then
      topologyProvider = function()
        return ScreenTopology.dualDisplay({
          id = "upper",
          rect = { x = 0, y = 0, width = 256, height = 192 },
          role = "world",
          touch = false,
        }, {
          id = "lower",
          rect = { x = 256, y = 0, width = 256, height = 192 },
          role = "auxiliary",
          touch = true,
        })
      end
    else
      topologyProvider = function()
        return topology(width, height, safeRect)
      end
    end
    state = FieldState.new(freshGame(readyVersion()), {
      topologyProvider = topologyProvider,
      derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
    })
    scope:own({
      release = function()
        state:dispose()
      end,
    })

    local renderer = assert(state.presentationResources).yesNoRenderer
    local originalDraw = renderer.draw
    renderer.draw = function(self, status, layout)
      resolvedStatus = status
      resolvedLayout = layout
      return originalDraw(self, status, layout)
    end

    local runtime = assert(state.runtime)
    for _ = 1, 120 do
      if runtime.session.mapEntryStage == nil then
        break
      end
      state:draw()
      state:update(1 / 60)
    end
    Assert.isNil(runtime.session.mapEntryStage, "production field entry settles before contextual choice")

    local dialogueHost = openScriptDialogue(state)
    local dialogueOnly = render(scope, state, width, height)
    local provider = assert(runtime.contextChoiceProvider)
    provider:open()
    Assert.isNil(dialogueHost:yesNoPresentation(), "context choice stays separate from opcode-63 Yes/No")
    Assert.deepEqual(provider:status(), { state = "active", selected = 0 })
    local contextChoice = render(scope, state, width, height)
    resolvedInputs = runtime:yesNoPresentationContext()

    Assert.notNil(resolvedLayout, "active context choice reaches the shared field Yes/No renderer")
    Assert.equal(resolvedStatus.active, true, "the normalized context choice is active")
    Assert.equal(resolvedStatus.selectedIndex, 0, "the renderer observes the provider's initial selection")
    local options = dialogueHost:yesNoOptions()
    Assert.equal(resolvedStatus.yesText, options.yesText, "context choice reuses localized Yes text")
    Assert.equal(resolvedStatus.noText, options.noText, "context choice reuses localized No text")
    Assert.equal(resolvedStatus.frameIndex, options.frameIndex, "context choice reuses the player frame")
    local placement = assert(resolvedLayout.placement)
    assertChangedPixelsInsideFrame(contextChoice, dialogueOnly, placement.frame)

    if dualDisplay then
      Assert.equal(resolvedLayout.presentation, "source", "dual-display choice uses auxiliary source coordinates")
      Assert.equal(assert(resolvedLayout.surface).role, "auxiliary", "choice is placed on the auxiliary display")
      Assert.isTrue(placement.frame.x >= 256, "source choice stays on the auxiliary surface")
    else
      Assert.equal(resolvedLayout.presentation, "adapted", "one-display choice uses adapted field coordinates")
      Assert.notNil(resolvedInputs.dialogueBox, "one-display contextual choice attaches to the open dialogue")
      Assert.equal(
        placement.frame.x + placement.frame.width,
        resolvedInputs.dialogueBox.x + resolvedInputs.dialogueBox.width,
        "context choice aligns its right edge with the dialogue"
      )
      Assert.equal(
        placement.frame.y + placement.frame.height + 2 * placement.scale,
        resolvedInputs.dialogueBox.y,
        "context choice keeps the existing dialogue gap"
      )
    end

    provider:select(1)
    local selectedNo = render(scope, state, width, height)
    Assert.equal(provider:status().selected, 1, "semantic navigation updates the provider selection")
    Assert.equal(resolvedStatus.selectedIndex, 1, "the next layout observes the selected No row")
    assertChangedPixelsInsideFrame(selectedNo, contextChoice, assert(resolvedLayout.placement).frame)
    provider:close()

    dialogueHost:askYesNo(runtime.session.tick)
    provider:open()
    local compositionValid, compositionError = pcall(function()
      render(scope, state, width, height)
    end)
    Assert.isFalse(compositionValid, "simultaneous field two-choice prompts are rejected")
    Assert.isTrue(
      tostring(compositionError):find(
        "field cannot present opcode-63 and contextual two-choice prompts at once",
        1,
        true
      ) ~= nil,
      "the invalid modal composition is identified"
    )
    provider:close()
    dialogueHost:closeYesNo()
    dialogueHost:close(true)
  end, debug.traceback)
  rawset(love.graphics, "getDimensions", originalGetDimensions)
  if not ok then
    error(err, 0)
  end
end

function T.message_bearing_scheduler_script_renders_yes_no_in_default_field_topology(scope)
  local width, height = love.graphics.getDimensions()
  local state = fieldStateWithAcceptanceScripts()
  scope:own({
    release = function()
      state:dispose()
    end,
  })

  local runtime = assert(state.runtime)
  Assert.equal(#runtime.screenTopology.surfaces, 1, "the default production topology is one display")
  local resolvedYesNoLayout
  local yesNoRenderer = assert(state.presentationResources).yesNoRenderer
  local originalDraw = yesNoRenderer.draw
  yesNoRenderer.draw = function(self, status, layout)
    resolvedYesNoLayout = layout
    return originalDraw(self, status, layout)
  end
  local dialogueOuterRect
  local dialogueRenderer =
    assert(assert(state.presentationResources).dialogueRenderer, "field presentation owns the dialogue renderer")
  local originalDrawDialogue = dialogueRenderer.draw
  dialogueRenderer.draw = function(self, dialogue, presentation)
    dialogueOuterRect = presentation.outerRect
    return originalDrawDialogue(self, dialogue, presentation)
  end
  for _ = 1, 120 do
    if runtime.session.mapEntryStage == nil then
      break
    end
    state:draw()
    state:update(1 / 60)
  end
  Assert.isNil(runtime.session.mapEntryStage, "production field entry settles before the script starts")

  startMessageYesNoScript(state)
  local host = assert(runtime.scripts.dialogueHost)
  advanceUntil(state, function()
    return host:isOpen() and host:printProgress().done
  end, "message-bearing script completes its message before opening Yes/No")
  Assert.isNil(host:yesNoPresentation(), "message-only comparison is captured before the task opens choice")
  local dialogueOnly = render(scope, state, width, height)

  advanceUntil(state, function()
    return host:yesNoPresentation() ~= nil
  end, "message-bearing scheduler task opens Yes/No after printing")
  local choiceFrame = render(scope, state, width, height)

  local layout = assert(resolvedYesNoLayout, "FieldState passes the active choice to its renderer")
  local frame = assert(layout.placement).frame
  local dialogue = assert(dialogueOuterRect, "FieldState renders the message before the active choice")
  local bounds = assert(runtime.viewport.worldViewport)
  assertChangedPixelsInsideFrame(choiceFrame, dialogueOnly, frame)
  Assert.equal(
    frame.x + frame.width,
    dialogue.x + dialogue.width,
    "production choice exterior right edge aligns with dialogue"
  )
  Assert.equal(
    frame.y + frame.height + 2 * layout.placement.scale,
    dialogue.y,
    "production choice stays two logical pixels above dialogue"
  )
  Assert.isTrue(frame.x >= bounds.x and frame.y >= bounds.y, "choice frame starts inside the world viewport")
  Assert.isTrue(
    frame.x + frame.width <= bounds.x + bounds.width and frame.y + frame.height <= bounds.y + bounds.height,
    "choice frame stays inside the world viewport"
  )
end

local function pixelEnvelope(image, comparison)
  local left, top, right, bottom
  for y = 0, image:getHeight() - 1 do
    for x = 0, image:getWidth() - 1 do
      local red, green, blue, alpha = image:getPixel(x, y)
      local otherRed, otherGreen, otherBlue, otherAlpha = comparison:getPixel(x, y)
      if red ~= otherRed or green ~= otherGreen or blue ~= otherBlue or alpha ~= otherAlpha then
        left = left and math.min(left, x) or x
        top = top and math.min(top, y) or y
        right = right and math.max(right, x) or x
        bottom = bottom and math.max(bottom, y) or y
      end
    end
  end
  Assert.notNil(left, "the choice must change final canvas pixels")
  return { x = left, y = top, width = right - left + 1, height = bottom - top + 1 }
end

local function assertMenuComposition(scope, width, height, safeRect)
  local originalGetDimensions = love.graphics.getDimensions
  rawset(love.graphics, "getDimensions", function()
    return width, height
  end)
  local state
  local resolvedYesNoLayout
  local resolvedYesNoInputs
  local resolvedDialoguePresentation
  local ok, err = xpcall(function()
    state = FieldState.new(freshGame(readyVersion()), {
      topologyProvider = function()
        return topology(width, height, safeRect)
      end,
      derivedAssets = FieldStatePresentationFixture.iconHost().derivedAssets,
    })
    scope:own({
      release = function()
        state:dispose()
      end,
    })

    local yesNoRenderer = assert(state.presentationResources and state.presentationResources.yesNoRenderer)
    local drawChoice = yesNoRenderer.draw
    yesNoRenderer.draw = function(self, status, layout)
      resolvedYesNoLayout = layout
      return drawChoice(self, status, layout)
    end
    local dialogueRenderer = assert(state.presentationResources.dialogueRenderer)
    local drawDialogue = dialogueRenderer.draw
    dialogueRenderer.draw = function(self, dialogue, presentation)
      resolvedDialoguePresentation = presentation
      return drawDialogue(self, dialogue, presentation)
    end

    local runtime = assert(state.runtime)
    for _ = 1, 120 do
      if runtime.session.mapEntryStage == nil then
        break
      end
      state:draw()
      state:update(1 / 60)
    end
    Assert.isNil(runtime.session.mapEntryStage, "the production field entry must settle before drawing")

    local dialogueHost = assert(runtime.scripts.dialogueHost)
    dialogueHost:askYesNo(runtime.session.tick)
    Assert.isFalse(runtime.dialogue:isModal(), "standalone choice must not require ordinary dialogue")
    Assert.notNil(dialogueHost:yesNoPresentation(), "the script-owned standalone choice must be active")

    local standaloneChoice = render(scope, state, width, height)
    Assert.notNil(resolvedYesNoLayout, "active standalone choice must reach the field Yes/No renderer")
    resolvedYesNoInputs = runtime:yesNoPresentationContext()
    dialogueHost:closeYesNo()
    local standaloneField = render(scope, state, width, height)
    local standalonePixels = pixelEnvelope(standaloneChoice, standaloneField)

    local bounds = assert(runtime.viewport.worldViewport)
    local standaloneLayout = assert(resolvedYesNoLayout)
    local standaloneInputs = assert(resolvedYesNoInputs)
    Assert.isNil(standaloneInputs.dialogueBox, "standalone choice layout has no dialogue anchor")
    Assert.equal(
      standaloneInputs.preferredScale,
      runtime.fieldPixelScale:resolvedScale(),
      "standalone choice layout uses the resolved field scale"
    )
    local standaloneFrame = assert(standaloneLayout.placement).frame
    Assert.isTrue(standaloneFrame.x >= bounds.x, "complete standalone frame stays inside field UI bounds")
    Assert.isTrue(standaloneFrame.y >= bounds.y, "complete standalone frame stays inside field UI bounds")
    Assert.isTrue(
      standaloneFrame.x + standaloneFrame.width <= bounds.x + bounds.width,
      "complete standalone frame stays inside field UI bounds"
    )
    Assert.isTrue(
      standaloneFrame.y + standaloneFrame.height <= bounds.y + bounds.height,
      "complete standalone frame stays inside field UI bounds"
    )
    Assert.isTrue(standalonePixels.x >= bounds.x, "standalone choice pixels stay inside field UI bounds")
    Assert.isTrue(standalonePixels.y >= bounds.y, "standalone choice pixels stay inside field UI bounds")
    Assert.isTrue(
      standalonePixels.x + standalonePixels.width <= bounds.x + bounds.width,
      "standalone choice pixels stay inside field UI bounds"
    )
    Assert.isTrue(
      standalonePixels.y + standalonePixels.height <= bounds.y + bounds.height,
      "standalone choice pixels stay inside field UI bounds"
    )

    openScriptDialogueAndChoice(state)

    local withChoice = render(scope, state, width, height)
    local attachedInputs = runtime:yesNoPresentationContext()
    runtime.scripts.dialogueHost:closeYesNo()
    local dialogueOnly = render(scope, state, width, height)
    local menuPixels = pixelEnvelope(withChoice, dialogueOnly)
    runtime.scripts.dialogueHost:close(true)
    local fieldOnly = render(scope, state, width, height)
    local dialoguePixels = pixelEnvelope(dialogueOnly, fieldOnly)

    local frame = assert(assert(resolvedYesNoLayout).placement).frame
    local dialogueBox = assert(attachedInputs.dialogueBox)
    local dialogueOuterRect = assert(assert(resolvedDialoguePresentation).outerRect)
    Assert.equal(dialogueBox.x, dialogueOuterRect.x, "dialogue-attached choice keeps the dialogue horizontal anchor")
    Assert.equal(dialogueBox.y, dialogueOuterRect.y, "dialogue-attached choice keeps the dialogue vertical anchor")
    Assert.equal(dialogueBox.width, dialogueOuterRect.width, "dialogue-attached choice keeps dialogue width")
    Assert.equal(dialogueBox.height, dialogueOuterRect.height, "dialogue-attached choice keeps dialogue height")
    Assert.near(
      frame.x + frame.width,
      dialogueBox.x + dialogueBox.width,
      1e-9,
      "the production layout aligns its complete exterior frame with the dialogue"
    )
    Assert.near(
      frame.y + frame.height + 2 * resolvedYesNoLayout.placement.scale,
      dialogueBox.y,
      1e-9,
      "the production layout keeps the choice two logical pixels above the dialogue"
    )
    local resolvedScale = runtime.fieldPixelScale:resolvedScale()
    local dialogueScale = PixelScale.fitPreferred(bounds, 256, 48, resolvedScale)
    Assert.equal(
      attachedInputs.preferredScale,
      dialogueScale,
      "dialogue-attached choice keeps the dialogue scale"
    )
    local expectedScale = resolvedYesNoLayout.placement.scale
    Assert.isTrue(expectedScale > 0 and expectedScale <= dialogueScale, "choice scale fits above the dialogue")
    Assert.isTrue(menuPixels.x >= bounds.x, "every changed menu pixel stays inside field UI bounds")
    Assert.isTrue(menuPixels.y >= bounds.y, "every changed menu pixel stays inside field UI bounds")
    Assert.isTrue(menuPixels.x + menuPixels.width <= bounds.x + bounds.width, "menu pixels stay inside field UI bounds")
    Assert.isTrue(
      menuPixels.y + menuPixels.height <= bounds.y + bounds.height,
      "menu pixels stay inside field UI bounds"
    )
    -- The complete menu spans the label-driven body plus the source frame
    -- overhang (two 8px tiles left, three right), at the resolved scale, with
    -- the same slack the fixed-width assertion allowed for transparent texels.
    local menuOuterWidth = assert(assert(resolvedYesNoLayout.content).width) + 40
    Assert.isTrue(
      menuPixels.width >= menuOuterWidth * expectedScale - (4 * expectedScale + 1),
      string.format(
        "the complete menu follows the field's resolved presentation scale (pixels=%d, expectedScale=%d, dialogueScale=%d, resolvedScale=%s)",
        menuPixels.width,
        expectedScale,
        dialogueScale,
        tostring(resolvedScale)
      )
    )
    Assert.isTrue(
      menuPixels.x + menuPixels.width <= dialoguePixels.x
        or menuPixels.x >= dialoguePixels.x + dialoguePixels.width
        or menuPixels.y + menuPixels.height <= dialoguePixels.y
        or menuPixels.y >= dialoguePixels.y + dialoguePixels.height,
      "choice pixels are spatially distinct from visible dialogue pixels"
    )
  end, debug.traceback)
  rawset(love.graphics, "getDimensions", originalGetDimensions)
  if not ok then
    error(err, 0)
  end
end

function T.four_three_standalone_choice_and_attached_dialogue_keep_their_layouts(scope)
  assertMenuComposition(scope, 640, 480)
end

function T.tall_standalone_choice_stays_complete_inside_the_attached_viewport(scope)
  assertMenuComposition(scope, 390, 844, { x = 12, y = 24, width = 366, height = 796 })
end

function T.context_choice_attaches_on_wide_four_three_and_tall_hosts(scope)
  assertContextChoiceComposition(scope, 1280, 720)
  assertContextChoiceComposition(scope, 640, 480)
  assertContextChoiceComposition(scope, 390, 844, { x = 12, y = 24, width = 366, height = 796 })
end

function T.context_choice_uses_auxiliary_source_layout_on_dual_display(scope)
  assertContextChoiceComposition(scope, 512, 192, nil, true)
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = { "field-runtime", "map:60" }
return suite
