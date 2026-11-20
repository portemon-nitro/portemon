-- FieldState's draw order: world, the retained Start Menu surface, the
-- foreground child application surface, then the developer HUD.
-- Dialogue or signpost attached to the world surface yield to modal
-- application surfaces (the session's at-most-one-owner assert guarantees
-- they cannot be modal underneath the menu). No host-owned transition
-- overlay is ever painted: the menu draws first through its resolved
-- presentation plan -- the same plan pointer input maps through -- and
-- the child draws second, covering menu pixels only where its own panes
-- and frames draw.

local AssetNeedsRegistry = require("libs.hgss.src.field.AssetNeedsRegistry")
local Assert = require("tests.support.Assert")
local FieldState = require("game.hgss.src.field.FieldState")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local FieldBlackoutRenderer = require("game.hgss.src.field.FieldBlackoutRenderer")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local FieldApplicationIds = require("libs.hgss.src.field.FieldApplicationIds")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local PixelScale = require("libs.ui.src.PixelScale")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local StubLease = require("tests.support.StubLease")

local T = {}

-- No choice is ever presented on these draw paths: the shared host stays
-- idle and fails loudly if a choice layout is ever requested.
local function idleChoiceHost()
  return {
    isModal = function()
      return false
    end,
    presentation = function()
      return nil
    end,
    layoutFor = function()
      error("no choice is active in this fixture", 0)
    end,
  }
end

-- One 640x480 world display: the placement record this topology resolves is
-- { frame = {0,0,640,480}, scale = 2.5 }, mirroring the component window.
local function worldTopology()
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = false,
    role = "world",
  })
end

-- A recording fake renderer: every draw appends its label and arguments.
local function recordingRenderer(label, sink)
  return {
    draw = function(_, ...)
      sink[#sink + 1] = { label, ... }
    end,
  }
end

-- Spies on the real love.graphics rectangle/print/setColor calls so the
-- fade and HUD primitives are observable in call order with their colors.
local function spyGraphics(sink)
  local realRectangle, realPrint, realSetColor = love.graphics.rectangle, love.graphics.print, love.graphics.setColor
  local color = { 1, 1, 1, 1 }
  rawset(love.graphics, "setColor", function(r, g, b, a)
    color = { r, g, b, a }
    realSetColor(r, g, b, a)
  end)
  rawset(love.graphics, "rectangle", function(mode, x, y, w, h)
    sink[#sink + 1] = { "rect", color[1], color[2], color[3], color[4], mode, x, y, w, h }
    realRectangle(mode, x, y, w, h)
  end)
  rawset(love.graphics, "print", function(text, ...)
    sink[#sink + 1] = { "print", color[1], color[2], color[3], color[4], text }
    realPrint(text, ...)
  end)
  return function()
    rawset(love.graphics, "rectangle", realRectangle)
    rawset(love.graphics, "print", realPrint)
    rawset(love.graphics, "setColor", realSetColor)
  end
end

-- Draws the field with the graphics primitives observed into the sink and
-- returns the sink length the draw started at, so a caller can read exactly
-- the records one frame appended. The spy is restored before a failure
-- propagates, so a failing draw never leaves the process-global namespace
-- patched for the next test.
---@param state FieldState
---@param sink table[]
---@return integer frameStart
local function drawSpying(state, sink)
  local restore = spyGraphics(sink)
  local start = #sink
  local ok, err = pcall(state.draw, state)
  restore()
  if not ok then
    error(err, 0)
  end
  return start
end

-- A bare FieldState shaped like a live presentation state: fake renderers
-- recording into the sink, a fake runtime carrying every field draw touches,
-- and the topology provider under test. The player visual record is
-- invisible, so the actor assembly never touches a real asset provider.
---@param options { hostStatus: table, dialogueModal?: boolean, signpostModal?: boolean, blackoutStatus?: table, development?: boolean, topology?: ScreenTopology, worldViewport?: table, pokegear?: table, companionImages?: table, incomingCalls?: table }
---@return FieldState state
---@return table[] sink
local function drawableState(options)
  local sink = {}
  local topology = options.topology or worldTopology()
  local worldViewport = options.worldViewport or { x = 0, y = 0, width = 640, height = 480 }
  local viewport = FieldViewport.new(640, 480, { mode = "expanded" })
  viewport.worldViewport = worldViewport
  local runtime = {
    assetNeeds = AssetNeedsRegistry.new(),
    playerData = { profile = { name = "TEST", gender = 0 } },
    uiManifest = {
      dialogueFrames = { continueCursor = { placement = { x = 240, y = 168, width = 16, height = 16 } } },
    },
    runtimeMap = {
      mapId = 61,
      mapSymbol = "MAP_NEW_BARK",
      sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
    },
    player = { fieldX = 3, fieldZ = 7, worldY = 1.5, surfaceId = 0, facing = "east", motion = "idle" },
    playerVisual = {
      drawRecord = function()
        return { visible = false }
      end,
    },
    actors = {
      drawRecords = function()
        return {}
      end,
    },
    session = {
      tick = 32,
      renderAlpha = function()
        return 0.5
      end,
    },
    overworld = {
      isPresent = function()
        return true
      end,
    },
    destinationWorldPresentable = function()
      return true
    end,
    acknowledgeDestinationPresentation = function() end,
    viewport = viewport,
    fieldPixelScale = {
      resolvedScale = function()
        return 3
      end,
    },
    camera = { zoom = 1 },
    transition = { fadeAlpha = 0 },
    fieldEntranceIndicator = {
      status = function()
        return { visible = false }
      end,
    },
    dialogue = {
      isModal = function()
        return options.dialogueModal == true
      end,
    },
    blackoutFlow = options.blackoutStatus and {
      status = function()
        return options.blackoutStatus
      end,
    } or nil,
    scripts = {
      dialogueHost = {
        yesNoPresentation = function()
          return nil
        end,
      },
    },
    contextChoiceProvider = {
      status = function()
        return nil
      end,
    },
    contextChoicePresentation = function()
      return nil
    end,
    signpost = {
      isModal = function()
        return options.signpostModal == true
      end,
    },
    pcApplicationHost = {
      isActive = function()
        return false
      end,
    },
    applicationHost = {
      isActive = function()
        return options.hostStatus.phase ~= "closed"
      end,
      status = function()
        return options.hostStatus
      end,
    },
    menuHost = {
      presentation = function()
        return nil
      end,
    },
    -- The script-owned companion host and the ambient call coordinator, when
    -- the scenario presents a script surface or a ringing caller.
    pokegear = options.pokegear,
    incomingCalls = options.incomingCalls,
    imageAssets = options.companionImages ~= nil and {
      request = function(_, path)
        return path
      end,
      poll = function()
        return "ready"
      end,
      acquire = function(_, path)
        return assert(options.companionImages[path], "the fixture realizes every companion image")
      end,
      release = function() end,
    } or nil,
    yesNoHost = idleChoiceHost(),
    resizePresentation = function() end,
  }
  local state = setmetatable({
    development = options.development == true,
    -- The depicted scene's actor visuals are ready, so the draw presents
    -- the world instead of holding it behind the cover.
    _actorDesiredReady = true,
    runtime = runtime,
    topologyProvider = function()
      return topology
    end,
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    presentationResources = {
      renderer = recordingRenderer("world", sink),
      dialogueRenderer = recordingRenderer("dialogue", sink),
      windowRenderer = recordingRenderer("window", sink),
      textRenderer = recordingRenderer("text", sink),
      signpostRenderer = recordingRenderer("signpost", sink),
      startMenuRenderer = recordingRenderer("menu", sink),
      trainerCardRenderer = recordingRenderer("card", sink),
      -- The incoming-call notice is built on first use in production; the
      -- fixture hands back a recorder so the dispatch stays observable.
      callNoticeRenderer = function(_)
        return {
          draw = function(_, notice, tick, referenceFrame)
            sink[#sink + 1] = { "call-notice", notice, tick, referenceFrame }
          end,
        }
      end,
      partyScreenRenderer = recordingRenderer("party", sink),
      monIconProvider = { id = "test-icon-provider" },
      menuRenderer = recordingRenderer("script-menu", sink),
      -- The Start Menu dispatch seam mirrors production: the resolved plan
      -- executes through the real shared presentation draw with borrowed
      -- collaborators, so coverage, chrome, and render routing are real.
      drawStartMenu = function(self, status)
        ApplicationPresentation.draw(love.graphics, {
          graphics = love.graphics,
          startMenuRenderer = assert(self.startMenuRenderer, "the start menu renderer is unavailable"),
        }, status, assert(status.presentation, "the start menu draws through its presentation plan"))
      end,
      -- The harness-side dispatch seam mirrors the production presenter map:
      -- explicit ids only, no fallback surface.
      drawApplication = function(self, applicationId, presentation, hostRuntime)
        if applicationId == FieldApplicationIds.POKEMON then
          assert(self.partyScreenRenderer, "party screen renderer is unavailable"):draw(
            presentation,
            assert(presentation.layout, "the party application presents its layout"),
            assert(self.monIconProvider, "party icon provider is unavailable")
          )
          return
        end
        if applicationId == FieldApplicationIds.TRAINER_CARD then
          assert(self.trainerCardRenderer, "trainer card renderer is unavailable"):draw(
            presentation,
            hostRuntime.viewport
          )
          return
        end
        error("no presenter is registered for application " .. tostring(applicationId))
      end,
      drawMart = function() end,
      fieldEntranceIndicatorRenderer = {
        drawItems = function()
          return {}
        end,
      },
      fieldEmoteRenderer = {
        drawItems = function()
          return {}
        end,
      },
    },
    actorPresentation = {
      drawItems = function()
        return {}
      end,
      records = function()
        return {}
      end,
    },
  }, FieldState)
  return state, sink
end

function T.draw_routes_blackout_message_without_a_dialogue_modal()
  local blackoutStatus = { phase = "message_in", message = { tokens = {} }, coverColor = "white", coverAlpha = 0 }
  local state, _ = drawableState({ hostStatus = { phase = "closed" }, blackoutStatus = blackoutStatus })
  local priorDraw = FieldBlackoutRenderer.draw
  local receivedStatus
  FieldBlackoutRenderer.draw = function(status)
    receivedStatus = status
  end
  local ok, err = pcall(drawSpying, state, {})
  FieldBlackoutRenderer.draw = priorDraw
  if not ok then
    error(err, 0)
  end
  Assert.equal(receivedStatus, blackoutStatus)
end

local function labels(sink)
  local out = {}
  for _, call in ipairs(sink) do
    out[#out + 1] = call[1]
  end
  return out
end

-- The incoming-call notice one frame painted into the sink, or nil when that
-- frame carried none. `frameStart` is the sink length the frame began at.
---@param sink table[]
---@param frameStart integer
---@return table?
local function callNoticeDraw(sink, frameStart)
  for index = #sink, frameStart + 1, -1 do
    if sink[index][1] == "call-notice" then
      return sink[index]
    end
  end
  return nil
end

-- Idle field: the world draws first, then the open dialogue attached to the
-- world surface, then the developer HUD. No fade, no application surface.
function T.draw_orders_world_then_dialogue_then_hud_when_the_field_is_idle()
  local state, sink = drawableState({ hostStatus = { phase = "closed" }, dialogueModal = true, development = true })
  -- The developer overlay starts hidden; F3 reveals it so the HUD position
  -- in the draw order stays observable.
  state:keypressed("f3")
  drawSpying(state, sink)

  Assert.deepEqual(labels(sink), {
    "world",
    "dialogue",
    "rect",
    "print",
    "print",
    "print",
    "print",
  })
  local dialogueCall = sink[2]
  Assert.equal(dialogueCall[2], state.runtime.dialogue, "the dialogue renderer receives the dialogue controller")
  local presentation = dialogueCall[3]
  DialoguePresentationLayout.validate(presentation)
  Assert.deepEqual(
    presentation.bounds,
    state.runtime.viewport.worldViewport,
    "the dialogue draws from a presentation resolved against the real world viewport"
  )
  Assert.isNil(dialogueCall[4], "the dialogue renders from one resolved presentation")
  Assert.equal(#sink, 7, "no signpost, menu, card, or fade draws on an idle field")
end

-- The signpost is the world-attached surface when it owns the modal slot:
-- drawn after the world, before the HUD, with the session render alpha for
-- wipe interpolation.
function T.draw_orders_world_then_signpost_then_hud_when_the_signpost_is_modal()
  local state, sink = drawableState({ hostStatus = { phase = "closed" }, signpostModal = true })
  drawSpying(state, sink)

  Assert.deepEqual(labels(sink), { "world", "signpost" })
  local signpostCall = sink[2]
  Assert.equal(signpostCall[2], state.runtime.signpost, "the signpost renderer receives the signpost controller")
  Assert.equal(signpostCall[3], state.runtime.viewport, "the signpost draws into the viewport")
  Assert.equal(signpostCall[4], 0.5, "the signpost renderer receives the session render alpha")
end

-- Menu phase: only the Start Menu surface is drawn, through its resolved
-- presentation plan. The world-attached dialogue and signpost are not
-- drawn even if they report modal (the session's at-most-one-owner assert
-- guarantees they cannot be, so the draw path must never composite them
-- underneath the menu).
function T.menu_phase_draws_only_the_start_menu_surface_through_its_plan()
  local bodyPlacement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 640, height = 480 }, 256, 192),
    "the menu test host fits the canonical body"
  )
  Assert.deepEqual(bodyPlacement.frame, { x = 64, y = 48, width = 512, height = 384 })
  Assert.equal(bodyPlacement.scale, 2)
  local menuStatus = { selectedPosition = 0, actions = {} }
  menuStatus.presentation = {
    panes = { { id = "content", placement = bodyPlacement, interactive = true } },
    content = {},
    inputKey = "start-menu",
    render = function(resources, view, plan)
      assert(resources.startMenuRenderer, "the menu render borrows its renderer"):draw(
        view,
        assert(plan.panes[1], "the menu plan needs its body pane").placement
      )
    end,
    mapInput = function()
      return nil
    end,
    frames = {},
  }
  local state, sink = drawableState({
    hostStatus = { phase = "menu", menu = menuStatus },
    dialogueModal = true,
    signpostModal = true,
  })
  drawSpying(state, sink)

  -- Settled plans paint no matte: the world draws, then the menu draws
  -- through its plan with no settled fill between them.
  Assert.deepEqual(labels(sink), { "world", "menu" })
  local menuCall = sink[2]
  Assert.equal(menuCall[2], menuStatus, "the start menu renderer receives the host's menu presentation")
  Assert.deepEqual(menuCall[3], bodyPlacement, "the menu draws through the plan body placement")
end

-- A minimal drawable Start Menu status for layered-application fixtures:
-- a canonical body pane with a render callback drawing through the plan.
local function layeredMenuStatus()
  local bodyPlacement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 640, height = 480 }, 256, 192),
    "the menu test host fits the canonical body"
  )
  local menuStatus = { selectedPosition = 0, actions = {} }
  menuStatus.presentation = {
    panes = { { id = "content", placement = bodyPlacement, interactive = true } },
    content = {},
    inputKey = "start-menu",
    render = function(resources, view, plan)
      assert(resources.startMenuRenderer, "the menu render borrows its renderer"):draw(
        view,
        assert(plan.panes[1], "the menu plan needs its body pane").placement
      )
    end,
    mapInput = function()
      return nil
    end,
    frames = {},
  }
  return menuStatus, bodyPlacement
end

-- Application phase: the paused world draws, then the retained Start Menu
-- through its plan, then the Trainer Card surface; the dialogue and
-- signpost stay yielded while the modal surfaces own the tick.
function T.application_phase_draws_the_menu_below_the_card_with_no_fade()
  local menuStatus, bodyPlacement = layeredMenuStatus()
  local applicationStatus = { name = "GOLD", trainerId = 0 }
  local state, sink = drawableState({
    hostStatus = {
      phase = "application",
      applicationId = FieldApplicationIds.TRAINER_CARD,
      menu = menuStatus,
      application = applicationStatus,
    },
    signpostModal = true,
  })
  drawSpying(state, sink)

  Assert.deepEqual(labels(sink), { "world", "menu", "card" })
  local menuCall = sink[2]
  Assert.equal(menuCall[2], menuStatus, "the start menu renderer receives the host's menu presentation")
  Assert.deepEqual(menuCall[3], bodyPlacement, "the menu draws through the plan body placement")
  local cardCall = sink[3]
  Assert.equal(cardCall[2], applicationStatus, "the trainer card renderer receives the host's application presentation")
  Assert.equal(cardCall[3], state.runtime.viewport, "the card draws into the viewport")
end

-- Application phase: the party application draws through the same dispatch
-- with its own id and layout under the retained menu; the card surface
-- never draws underneath it.
function T.application_phase_draws_the_party_surface_through_the_presentation_dispatch()
  local menuStatus = layeredMenuStatus()
  local applicationStatus = { layout = { frame = { x = 0, y = 0, width = 640, height = 480 } } }
  local state, sink = drawableState({
    hostStatus = {
      phase = "application",
      applicationId = FieldApplicationIds.POKEMON,
      menu = menuStatus,
      application = applicationStatus,
    },
  })
  drawSpying(state, sink)

  Assert.deepEqual(labels(sink), { "world", "menu", "party" })
  local partyCall = sink[3]
  Assert.equal(partyCall[2], applicationStatus, "the party renderer receives the host's application presentation")
  Assert.equal(partyCall[3], applicationStatus.layout, "the party draws through the application layout")
  Assert.equal(
    partyCall[4],
    state.presentationResources.monIconProvider,
    "the party draws with the shared icon provider"
  )
end

-- Application phase with a retained menu: the paused world draws, then the
-- Start Menu background through its plan, then the child application. No
-- host-owned black overlay is painted between them; the child covers the
-- menu only where its own panes and frames draw.
function T.application_phase_layers_the_retained_menu_below_the_child_with_no_fade()
  local bodyPlacement = assert(
    PixelScale.placeFixed({ x = 0, y = 0, width = 640, height = 480 }, 256, 192),
    "the menu test host fits the canonical body"
  )
  Assert.deepEqual(bodyPlacement.frame, { x = 64, y = 48, width = 512, height = 384 })
  Assert.equal(bodyPlacement.scale, 2)
  local menuStatus = { selectedPosition = 0, actions = {} }
  menuStatus.presentation = {
    panes = { { id = "content", placement = bodyPlacement, interactive = true } },
    content = {},
    inputKey = "start-menu",
    render = function(resources, view, plan)
      assert(resources.startMenuRenderer, "the menu render borrows its renderer"):draw(
        view,
        assert(plan.panes[1], "the menu plan needs its body pane").placement
      )
    end,
    mapInput = function()
      return nil
    end,
    frames = {},
  }
  local applicationStatus = { name = "GOLD", trainerId = 0 }
  local state, sink = drawableState({
    hostStatus = {
      phase = "application",
      applicationId = FieldApplicationIds.TRAINER_CARD,
      menu = menuStatus,
      application = applicationStatus,
    },
  })
  drawSpying(state, sink)

  Assert.deepEqual(labels(sink), { "world", "menu", "card" })
  local menuCall = sink[2]
  Assert.equal(menuCall[2], menuStatus, "the start menu renderer receives the host's menu presentation")
  Assert.deepEqual(menuCall[3], bodyPlacement, "the menu draws through the plan body placement")
  local cardCall = sink[3]
  Assert.equal(cardCall[2], applicationStatus, "the trainer card renderer receives the host's application presentation")
  Assert.equal(cardCall[3], state.runtime.viewport, "the card draws into the viewport")
end

-- A live call started by a script or accepted from a ring draws through the
-- script host over the field: the published call window render paints the
-- caller and message plates, the phone card's own plan render never runs,
-- and its plan images realize through the shared companion image owner.
function T.a_script_host_call_draws_the_call_window_over_the_field()
  local upper = "assets/generated/pokegear/phone-upper-skin-0.png"
  local drawn = nil
  local plan = {
    content = { upper = upper },
    render = function()
      error("the live call never draws the phone card over the field", 0)
    end,
    renderCallWindow = function(resources, snapshot, published)
      drawn = { resources = resources, snapshot = snapshot, plan = published }
    end,
  }
  local status = { tab = "phone", focus = "phone", view = { call = { name = "ELM" } }, presentation = plan }
  local state, sink = drawableState({
    hostStatus = { phase = "closed" },
    pokegear = {
      scriptHost = {
        isActive = function()
          return true
        end,
        status = function()
          return status
        end,
      },
    },
    companionImages = { [upper] = StubLease.new("phone-upper") },
  })
  drawSpying(state, sink)

  Assert.deepEqual(labels(sink), { "world" })
  local call = assert(drawn, "the live call draws through its published call window render") --[[@as table]]
  Assert.equal(call.snapshot, status, "the call window render receives the host's live status")
  Assert.equal(call.plan, plan, "the call window render receives the published plan")
  Assert.isTrue(
    (call.resources --[[@as table]]).images[upper] ~= nil,
    "the call window realizes its plan images through the companion image owner"
  )
end

-- The ringing caller presents the compiled incoming-call notice over the
-- live field on the field's own fixed tick: the clock arms on the first
-- published ring and keeps its opening tick while the ring lasts, later
-- draws only read it, a quiet coordinator paints nothing, and a modal
-- surface owns the frame instead.
function T.a_ringing_caller_draws_the_compiled_notice_on_the_field_tick()
  local notice = nil
  local state, sink = drawableState({
    hostStatus = { phase = "closed" },
    incomingCalls = {
      notification = function()
        return notice or false
      end,
    },
  })

  state:_trackIncomingCallNotice()
  local frameStart = drawSpying(state, sink)
  Assert.isNil(callNoticeDraw(sink, frameStart), "a quiet coordinator paints no notice")

  notice = { contactKey = "custom.mom", name = "MOM", ringingAnimation = 5 }
  state:_trackIncomingCallNotice()
  frameStart = drawSpying(state, sink)
  local call = assert(callNoticeDraw(sink, frameStart), "the field draws the ringing notice") --[[@as table]]
  Assert.equal(call[2], notice, "the notice draw receives the live caller view")
  Assert.equal(call[3], 0, "the first published ring reads tick zero")
  Assert.equal(call[4], state.runtime.viewport.referenceFrame, "the notice draws in the field reference frame")

  -- Later frames read elapsed field ticks instead of advancing their own
  -- clock.
  state.runtime.session.tick = state.runtime.session.tick + 16
  state:_trackIncomingCallNotice()
  frameStart = drawSpying(state, sink)
  local advanced = assert(callNoticeDraw(sink, frameStart), "a live ring keeps painting") --[[@as table]]
  Assert.equal(advanced[3], 16, "the ring reads the field ticks since the caller appeared")

  -- The open menu owns the frame instead of the notice.
  local before = #sink
  state:_drawIncomingCallNotice(state.presentationResources, { menu = {} })
  Assert.equal(#sink, before, "the open menu owns the frame instead of the notice")

  -- Going quiet and ringing again re-arms the clock at the new field tick
  -- rather than resuming the expired ring. The quiet frame itself paints
  -- nothing, which the first frame above already proved.
  notice = nil
  state:_trackIncomingCallNotice()
  state.runtime.session.tick = state.runtime.session.tick + 40
  notice = { contactKey = "custom.mom", name = "MOM", ringingAnimation = 5 }
  state:_trackIncomingCallNotice()
  frameStart = drawSpying(state, sink)
  local rearmed = assert(callNoticeDraw(sink, frameStart), "the second ring paints again") --[[@as table]]
  Assert.equal(rearmed[2], notice, "the second ring presents its own caller view")
  Assert.equal(rearmed[3], 0, "the next ring restarts the field tick")
end

return { tests = T }
