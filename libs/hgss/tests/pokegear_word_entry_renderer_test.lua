-- Single-word entry presentation: the renderer projects the gate
-- established single-word plan (sprite members, background binding,
-- interface banks, hitbox and sound facts) without invented pixels, rejects
-- foreign modes, and draws only prepared content plus focused identities.

local Assert = require("tests.support.Assert")

local T = { tests = {} }

local function requireRenderer()
  local ok, mod = pcall(require, "libs.hgss.src.presentation.PokegearWordEntryRenderer")
  if not ok then
    error("the map annotation has no word renderer yet", 0)
  end
  return mod --[[@as table]]
end

---@return table status behind a fresh single-word selector
local function freshStatus()
  return {
    mode = "single-word",
    level = "category",
    group = 0,
    index = 0,
    wordKey = "0",
    selectedWord = false,
    groupCount = 11,
    groupSize = 496,
  }
end

---@return table graphics host recording every call
local function fakeGraphics()
  local calls = {}
  local graphics = {}
  function graphics.setColor(r, g, b, a)
    calls[#calls + 1] = { op = "setColor", r = r, g = g, b = b, a = a }
  end
  function graphics.rectangle(mode, x, y, width, height)
    calls[#calls + 1] = { op = "rectangle", mode = mode, x = x, y = y, width = width, height = height }
  end
  function graphics.draw(image, x, y)
    calls[#calls + 1] = { op = "draw", image = image, x = x, y = y }
  end
  return graphics, calls
end

---@return table text primitive recording drawn lines
local function fakeText()
  local lines = {}
  local text = {}
  function text:drawText(value, x, y)
    lines[#lines + 1] = { value = value, x = x, y = y }
  end
  return text, lines
end

T.tests["layout projects the gate-established single-word plan"] = function()
  local Renderer = requireRenderer()
  local plan = Renderer.layout(freshStatus())
  Assert.equal(plan.mode, "single-word", "the plan names the single-word mode")
  Assert.equal(plan.focus.level, "category", "the plan carries the selector focus level")
  Assert.equal(plan.focus.group, 0, "the plan carries the focused group")
  Assert.equal(plan.focus.wordKey, "0", "the plan carries the focused word identity")
  Assert.equal(plan.groups, 11, "the plan keeps all eleven source groups")
  Assert.equal(plan.sprites.cell, 7, "the plan binds the source cell member")
  Assert.equal(plan.sprites.animation, 8, "the plan binds the source animation member")
  Assert.equal(plan.sprites.mapping, 9, "the plan binds the source mapping member")
  Assert.equal(plan.sprites.palette, 10, "the plan binds the source palette member")
  Assert.equal(plan.background.screenMember, 0, "the plan binds the source screen member")
  Assert.equal(plan.background.charMember, 1, "the plan binds the source character member")
  Assert.deepEqual(plan.background.layers, { 0, 4 }, "the plan binds the source background layers")
  Assert.deepEqual(plan.text.interfaceBanks, { 282, 283, 284 }, "the plan binds the interface banks")
  Assert.equal(plan.input.hitboxes, 5, "the plan keeps the five source hitboxes")
  Assert.equal(plan.input.confirmSound, 1500, "the plan keeps the source confirm sound")
end

T.tests["layout rejects foreign modes instead of rendering them"] = function()
  local Renderer = requireRenderer()
  Assert.isFalse(
    pcall(Renderer.layout, {
      mode = "mail",
      level = "category",
      group = 0,
      index = 0,
      groupCount = 11,
      groupSize = 496,
    }),
    "mail-mode geometry never lays out as the single-word selector"
  )
  Assert.isFalse(pcall(Renderer.layout, {}), "a modeless status never lays out")
  Assert.isFalse(pcall(Renderer.layout, nil), "a missing status never lays out")
end

T.tests["drawing uses only prepared content and focused identities"] = function()
  local Renderer = requireRenderer()
  local graphics, calls = fakeGraphics()
  local text, lines = fakeText()
  local plan = Renderer.layout(freshStatus())
  local panel = { prepared = true }
  Renderer.drawPane(graphics, { ["test-panel"] = panel }, text, { panel = "test-panel" }, freshStatus())
  local drewPanel = false
  for _, call in ipairs(calls) do
    if call.op == "draw" and call.image == panel then
      drewPanel = true
    end
  end
  Assert.isTrue(drewPanel, "the draw uses the prepared panel image")
  Assert.isTrue(#lines >= 1, "the draw names the focused identity through the text primitive")
  Assert.equal(lines[1].value, "0", "the first drawn line carries the focused word identity")

  local bareGraphics, bareCalls = fakeGraphics()
  Renderer.drawPane(bareGraphics, {}, nil, plan, freshStatus())
  Assert.isTrue(#bareCalls >= 1, "the draw still runs without prepared images or text")
  for _, call in ipairs(bareCalls) do
    Assert.isFalse(call.op == "draw", "nothing draws from missing prepared images")
  end
end

return T
