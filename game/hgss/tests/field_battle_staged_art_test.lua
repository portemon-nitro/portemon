-- Unit coverage for the presented battle envelope's staged menu and HUD
-- art resolution: every drawable key the battle renderers request
-- resolves to the exact staged path the verified manifest names, per-control
-- artwork without a staged counterpart resolves to nothing, and a planning
-- inventory stages nothing at all. Resolution is observed through the
-- shared image owner's requested paths.

local Assert = require("tests.support.Assert")
local BattlePresentationCache = require("libs.assets.src.battle.BattlePresentationCache")
local BattlePresentationSchema = require("libs.assets.src.battle.BattlePresentationSchema")
local ManifestFixture = require("tests.support.BattlePresentationManifestFixture")
local FieldBattlePresentation = require("game.hgss.src.field.FieldBattlePresentation")

local T = {}

local ART = "assets/generated/battle/"

---@param manifest table<string, unknown>
---@param path string
local function stageImage(manifest, path)
  manifest.menus.images[path] = { width = 256, height = 256 }
  return path
end

-- The shared fixture extended with every per-screen art family the
-- resolver indexes: distinct section and screen images, background and
-- touch variants (including a digit-bearing background name), pressed
-- feedback patches, and the four fight-menu move buttons.
---@return table<string, unknown> schema-valid staged manifest
local function stagedManifest()
  local manifest = ManifestFixture.manifest()
  for _, name in ipairs({ "command", "moves", "target", "twoOption" }) do
    local section = manifest.menus[name]
    section.image = stageImage(manifest, ART .. name .. "-section.png")
    section.screens[1].image = stageImage(manifest, ART .. name .. "-screen-1.png")
  end
  local command = manifest.menus.command.screens[1]
  command.backgrounds = {
    general = ART .. "command-screen-1-general.png",
    building_1 = ART .. "command-screen-1-building-1.png",
  }
  command.touchBackgrounds = { general = ART .. "command-screen-1-touch-general.png" }
  command.feedback = {
    fight = { pressed = { image = ART .. "command-fight-pressed.png", x = 0, y = 0, width = 8, height = 8 } },
  }
  local buttons = {}
  for slot = 1, 4 do
    buttons[slot] = {
      x = 0,
      y = 0,
      width = 8,
      height = 8,
      empty = ART .. "move-button-" .. slot .. "-empty.png",
      types = {
        fire = {
          normal = ART .. "move-button-" .. slot .. "-fire-normal.png",
          pressed = ART .. "move-button-" .. slot .. "-fire-pressed.png",
        },
      },
    }
  end
  manifest.menus.moves.screens[1].moveButtons = buttons
  BattlePresentationSchema.assertManifest(manifest)
  return manifest
end

---@return table<string, unknown> shared image owner double recording requested paths by key
local function recordingPool()
  local pool = { paths = {} }
  function pool:request(path, _, _)
    self.paths[#self.paths + 1] = path
    return path
  end
  function pool:poll(_)
    return "ready"
  end
  function pool:acquire(token)
    return { image = {}, path = token }
  end
  function pool:release(_) end
  return pool
end

---@param staged table<string, unknown>? staged manifest the cache answers, nil for the planning inventory
---@return FieldBattlePresentation
---@return table<string, unknown> recording pool
local function envelopeFor(staged)
  local cacheFs = { versionId = "staged-art-probe" }
  function cacheFs:loadLua(path)
    if path == BattlePresentationCache.manifestPath() then
      return staged
    end
    return nil
  end
  function cacheFs:read(_)
    return nil
  end
  local pool = recordingPool()
  local envelope = FieldBattlePresentation.new({
    cacheFs = cacheFs,
    windows = {},
    text = {},
    measureDisplay = function()
      return {}
    end,
    graphics = {},
    imagePool = pool,
  })
  return envelope, pool
end

---@param envelope FieldBattlePresentation
---@param pool table<string, unknown>
---@param key string drawable key under resolution
---@return string? staged path the key borrowed, nil when it resolved to nothing
local function resolvedPath(envelope, pool, key)
  local before = #pool.paths
  local handle, failure = envelope._services.drawable(key)
  Assert.isNil(failure, "staged art resolution never fails for " .. key)
  if #pool.paths == before then
    Assert.isNil(handle, "an unresolved key hands out no drawable: " .. key)
    return nil
  end
  Assert.notNil(handle, "a resolved key hands out its borrowed drawable: " .. key)
  return pool.paths[#pool.paths]
end

function T.staged_keys_resolve_to_their_verified_manifest_paths()
  local manifest = stagedManifest()
  local envelope, pool = envelopeFor(manifest)
  local hud, menus = manifest.hud, manifest.menus
  local command = menus.command.screens[1]
  local button = menus.moves.screens[1].moveButtons[2]
  local expected = {
    ["shadow"] = manifest.pictures.shadow.image,
    ["hud:enemy"] = hud.enemy.image,
    ["hud:player"] = hud.player.image,
    ["hud:player-left"] = hud.doubles.playerLeft.image,
    ["hud:player-right"] = hud.doubles.playerRight.image,
    ["hud:enemy-left"] = hud.doubles.enemyLeft.image,
    ["hud:enemy-right"] = hud.doubles.enemyRight.image,
    ["arrow"] = hud.arrow.image,
    ["cursor"] = hud.cursor.image,
    ["gauges:player"] = hud.partyGauges[2].image,
    ["gauges:enemy"] = hud.partyGauges[1].image,
    ["menu:command"] = menus.command.image,
    ["menu:moves"] = menus.moves.image,
    ["menu:target"] = menus.target.image,
    ["menu:pulse-mask"] = menus.lower.pulseMask,
    ["menu:command:screen:1"] = command.image,
    ["menu:command:screen:1@general"] = command.backgrounds.general,
    ["menu:command:screen:1@general:touch"] = command.touchBackgrounds.general,
    ["menu:command:screen:1@building_1"] = command.backgrounds.building_1,
    ["menu:command:screen:1@building_1:touch"] = command.backgrounds.building_1,
    ["menu:command:screen:1@forest"] = command.image,
    ["menu:command:screen:1@forest:touch"] = command.image,
    ["menu:moves:screen:1@general"] = menus.moves.screens[1].image,
    ["menu:target:screen:1@general:touch"] = menus.target.screens[1].image,
    ["menu:two-option:screen:1@general"] = menus.twoOption.screens[1].image,
    ["menu:command:feedback:fight:pressed"] = command.feedback.fight.pressed.image,
    ["menu:moves:move-button:1:empty"] = button.empty,
    ["menu:moves:move-button:1:fire:normal"] = button.types.fire.normal,
    ["menu:moves:move-button:1:fire:pressed"] = button.types.fire.pressed,
  }
  for key, path in pairs(expected) do
    Assert.equal(resolvedPath(envelope, pool, key), path, "staged key resolves its manifest path: " .. key)
  end
  for _, key in ipairs({
    "menu:command:fight",
    "menu:moves:move:0",
    "menu:two-option",
    "menu:command:screen:2@general",
    "menu:bogus:screen:1@general",
    "menu:command:feedback:fight:selected",
    "menu:command:feedback:run:pressed",
    "menu:target:feedback:fight:pressed",
    "menu:moves:move-button:4:empty",
    "menu:moves:move-button:1:water:normal",
    "hud:doubles",
    "gauges",
  }) do
    Assert.isNil(resolvedPath(envelope, pool, key), "key without staged art resolves to nothing: " .. key)
  end
  envelope:dispose()
end

function T.planning_inventory_resolves_no_staged_art()
  local envelope, pool = envelopeFor(nil)
  for _, key in ipairs({
    "shadow",
    "hud:enemy",
    "hud:player-left",
    "cursor",
    "gauges:player",
    "menu:command",
    "menu:pulse-mask",
    "menu:command:screen:1@general",
    "menu:command:feedback:fight:pressed",
    "menu:moves:move-button:0:empty",
  }) do
    Assert.isNil(resolvedPath(envelope, pool, key), "a planning inventory stages nothing: " .. key)
  end
  envelope:dispose()
end

return { tests = T }
