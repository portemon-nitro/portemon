-- Closed semantic message substitution over generated segment records: text
-- segments contribute their literal while every other segment kind resolves
-- the binding of that exact name. The template and bindings are never
-- mutated, and no range or naming policy lives here.

local Assert = require("tests.support.Assert")
local MenuTextTemplate = require("libs.hgss.src.ui.MenuTextTemplate")

local T = {}

function T.literals_and_repeated_bindings_concatenate_in_order()
  local template = {
    segments = {
      { kind = "text", value = "Give " },
      { kind = "item" },
      { kind = "text", value = " to " },
      { kind = "item" },
      { kind = "text", value = "?" },
    },
  }
  local rendered = MenuTextTemplate.format(template, { item = "Potion" })
  Assert.equal(rendered, "Give Potion to Potion?")
  Assert.equal(#template.segments, 5, "the template keeps every segment")
end

function T.zero_and_negative_integers_render_without_a_range_policy()
  local template = {
    segments = {
      { kind = "text", value = "x" },
      { kind = "quantity" },
    },
  }
  Assert.equal(MenuTextTemplate.format(template, { quantity = 0 }), "x0")
  Assert.equal(MenuTextTemplate.format(template, { quantity = -3 }), "x-3")
end

function T.unicode_literals_pass_through_untouched()
  local template = {
    segments = {
      { kind = "text", value = "Poké " },
      { kind = "name" },
    },
  }
  Assert.equal(MenuTextTemplate.format(template, { name = "Pikachu" }), "Poké Pikachu")
end

function T.missing_bindings_fail()
  local template = {
    segments = {
      { kind = "text", value = "Toss " },
      { kind = "quantity" },
    },
  }
  local ok, err = pcall(MenuTextTemplate.format, template, {})
  Assert.isFalse(ok, "an unbound segment kind must fail")
  Assert.notNil(tostring(err):find("MENU_TEXT_TEMPLATE"), "the failure must carry the protocol code")
end

function T.callback_and_non_integer_bindings_fail()
  local template = {
    segments = {
      { kind = "text", value = "Use " },
      { kind = "item" },
    },
  }
  local function potionName()
    return "Potion"
  end
  local callbackValue = potionName ---@type any -- the callback is the invalid input under test
  local callbackErr = Assert.throws(function()
    MenuTextTemplate.format(template, { item = callbackValue })
  end, "callbacks are never valid bindings")
  Assert.notNil(tostring(callbackErr):find("MENU_TEXT_TEMPLATE"), "the failure must carry the protocol code")
  local fractionalValue = 1.5 ---@type any -- the fractional number is the invalid input under test
  local floatErr = Assert.throws(function()
    MenuTextTemplate.format({ segments = { { kind = "quantity" } } }, { quantity = fractionalValue })
  end, "non-integer numbers are never valid bindings")
  Assert.notNil(tostring(floatErr):find("MENU_TEXT_TEMPLATE"), "the failure must carry the protocol code")
end

function T.inputs_are_never_mutated()
  local template = {
    segments = {
      { kind = "text", value = "x" },
      { kind = "quantity" },
    },
  }
  local bindings = { quantity = 7 }
  Assert.equal(MenuTextTemplate.format(template, bindings), "x7")
  Assert.deepEqual(template, {
    segments = {
      { kind = "text", value = "x" },
      { kind = "quantity" },
    },
  })
  Assert.deepEqual(bindings, { quantity = 7 })
end

return { tests = T }
