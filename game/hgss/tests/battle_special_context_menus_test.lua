-- Fixture-driven presentation for battle contexts the field story and
-- facility launchers cannot produce yet: safari, pal-park, bug-contest,
-- tutorial, frontier-facility, and link/recording launches. Each fixture
-- drives the real battle screen behind explicit detached packets using the
-- staged manifest, so the assertions below test the presentation route
-- itself, never a mocked visual subsystem. The screen build and the
-- arrival on the command view are setup: they pass before the
-- context-specific contract is checked. Contexts whose specialized
-- controls are missing fail on the final assertion only. The link context
-- has no production entry seam, so it has no test expectation yet. Synthetic
-- fixtures only: no dump capability is needed.

local Assert = require("tests.support.Assert")
local BattleScreenState = require("game.hgss.tests.support.BattleScreenFixture")
local CompositionFrameDrain = require("tests.support.CompositionFrameDrain")
local FakeGraphics = require("tests.support.FakeGraphics")
local ItemFixture = require("libs.items.tests.item_fixture")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local SourceTick = require("libs.hgss.src.field.SourceTick")

local T = {}
local TICK = 1 / 60
local DRIVE_BUDGET = 1200

local ORDINARY_IDS = { fight = true, bag = true, pokemon = true, run = true }

---@return table preparation double resolving every key synthetically
local function stubAssets()
  local assets = { images = {} }
  function assets.prepare(_)
    return true
  end
  function assets.drawable(key)
    if assets.images[key] == nil then
      assets.images[key] = { handle = key }
    end
    return assets.images[key]
  end
  function assets.release(_) end
  -- Composition frames drain through the recording boundary so drawn
  -- content stays observable without a GPU.
  function assets.renderPictures(_, drawGraphics, frame)
    CompositionFrameDrain.drain(drawGraphics, frame)
    return { handle = "picture-composite" }
  end
  return assets
end

---@return table recording text boundary
local function recordingText()
  local text = { draws = {} }
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(content, x, y)
    text.draws[#text.draws + 1] = { content = content, x = x, y = y }
  end
  return text
end

---@return table recording window boundary
local function recordingWindows()
  local windows = { calls = {}, background = { 0, 0, 0, 1 } }
  function windows.drawWindow(box, frameKey, background)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey, background = background }
  end
  function windows.drawApplicationFrame(box, frameKey)
    windows.calls[#windows.calls + 1] = { box = box, frame = frameKey }
  end
  return windows
end

---@return table single-surface display facts
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
    signature = "special-context-fixture:compact",
  }
end

---@param launchId string owning launch identity
---@return table live screen plus its presentation port and launch identity
local function openScreen(launchId)
  local audio = { plays = {} }
  function audio.play(name)
    audio.plays[#audio.plays + 1] = name
    return true
  end
  local submitted = {}
  local screen = BattleScreenState.new({
    splRandomState = { state = 0 },
    launchId = launchId,
    manifest = ManifestFixture.launchView(
      { "back:PKMN_TRAINER_ETHAN", "back:PKMN_TRAINER_LYRA", "front:YOUNGSTER" },
      { "ball:POKE_BALL" }
    ),
    model = {},
    submit = function(reply)
      submitted[#submitted + 1] = reply
      return true
    end,
    measureDisplay = compactMeasurement,
    itemCatalog = ItemFixture.makeCatalog(),
    assets = stubAssets(),
    text = recordingText(),
    windows = recordingWindows(),
    audio = audio,
  })
  -- Preparation resolves on fixed updates, so the port acknowledges
  -- entry only after the holder reaches ready: settle first.
  for _ = 1, 10 do
    screen:updateFixed(TICK)
  end
  return { screen = screen, port = screen:presentationPort(), launchId = launchId, submitted = submitted }
end

---@param combatant integer stable battler identity
---@param side integer 1 for own, 2 for foe
---@param species string staged species key
---@param name string displayed name
---@param portrait string exact canonical portrait selector
---@return table detached battler record
local function battlerRecord(combatant, side, species, name, portrait)
  return {
    combatant = combatant,
    participant = combatant,
    side = side,
    controller = side == 1 and "player" or "wild",
    active = true,
    position = combatant,
    activation = combatant,
    hp = 20,
    maxHp = 20,
    species = species,
    form = 0,
    name = name,
    level = 9,
    selector = side == 1 and "back" or "front",
    portraitSelector = portrait,
    moves = {},
    experience = 100,
  }
end

---@param fixture table open screen fixture
---@param choices table[] detached command choices for the acting lead
---@param packetId integer? packet and request sequence, defaulting to the first
local function presentCommandPacket(fixture, choices, packetId)
  local sequence = packetId or 1
  local view = {
    own = { battlerRecord(1, 1, "EEVEE", "LEADA", "EEVEE/0/male/plain/back") },
    foes = { battlerRecord(3, 2, "RATTATA", "FOEX", "RATTATA/0/male/plain/front") },
    playerName = "ETHAN",
    playerTrainer = { classKey = "PKMN_TRAINER_ETHAN", name = "ETHAN" },
  }
  fixture.port.present({
    launchId = fixture.launchId,
    packetId = sequence,
    events = {},
    before = view,
    after = view,
    request = {
      requestId = 6 + sequence,
      epoch = 1,
      controller = "player",
      actors = { { combatant = 1, activation = 1, kind = "command" } },
      options = {
        kind = "command",
        actors = { { combatant = 1, activation = 1, kind = "command", choices = choices } },
      },
    },
  })
end

---@param fixture table open screen fixture under driving
---@param contextName string presentation context under driving, for diagnostics
---@return table command-mode status once the request is exposed
local function driveToCommand(fixture, contextName)
  for _ = 1, DRIVE_BUDGET do
    fixture.screen:updateFixed(TICK)
    local status = fixture.screen:status()
    if status.mode == "failed" then
      error(contextName .. " fixture failed during setup: " .. tostring(status.error), 0)
    end
    if status.mode == "command" and status.request ~= nil then
      return status
    end
  end
  error(contextName .. " fixture never exposed its command request during setup", 0)
end

---@param view table detached public screen view
---@return table<string, boolean> command identity set on the view
local function commandIds(view)
  local ids = {}
  for _, command in ipairs(view.commands or {}) do
    if type(command) == "table" and type(command.id) == "string" then
      ids[command.id] = true
    end
  end
  return ids
end

---@param ids table<string, boolean> command identity set under inspection
---@return boolean true when the surface is exactly the ordinary four-command set
local function isOrdinarySurface(ids)
  for id in pairs(ids) do
    if ORDINARY_IDS[id] ~= true then
      return false
    end
  end
  for id in pairs(ORDINARY_IDS) do
    if ids[id] ~= true then
      return false
    end
  end
  return true
end

---@return table[] ordinary detached command choices with run permitted
local function ordinaryChoices()
  return {
    {
      role = "move",
      id = "move:0",
      enabled = true,
      display = { name = "TACKLE", pp = 35, maxPp = 35, type = "NORMAL" },
      choice = { kind = "attack", actor = { combatant = 1, activation = 1 }, payload = {} },
    },
    {
      role = "run",
      enabled = true,
      choice = { kind = "run", actor = { combatant = 1, activation = 1 }, payload = {} },
    },
  }
end

-- The ordinary wild surface stays available through the fixture route:
-- the setup itself (build, enter, present, command) must keep working
-- while the specialized contexts below fail on their own contracts.
function T.ordinary_command_surface_stays_available_through_the_fixture_route()
  local fixture = openScreen("special-context-ordinary")
  Assert.isTrue(fixture.port.enter({ launchId = fixture.launchId, kind = "wild" }), "setup: the ordinary launch enters")
  presentCommandPacket(fixture, ordinaryChoices())
  local status = driveToCommand(fixture, "ordinary")
  Assert.equal(status.mode, "command", "setup: the ordinary fixture rests on the command view")
  local ids = commandIds(fixture.screen:view())
  Assert.isTrue(isOrdinarySurface(ids), "the ordinary wild launch keeps its four-command surface")
  fixture.screen:dispose()
end

-- The safari presentation must not show the ordinary
-- fight/bag/pokemon/run surface: its native controls use the
-- ball/bait/rock families with ball-count state and no run command.
function T.safari_presentation_uses_its_own_controls()
  local fixture = openScreen("special-context-safari")
  Assert.isTrue(fixture.port.enter({ launchId = fixture.launchId, kind = "safari" }), "setup: the safari launch enters")
  presentCommandPacket(fixture, ordinaryChoices())
  local status = driveToCommand(fixture, "safari")
  Assert.equal(status.mode, "command", "setup: the safari fixture rests on the command view")
  Assert.isTrue(status.request ~= nil, "setup: the safari fixture exposes its decision request")
  local ids = commandIds(fixture.screen:view())
  Assert.isFalse(isOrdinarySurface(ids), "the safari surface never shows the ordinary four-command set")
  fixture.screen:dispose()
end

-- The pal-park presentation must not show the ordinary
-- fight/bag/pokemon/run surface: its native controls use the park-ball
-- family with no run command.
function T.pal_park_presentation_uses_its_own_controls()
  local fixture = openScreen("special-context-pal-park")
  Assert.isTrue(
    fixture.port.enter({ launchId = fixture.launchId, kind = "pal-park" }),
    "setup: the pal-park launch enters"
  )
  presentCommandPacket(fixture, ordinaryChoices())
  local status = driveToCommand(fixture, "pal-park")
  Assert.equal(status.mode, "command", "setup: the pal-park fixture rests on the command view")
  Assert.isTrue(status.request ~= nil, "setup: the pal-park fixture exposes its decision request")
  local ids = commandIds(fixture.screen:view())
  Assert.isFalse(isOrdinarySurface(ids), "the pal-park surface never shows the ordinary four-command set")
  fixture.screen:dispose()
end

-- The bug-contest presentation tracks its remaining park balls and the
-- caught display on the command view instead of the ordinary surface.
function T.bug_contest_presentation_tracks_balls_and_the_caught_display()
  local fixture = openScreen("special-context-bug-contest")
  Assert.isTrue(
    fixture.port.enter({ launchId = fixture.launchId, kind = "bug-contest" }),
    "setup: the bug-contest launch enters"
  )
  presentCommandPacket(fixture, ordinaryChoices())
  local status = driveToCommand(fixture, "bug-contest")
  Assert.equal(status.mode, "command", "setup: the bug-contest fixture rests on the command view")
  Assert.isTrue(status.request ~= nil, "setup: the bug-contest fixture exposes its decision request")
  local ids = commandIds(fixture.screen:view())
  Assert.isFalse(isOrdinarySurface(ids), "the bug-contest surface never shows the ordinary four-command set")
  fixture.screen:dispose()
end

-- The tutorial presentation restricts its command family: the scripted
-- opening never offers the full ordinary decision set.
function T.tutorial_presentation_restricts_its_command_family()
  local fixture = openScreen("special-context-tutorial")
  Assert.isTrue(
    fixture.port.enter({ launchId = fixture.launchId, kind = "tutorial" }),
    "setup: the tutorial launch enters"
  )
  presentCommandPacket(fixture, ordinaryChoices())
  local status = driveToCommand(fixture, "tutorial")
  Assert.equal(status.mode, "command", "setup: the tutorial fixture rests on the command view")
  Assert.isTrue(status.request ~= nil, "setup: the tutorial fixture exposes its decision request")
  local ids = commandIds(fixture.screen:view())
  Assert.isFalse(isOrdinarySurface(ids), "the tutorial surface never shows the ordinary four-command set")
  fixture.screen:dispose()
end

-- The scripted lesson reaches the same tutorial surface behind its
-- marker: a scripted launch carrying the tutorial flag offers only
-- fight and bag, never a new launch kind.
function T.scripted_tutorial_marker_reaches_the_lesson_surface()
  local fixture = openScreen("special-context-scripted-tutorial")
  Assert.isTrue(
    fixture.port.enter({ launchId = fixture.launchId, kind = "scripted", tutorial = true }),
    "setup: the marked scripted launch enters"
  )
  presentCommandPacket(fixture, ordinaryChoices())
  local status = driveToCommand(fixture, "scripted-tutorial")
  Assert.equal(status.mode, "command", "setup: the marked fixture rests on the command view")
  local ids = commandIds(fixture.screen:view())
  Assert.isTrue(ids.fight == true, "the lesson offers its scripted fight")
  Assert.isTrue(ids.bag == true, "the lesson offers its scripted bag")
  Assert.isTrue(ids.pokemon == nil, "the lesson never offers party selection")
  Assert.isTrue(ids.run == nil, "the lesson never offers flight")
  fixture.screen:dispose()
end

-- The lesson finger plays the scripted commands for the player's friend
-- (battle_input.c BattleInput_CatchingTutorialMain): it touches FIGHT and
-- then the first move on the first turn, and BAG on the next after the
-- lesson prompt (battle_controller_opponent.c msg_0197_01226 plus the
-- author's gender, the player's opposite). Each touch lands 76 ticks after
-- the finger arms, and the BAG finger arms 61 ticks after the menu opens.
-- The lesson never reads the player's menu input.
function T.scripted_tutorial_finger_plays_the_lesson_commands()
  local fixture = openScreen("special-context-tutorial-finger")
  Assert.isTrue(
    fixture.port.enter({ launchId = fixture.launchId, kind = "scripted", tutorial = true }),
    "setup: the marked scripted launch enters"
  )
  presentCommandPacket(fixture, ordinaryChoices())
  driveToCommand(fixture, "tutorial-finger")
  local screen = fixture.screen
  -- The friend fights the lesson (BattleSetup_New_Tutorial): the player
  -- side takes the opposite trainer and the gender-selected author name.
  Assert.deepEqual(
    screen:view().playerTrainer,
    { classKey = "PKMN_TRAINER_LYRA", name = "LYRA" },
    "the lesson author stands on the player side"
  )
  local opened = 0
  while not screen:view().menuInputEnabled do
    screen:updateFixed(SourceTick.DT)
    opened = opened + 1
    Assert.isTrue(opened < 30, "setup: the command menu opens")
  end
  Assert.deepEqual(
    screen:view().tutorialFinger,
    { id = "fight", x = 128, y = 59, dy = 0 },
    "the finger arms over FIGHT"
  )
  local graphics = FakeGraphics.new({})
  screen:draw({ graphics = graphics })
  local drawnFinger = false
  for _, drawn in ipairs(graphics.draws) do
    if type(drawn.image) == "table" and drawn.image.handle == "battle:finger" then
      drawnFinger = true
    end
  end
  Assert.isTrue(drawnFinger, "the compact command dock draws the lesson finger")
  local function holdFor(ticks, mode, what)
    for _ = 1, ticks do
      screen:input({ { type = "navigate", direction = "down" }, { type = "cancel" }, { type = "confirm" } })
      Assert.equal(screen:status().mode, mode, what)
      screen:updateFixed(SourceTick.DT)
    end
  end
  holdFor(75, "command", "the finger owns FIGHT until its touch")
  local pressed = 0
  while screen:status().mode == "command" do
    screen:updateFixed(SourceTick.DT)
    pressed = pressed + 1
    Assert.isTrue(pressed < 10, "the finger touches FIGHT")
  end
  Assert.equal(screen:status().mode, "moves", "the touch opens the move menu")
  while not screen:view().menuInputEnabled do
    screen:updateFixed(SourceTick.DT)
  end
  Assert.deepEqual(
    screen:view().tutorialFinger,
    { id = "move:0", x = 64, y = 21, dy = 0 },
    "the finger arms over the first move"
  )
  holdFor(75, "moves", "the finger owns the move menu until its touch")
  pressed = 0
  while #fixture.submitted == 0 do
    screen:updateFixed(SourceTick.DT)
    pressed = pressed + 1
    Assert.isTrue(pressed < 10, "the finger touches the first move")
  end
  Assert.equal(fixture.submitted[1].choices[1].kind, "attack", "the first turn seals the lesson attack")

  presentCommandPacket(fixture, ordinaryChoices(), 2)
  local prompted = nil
  for _ = 1, DRIVE_BUDGET do
    screen:updateFixed(SourceTick.DT)
    if screen:status().mode == "command" and screen:view().menuInputEnabled then
      break
    end
    local message = screen:view().message
    if type(message) == "string" and message:find("Poké Ball", 1, true) then
      prompted = message
    end
  end
  Assert.equal(prompted, "OK! Its HP is down!\nIt’s ready for a Poké Ball!", "the lesson prompt names its author")
  Assert.isNil(screen:view().tutorialFinger, "the BAG finger waits before arming")
  holdFor(61, "command", "the BAG finger waits out its lead")
  Assert.deepEqual(screen:view().tutorialFinger, { id = "bag", x = 40, y = 145, dy = 0 }, "the finger arms over BAG")
  holdFor(75, "command", "the finger owns BAG until its touch")
  pressed = 0
  while screen:status().mode == "command" do
    screen:updateFixed(SourceTick.DT)
    pressed = pressed + 1
    Assert.isTrue(pressed < 10, "the finger touches BAG")
  end
  Assert.equal(screen:status().mode, "child", "the touch opens the lesson bag")
  Assert.equal(screen:view().childView.kind, "bag", "the lesson bag opens")
  screen:dispose()
end

-- A frontier-facility presentation keeps its facility restrictions on
-- the command view instead of silently running ordinary rules.
function T.frontier_facility_presentation_keeps_facility_restrictions()
  local fixture = openScreen("special-context-frontier")
  Assert.isTrue(
    fixture.port.enter({ launchId = fixture.launchId, kind = "frontier" }),
    "setup: the frontier launch enters"
  )
  presentCommandPacket(fixture, ordinaryChoices())
  local status = driveToCommand(fixture, "frontier")
  Assert.equal(status.mode, "command", "setup: the frontier fixture rests on the command view")
  Assert.isTrue(status.request ~= nil, "setup: the frontier fixture exposes its decision request")
  local ids = commandIds(fixture.screen:view())
  Assert.isFalse(isOrdinarySurface(ids), "the frontier surface never shows the ordinary four-command set")
  fixture.screen:dispose()
end

-- Restricted facilities refuse bag items with the retail message
-- (battle_input.c BATTLE_INPUT_BAG prints msg_0197_00593 via
-- EmitPrintSelectionMessage) instead of an invented banner. Frontier and
-- link share the gate; one journey per kind proves the command stays
-- open for another selection.
function T.restricted_bags_refuse_with_their_retail_message()
  for _, case in ipairs({
    { fixture = "special-context-frontier-bag", kind = "frontier", label = "frontier" },
    { fixture = "special-context-link-bag", kind = "link", label = "link" },
  }) do
    local fixture = openScreen(case.fixture)
    Assert.isTrue(
      fixture.port.enter({ launchId = fixture.launchId, kind = case.kind }),
      "setup: the " .. case.label .. " launch enters"
    )
    presentCommandPacket(fixture, ordinaryChoices())
    driveToCommand(fixture, case.label .. "-bag")
    fixture.screen:input({ { type = "navigate", direction = "left" } })
    for _ = 1, 10 do
      fixture.screen:updateFixed(TICK)
    end
    -- The compact 2x2 grid draws Bag right of Fight, so the setup
    -- walk steps right after the reveal edge.
    fixture.screen:input({ { type = "navigate", direction = "right" } })
    for _ = 1, 10 do
      fixture.screen:updateFixed(TICK)
    end
    Assert.equal(
      fixture.screen:view().selection,
      "bag",
      "setup: the " .. case.label .. " cursor rests on Bag"
    )
    fixture.screen:input({ { type = "confirm" } })
    for _ = 1, 10 do
      fixture.screen:updateFixed(TICK)
    end
    local statusAfter = fixture.screen:status()
    local view = fixture.screen:view()
    Assert.equal(statusAfter.mode, "command", "the refused Bag keeps the command open (" .. case.label .. ")")
    Assert.equal(
      view.message,
      "Items can’t be used here.",
      "the " .. case.label .. " Bag refuses with its asset-derived retail message"
    )
    fixture.screen:dispose()
  end
end

return { tests = T }
