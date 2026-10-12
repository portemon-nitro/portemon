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
  Assert.equal(assert(stack:top()).id, move.id, "the parent resumes after its child is removed")
  Assert.equal(assert(stack:top()).payload.slot0, 0, "the resumed handle carries the owned payload content")
  Assert.equal(stack:layers()[1].opener.controlId, "party:move:0", "the base opener remains remembered")
end

function T.tests.borrowed_top_handles_never_expose_owned_payload_tables()
  Assert.isTrue(loaded, "modal layers require an explicit Save Editor stack owner")
  local stack = ModalStack.new()
  stack:push({
    id = "move:1",
    kind = "move",
    payload = { slot0 = 0 },
    opener = { controlId = "party:move:0", regionId = "party:moves", scrollAnchor = 0 },
  })
  stack:push({
    id = "value:2",
    kind = "number",
    payload = { value = 35 },
    opener = { controlId = "party-move:pp", regionId = "modal:move:1", scrollAnchor = 0 },
  })
  local borrowed = assert(stack:top(), "the newest layer owns input")
  borrowed.payload.value = 999
  Assert.equal(stack:layers()[2].payload.value, 35, "borrowed payload edits never reach the owned record")
  Assert.equal(stack:top().payload.value, 35, "rereading the top handle shows the owned record unchanged")
end

function T.tests.stable_snapshots_stay_distinct_and_pop_invalidates_the_cached_view()
  Assert.isTrue(loaded, "modal layers require an explicit Save Editor stack owner")
  local stack = ModalStack.new()
  stack:push({
    id = "move:1",
    kind = "move",
    payload = { slot0 = 0 },
    opener = { controlId = "party:move:0", regionId = "party:moves", scrollAnchor = 0 },
  })
  stack:push({
    id = "value:2",
    kind = "number",
    payload = { value = 35 },
    opener = { controlId = "party-move:pp", regionId = "modal:move:1", scrollAnchor = 0 },
  })
  local first = stack:layers()
  local second = stack:layers()
  Assert.deepEqual(first, second, "stable snapshots carry the same content")
  Assert.isTrue(not rawequal(first, second), "stable snapshots never share their container")
  Assert.isTrue(not rawequal(first[2].payload, second[2].payload), "stable snapshots never share owned payload tables")
  local popped = stack:pop()
  Assert.equal(popped.id, "value:2", "pop returns the child for owner cleanup")
  Assert.equal(#stack:layers(), 1, "pop invalidates the cached detached representation")
  Assert.equal(stack:top().id, "move:1", "the parent resumes after its child is removed")
  Assert.equal(stack:layers()[1].payload.slot0, 0, "the remaining owned payload is unchanged by the pop")
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
