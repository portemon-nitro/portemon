-- Asset needs: ops declare the assets they imply, one pure extractor turns a
-- script's steps into sorted unique `kind:id` keys, and a script may add
-- needs the scanner cannot see through an optional `needs` hint.

local Assert = require("tests.support.Assert")
local AssetNeeds = require("libs.script.src.AssetNeeds")
local Schema = require("libs.script.src.Schema")
local ScriptErrors = require("libs.script.src.errors")
local S = require("gen4.script")

local T = {}

local HO_OH = "field-effect:ho_oh_appearance"

function T.key_parse_round_trip()
  local need = { kind = "field-effect", id = "ho_oh_appearance" }
  Assert.equal(AssetNeeds.key(need), HO_OH)
  Assert.deepEqual(AssetNeeds.parse(HO_OH), need)
  Assert.deepEqual(AssetNeeds.parse("kind:id:with:colons"), { kind = "kind", id = "id:with:colons" })
end

function T.parse_rejects_missing_colon_empty_kind_or_empty_id()
  for _, key in ipairs({ "nocolon", ":id", "kind:", "", 7 }) do
    Assert.throws(function()
      AssetNeeds.parse(key)
    end, "malformed key " .. tostring(key))
  end
  Assert.throws(function()
    AssetNeeds.key({ kind = "a:b", id = "c" })
  end, "kind must not contain a colon")
  Assert.throws(function()
    AssetNeeds.key({ kind = "a", id = "" })
  end, "id must not be empty")
end

function T.legend_ops_declare_the_ho_oh_need()
  local found = 0
  for name in pairs(Schema.OPERATIONS) do
    if name:match("^legend_cutscene_") or name == "legend_cinematic" then
      found = found + 1
      Assert.deepEqual(AssetNeeds.forSteps({ { op = name } }), { HO_OH }, name)
    end
  end
  Assert.isTrue(found > 0, "the legend ops exist")
end

function T.for_steps_walks_if_and_switch_and_dedupes()
  local steps = {
    { op = "legend_cutscene_bell_begin" },
    {
      op = "if",
      yes = { { op = "legend_cutscene_bell_rise" } },
      no = { { op = "legend_cinematic", destination = 0 } },
    },
    {
      op = "switch",
      cases = { [1] = { { op = "legend_cutscene_effect_begin" } } },
      default = { { op = "legend_cutscene_effect_end" } },
    },
  }
  Assert.deepEqual(AssetNeeds.forSteps(steps), { HO_OH })
end

function T.for_steps_without_asset_ops_is_empty()
  Assert.deepEqual(AssetNeeds.forSteps({ S.stop() }), {})
  Assert.deepEqual(AssetNeeds.forSteps({}), {})
end

function T.argument_dependent_declaration_reads_the_step()
  Schema.OPERATIONS.asset_needs_probe_op = {
    fields = {},
    assets = function(step)
      return { { kind = "probe", id = step.which } }
    end,
  }
  local ok, err = pcall(function()
    Assert.deepEqual(
      AssetNeeds.forSteps({
        { op = "asset_needs_probe_op", which = "b" },
        { op = "asset_needs_probe_op", which = "a" },
        { op = "asset_needs_probe_op", which = "b" },
      }),
      { "probe:a", "probe:b" }
    )
  end)
  Schema.OPERATIONS.asset_needs_probe_op = nil
  assert(ok, err)
end

function T.for_resource_unions_the_optional_needs_hint()
  local resource = S.script({
    api = 1,
    id = "test.asset_needs_hint",
    needs = { { kind = "custom", id = "thing" } },
    steps = { { op = "legend_cutscene_bell_begin" } },
  })
  Assert.deepEqual(AssetNeeds.forResource(resource), { "custom:thing", HO_OH })
  Assert.deepEqual(AssetNeeds.forResource(S.script({ api = 1, id = "test.asset_needs_none", steps = { S.stop() } })), {})
end

function T.validator_rejects_malformed_needs_hint()
  local function script(needs)
    return { kind = "field_script", api = 1, id = "test.bad_needs", needs = needs, steps = { S.stop() } }
  end
  local ok = S.validate(script({ { kind = "custom", id = "thing" } }))
  Assert.isTrue(ok, "a well-formed hint validates")
  for label, needs in pairs({
    notArray = "custom:thing",
    missingId = { { kind = "custom" } },
    nonStringKind = { { kind = 1, id = "thing" } },
    colonInKind = { { kind = "a:b", id = "thing" } },
    emptyId = { { kind = "custom", id = "" } },
  }) do
    local valid, err = S.validate(script(needs))
    Assert.isNil(valid, label)
    Assert.equal(assert(err).code, ScriptErrors.SCRIPT_SCHEMA_INVALID, label)
  end
end

return { tests = T }
