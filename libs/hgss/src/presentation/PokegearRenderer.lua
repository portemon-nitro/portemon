-- The gear companion's shared shell composition: the shell planes, the
-- civil clock strip, the fixed card strip, and the active child, drawn from
-- the plan's resolved image paths and the shell snapshot only. The child
-- renderer routes by closed semantic card, never by require strings in
-- generated data; brightness and window-mask composition stay explicit.
-- Borrows prepared images and draws with no allocation. Pure presentation:
-- no love globals, the host graphics namespace arrives through resources.

local LogicalSurface = require("libs.ui.src.LogicalSurface")
local PokegearAtlas = require("libs.hgss.src.presentation.PokegearAtlas")
local PokegearConfigureRenderer = require("libs.hgss.src.presentation.PokegearConfigureRenderer")
local PokegearPhoneRenderer = require("libs.hgss.src.presentation.PokegearPhoneRenderer")

---@class PokegearRenderer
local PokegearRenderer = {}

-- Source clock sprite centers on the information screen: the four hour and
-- minute digits, the colon, the weekday strip, and the reception indicator.
local DIGIT_X = { 70, 86, 110, 126 }
local DIGIT_Y = 46
local COLON_X = 98
local WEEKDAY_X = 173
local SIGNAL_X = 197
local ICON_Y = 48

---@param panes table[]
---@param id string
---@return table<string, unknown>? pane
local function findPane(panes, id)
  for _, pane in ipairs(panes) do
    if type(pane) == "table" and pane.id == id then
      return pane
    end
  end
  return nil
end

---@param graphics love.graphics
---@param images table<string, unknown>
---@param path unknown
---@param what string
local function drawPrepared(graphics, images, path, what)
  assert(type(path) == "string", "the companion plan resolves its " .. what .. " image")
  local lease = images[path]
  assert(lease ~= nil, "the companion render needs its prepared " .. what .. " image")
  graphics.setColor(1, 1, 1, 1)
  lease:draw(graphics, 0, 0)
end

---@param graphics love.graphics
---@param images table<string, unknown>
---@param frames table[] compiled sprite frames
---@param frameIndex integer one-based frame
---@param x number sprite center
---@param y number sprite center
local function drawSprite(graphics, images, frames, frameIndex, x, y)
  local frame = assert(frames[frameIndex], "the clock sprite strip carries its frame")
  local lease = images[frame.image]
  assert(lease ~= nil, "the companion render needs its prepared clock sprite")
  lease:draw(graphics, x + frame.anchorX, y + frame.anchorY)
end

-- The civil clock strip in upper information-local coordinates: the source
-- digit sprites with the native colon phase, the weekday strip frame
-- (Sunday first), and the reception indicator frame.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param sprites table<string, table[]>
---@param clock table<string, unknown>
local function drawClock(graphics, images, sprites, clock)
  local hour = clock.hour
  local minute = clock.minute
  local weekday = clock.weekday
  assert(type(hour) == "number" and type(minute) == "number", "the clock strip carries civil time")
  assert(type(weekday) == "number", "the clock strip carries its weekday")
  graphics.setColor(1, 1, 1, 1)
  local digits = { math.floor(hour / 10), hour % 10, math.floor(minute / 10), minute % 10 }
  for index, digit in ipairs(digits) do
    drawSprite(graphics, images, sprites.digits, digit + 1, DIGIT_X[index], DIGIT_Y)
  end
  if clock.colon == 1 then
    drawSprite(graphics, images, sprites.colon, 1, COLON_X, DIGIT_Y)
  end
  -- The shell weekday counts Monday as zero; the source strip starts Sunday.
  drawSprite(graphics, images, sprites.weekday, (weekday + 1) % 7 + 1, WEEKDAY_X, ICON_Y)
  drawSprite(graphics, images, sprites.signal, clock.signal == true and 1 or 2, SIGNAL_X, ICON_Y)
end

-- The strip band atlas is the source picker tilemap: the full picker row,
-- the pressed row, and the blank block that masks locked cards. Strip
-- cells are 48 wide on 8-pixel tile columns.
local STRIP_Y = 160
local STRIP_HEIGHT = 32
local CELL_WIDTH = 48
local ATLAS_PICKER_Y = 0
local ATLAS_PRESSED_Y = 32
local ATLAS_BLANK_Y = 64
local SLOT_X = { configure = 8, radio = 56, map = 104, phone = 152 }
local SLOT_CENTER_X = { configure = 32, radio = 80, map = 128, phone = 176 }
local SLOT_CENTER_Y = 176

-- Source cursor corner offsets from the button center, in sprite order:
-- top-left, bottom-left, top-right, bottom-right.
local CORNER_OFFSETS = { { -16, -10 }, { -16, 10 }, { 16, -10 }, { 16, 10 } }

-- The fixed card strip over the lower controls band, drawn from the source
-- picker atlas: the full picker, the pressed cell of the card being
-- switched to, the blank block over locked radio/map cards, and the focus
-- corners at the focused card while the strip owns focus. While a phone
-- call dims the touchscreen, the strip repaints from the phone plan's
-- precompiled dimmed strip atlas instead; a missing dim role during a
-- dimmed call is a programming error, never a reason to draw bright.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param content table<string, unknown>
---@param view table<string, unknown>
local function drawStrip(graphics, images, content, view)
  local atlasPath = content.shellForeground
  if view.tab == "phone" then
    local child = view.child
    local childView = type(child) == "table" and (child --[[@as table<string, unknown>]]).view or nil
    local call = type(childView) == "table" and (childView --[[@as table<string, unknown>]]).call or nil
    if
      type(call) == "table" and (call --[[@as table<string, unknown>]]).dim == true
    then
      local published = type(child) == "table" and (child --[[@as table<string, unknown>]]).presentation or nil
      local planContent = type(published) == "table" and (published --[[@as table<string, unknown>]]).content or nil
      local dimAtlas = type(planContent) == "table"
          and (planContent --[[@as table<string, unknown>]]).dimShellForeground
        or nil
      assert(type(dimAtlas) == "string", "the dimmed phone call needs its dimmed strip atlas")
      atlasPath = dimAtlas
    end
  end
  assert(type(atlasPath) == "string", "the companion plan resolves its shell image")
  local atlas = images[atlasPath] --[[@as love.Image]]
  assert(atlas ~= nil, "the companion render needs its prepared shell image")
  graphics.setColor(1, 1, 1, 1)
  PokegearAtlas.draw(graphics, atlas, 0, ATLAS_PICKER_Y, 256, STRIP_HEIGHT, 0, STRIP_Y)
  local cards = view.cards --[[@as table<string, boolean>]]
  assert(type(cards) == "table", "the companion view carries its card availability")
  for _, tab in ipairs({ "radio", "map" }) do
    if cards[tab] ~= true then
      PokegearAtlas.draw(graphics, atlas, 0, ATLAS_BLANK_Y, CELL_WIDTH, STRIP_HEIGHT, SLOT_X[tab], STRIP_Y)
    end
  end
  local pressedX = SLOT_X[
    view.tab --[[@as string]]
  ]
  if pressedX ~= nil then
    PokegearAtlas.draw(graphics, atlas, pressedX, ATLAS_PRESSED_Y, CELL_WIDTH, STRIP_HEIGHT, pressedX, STRIP_Y)
  end
  local corners = content.cursorCorners --[[@as table[]?]]
  local centerX = SLOT_CENTER_X[
    view.focus --[[@as string]]
  ]
  if corners ~= nil and view.entered ~= true and centerX ~= nil then
    local tick = type(view.ticks) == "number" and view.ticks or 0
    for index, offset in ipairs(CORNER_OFFSETS) do
      local frames = corners[index]
      local frame = nil
      if type(frames) == "table" and type(frames[1]) == "table" then
        -- Compiled corner animations blink on their source durations.
        local total = 0
        for _, candidate in ipairs(frames) do
          local duration = (candidate --[[@as table<string, unknown>]]).duration or 1
          if type(duration) ~= "number" or duration < 1 then
            duration = 1
          end
          total = total + duration
        end
        local elapsed = total > 0 and (tick % total) or 0
        for _, candidate in ipairs(frames) do
          local record = candidate --[[@as table<string, unknown>]]
          local duration = record.duration or 1
          if type(duration) ~= "number" or duration < 1 then
            duration = 1
          end
          if elapsed < duration then
            frame = record
            break
          end
          elapsed = elapsed - duration
        end
        frame = frame or frames[#frames]
      elseif type(frames) == "string" then
        -- Legacy single-image corners stay static.
        local lease = images[frames]
        assert(lease ~= nil, "the companion render needs its prepared cursor corners")
        lease:draw(graphics, centerX + offset[1] - 8, SLOT_CENTER_Y + offset[2] - 8)
        frame = nil
      else
        assert(frames ~= nil, "the companion render needs its prepared cursor corners")
      end
      if type(frame) == "table" then
        local path = assert((frame --[[@as table<string, unknown>]]).image, "corner frames carry their image")
        local lease = images[path]
        assert(lease ~= nil, "the companion render needs its prepared cursor corners")
        local anchorX = (frame --[[@as table<string, unknown>]]).anchorX or -8
        local anchorY = (frame --[[@as table<string, unknown>]]).anchorY or -8
        if type(anchorX) ~= "number" then
          anchorX = -8
        end
        if type(anchorY) ~= "number" then
          anchorY = -8
        end
        lease:draw(graphics, centerX + offset[1] + anchorX, SLOT_CENTER_Y + offset[2] + anchorY)
      end
    end
  end
end

-- The active child inside the controls pane: the setup card through its
-- exact frame renderer, every other card as its resolved compiled plane
-- beneath the shared strip.
---@param graphics love.graphics
---@param images table<string, unknown>
---@param text table<string, unknown>?
---@param nameText table<string, unknown>? the borrowed phone-list name renderer
---@param content table<string, unknown>
---@param view table<string, unknown>
local function drawChild(graphics, images, text, nameText, content, view)
  local tab = view.tab
  local child = view.child
  if tab == "configure" and type(child) == "table" and type(child.view) == "table" then
    PokegearConfigureRenderer.drawPane(
      graphics,
      images,
      text,
      content,
      child.view --[[@as table<string, unknown>]],
      view.unlockedSkins --[[@as table<integer, integer>]],
      view
    )
    return
  end
  local presentation = child ~= nil and type(child) == "table" and child.presentation or nil
  if
    type(presentation) == "table" and type((presentation --[[@as table<string, unknown>]]).render) == "function"
  then
    local published = presentation --[[@as table<string, unknown>]]
    local render = published.render --[[@as fun(resources: table, child: table, plan: table, shell: table)]]
    render(
      { graphics = graphics, images = images, textRenderer = text, phoneNameTextRenderer = nameText },
      child --[[@as table<string, unknown>]],
      published,
      view
    )
    return
  end
  local visuals = content.childVisuals
  local path = type(visuals) == "table" and visuals[
    tab --[[@as string]]
  ]
  if type(path) == "string" then
    local lease = images[path]
    if lease ~= nil then
      graphics.setColor(1, 1, 1, 1)
      lease:draw(graphics, 0, 0)
    end
  end
end

-- Draws the published plan with borrowed collaborators: information carries
-- the shell information plane and the clock, controls carry the shell
-- foreground, the active child, and the strip. Runs inside one pushed
-- graphics scope per pane and leaves identity tint behind.
---@param resources table<string, unknown> borrowed host collaborators
---@param view table<string, unknown> the shell snapshot
---@param plan ApplicationPlan the already-resolved published plan
function PokegearRenderer.draw(resources, view, plan)
  local graphics = assert(resources.graphics, "the companion render borrows its host graphics")
  local images = assert(resources.images, "the companion render borrows its prepared images")
  assert(type(images) == "table", "the companion render borrows its prepared images")
  local text = resources.textRenderer
  if text ~= nil then
    assert(type(text) == "table", "the companion render borrows its text primitives")
  end
  local phoneNameText = resources.phoneNameTextRenderer
  if phoneNameText ~= nil then
    assert(type(phoneNameText) == "table", "the companion render borrows its phone name primitives")
  end
  local panes = assert(plan.panes, "the companion plan carries its panes")
  assert(type(panes) == "table", "the companion plan carries its panes")
  local content = assert(plan.content, "the companion plan carries its payload")
  assert(type(content) == "table", "the companion plan carries its payload")
  local information = findPane(panes --[[@as table[] ]], "information")
  local controls = findPane(panes --[[@as table[] ]], "controls")
  if information ~= nil then
    local placement = assert(information.placement, "the information pane carries its placement")
    LogicalSurface.draw(graphics, placement --[[@as LayoutGeometry.Placement]], function()
      drawPrepared(graphics, images --[[@as table<string, unknown>]], content.shellInformation, "shell information")
      local child = view.child
      local published = type(child) == "table" and (child --[[@as table<string, unknown>]]).presentation or nil
      local renderInformation = type(published) == "table"
          and (published --[[@as table<string, unknown>]]).renderInformation
        or nil
      if type(renderInformation) == "function" then
        (renderInformation --[[@as fun(resources: table, child: table, plan: table, shell: table)]])({
          graphics = graphics,
          images = images,
          textRenderer = text,
          phoneNameTextRenderer = phoneNameText,
        }, child --[[@as table<string, unknown>]], published --[[@as table<string, unknown>]], view)
      end
      local clock = view.clock
      local sprites = content.clockSprites
      if type(clock) == "table" and type(sprites) == "table" then
        drawClock(
          graphics,
          images --[[@as table<string, unknown>]],
          sprites --[[@as table<string, table[]>]],
          clock --[[@as table<string, unknown>]]
        )
      end
    end)
  end
  if controls ~= nil then
    local placement = assert(controls.placement, "the controls pane carries its placement")
    LogicalSurface.draw(graphics, placement --[[@as LayoutGeometry.Placement]], function()
      local child = view.child
      local childView = type(child) == "table" and (child --[[@as table<string, unknown>]]).view or nil
      -- A live phone call without an open choice paints its strip first
      -- so the fast-forward sprite at y160 overlays the strip; every
      -- other state keeps the child-then-strip order.
      local stripFirst = view.tab == "phone"
        and type(childView) == "table"
        and type((childView --[[@as table<string, unknown>]]).call) == "table"
        and (childView --[[@as table<string, unknown>]]).callMenu == nil
      local stripHidden = type(child) == "table" and (child --[[@as table<string, unknown>]]).stripHidden == true
      if stripFirst and not stripHidden then
        drawStrip(graphics, images --[[@as table<string, unknown>]], content --[[@as table<string, unknown>]], view)
      end
      drawChild(
        graphics,
        images --[[@as table<string, unknown>]],
        text --[[@as table<string, unknown>?]],
        phoneNameText --[[@as table<string, unknown>?]],
        content --[[@as table<string, unknown>]],
        view
      )
      if not stripFirst and not stripHidden then
        drawStrip(graphics, images --[[@as table<string, unknown>]], content --[[@as table<string, unknown>]], view)
      end
      -- The phone tooltip bar shows over the bottom strip whenever the
      -- phone child owes a prompt (context, sort, or choice menus): the
      -- child paints below the strip, so the shell repaints the bar on
      -- top here from the child's detached prompt and palette.
      if view.tab == "phone" then
        local phoneTooltip = type(childView) == "table" and (childView --[[@as table<string, unknown>]]).tooltip or nil
        if type(phoneTooltip) == "string" and phoneTooltip ~= "" then
          local phonePresentation = type(child) == "table" and (child --[[@as table<string, unknown>]]).presentation
            or nil
          local phoneContent = type(phonePresentation) == "table"
              and (phonePresentation --[[@as table<string, unknown>]]).content
            or nil
          local tooltipPalette = type(phoneContent) == "table"
              and (phoneContent --[[@as table<string, unknown>]]).tooltipPalette
            or nil
          if type(tooltipPalette) == "table" then
            PokegearPhoneRenderer.drawTooltipBar(
              graphics,
              text --[[@as table<string, unknown>?]],
              tooltipPalette --[[@as table]],
              phoneTooltip
            )
          end
        end
      end
      -- A card fade covers the whole lower screen, strip included.
      local fade = type(childView) == "table" and (childView --[[@as table<string, unknown>]]).fade or nil
      if type(fade) == "number" and fade > 0 then
        graphics.setColor(0, 0, 0, fade)
        graphics.rectangle("fill", 0, 0, 256, 192)
        graphics.setColor(1, 1, 1, 1)
      end
    end)
  end
  graphics.setColor(1, 1, 1, 1)
end

return PokegearRenderer
