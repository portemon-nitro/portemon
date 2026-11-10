-- Battle child composition ownership: the private composition module builds
-- every concrete child application with battle-local data and command
-- adapters over the real application mechanisms, never the field host.
-- Selection results translate native application outcomes into the exact
-- authoritative option payload, stale selections translate to nothing, and
-- detached snapshots stay untouched no matter how the child is driven.

local Assert = require("tests.support.Assert")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local ItemFixture = require("libs.items.tests.item_fixture")

local BattleChildApplications = require("game.hgss.src.battle.BattleChildApplications")

local T = {}

---@return table<integer, table<string, unknown>> detached own-party snapshot
local function twoEeveeRoster()
  return {
    { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 30, maxHp = 30 },
    { combatant = 2, slot = 1, name = "BACK", level = 5, hp = 10, maxHp = 18 },
  }
end

---@param replacement integer stable combatant identity of the eligible reserve
---@return table<string, unknown> detached action options projecting one reserve switch
local function switchOptions(replacement)
  return {
    requestId = 7,
    epoch = 3,
    controller = "player",
    kind = "action",
    actors = {
      {
        combatant = 1,
        activation = 5,
        kind = "action",
        choices = {
          {
            id = "switch:" .. tostring(replacement),
            role = "switch",
            enabled = true,
            reason = "refused",
            display = { combatant = replacement },
            choice = {
              actor = { combatant = 1, activation = 5 },
              kind = "switch",
              payload = { replacement = replacement },
            },
          },
        },
      },
    },
  }
end

---@param key string staged item identity under projection
---@param holder integer choice target combatant under projection
---@return table<string, unknown> native item choice for the synthetic options
local function itemChoice(key, holder)
  return {
    id = "item:" .. key .. ":" .. tostring(holder),
    role = "item",
    enabled = true,
    reason = "refused",
    display = { item = key },
    choice = {
      actor = { combatant = 1, activation = 5 },
      kind = "item",
      payload = { item = key, target = { kind = "combatant", combatant = holder } },
    },
  }
end

---@param inventory table<string, integer> detached battle stock under test preparation
---@return table<string, unknown> bag selection intent for the synthetic request
local function bagIntent(inventory)
  return {
    kind = "bag",
    purpose = "bag",
    launchId = "launch-composer-child",
    requestId = 7,
    epoch = 3,
    controller = "player",
    cancellable = true,
    request = { requestId = 7, epoch = 3, controller = "player", kind = "action" },
    options = {
      requestId = 7,
      epoch = 3,
      controller = "player",
      kind = "action",
      actors = { { combatant = 1, activation = 5, kind = "action", choices = { itemChoice("POTION", 1) } } },
    },
    party = twoEeveeRoster(),
    inventory = inventory,
  }
end

---@param recipient integer roster-bound learning recipient under test preparation
---@return table<string, unknown> learning intent for the synthetic request
local function learnIntent(recipient)
  local moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "TAIL_WHIP", pp = 30, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "LEER", pp = 30, ppUps = 0 },
  }
  local choices = {}
  for slot = 0, 3 do
    choices[#choices + 1] = {
      id = "learn:replace:" .. tostring(slot),
      role = "learn",
      enabled = true,
      reason = "refused",
      display = { move = "MOVE" .. tostring(slot) },
      choice = {
        actor = { combatant = recipient },
        kind = "confirm",
        payload = { decision = "replace", slot = slot },
      },
    }
  end
  choices[#choices + 1] = {
    id = "learn:decline",
    role = "learn",
    enabled = true,
    reason = "refused",
    display = { decision = "decline" },
    choice = {
      actor = { combatant = recipient },
      kind = "confirm",
      payload = { decision = "decline" },
    },
  }
  return {
    kind = "learn",
    purpose = "learn",
    launchId = "launch-composer-child",
    requestId = 11,
    epoch = 4,
    controller = "player",
    cancellable = false,
    request = {
      requestId = 11,
      epoch = 4,
      controller = "player",
      kind = "learn_move",
      incomingMove = "SAND_ATTACK",
      currentMoves = moves,
      actors = { { combatant = recipient } },
    },
    options = {
      requestId = 11,
      epoch = 4,
      controller = "player",
      kind = "learn_move",
      actors = {
        {
          combatant = recipient,
          kind = "learn_move",
          incomingMove = "SAND_ATTACK",
          currentMoves = moves,
          choices = choices,
        },
      },
    },
    party = twoEeveeRoster(),
    inventory = {},
  }
end

-- Copies one detached roster without sharing mutable state.
---@param roster table<integer, table<string, unknown>> detached roster under copying
---@return table<integer, table<string, unknown>> detached copy
local function copyRoster(roster)
  local out = {}
  for index, record in ipairs(roster) do
    local cell = {}
    for key, value in pairs(record) do
      cell[key] = value
    end
    out[index] = cell
  end
  return out
end

---@return table<string, unknown> naming intent for the synthetic captured subject
local function namingIntent()
  return {
    kind = "naming",
    purpose = "nickname",
    launchId = "launch-composer-child",
    requestId = 13,
    epoch = 5,
    controller = "player",
    cancellable = true,
    subject = { species = 25 },
    request = { requestId = 13, epoch = 5, controller = "player", kind = "nickname" },
    options = {
      requestId = 13,
      epoch = 5,
      controller = "player",
      kind = "nickname",
      actors = { { combatant = 1, activation = 5, kind = "nickname", choices = {} } },
    },
    party = {
      { combatant = 1, slot = 0, name = "LEAD", level = 20, hp = 30, maxHp = 30 },
    },
    inventory = {},
  }
end

---@return table<string, unknown> naming intent without its committed subject
local function namingIntentWithoutSubject()
  local intent = namingIntent()
  intent.subject = nil
  return intent
end

function T.unknown_kinds_fail_their_boundary()
  local child, openErr = BattleChildApplications.open({ kind = "atlas" }, {})
  Assert.isNil(child, "unknown child kinds compose nothing")
  Assert.isTrue(type(openErr) == "string" and openErr ~= "", "the boundary names itself")
end

function T.missing_barrier_identity_composes_nothing()
  local child, openErr = BattleChildApplications.open({}, {})
  Assert.isNil(child, "identity-free intents compose nothing")
  Assert.isTrue(type(openErr) == "string" and openErr ~= "", "the boundary names itself")
end

function T.bag_child_stages_value_only_intents_over_detached_stock()
  local catalog = ItemFixture.makeCatalog()
  local inventory = { POTION = 5 }
  local child, openErr = BattleChildApplications.open(bagIntent(inventory), { itemCatalog = catalog })
  Assert.notNil(child, "the stocked bag composes: " .. tostring(openErr))
  assert(child ~= nil, "the bag child composes")
  Assert.equal(child:application(), "bag", "the bag child carries its native receipt")
  Assert.isNil(child:takeResult(), "opening consumes the initiating edge: nothing is staged")
  Assert.equal(child:draw().bagPage, "pocket_menu", "the bag opens on its pocket menu")
  child:input({ { type = "tap", id = "bagpocket:0" } })
  child:stepSourceTick(1)
  child:stepSourceTick(1)
  child:stepSourceTick(1)
  Assert.equal(child:draw().bagPage, "item_list", "selecting a pocket opens its item list")
  child:input({ { type = "confirm" } })
  child:stepSourceTick(1)
  child:stepSourceTick(1)
  child:stepSourceTick(1)
  Assert.equal(child:draw().state, "use_item", "selecting a cell opens the use-item page")
  Assert.equal(child:draw().bagPage, "use_item", "selecting a cell opens the use-item page")
  child:input({ { type = "confirm" } })
  for _ = 1, 8 do
    child:stepSourceTick(1)
  end
  local native = child:status().native
  Assert.notNil(native, "the native bag application answers its own selection")
  Assert.equal(native.kind, "battle_select", "the native intent selects without mutating")
  Assert.equal(native.item, "POTION", "the native intent names the stocked key")
  Assert.isNil(child:takeResult(), "the composed bag never seals a barrier reply on its own")
  Assert.deepEqual(inventory, { POTION = 5 }, "browsing and staging never mutate the detached stock")
  child:dispose()
  child:input({ { type = "confirm" } })
  Assert.isNil(child:takeResult(), "a disposed child seals nothing")
end

function T.empty_stock_composes_a_resting_browser_without_sealing()
  local catalog = ItemFixture.makeCatalog()
  local child, openErr = BattleChildApplications.open(bagIntent({}), { itemCatalog = catalog })
  Assert.notNil(child, "the empty bag composes: " .. tostring(openErr))
  assert(child ~= nil, "the empty bag child composes")
  Assert.equal(child:application(), "bag", "the resting browser carries its native receipt")
  Assert.equal(child:draw().bagPage, "pocket_menu", "the empty bag opens on its pocket menu")
  child:input({ { type = "confirm" } })
  child:stepSourceTick(1)
  child:stepSourceTick(1)
  child:stepSourceTick(1)
  Assert.equal(child:draw().bagPage, "item_list", "confirming an empty pocket lists nothing")
  Assert.isNil(child:takeResult(), "confirming an empty browser stages nothing")
  child:input({ { type = "cancel" } })
  child:stepSourceTick(1)
  child:stepSourceTick(1)
  child:stepSourceTick(1)
  Assert.equal(child:draw().bagPage, "pocket_menu", "list cancel returns to the pocket menu")
  child:input({ { type = "cancel" } })
  local result = child:takeResult()
  Assert.notNil(result, "cancelling the empty browser answers")
  assert(result ~= nil, "the empty cancel seals")
  Assert.equal(result.kind, "cancelled", "empty cancel reports a navigation cancellation")
  Assert.isNil(child:takeResult(), "the cancellation reports exactly once")
  child:dispose()
end

function T.evolution_child_wraps_the_native_presentation_state()
  local catalog = CatalogFixture.makeCatalog()
  local mon = {
    species = "EEVEE",
    form = 0,
    personality = 0,
    experience = 1000,
    moves = {},
  }
  local intent = {
    kind = "evolution",
    purpose = "evolution",
    launchId = "launch-composer-child",
    requestId = 17,
    epoch = 7,
    controller = "player",
    cancellable = false,
    subject = mon,
    context = { trigger = { kind = "level" }, timeOfDay = "day", party = {}, inventory = {} },
    request = { requestId = 17, epoch = 7, controller = "player", kind = "evolution" },
    options = { requestId = 17, epoch = 7, controller = "player", kind = "evolution", actors = {} },
  }
  local child, openErr = BattleChildApplications.open(intent, { monCatalog = catalog })
  Assert.notNil(child, "evolution composes through its native state: " .. tostring(openErr))
  assert(child ~= nil, "the evolution child composes")
  Assert.equal(child:application(), "evolution", "the evolution child carries its native receipt")
  Assert.notNil(child:takeResult(), "the settled sequence answers its choice")
  Assert.isNil(child:takeResult(), "the settled choice reports exactly once")
  local missing, missingErr = BattleChildApplications.open(intent, {})
  Assert.isNil(missing, "evolution without its catalog composes nothing")
  Assert.isTrue(type(missingErr) == "string" and missingErr ~= "", "the boundary names the catalog")
  local clockless = {
    kind = "evolution",
    purpose = "evolution",
    launchId = "launch-composer-child",
    requestId = 17,
    epoch = 7,
    controller = "player",
    cancellable = false,
    subject = mon,
    context = { trigger = { kind = "level" }, party = {}, inventory = {} },
    request = { requestId = 17, epoch = 7, controller = "player", kind = "evolution" },
    options = { requestId = 17, epoch = 7, controller = "player", kind = "evolution", actors = {} },
  }
  local timeless, timelessErr = BattleChildApplications.open(clockless, { monCatalog = catalog })
  Assert.isNil(timeless, "evolution without its frozen clock composes nothing")
  Assert.isTrue(type(timelessErr) == "string" and timelessErr ~= "", "the boundary names the clock")
  child:dispose()
  child:dispose()
end

function T.evolution_cursor_runs_while_hidden_and_keeps_the_source_selection_pose()
  local root = CatalogFixture.buildAssetRoot()
  local species = root.species
  species.CHIKORITA.forms[0].evolutions = {
    { method = "level", level = 16, target = "TOTODILE", form = 0 },
  }
  local targetMoves = species.TOTODILE.forms[0].levelUpMoves
  targetMoves[#targetMoves + 1] = { level = 16, move = "SCRATCH" }
  local MonCatalog = require("libs.mons.src.MonCatalog")
  local catalog = MonCatalog.new(root, CatalogFixture.makeItemCatalog())
  local mon = CatalogFixture.makeFactory(0xE0010001, catalog)
    :createNormal(CatalogFixture.normalRequest({ species = "CHIKORITA", level = 16 }))
  mon.moves = {
    { move = "TACKLE", pp = 35, ppUps = 0 },
    { move = "GROWL", pp = 40, ppUps = 0 },
    { move = "RAZOR_LEAF", pp = 25, ppUps = 0 },
    { move = "POISONPOWDER", pp = 35, ppUps = 0 },
  }
  local function cursorFrame(sourceFrame, durationTicks)
    return {
      sourceFrame = sourceFrame,
      durationTicks = durationTicks,
      drawableKey = "battle:evolution-cursor:test:" .. sourceFrame,
      rasterOffset = { x = 0, y = 0 },
    }
  end
  local intent = {
    kind = "evolution",
    purpose = "evolution",
    launchId = "evolution-cursor-clock",
    requestId = 18,
    epoch = 8,
    controller = "player",
    cancellable = true,
    subject = mon,
    context = { trigger = { kind = "level" }, timeOfDay = "day", party = {}, inventory = {} },
    request = { requestId = 18, epoch = 8, controller = "player", kind = "evolution" },
    options = { requestId = 18, epoch = 8, controller = "player", kind = "evolution", actors = {} },
  }
  local child, openErr = BattleChildApplications.open(intent, {
    monCatalog = catalog,
    evolutionCursor = {
      idle = { playMode = "forward_loop", loopStartFrameIdx = 0, frames = { cursorFrame(11, 2), cursorFrame(12, 3) } },
      select = { playMode = "forward", frames = { cursorFrame(13, 1), cursorFrame(14, 1) } },
    },
  })
  assert(child ~= nil, tostring(openErr))
  local ticks = 0
  local heldPrinter = false
  local function advanceUntil(predicate)
    for _ = 1, 400 do
      local status = child:status()
      if status.palettePending == true then
        local channels = status.paletteChannels
        local channel = channels.scene ~= nil and "scene" or "pictures"
        child:completePaletteFade(channel, assert(channels[channel]))
      end
      if child:status().printerPending == true and not heldPrinter then
        heldPrinter = true
        for _ = 1, 4 do
          child:stepPresentationSourceTick(1)
          child:stepSourceTick(1)
          ticks = ticks + 1
        end
      end
      if child:status().printerPending == true then
        child:completeMessage()
      end
      child:stepPresentationSourceTick(1)
      child:stepSourceTick(1)
      ticks = ticks + 1
      local view = child:draw()
      if predicate(view) then
        return view
      end
    end
    error("the evolution cursor test never reached its requested menu")
  end
  local firstMenu = advanceUntil(function(view)
    return type(view.learnMenu) == "table"
  end)
  local idleFrame = (ticks % 5) < 2 and 11 or 12
  Assert.equal(firstMenu.learnMenu.cursor.role, "idle", "the first menu reveals the scene's original idle animation")
  Assert.equal(firstMenu.learnMenu.cursor.sourceFrame, idleFrame, "the hidden idle cursor has kept its source age")
  child:input({ { type = "navigate", direction = "down" } })
  child:input({ { type = "confirm" } })
  local stopMenu = advanceUntil(function(view)
    return type(view.learnMenu) == "table" and view.learnMenu.kind == "stop"
  end)
  Assert.equal(stopMenu.learnMenu.cursor.role, "select", "ShowMenu reveals the completed source selection animation")
  Assert.equal(stopMenu.learnMenu.cursor.sourceFrame, 14, "ShowMenu does not restart the cursor idle animation")
  child:dispose()
end

function T.bag_child_needs_its_item_catalog()
  local child, openErr = BattleChildApplications.open(bagIntent({ POTION = 5 }), {})
  Assert.isNil(child, "catalog-free stock composes no native bag")
  Assert.isTrue(type(openErr) == "string" and openErr ~= "", "the boundary names the catalog")
end

function T.party_child_translates_native_selections_into_kernel_fragments()
  local options = switchOptions(2)
  local intent = {
    kind = "party",
    purpose = "switch",
    launchId = "launch-composer-child",
    requestId = 7,
    epoch = 3,
    controller = "player",
    cancellable = true,
    request = { requestId = 7, epoch = 3, controller = "player", kind = "action" },
    options = options,
    party = twoEeveeRoster(),
    inventory = {},
  }
  local rosterCopy = copyRoster(twoEeveeRoster())
  local child, openErr = BattleChildApplications.open(intent, {})
  Assert.notNil(child, "the voluntary party composes: " .. tostring(openErr))
  assert(child ~= nil, "the party child composes")
  Assert.equal(child:application(), "party", "the party child carries its native receipt")
  Assert.isNil(child:takeResult(), "opening consumes the initiating edge: nothing is staged")
  child:input({ { type = "navigate", direction = "down" } })
  child:input({ { type = "confirm" } })
  Assert.equal(child:draw().state, "context", "the selected mon opens the native party action menu")
  child:input({ { type = "confirm" } })
  for _ = 1, 12 do
    child:stepSourceTick(1)
  end
  local result = child:takeResult()
  Assert.notNil(result, "the native selection translates into a bound result")
  assert(result ~= nil, "the translated result seals")
  Assert.equal(result.kind, "choice", "the native selection stages a choice")
  Assert.deepEqual(
    result.reply.choices[1],
    options.actors[1].choices[1].choice,
    "the translation copies the projected fragment"
  )
  Assert.isNil(child:takeResult(), "the translated result reports exactly once")
  Assert.deepEqual(twoEeveeRoster(), rosterCopy, "selection never touches the detached roster")
  child:dispose()
end

function T.party_child_refuses_stale_slots_without_inventing_replies()
  local intent = {
    kind = "party",
    purpose = "switch",
    launchId = "launch-composer-child",
    requestId = 7,
    epoch = 3,
    controller = "player",
    cancellable = true,
    request = { requestId = 7, epoch = 3, controller = "player", kind = "action" },
    options = switchOptions(2),
    party = twoEeveeRoster(),
    inventory = {},
  }
  local child, openErr = BattleChildApplications.open(intent, {})
  Assert.notNil(child, "the voluntary party composes: " .. tostring(openErr))
  assert(child ~= nil, "the party child composes")
  Assert.isNil(child:translateSelection(5), "an empty slot translates to nothing")
  Assert.isNil(child:takeResult(), "an untranslated tap seals nothing")
  child:dispose()
end

function T.learn_child_reports_native_summary_facts_and_translates_moves()
  local child, openErr = BattleChildApplications.open(learnIntent(1), {})
  Assert.notNil(child, "move learning composes: " .. tostring(openErr))
  assert(child ~= nil, "the learning child composes")
  Assert.equal(child:application(), "summary", "the learning child carries its native summary receipt")
  local facts = child:moveFacts()
  Assert.equal(#facts, 4, "four held rows carry detail facts")
  Assert.equal(facts[1].move, "TACKLE", "the first held fact names its move")
  Assert.equal(facts[1].pp, 35, "the first held fact carries its PP")
  Assert.isFalse(facts[1].incoming == true, "held facts mark only the incoming move")
  child:input({ { type = "confirm" } })
  local result = child:takeResult()
  Assert.notNil(result, "the native move selection translates into a bound result")
  assert(result ~= nil, "the translated result seals")
  Assert.deepEqual(
    result.reply.choices[1].payload,
    { decision = "replace", slot = 0 },
    "the translation binds the first held slot"
  )
  Assert.isNil(child:takeResult(), "the translated result reports exactly once")
  local decline = child:translateSelection(4)
  Assert.notNil(decline, "the decline row translates through the composer")
  assert(decline ~= nil, "the decline fragment resolves")
  Assert.equal(decline.payload.decision, "decline", "the decline translation declines without replacing")
  Assert.isNil(child:translateSelection(9), "an out-of-range slot translates to nothing")
  child:dispose()
end

function T.naming_child_requires_its_committed_subject()
  local missing, missingErr = BattleChildApplications.open(namingIntentWithoutSubject(), {})
  Assert.isNil(missing, "subject-free naming composes nothing")
  Assert.isTrue(type(missingErr) == "string" and missingErr ~= "", "the boundary names the subject")
  local intent = namingIntent()
  intent.subject = { species = 0 }
  local bad, badErr = BattleChildApplications.open(intent, {})
  Assert.isNil(bad, "species-free naming composes nothing")
  Assert.isTrue(type(badErr) == "string" and badErr ~= "", "the boundary names the species")
end

---@return table<string, unknown> naming intent without its committed subject
function T.naming_child_seals_entered_text_exactly_once()
  local child, openErr = BattleChildApplications.open(namingIntent(), {})
  Assert.notNil(child, "capture naming composes: " .. tostring(openErr))
  assert(child ~= nil, "the naming child composes")
  Assert.equal(child:application(), "naming", "the naming child carries its native receipt")
  Assert.equal(child:namingText(), "", "the capture starts from the empty default")
  child:input({ { type = "text", text = "AB" } })
  Assert.equal(child:namingText(), "AB", "the native screen accepts text")
  Assert.isNil(child:takeResult(), "entry alone seals nothing")
  child:input({ { type = "name_control", id = "ok" } })
  local result = child:takeResult()
  Assert.notNil(result, "submitting seals the entered text")
  assert(result ~= nil, "the sealed naming result seals")
  Assert.equal(result.kind, "choice", "naming seals a choice")
  Assert.deepEqual(result.choice, { kind = "nickname", text = "AB" }, "the sealed text matches the entry")
  Assert.isNil(result.reply, "the typed naming completion never carries an action reply")
  Assert.isNil(child:takeResult(), "a second collection seals nothing more")
  Assert.equal(child:namingText(), "AB", "the sealed text is preserved after the extra collection")
  child:dispose()
end

function T.naming_cancel_reports_once_without_sealing_text()
  local child, openErr = BattleChildApplications.open(namingIntent(), {})
  Assert.notNil(child, "capture naming composes: " .. tostring(openErr))
  assert(child ~= nil, "the naming child composes")
  child:input({ { type = "cancel" } })
  local result = child:takeResult()
  Assert.notNil(result, "a permitted cancel stages its navigation result")
  assert(result ~= nil, "the cancel result seals")
  Assert.equal(result.kind, "cancelled", "naming cancel reports a navigation cancellation")
  Assert.isNil(child:takeResult(), "the cancellation reports exactly once")
  child:dispose()
end

-- Native Bag authority behind the battle barrier: navigation edges wait for
-- the accepted source tick, an empty-cell tap stages nothing and moves no
-- focus, a ball binds its projected foe target, a refused item
-- never consumes stock, and target cancel restores the resting browse.
function T.native_bag_focus_and_target_continuation()
  local catalog = ItemFixture.makeCatalog()
  local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")
  local function healingIntent(inventory, actors)
    return {
      kind = "bag",
      purpose = "bag",
      launchId = "launch-native-bag",
      requestId = 7,
      epoch = 3,
      controller = "player",
      cancellable = true,
      request = { requestId = 7, epoch = 3, controller = "player", kind = "action" },
      options = {
        requestId = 7,
        epoch = 3,
        controller = "player",
        kind = "action",
        actors = actors,
      },
      party = twoEeveeRoster(),
      inventory = inventory,
    }
  end
  local function healingActors()
    return {
      {
        combatant = 1,
        activation = 5,
        kind = "action",
        choices = { itemChoice("POTION", 1), itemChoice("POTION", 2) },
      },
    }
  end
  local flows = BattleSubflows.new({ launchId = "launch-native-bag", itemCatalog = catalog })
  Assert.isTrue(flows:open(healingIntent({ POTION = 5 }, healingActors())), "the stocked bag opens")
  local function step(events)
    flows:update(events)
    flows:tick()
  end
  local function focusId()
    local view = flows:status().childView
    Assert.notNil(view, "the open child projects its view")
    return assert(view.focusId, "the bag projects its focus")
  end
  Assert.equal(flows:status().childView.bagPage, "pocket_menu", "the bag opens on its pocket menu")
  Assert.isTrue(flows:activateControl("bagpocket:0"), "the HP/PP pocket takes its tap")
  flows:tick()
  flows:tick()
  flows:tick()
  Assert.equal(flows:status().childView.currentPocket, "hp_pp", "taps reach the serving pocket")
  Assert.equal(focusId(), "bag:0", "the serving cell owns the opening focus")
  -- A bare input moves no focus: edges wait for the accepted tick.
  flows:update({ { type = "navigate", direction = "down" } })
  Assert.equal(focusId(), "bag:0", "the navigation edge waits for the accepted source tick")
  flows:tick()
  Assert.equal(focusId(), "bag:2", "the cursor roams onto the empty cell")
  -- The d-pad cursor roams freely, even onto empty cells: only a stocked
  -- cell stages. Touch never moves the dpad cursor
  -- (battle_bag_menu.c cursor boxes versus CheckTouchHitbox).
  Assert.isTrue(flows:activateControl("bag:1"), "the empty cell tap belongs to the open child")
  flows:tick()
  Assert.equal(focusId(), "bag:2", "the empty tap moves no cursor and stages nothing")
  Assert.isNil(flows:takeResult(), "the empty tap stages nothing")
  step({ { type = "navigate", direction = "up" } })
  Assert.equal(focusId(), "bag:0", "keys return the cursor to the serving cell")
  -- Selecting a cell opens the use-item page. The battle barrier must
  -- wait for USE before opening a target.
  step({ { type = "confirm" } })
  flows:tick()
  flows:tick()
  flows:tick()
  Assert.equal(flows:status().kind, "bag", "selecting an item keeps the native bag open")
  Assert.equal(flows:status().childView.bagPage, "use_item", "item selection opens the use-item page")
  Assert.isNil(flows:takeResult(), "opening the use-item page stages no battle intent")
  step({ { type = "confirm" } })
  for _ = 1, 8 do
    flows:tick()
  end
  Assert.isNil(flows:takeResult(), "staging the serving seals no reply")
  Assert.equal(flows:status().kind, "target", "staging opens target selection")
  Assert.equal(
    flows:status().childView.native.targetPromptKey,
    "useTarget",
    "the battle target pick carries the Use prompt"
  )
  step({ { type = "cancel" } })
  Assert.equal(flows:status().kind, "bag", "target cancel reactivates the bag")
  Assert.equal(flows:status().childView.currentPocket, "hp_pp", "target cancel keeps the resting pocket")
  Assert.equal(focusId(), "bag:0", "target cancel keeps the serving focus")
  Assert.isNil(flows:takeResult(), "target cancel seals no reply")
  step({ { type = "cancel" } })
  flows:tick()
  flows:tick()
  Assert.equal(flows:status().childView.bagPage, "pocket_menu", "list cancel returns to the pocket menu")
  step({ { type = "cancel" } })
  local cancelled = flows:takeResult()
  Assert.notNil(cancelled, "bag cancel answers")
  assert(cancelled ~= nil, "the bag cancel seals")
  Assert.equal(cancelled.kind, "cancelled", "bag cancel reports its navigation cancellation")
  flows:dispose()
  -- A ball binds its single projected foe target immediately.
  local ballActors = {
    {
      combatant = 1,
      activation = 5,
      kind = "action",
      choices = {
        {
          id = "item:POKE_BALL:9",
          role = "item",
          enabled = true,
          reason = "refused",
          display = { item = "POKE_BALL" },
          choice = {
            actor = { combatant = 1, activation = 5 },
            kind = "item",
            payload = { item = "POKE_BALL", target = { kind = "combatant", combatant = 9 } },
          },
        },
      },
    },
  }
  local thrown = BattleSubflows.new({ launchId = "launch-native-bag", itemCatalog = catalog })
  Assert.isTrue(thrown:open(healingIntent({ POKE_BALL = 5 }, ballActors)), "the ball bag opens")
  Assert.isTrue(thrown:activateControl("bagpocket:2"), "the BALLS pocket takes its tap")
  thrown:tick()
  thrown:tick()
  thrown:tick()
  Assert.equal(thrown:status().childView.currentPocket, "balls", "taps reach the ball pocket")
  thrown:update({ { type = "confirm" } })
  thrown:tick()
  thrown:tick()
  thrown:tick()
  thrown:update({ { type = "confirm" } })
  thrown:tick()
  for _ = 1, 8 do
    thrown:tick()
  end
  local ballResult = thrown:takeResult()
  Assert.notNil(ballResult, "throwing the ball seals its reply")
  assert(ballResult ~= nil, "the ball reply seals")
  Assert.equal(ballResult.kind, "choice", "the throw stages a choice")
  Assert.deepEqual(
    ballResult.reply.choices[1],
    ballActors[1].choices[1].choice,
    "the throw binds its projected foe target"
  )
  Assert.isNil(thrown:takeResult(), "the throw reports exactly once")
  thrown:dispose()
end
-- Retail bag navigation edges (battle_bag_menu.c states 2 and 7): turning
-- the item-list page resets the cell to the first slot, a disabled
-- last-used touch is ignored without moving focus, and the d-pad walks
-- down from the bottom row onto Back, which returns to the pocket menu.
function T.battle_bag_retail_navigation_edges()
  local catalog = ItemFixture.makeCatalog()
  local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")
  local stock = {
    ITEM_1 = 1,
    ITEM_2 = 1,
    ITEM_5 = 1,
    ITEM_6 = 1,
    ITEM_8 = 1,
    ITEM_9 = 1,
    ITEM_10 = 1,
    ITEM_12 = 1,
  }
  local flows = BattleSubflows.new({ launchId = "launch-composer-child", itemCatalog = catalog })
  Assert.isTrue(flows:open(bagIntent(stock)), "the crowded bag opens")
  local function step(events)
    flows:update(events)
    flows:tick()
  end
  local function focusId()
    local view = flows:status().childView
    Assert.notNil(view, "the open child projects its view")
    return assert(view.focusId, "the bag projects its focus")
  end
  Assert.isTrue(flows:activateControl("bagpocket:0"), "the HP/PP pocket takes its tap")
  flows:tick()
  flows:tick()
  flows:tick()
  Assert.equal(focusId(), "bag:0", "the pocket opens on its first cell")
  -- A disabled last-used touch is ignored without moving focus
  -- (HandlePocketMenuInput breaks when lastUsedItem is none).
  step({ { type = "cancel" } })
  flows:tick()
  flows:tick()
  Assert.equal(flows:status().childView.bagPage, "pocket_menu", "setup: list cancel returns to the pocket menu")
  Assert.isTrue(flows:activateControl("last_used"), "the disabled shortcut takes its tap")
  flows:tick()
  Assert.equal(focusId(), "bagpocket:0", "the disabled shortcut keeps the pocket focus")
  Assert.isTrue(flows:activateControl("bagpocket:0"), "the HP/PP pocket takes its tap again")
  flows:tick()
  flows:tick()
  flows:tick()
  step({ { type = "navigate", direction = "down" } })
  step({ { type = "navigate", direction = "down" } })
  Assert.equal(focusId(), "bag:4", "setup: keys walk to the bottom row")
  -- Turning the page resets the saved cell (ChangeItemPage clears
  -- pocketPositions) while the cursor keeps its box: re-entering the
  -- pocket lands on the first cell.
  Assert.isTrue(flows:activateControl("page_next"), "the next-page stepper takes its tap")
  flows:tick()
  flows:tick()
  flows:tick()
  local turned = flows:status().childView
  Assert.notNil(turned, "the turned page projects its view")
  Assert.equal(turned.bagPage, "item_list", "the page turn stays on the list")
  Assert.equal(turned.page.current, 2, "the stepper advances the page")
  Assert.equal(focusId(), "bag:4", "the cursor keeps its box across the turn")
  Assert.isTrue(flows:activateControl("back"), "the list Back takes its tap")
  flows:tick()
  flows:tick()
  flows:tick()
  Assert.isTrue(flows:activateControl("bagpocket:0"), "the HP/PP pocket takes its tap again")
  flows:tick()
  flows:tick()
  flows:tick()
  Assert.equal(focusId(), "bag:0", "re-entering the pocket lands on the reset cell")
  flows:dispose()
  -- The d-pad walks down from the bottom row onto Back (the seventh
  -- item-list cursor box), and confirming Back returns to the pocket
  -- menu like the retail cancel button.
  local short = BattleSubflows.new({ launchId = "launch-composer-child", itemCatalog = catalog })
  local shortStock = { ITEM_1 = 1, ITEM_2 = 1, ITEM_5 = 1, ITEM_6 = 1, ITEM_8 = 1, POTION = 1 }
  Assert.isTrue(short:open(bagIntent(shortStock)), "the single-page bag opens")
  local function shortStep(events)
    short:update(events)
    short:tick()
  end
  local function shortFocus()
    local view = short:status().childView
    Assert.notNil(view, "the open child projects its view")
    return assert(view.focusId, "the bag projects its focus")
  end
  Assert.isTrue(short:activateControl("bagpocket:0"), "the HP/PP pocket takes its tap")
  short:tick()
  short:tick()
  short:tick()
  shortStep({ { type = "navigate", direction = "down" } })
  Assert.equal(shortFocus(), "bag:2", "setup: keys walk to the middle row")
  shortStep({ { type = "navigate", direction = "down" } })
  Assert.equal(shortFocus(), "bag:4", "setup: keys walk to the bottom row")
  shortStep({ { type = "navigate", direction = "down" } })
  Assert.equal(shortFocus(), "back", "down from the bottom row focuses Back")
  shortStep({ { type = "confirm" } })
  short:tick()
  short:tick()
  Assert.equal(short:status().childView.bagPage, "pocket_menu", "confirming Back returns to the pocket menu")
  short:dispose()
end
-- Retail battle cursor memory (battle_bag_menu.c Create/Exit): the bag
-- reopens on its last pocket with each pocket's page and cell restored,
-- and sealing an item carries the new cursor for the next opening.
function T.battle_bag_restores_and_reports_its_cursor()
  local catalog = ItemFixture.makeCatalog()
  local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")
  local stock = {
    ITEM_1 = 1,
    ITEM_2 = 1,
    ITEM_5 = 1,
    ITEM_6 = 1,
    ITEM_8 = 1,
    ITEM_9 = 1,
    ITEM_10 = 1,
    ITEM_12 = 1,
    POKE_BALL = 3,
  }
  local intent = bagIntent(stock)
  intent.battleCursor = {
    pocket = 2,
    pages = { [0] = 1, [1] = 0, [2] = 0, [3] = 0 },
    positions = { [0] = 3, [1] = 0, [2] = 0, [3] = 0 },
  }
  local flows = BattleSubflows.new({ launchId = "launch-composer-child", itemCatalog = catalog })
  Assert.isTrue(flows:open(intent), "the bag opens behind its saved cursor")
  local view = flows:status().childView
  Assert.notNil(view, "the open bag projects its view")
  Assert.equal(view.focusId, "bagpocket:2", "the pocket menu reopens on the saved pocket")
  Assert.isTrue(flows:activateControl("bagpocket:0"), "the HP/PP pocket takes its tap")
  flows:tick()
  flows:tick()
  flows:tick()
  local listed = flows:status().childView
  Assert.notNil(listed, "the pocket projects its view")
  Assert.equal(listed.page.current, 2, "the pocket reopens on its saved page")
  Assert.equal(listed.focusId, "bag:3", "the pocket reopens on its saved cell")
  flows:dispose()
  -- Sealing an item reports the new cursor with the sealed pocket.
  local ballChoice = itemChoice("POKE_BALL", 9)
  ballChoice.choice.payload.target = { kind = "combatant", combatant = 9 }
  local ballIntent = bagIntent({ POKE_BALL = 3 })
  ballIntent.options = {
    requestId = 7,
    epoch = 3,
    controller = "player",
    kind = "action",
    actors = { { combatant = 1, activation = 5, kind = "action", choices = { ballChoice } } },
  }
  ballIntent.battleCursor = {
    pocket = 0,
    pages = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 },
    positions = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 },
  }
  local thrown = BattleSubflows.new({ launchId = "launch-composer-child", itemCatalog = catalog })
  Assert.isTrue(thrown:open(ballIntent), "the ball bag opens")
  Assert.isTrue(thrown:activateControl("bagpocket:2"), "the BALLS pocket takes its tap")
  thrown:tick()
  thrown:tick()
  thrown:tick()
  thrown:update({ { type = "confirm" } })
  thrown:tick()
  thrown:tick()
  thrown:tick()
  thrown:update({ { type = "confirm" } })
  thrown:tick()
  for _ = 1, 8 do
    thrown:tick()
  end
  local sealed = thrown:takeResult()
  Assert.notNil(sealed, "the throw seals its reply")
  assert(sealed ~= nil, "the sealed throw seals")
  Assert.equal(sealed.kind, "choice", "the throw stages a choice")
  local cursor = assert(sealed.cursor, "the sealed choice carries the new cursor") --[[@as table<string, unknown>]]
  Assert.equal(cursor.pocket, 2, "the sealed cursor names the thrown pocket")
  thrown:dispose()
end
-- The carried bag slot order reaches the browser listing: pockets list
-- in saved-bag order instead of native-id order.
function T.battle_bag_lists_in_carried_slot_order()
  local catalog = ItemFixture.makeCatalog()
  local BattleSubflows = require("game.hgss.src.battle.BattleSubflows")
  local intent = bagIntent({ SITRUS_BERRY = 1, POTION = 1, ETHER = 1 })
  intent.slotOrder = { "SITRUS_BERRY", "ETHER", "POTION" }
  local flows = BattleSubflows.new({ launchId = "launch-composer-child", itemCatalog = catalog })
  Assert.isTrue(flows:open(intent), "the ordered bag opens")
  Assert.isTrue(flows:activateControl("bagpocket:0"), "the HP/PP pocket takes its tap")
  flows:tick()
  flows:tick()
  flows:tick()
  local native = flows:status().childView.native
  Assert.notNil(native, "the pocket projects its native record")
  local keys = {}
  for _, entry in ipairs(native.slots) do
    keys[#keys + 1] = entry.item
  end
  Assert.deepEqual(keys, { "SITRUS_BERRY", "ETHER", "POTION" }, "the pocket lists in bag order")
  flows:dispose()
end
function T.target_picker_disposes_alone_behind_the_retained_browser()
  local catalog = ItemFixture.makeCatalog()
  local child, openErr = BattleChildApplications.open(bagIntent({ POTION = 5 }), { itemCatalog = catalog })
  Assert.notNil(child, "the stocked bag composes: " .. tostring(openErr))
  assert(child ~= nil, "the bag child composes")
  child:openTarget("POTION")
  child:input({ { type = "navigate", direction = "down" } })
  child:input({ { type = "confirm" } })
  child:closeTarget()
  Assert.isTrue(child:status().active, "closing the target keeps the retained browser")
  child:input({ { type = "cancel" } })
  child:dispose()
  child:input({ { type = "confirm" } })
  Assert.isNil(child:takeResult(), "a disposed browser seals nothing")
end

return { tests = T }
