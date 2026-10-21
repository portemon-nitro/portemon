-- App integration fixture that isolates startup-title animation and asset loading.

local FakeStartupTitleState = {}

function FakeStartupTitleState.new(options)
  local state = { kind = "startup-title", titleReady = false, finished = false, failure = nil }
  function state:update()
    if self.finished then
      return
    end
    if not self.titleReady then
      self.titleReady = true
      if options.onTitleReady ~= nil then
        options.onTitleReady()
      end
    end
    local ok, ready, failure = pcall(options.derivedAssets.requestMilestone, "bootstrap", "required")
    if not ok or failure ~= nil then
      self.failure = tostring(ok and failure or ready)
      return
    end
    if not ready then
      return
    end
    local staged, menu = pcall(options.stageMenu)
    if not staged then
      self.failure = tostring(menu)
      return
    end
    self.finished = true
    options.onFinished(menu)
  end
  function state:keypressed(key)
    if key == "escape" and not self.finished and options.onCancel ~= nil then
      options.onCancel()
    end
  end
  function state:draw()
    love.graphics.print(self.failure or "Preparing startup…", 0, 0)
  end
  function state:dispose() end
  return state
end

return FakeStartupTitleState
