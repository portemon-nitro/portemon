-- Adapts one private saved-scene snapshot to the existing field renderer.

local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")

local PhotoSceneRenderer = {}

---@param view table<string, unknown> ready immutable scene snapshot
---@param plan table<string, unknown> resolved Photo Album display plan
---@param resources table<string, unknown> renderer resources
function PhotoSceneRenderer.draw(view, plan, resources)
  assert(type(view) == "table", "ready photo view is required")
  assert(type(plan) == "table", "photo display plan is required")
  assert(type(resources) == "table", "photo renderer resources are required")
  local renderer = assert(resources.fieldRenderer, "PhotoSceneRenderer requires FieldRenderer")
  local sourceViewport = assert(view.viewport, "photo snapshot carries its native viewport")
  local viewport = FieldViewport.new(sourceViewport.width, sourceViewport.height, {
    mode = "expanded",
    x = sourceViewport.x,
    y = sourceViewport.y,
  })
  renderer:draw(
    assert(view.renderEnvironment),
    assert(view.camera),
    assert(view.worldParts),
    assert(view.spriteItems),
    viewport,
    assert(view.alpha),
    view.presentationPixelScale or 1
  )
end

return PhotoSceneRenderer
