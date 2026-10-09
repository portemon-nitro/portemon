-- The Save Editor keeps modal lifetime and opener state in one typed LIFO owner.

local Assert = require("tests.support.Assert")
local loaded, ModalStack = pcall(require, "app.src.saveeditor.SaveEditorModalStack")

local T = { tests = {} }

function T.tests.layers_are_an_ordered_snapshot_and_pop_returns_only_the_child()
  Assert.isTrue(loaded, "modal layers require an explicit Save Editor stack owner")
  local stack = ModalStack.new()
  local move = {
    id = "move:1",
    kind = "move",
    payload = { slot0 = 0 },
    opener = { controlId = "party:move:0", regionId = "party:moves", scrollAnchor = 0 },
  }
  local value = {
    id = "value:2",
    kind = "number",
    payload = { value = 35 },
    opener = { controlId = "party-move:pp", regionId = "modal:move:1", scrollAnchor = 0 },
  }

  stack:push(move)
  stack:push(value)
  local layers = stack:layers()
  Assert.equal(#layers, 2, "the snapshot contains each retained layer")
  Assert.equal(layers[1].id, move.id, "the parent remains below the child")
  Assert.equal(layers[2].id, value.id, "the child is the final render/input layer")
  layers[1].payload.slot0 = 4
  layers[1].opener.controlId = "changed"
  Assert.equal(stack:layers()[1].payload.slot0, 0, "snapshot payload edits do not leak")
  Assert.equal(stack:layers()[1].opener.controlId, "party:move:0", "snapshot opener edits do not leak")
  Assert.equal(stack:top().id, value.id, "only the newest layer owns input")
  Assert.equal(stack:pop(), value, "pop returns the child for owner cleanup")
  Assert.equal(stack:top(), move, "the parent resumes after its child is removed")
  Assert.equal(stack:layers()[1].opener.controlId, "party:move:0", "the base opener remains remembered")
end

function T.tests.duplicate_layer_identity_is_rejected()
  Assert.isTrue(loaded, "modal layers require an explicit Save Editor stack owner")
  local stack = ModalStack.new()
  local layer = {
    id = "leave:1",
    kind = "leave",
    payload = {},
    opener = { controlId = "back", regionId = "global-footer", scrollAnchor = 0 },
  }
  stack:push(layer)
  Assert.throws(function()
    stack:push(layer)
  end, "a live layer identity cannot be pushed twice")
end

return T
