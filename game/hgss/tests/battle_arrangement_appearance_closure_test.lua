-- Complete arrangement and appearance coverage through the real cue
-- player and the real battle screen: singles and doubles keep every
-- slot and appearance across entry, action, faint, and replacement;
-- two-trainer foes keep distinct identities; form, gender, and facing
-- ride the displayed record; and exact portrait demands grow when an
-- appearance changes. The setup legs (packet accepted, cues drained)
-- pass before each contract check. Transformed pictures, shiny
-- variants, and corrupt appearance facts fail on their final
-- assertion: the production path keeps the stale picture or stays
-- silent. Synthetic fixtures only: no dump capability is needed.

local Assert = require("tests.support.Assert")
local BattleScreenState = require("game.hgss.src.battle.BattleScreenState")
local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = {}
local TICK = 1 / 30
local SCREEN_TICK = 1 / 60

---@param combatant integer stable battler identity
---@param side integer 1 for own, 2 for foe
---@param species string staged species key
---@param name string displayed name
---@param portrait string exact canonical portrait selector
---@return table detached battler record for screen fixtures
local function battlerRecordFor(combatant, side, species, name, portrait)
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

---@param combatant integer stable battler identity
---@param name string displayed name
---@param species string species key
---@param hp integer current hit points
---@param maxHp integer maximum hit points
---@param own boolean true for the player side
---@return table displayed battler record under test driving
local function entry(combatant, name, species, hp, maxHp, own)
  return {
    combatant = combatant,
    participant = combatant,
    side = own and 1 or 2,
    controller = own and "player" or "wild",
    active = true,
    position = combatant,
    activation = combatant,
    hp = hp,
    maxHp = maxHp,
    species = species,
    form = 0,
    name = name,
    level = 20,
    selector = own and "back" or "front",
    portraitSelector = species .. "/0/male/plain/" .. (own and "back" or "front"),
    moves = own and { { move = "TACKLE", name = "Tackle", pp = 35, maxPp = 35 } } or nil,
    experience = 8000,
  }
end

---@return table detached singles view with one lead and one foe
local function singlesView()
  return {
    round = 1,
    status = "running",
    own = { entry(1, "LEFTY", "EEVEE", 52, 52, true) },
    foes = { entry(3, "FOE-A", "GEODUDE", 45, 45, false) },
    participants = {},
  }
end

---@return table detached doubles view with two leads and two foes
local function doublesView()
  return {
    round = 1,
    status = "running",
    own = {
      entry(1, "LEFTY", "EEVEE", 52, 52, true),
      entry(2, "RIGHTY", "SHINX", 38, 38, true),
    },
    foes = {
      entry(3, "FOE-A", "GEODUDE", 45, 45, false),
      entry(4, "FOE-B", "ZUBAT", 30, 33, false),
    },
    participants = {},
  }
end

---@param battlers table displayed battler facts under inspection
---@param combatant integer stable battler identity under lookup
---@return table the displayed facts for one combatant
local function battler(battlers, combatant)
  for _, record in ipairs(battlers) do
    if record.combatant == combatant then
      return record
    end
  end
  error("no displayed battler " .. tostring(combatant), 0)
end

---@param timeline table cue player under test driving
---@param budget integer maximum source ticks before giving up
local function drain(timeline, budget)
  for _ = 1, budget do
    timeline:update(TICK, function(_)
      return true
    end)
    if timeline:settled() then
      break
    end
  end
end

---@param id integer packet identity under delivery
---@param events table ordered kernel events under delivery
---@param before table detached before view under delivery
---@param after table detached after view under delivery
---@return table delivery-shaped packet
local function packet(id, events, before, after)
  return {
    launchId = "arrangement-probe",
    packetId = id,
    events = events,
    before = before,
    after = after,
    request = nil,
    result = nil,
  }
end

-- A singles journey keeps every slot across entry, action, faint, and
-- replacement: the survivor never moves and the newcomer arrives under
-- its own identity.
function T.singles_slots_survive_entry_action_faint_and_replacement()
  local timeline = BattleTimeline.new({})
  timeline:reset(singlesView())
  local struck = singlesView()
  struck.foes[1].hp = 12
  Assert.isTrue(
    timeline:present(packet(1, {
      {
        sequence = 1,
        kind = "struck",
        cause = { key = "TACKLE" },
        audience = "public",
        actors = { { combatant = 1 } },
        targets = { { combatant = 3 } },
        move = { executed = "TACKLE" },
        payload = { target = 3, damage = 33 },
        after = { hp = { [1] = 52, [3] = 12 } },
      },
    }, singlesView(), struck)),
    "setup: the action packet is accepted"
  )
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "setup: the action drains fully")
  Assert.equal(battler(timeline:battlers(), 3).hp, 12, "the action checkpoint lands on the foe")
  Assert.equal(battler(timeline:battlers(), 1).hp, 52, "the acting lead never moves")
  local fainted = singlesView()
  fainted.foes[1].hp = 0
  Assert.isTrue(
    timeline:present(packet(2, {
      {
        sequence = 2,
        kind = "faint",
        cause = { key = "TACKLE" },
        audience = "public",
        payload = { combatant = 3, activation = 3, position = 3 },
        after = { hp = { [1] = 52, [3] = 0 } },
      },
    }, struck, fainted)),
    "setup: the faint packet is accepted"
  )
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "setup: the faint drains fully")
  Assert.isFalse(battler(timeline:battlers(), 3).visible, "the fainted foe hides")
  Assert.isTrue(battler(timeline:battlers(), 1).visible, "the surviving lead never leaves")
  local relief = singlesView()
  relief.foes[1] = entry(4, "FOE-B", "ZUBAT", 30, 33, false)
  Assert.isTrue(
    timeline:present(packet(3, {
      {
        sequence = 3,
        kind = "switch",
        cause = { key = "SEND" },
        audience = "public",
        payload = { from = 3, to = 4 },
        after = { hp = { [1] = 52, [4] = 30 } },
      },
    }, fainted, relief)),
    "setup: the replacement packet is accepted"
  )
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "setup: the replacement drains fully")
  Assert.isTrue(battler(timeline:battlers(), 4).visible, "the relief arrives under its own identity")
  Assert.equal(battler(timeline:battlers(), 4).species, "ZUBAT", "the relief keeps its own appearance")
  Assert.equal(battler(timeline:battlers(), 1).hp, 52, "the surviving lead still never moves")
  Assert.equal(battler(timeline:battlers(), 1).side, 1, "the surviving lead keeps its side")
end

-- A doubles switch moves only the affected slot: the partner and both
-- foes keep their health, visibility, and identities.
function T.doubles_switch_moves_only_the_affected_slot()
  local timeline = BattleTimeline.new({})
  timeline:reset(doublesView())
  local after = doublesView()
  after.own[1] = entry(5, "BACKUP", "STARLY", 40, 40, true)
  after.own[1].position = 1
  after.own[1].activation = 5
  Assert.isTrue(
    timeline:present(packet(1, {
      {
        sequence = 1,
        kind = "switch",
        cause = { key = "SWITCH" },
        audience = "public",
        payload = { from = 1, to = 5 },
        after = { hp = { [1] = 52, [2] = 38, [3] = 45, [4] = 30 } },
      },
    }, doublesView(), after)),
    "setup: the doubles switch packet is accepted"
  )
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "setup: the withdrawal and reveal complete")
  Assert.isFalse(battler(timeline:battlers(), 1).visible, "the departed slot hides")
  Assert.isTrue(battler(timeline:battlers(), 5).visible, "the incoming slot reveals")
  Assert.isTrue(battler(timeline:battlers(), 2).visible, "the surviving partner never leaves")
  Assert.equal(battler(timeline:battlers(), 2).hp, 38, "the surviving partner keeps its health")
  Assert.equal(battler(timeline:battlers(), 2).species, "SHINX", "the surviving partner keeps its appearance")
  Assert.equal(battler(timeline:battlers(), 4).hp, 30, "the far foe never moves")
  Assert.equal(battler(timeline:battlers(), 3).side, 2, "the near foe keeps its side")
end

-- Two simultaneous trainers field two distinct foes: fainting one
-- never disturbs the other, and each keeps its own name and picture.
function T.two_trainer_foes_keep_distinct_identities()
  local timeline = BattleTimeline.new({})
  timeline:reset(doublesView())
  local fainted = doublesView()
  fainted.foes[1].hp = 0
  Assert.isTrue(
    timeline:present(packet(1, {
      {
        sequence = 1,
        kind = "faint",
        cause = { key = "TACKLE" },
        audience = "public",
        payload = { combatant = 3, activation = 3, position = 3 },
        after = { hp = { [1] = 52, [2] = 38, [3] = 0, [4] = 30 } },
      },
    }, doublesView(), fainted)),
    "setup: the first-trainer faint is accepted"
  )
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "setup: the faint drains fully")
  Assert.isFalse(battler(timeline:battlers(), 3).visible, "the first trainer's battler hides")
  Assert.isTrue(battler(timeline:battlers(), 4).visible, "the second trainer's battler stays")
  Assert.equal(battler(timeline:battlers(), 4).name, "FOE-B", "the second trainer's battler keeps its name")
  Assert.equal(
    battler(timeline:battlers(), 4).portraitSelector,
    "ZUBAT/0/male/plain/front",
    "the second trainer's battler keeps its own picture"
  )
  Assert.isTrue(
    battler(timeline:battlers(), 4).portraitSelector ~= battler(timeline:battlers(), 3).portraitSelector,
    "the two trainers never share a picture identity"
  )
end

-- Form, gender, and facing ride the displayed record so the picture
-- and height owners can resolve the exact appearance.
function T.form_gender_and_facing_ride_the_displayed_record()
  local timeline = BattleTimeline.new({})
  local view = singlesView()
  view.foes[1].form = 1
  view.foes[1].gender = "female"
  view.foes[1].portraitSelector = "GEODUDE/1/female/plain/front"
  timeline:reset(view)
  local shown = battler(timeline:battlers(), 3)
  Assert.equal(shown.form, 1, "the displayed foe keeps its form")
  Assert.equal(shown.gender, "female", "the displayed foe keeps its gender")
  Assert.equal(
    shown.portraitSelector,
    "GEODUDE/1/female/plain/front",
    "the displayed foe keeps its exact picture selector"
  )
  local lead = battler(timeline:battlers(), 1)
  Assert.isTrue(
    tostring(lead.portraitSelector):sub(-5) == "/back",
    "the own picture selector keeps its back facing"
  )
  Assert.isTrue(
    tostring(shown.portraitSelector):sub(-6) == "/front",
    "the foe picture selector keeps its front facing"
  )
end

-- The screen grows its exact portrait demand when one combatant's
-- appearance changes without leaving: the new selector is demanded
-- and no shorthand or side-aliased key appears.
function T.screen_grows_exact_demand_when_an_appearance_changes()
  local launchId = "appearance-demand-probe"
  local prepared = {}
  local assets = { images = {} }
  function assets.prepare(demand)
    prepared[#prepared + 1] = demand
    return true
  end
  function assets.drawable(key)
    if assets.images[key] == nil then
      assets.images[key] = { handle = key }
    end
    return assets.images[key]
  end
  function assets.release(_) end
  local text = {}
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(_) end
  local windows = {}
  function windows.drawWindow(_, _, _) end
  function windows.drawApplicationFrame(_, _) end
  local audio = {}
  function audio.play(_)
    return true
  end
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = ManifestFixture.manifest(),
    model = {},
    submit = function(_)
      return true
    end,
    measureDisplay = function()
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
        signature = "appearance-demand-probe:compact",
      }
    end,
    assets = assets,
    text = text,
    windows = windows,
    audio = audio,
  })
  local port = screen:presentationPort()
  local function hasPage(want)
    for _, demand in ipairs(prepared) do
      for _, page in ipairs(demand.pages or {}) do
        if page == want then
          return true
        end
      end
    end
    return false
  end
  local function pump(ticks)
    for _ = 1, ticks do
      screen:updateFixed(SCREEN_TICK)
    end
    local status = screen:status()
    if status.mode == "failed" then
      error("the appearance screen failed: " .. tostring(status.error), 0)
    end
  end
  local beforeSelector = "EEVEE/0/male/plain/back"
  local afterSelector = "EEVEE/1/male/plain/back"
  local function viewWith(selector)
    local record = battlerRecordFor(1, 1, "EEVEE", "LEADA", selector)
    record.form = selector == afterSelector and 1 or 0
    return {
      own = { record },
      foes = { battlerRecordFor(3, 2, "RATTATA", "FOEX", "RATTATA/0/male/plain/front") },
    }
  end
  for _ = 1, 10 do
    screen:updateFixed(SCREEN_TICK)
  end
  Assert.isTrue(port.enter({ launchId = launchId, kind = "wild" }), "setup: the appearance launch enters")
  port.present({ launchId = launchId, packetId = 1, events = {}, before = viewWith(beforeSelector), after = viewWith(beforeSelector) })
  pump(400)
  Assert.isTrue(hasPage(beforeSelector), "setup: the opening demands the initial appearance selector")
  port.present({ launchId = launchId, packetId = 2, events = {}, before = viewWith(beforeSelector), after = viewWith(afterSelector) })
  pump(400)
  Assert.isTrue(hasPage(afterSelector), "the changed appearance grows the exact demand")
  screen:dispose()
end

-- A transformed battler must draw the donor's appearance, not the
-- stale pre-transform picture: once the transform event is accepted,
-- the displayed record has to carry the donor's picture selector.
function T.transformed_appearance_replaces_the_stale_picture()
  local timeline = BattleTimeline.new({})
  local view = singlesView()
  view.own[1].portraitSelector = "EEVEE/0/male/plain/back"
  view.foes[1].species = "GEODUDE"
  view.foes[1].portraitSelector = "GEODUDE/0/male/plain/front"
  timeline:reset(view)
  Assert.isTrue(
    timeline:present(packet(1, {
      {
        sequence = 1,
        kind = "transformed",
        cause = { key = "TRANSFORM" },
        audience = "public",
        payload = { target = 1, copiedFrom = 3 },
      },
    }, view, view)),
    "setup: the transform packet is accepted"
  )
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "setup: the transform drains fully")
  local shown = battler(timeline:battlers(), 1)
  Assert.equal(shown.species, "GEODUDE", "setup: the displayed species tracks the donor")
  Assert.equal(
    shown.portraitSelector,
    "GEODUDE/0/male/plain/front",
    "the transformed battler draws the donor picture, never the stale one"
  )
end

-- Shiny variants must resolve distinct picture resources: two
-- battlers sharing a species but not a shiny state never share one
-- picture demand.
function T.shiny_variants_resolve_distinct_picture_resources()
  local launchId = "shiny-demand-probe"
  local prepared = {}
  local assets = { images = {} }
  function assets.prepare(demand)
    prepared[#prepared + 1] = demand
    return true
  end
  function assets.drawable(key)
    if assets.images[key] == nil then
      assets.images[key] = { handle = key }
    end
    return assets.images[key]
  end
  function assets.release(_) end
  local text = {}
  function text.measure(content)
    return { width = 8 * #tostring(content), height = 16 }
  end
  function text.drawText(_) end
  local windows = {}
  function windows.drawWindow(_, _, _) end
  function windows.drawApplicationFrame(_, _) end
  local audio = {}
  function audio.play(_)
    return true
  end
  local screen = BattleScreenState.new({
    launchId = launchId,
    manifest = ManifestFixture.manifest(),
    model = {},
    submit = function(_)
      return true
    end,
    measureDisplay = function()
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
        signature = "shiny-demand-probe:compact",
      }
    end,
    assets = assets,
    text = text,
    windows = windows,
    audio = audio,
  })
  local port = screen:presentationPort()
  local function pages()
    local found = {}
    for _, demand in ipairs(prepared) do
      for _, page in ipairs(demand.pages or {}) do
        found[#found + 1] = page
      end
    end
    return found
  end
  local function hasEeveePage(found)
    for _, page in ipairs(found) do
      if page == "EEVEE/0/male/plain/back" then
        return true
      end
    end
    return false
  end
  local function hasPage(found, want)
    for _, page in ipairs(found) do
      if page == want then
        return true
      end
    end
    return false
  end
  local function countEeveePages(found)
    local count = 0
    for _, page in ipairs(found) do
      if tostring(page):match("^EEVEE/") ~= nil then
        count = count + 1
      end
    end
    return count
  end
  local function pump(ticks)
    for _ = 1, ticks do
      screen:updateFixed(SCREEN_TICK)
    end
    local status = screen:status()
    if status.mode == "failed" then
      error("the shiny screen failed: " .. tostring(status.error), 0)
    end
  end
  local plain = battlerRecordFor(1, 1, "EEVEE", "PLAIN", "EEVEE/0/male/plain/back")
  plain.shiny = false
  local shiny = battlerRecordFor(2, 1, "EEVEE", "SHINY", "EEVEE/0/male/plain/back")
  shiny.shiny = true
  shiny.position = 2
  shiny.activation = 2
  local view = {
    own = { plain, shiny },
    foes = { battlerRecordFor(3, 2, "RATTATA", "FOEX", "RATTATA/0/male/plain/front") },
  }
  for _ = 1, 10 do
    screen:updateFixed(SCREEN_TICK)
  end
  Assert.isTrue(port.enter({ launchId = launchId, kind = "wild" }), "setup: the shiny launch enters")
  port.present({ launchId = launchId, packetId = 1, events = {}, before = view, after = view })
  pump(400)
  Assert.isTrue(hasEeveePage(pages()), "setup: the shared selector is demanded")
  Assert.isTrue(hasPage(pages(), "RATTATA/0/male/plain/front"), "setup: the foe selector is demanded")
  Assert.isTrue(
    countEeveePages(pages()) >= 2,
    "the plain and shiny battlers never share one picture demand"
  )
  screen:dispose()
end

-- Corrupt appearance facts fail diagnostically instead of rendering a
-- plausible battler: an unknown gender and a negative form must not
-- be silently dropped.
function T.corrupt_appearance_facts_fail_diagnostically()
  local timeline = BattleTimeline.new({})
  local view = singlesView()
  Assert.isTrue(pcall(timeline.reset, timeline, view), "setup: the valid view resets cleanly")
  local bad = singlesView()
  bad.foes[1].gender = "unknown-gender"
  bad.foes[1].form = -1
  Assert.isFalse(
    pcall(timeline.reset, timeline, bad),
    "corrupt appearance facts never reset silently"
  )
end

return { tests = T }
