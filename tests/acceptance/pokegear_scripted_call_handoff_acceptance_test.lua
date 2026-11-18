-- A source scripted phone call across the real field composition. Route
-- 30's frame-table script stages Elm's panic call, so the field must lock
-- for the whole scripted call, the call must open as a framed window over
-- the live field with no field cover presented, its source line must play
-- to the staged hangup, and the script must resume and rewrite its scene
-- variable afterwards. Production boot, real catalog/state/streams/host,
-- ROM-derived messages and audio. Stops before GPU rendering.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.field.FieldScriptSymbols")

local T = {
  metadata = {
    capabilities = { "rom_dump" },
    derivedAssets = { "field-runtime", "map:34", "map-data:34" },
    tags = { "pokegear", "phone", "field" },
  },
  tests = {},
}

local SCENE_VARIABLE = FieldScriptSymbols.variablesByName.VAR_SCENE_ROUTE_30_OW
local SCENE_TRIGGERED = 2
local SCENE_DONE = 3

---@param catalog table
---@return table elm the compiled Elm contact
local function elmContact(catalog)
  for _, entry in ipairs(assert(catalog.contacts, "the phone catalog carries its contacts")) do
    local record = entry --[[@as table<string, unknown>]]
    if record.id == 1 then
      return record
    end
  end
  error("the compiled phonebook carries Elm as contact 1", 0)
end

function T.tests.scripted_call_presents_a_window_without_covering_the_field()
  local harness = AcceptanceHarness.new()
  local game = harness:boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_ROUTE_30",
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
  local ok, err = xpcall(function()
    game:waitForFieldEntry()
    local runtime = game.runtime
    local elm = elmContact(assert(runtime.pokegearCatalog, "the field runtime owns the phone catalog"))
    assert(runtime.pokegearState, "the field runtime owns the phonebook state")
    runtime.pokegearState:registerContact(elm.key)
    local host = assert(runtime.pokegear and runtime.pokegear.scriptHost, "the field owns the script companion host")
    local world = assert(runtime.scripts and runtime.scripts.worldState, "field scripts are composed")

    -- The frame table starts the source script once its scene variable
    -- matches; nothing else in the journey stages this call.
    world:setVar(SCENE_VARIABLE, SCENE_TRIGGERED)
    local highestCover = 0
    game:advanceUntil("the scripted call opens", function()
      highestCover = math.max(highestCover, game:snapshot().screenFade.coefficient)
      return host:isActive()
    end, 240)

    -- The frame script is a source map-scene script: the field stays
    -- locked for the ring and for the whole call, and the port presents
    -- the call as a window instead of covering the field.
    local opened = game:snapshot()
    Assert.isTrue(opened.fieldLocked, "the scripted call locks the field")
    Assert.equal(opened.screenFade.coefficient, 0, "the scripted call never covers the field")
    Assert.equal(highestCover, 0, "the field stays visible through the ring tones")
    local status = assert(host:status(), "the opened call publishes its status")
    Assert.equal(status.tab, "phone", "the companion opens its phone card")
    local call = assert(status.view and status.view.call, "the call publishes its conversation view")
    Assert.equal(call.contact, elm.key, "the scripted call names its staged caller")
    Assert.equal(call.stage, "message", "the scripted call starts on its staged message")

    -- The source script rings the line twice before it hands off.
    local rings = 0
    for _, effect in ipairs(game:hostEffects()) do
      if effect == "audio:SEQ_SE_GS_PHONE0" then
        rings = rings + 1
      end
    end
    Assert.isTrue(rings >= 2, "the scripted handoff rings its source line")

    -- Action edges play the conversation to its terminal hangup.
    local sawText = false
    for _ = 1, 2000 do
      if not host:isActive() then
        break
      end
      local live = assert(host:status(), "the live call keeps its status")
      local view = live.view and live.view.call
      if type(view) == "table" and type(view.lines) == "table" and #view.lines > 0 then
        sawText = true
      end
      highestCover = math.max(highestCover, game:snapshot().screenFade.coefficient)
      game:pressAction()
    end
    Assert.isTrue(sawText, "the scripted call prints its source line")
    Assert.isFalse(host:isActive(), "the terminal call releases the companion host")

    -- The script resumes after the handoff: it closes its own scene
    -- variable and releases the field.
    game:advanceUntil("the scripted call script finishes", function()
      return game:snapshot().foregroundScript == nil
    end, 240)
    Assert.equal(highestCover, 0, "no field cover is presented across the handoff")
    Assert.equal(world:getVar(SCENE_VARIABLE), SCENE_DONE, "the source script resumes past the call")
    local settled = game:snapshot()
    Assert.isFalse(settled.fieldLocked, "the finished script releases the field")
    Assert.isFalse(host:isActive(), "the closed call leaves the companion lease free")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
