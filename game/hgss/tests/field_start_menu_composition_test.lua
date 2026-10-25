-- Focused composition tests for the field Start Menu: the runtime joins the
-- source action policy, the implementation capabilities, the live player
-- profile, and the generated source label bank into the controller entries
-- the renderer draws. Static labels resolve from the acquired source label
-- bank through the shared message provider; the trainer card row always
-- carries the live profile name instead.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local MenuProtocol = require("libs.assets.src.MenuProtocol")
local FieldMenuCompositionCoordinator = require("game.hgss.src.field.FieldMenuCompositionCoordinator")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local ApplicationLayout = require("libs.ui.src.ApplicationLayout")
local ScreenTopology = require("libs.ui.src.ScreenTopology")

local T = { tests = {} }

local SOURCE_LABEL_BANK = MenuProtocol.START_MENU_MESSAGE_BANK

local LABEL_TEXTS = {
  [0] = "DEX-LABEL",
  [1] = "PARTY-LABEL",
  [2] = "BAG-LABEL",
  [14] = "GEAR-LABEL",
  [4] = "SAVE-LABEL",
  [5] = "OPTIONS-LABEL",
}

local ALL_FLAGS = {
  "FLAG_GOT_POKEDEX",
  "FLAG_GOT_STARTER",
  "FLAG_GOT_BAG",
  "FLAG_GOT_POKEGEAR",
  "FLAG_GOT_TRAINER_CARD",
  "FLAG_GOT_SAVE_BUTTON",
  "FLAG_GOT_OPTIONS_BUTTON",
}

local function manifestWithIcons()
  local manifest = FieldUiFixture.manifest()
  FieldUiFixture.addStartMenuIconContract(manifest)
  return manifest
end

local function seedLabelBank(cache)
  local messages = {}
  for id, text in pairs(LABEL_TEXTS) do
    messages[id] = { id = id, text = text, raw = {}, tokens = {} }
  end
  cache:writeLua(FieldMessageCache.bankPath(SOURCE_LABEL_BANK), {
    schema = FieldMessageCache.SCHEMA,
    bankId = SOURCE_LABEL_BANK,
    messageCount = 15,
    key = 0,
    messages = messages,
  })
end

-- The shared provider with the source label bank acquired, mirroring the
-- runtime boot pinning the bank for the field-runtime lifetime.
local function providerWithLabels()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  seedLabelBank(cache)
  local provider = FieldMessageProvider.new(cache)
  local bank, err = provider:acquireBank(SOURCE_LABEL_BANK)
  assert(bank ~= nil, err and err.message or "the source label bank must acquire")
  return provider
end

local function worldWith(flagNames)
  local set = {}
  for _, name in ipairs(flagNames) do
    set[assert(FieldScriptSymbols.flagsByName[name], "unknown world flag " .. name)] = true
  end
  return {
    isFlagSet = function(_, flag)
      return set[flag] == true
    end,
  }
end

-- The minimal fake runtime composition: real policy, real icon contract,
-- real message provider, and fakes only at the true host boundaries (world
-- flags, installed applications, live services). The menu wrapper reads
-- the current display facts and its window memory, so the fake carries the
-- same measurement closure and per-application memory the production
-- runtime supplies.
local function composeSelf(overrides)
  overrides = overrides or {}
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 640, height = 480 },
    touch = false,
    role = "world",
  })
  local display = {
    width = 640,
    height = 480,
    topology = topology,
    pixelRatio = 1,
    signature = "composition",
  }
  local worldState = overrides.worldState or worldWith(ALL_FLAGS)
  -- Test-only dex owner behind the production owner query: mirrors the
  -- fake world flags so existing flag-driven cases keep their meaning
  -- while the composed menu reads the owner like production.
  local dexKnowledge = overrides.dexKnowledge
    or {
      hasPokedex = function()
        return worldState:isFlagSet(FieldScriptSymbols.flagsByName.FLAG_GOT_POKEDEX)
      end,
      hasNationalDex = function()
        return false
      end,
    }
  return {
    scripts = { worldState = worldState },
    dexKnowledge = dexKnowledge,
    uiManifest = overrides.uiManifest or manifestWithIcons(),
    playerData = { profile = { name = "PLAYER", badges = 0, runningShoes = false, runningShoesLock = false } },
    playerAvatar = {
      durableState = function()
        return "walking"
      end,
    },
    messageProvider = overrides.messageProvider or providerWithLabels(),
    applications = {
      has = function()
        return true
      end,
    },
    monService = {
      partyCount = function()
        return 1
      end,
    },
    bagService = {},
    bagCursor = {},
    itemCatalog = {},
    saveStore = {},
    audio = nil,
    presentationDisplay = display,
    applicationHost = {
      phase = function()
        return overrides.hostPhase ~= nil and overrides.hostPhase or "menu"
      end,
    },
  }
end

local function composeStartMenu(self, rememberedActionId)
  return FieldMenuCompositionCoordinator.new(self):composeStartMenu(rememberedActionId)
end

local function actionById(status, id)
  assert(status.open, "the start menu must stay open")
  for _, action in ipairs(status.actions) do
    if action.id == id then
      return action
    end
  end
  error("action " .. id .. " has no composed entry", 0)
end

function T.tests.static_labels_resolve_from_the_source_bank_and_trainer_card_uses_the_live_name()
  local controller = assert(composeStartMenu(composeSelf()), "the full normal menu composes a controller")
  local status = controller:status()
  local expected = {
    ["vanilla.pokedex"] = "DEX-LABEL",
    ["vanilla.pokemon"] = "PARTY-LABEL",
    ["vanilla.bag"] = "BAG-LABEL",
    ["vanilla.pokegear"] = "GEAR-LABEL",
    ["vanilla.trainer_card"] = "PLAYER",
    ["vanilla.save"] = "SAVE-LABEL",
    ["vanilla.options"] = "OPTIONS-LABEL",
  }
  for id, label in pairs(expected) do
    Assert.equal(actionById(status, id).label, label, id .. " carries its composed label")
  end
end

function T.tests.sparse_menus_keep_fixed_positions_with_holes_instead_of_compacting()
  local self = composeSelf({
    worldState = worldWith({ "FLAG_GOT_TRAINER_CARD", "FLAG_GOT_SAVE_BUTTON", "FLAG_GOT_OPTIONS_BUTTON" }),
  })
  local status = composeStartMenu(self):status()
  Assert.equal(#status.actions, 3, "only the present actions compose entries")
  Assert.equal(actionById(status, "vanilla.trainer_card").position, 4)
  Assert.equal(actionById(status, "vanilla.save").position, 5)
  Assert.equal(actionById(status, "vanilla.options").position, 6)
  Assert.equal(actionById(status, "vanilla.trainer_card").label, "PLAYER")
end

function T.tests.running_shoes_visibility_tracks_live_ownership_avatar_and_child_phase()
  local avatarState = "walking"
  local hostPhase = "menu"
  local self = composeSelf()
  self.playerData.profile.runningShoes = true
  self.playerData.profile.runningShoesLock = true
  self.playerAvatar.durableState = function()
    return avatarState
  end
  self.applicationHost.phase = function()
    return hostPhase
  end
  local controller = composeStartMenu(self)
  Assert.deepEqual(controller:status().runningShoes, { locked = true, focused = false })

  avatarState = "cycling"
  Assert.isNil(controller:status().runningShoes, "cycling hides the toggle")
  avatarState = "walking"
  hostPhase = "application"
  Assert.isNil(controller:status().runningShoes, "a foreground child masks the retained parent control")
  controller:updateFixed({ { type = "confirm" } })
  Assert.isTrue(self.playerData.profile.runningShoesLock, "confirm during child phase cannot toggle the profile")

  hostPhase = "menu"
  Assert.deepEqual(controller:status().runningShoes, { locked = true, focused = false })
  self.playerData.profile.runningShoes = false
  Assert.isNil(controller:status().runningShoes, "ownership is read live")
end

function T.tests.controller_accessible_shoes_survive_each_menu_layout()
  local layouts = {
    dualDisplay = {
      width = 512,
      height = 192,
      topology = ScreenTopology.dualDisplay(
        { id = "main", rect = { x = 0, y = 0, width = 256, height = 192 }, role = "world", touch = false },
        { id = "sub", rect = { x = 256, y = 0, width = 256, height = 192 }, role = "auxiliary", touch = false }
      ),
    },
    nativeLike = {
      width = 640,
      height = 480,
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 640, height = 480 },
        role = "world",
        touch = false,
      }),
    },
    wide = {
      width = 960,
      height = 540,
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 960, height = 540 },
        role = "world",
        touch = false,
      }),
    },
    tall = {
      width = 360,
      height = 640,
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 360, height = 640 },
        role = "world",
        touch = false,
      }),
    },
  }

  for expectedConfiguration, display in pairs(layouts) do
    local runtime = composeSelf()
    runtime.playerData.profile.runningShoes = true
    runtime.presentationDisplay = {
      width = display.width,
      height = display.height,
      topology = display.topology,
      pixelRatio = 1,
      signature = "running-shoes-layout:" .. expectedConfiguration,
    }
    Assert.equal(ApplicationLayout.classify(runtime.presentationDisplay), expectedConfiguration)

    local menu = composeStartMenu(runtime)
    menu:updateFixed({
      { type = "navigate", direction = "right" },
      { type = "navigate", direction = "down" },
      { type = "navigate", direction = "down" },
      { type = "navigate", direction = "right" },
    })
    Assert.isTrue(menu:status().runningShoes.focused, "controller focus reaches shoes in " .. expectedConfiguration)
    menu:updateFixed({ { type = "confirm" } })
    Assert.isTrue(runtime.playerData.profile.runningShoesLock, "confirm saves the lock in " .. expectedConfiguration)
    Assert.isTrue(menu:status().open, "confirm keeps the menu open in " .. expectedConfiguration)
    menu:updateFixed({ { type = "cancel" } })
    Assert.isFalse(menu:status().open, "cancel closes the menu in " .. expectedConfiguration)
    menu:dispose()
  end
end

function T.tests.disabled_but_visible_actions_still_carry_their_labels()
  local flags = {}
  for _, name in ipairs(ALL_FLAGS) do
    if name ~= "FLAG_GOT_TRAINER_CARD" then
      flags[#flags + 1] = name
    end
  end
  local status = composeStartMenu(composeSelf({ worldState = worldWith(flags) })):status()
  local card = actionById(status, "vanilla.trainer_card")
  Assert.equal(card.enabled, false, "an unlock-gated action stays visible but disabled")
  Assert.equal(card.label, "PLAYER", "a disabled action still carries its label")
end

function T.tests.composition_without_the_source_label_bank_fails_instead_of_leaving_icons_unlabeled()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local self = composeSelf({ messageProvider = FieldMessageProvider.new(cache) })
  local err = Assert.throws(function()
    composeStartMenu(self)
  end)
  Assert.isTrue(tostring(err):find("196", 1, true) ~= nil, "the failure names the missing source label bank")
end

-- The pinned source label bank rides the shared provider lifetime: tearing
-- the provider down clears it with no extra cleanup step, and tearing it
-- down twice stays a no-op.
function T.tests.pinned_source_label_bank_needs_no_bespoke_cleanup()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  seedLabelBank(cache)
  local provider = FieldMessageProvider.new(cache)
  assert(provider:acquireBank(SOURCE_LABEL_BANK))
  composeStartMenu(composeSelf({ messageProvider = provider }))
  provider:dispose()
  provider:dispose()
  Assert.equal(provider:stats().live, 0, "disposal clears the pinned bank")
end

return T
