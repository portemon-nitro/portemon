-- Pure responsive geometry for the app-owned game launcher.

local ScrollViewport = require("libs.ui.src.ScrollViewport")

local LauncherLayout = {}

local MARGIN = 10
local HEADER_HEIGHT = 24
local ACTION_HEIGHT = 44
local ACTION_GAP = 8
local CANCEL_WIDTH = 112
local ROW_HEIGHT = 48
local ROW_GAP = 8

local function rect(x, y, width, height)
  return { x = x, y = y, width = math.max(1, width), height = math.max(1, height) }
end

local function contains(shape, x, y)
  return x >= shape.x and x < shape.x + shape.width and y >= shape.y and y < shape.y + shape.height
end

function LauncherLayout.cancelRect(x, y, width, height)
  local actionWidth = math.min(CANCEL_WIDTH, width)
  return rect(x + width - actionWidth, y, actionWidth, height)
end

function LauncherLayout.loading(width, height)
  assert(type(width) == "number" and width > 0 and type(height) == "number" and height > 0)
  local cancel = LauncherLayout.cancelRect(MARGIN, height - MARGIN - ACTION_HEIGHT, width - MARGIN * 2, ACTION_HEIGHT)
  local contentHeight = math.max(1, cancel.y - MARGIN - 12)
  local graph = { cancel = { up = {}, down = {}, left = {}, right = {} } }
  return {
    viewport = { x = 0, y = 0, width = width, height = height },
    content = rect(MARGIN, MARGIN, width - MARGIN * 2, contentHeight),
    cancelRect = cancel,
    graph = {
      graph = graph,
      targets = { cancel = { kind = "cancel", rect = cancel } },
      fallbacks = { "cancel" },
    },
  }
end

function LauncherLayout.compute(view, width, height)
  assert(type(view) == "table" and type(view.games) == "table", "launcher geometry needs its game snapshot")
  assert(type(width) == "number" and width > 0 and type(height) == "number" and height > 0)
  local header = rect(MARGIN, MARGIN, width - MARGIN * 2, HEADER_HEIGHT)
  local wide = width >= 480 and width / height >= 1.35
  local tiny = width < 280
  local stacked = width < 296
  local footerHeight = stacked and ACTION_HEIGHT * 2 + ACTION_GAP or ACTION_HEIGHT
  local footerY = height - MARGIN - footerHeight
  local contentX, contentWidth = MARGIN, width - MARGIN * 2
  local summary
  local listX, listWidth
  if wide then
    summary = rect(
      contentX,
      header.y + header.height + MARGIN,
      208,
      math.max(32, footerY - header.y - header.height - MARGIN * 2)
    )
    listX = summary.x + summary.width + 12
    listWidth = width - MARGIN - listX
  else
    local summaryHeight = math.min(96, math.max(32, math.floor((footerY - header.y - header.height) * 0.3)))
    if height < 300 then
      summaryHeight = 32
    end
    summary = rect(contentX, header.y + header.height + 4, contentWidth, summaryHeight)
    listX, listWidth = contentX, contentWidth
  end
  if stacked then
    local actionWidth = contentWidth
    local actions = {
      addGame = rect(contentX, footerY, actionWidth, ACTION_HEIGHT),
      play = rect(contentX, footerY + ACTION_HEIGHT + ACTION_GAP, actionWidth, ACTION_HEIGHT),
    }
    local listTop = summary.y + summary.height + 8
    local statusHeight = view.status ~= nil and ((view.canCancel == true or view.busy == true) and ACTION_HEIGHT or 24)
      or 0
    local statusRect = view.status ~= nil and rect(listX, listTop, listWidth, statusHeight) or nil
    local cancelRect = statusRect ~= nil
        and view.canCancel == true
        and LauncherLayout.cancelRect(statusRect.x, statusRect.y, statusRect.width, statusRect.height)
      or nil
    local list =
      LauncherLayout._list(view, listX, listTop + statusHeight, listWidth, footerY - listTop - statusHeight - 8)
    return {
      viewport = { x = 0, y = 0, width = width, height = height },
      header = header,
      summary = summary,
      statusRect = statusRect,
      cancelRect = cancelRect,
      list = list,
      actions = actions,
      scroll = { offset = list.offset, maxOffset = list.maxOffset },
      wide = wide,
      tiny = tiny,
      modal = view.modal and LauncherLayout._modal(view.modal, width, height) or nil,
      graph = LauncherLayout._graph(view, list.rows, actions, cancelRect),
    }
  end
  local actionWidth = math.floor((contentWidth - ACTION_GAP) / 2)
  local actions = {
    addGame = rect(contentX, footerY, actionWidth, ACTION_HEIGHT),
    play = rect(contentX + actionWidth + ACTION_GAP, footerY, contentWidth - actionWidth - ACTION_GAP, ACTION_HEIGHT),
  }
  local listTop = wide and header.y + header.height + MARGIN or summary.y + summary.height + 8
  local statusHeight = view.status ~= nil and ((view.canCancel == true or view.busy == true) and ACTION_HEIGHT or 24)
    or 0
  local statusRect = view.status ~= nil and rect(listX, listTop, listWidth, statusHeight) or nil
  local cancelRect = statusRect ~= nil
      and view.canCancel == true
      and LauncherLayout.cancelRect(statusRect.x, statusRect.y, statusRect.width, statusRect.height)
    or nil
  local list =
    LauncherLayout._list(view, listX, listTop + statusHeight, listWidth, footerY - listTop - statusHeight - 8)
  return {
    viewport = { x = 0, y = 0, width = width, height = height },
    header = header,
    summary = summary,
    statusRect = statusRect,
    cancelRect = cancelRect,
    list = list,
    actions = actions,
    scroll = { offset = list.offset, maxOffset = list.maxOffset },
    wide = wide,
    tiny = tiny,
    modal = view.modal and LauncherLayout._modal(view.modal, width, height) or nil,
    graph = LauncherLayout._graph(view, list.rows, actions, cancelRect),
  }
end

function LauncherLayout._list(view, x, y, width, height)
  local viewport = rect(x, y, width, height)
  local count = #view.games
  local stride = ROW_HEIGHT + ROW_GAP
  local extent = count == 0 and 0 or count * stride - ROW_GAP
  local maxOffset = math.max(0, extent - viewport.height)
  local offset = ScrollViewport.clamp(view.scrollOffset or 0, extent, viewport.height)
  local focusedIndex = 1
  for index, game in ipairs(view.games) do
    if game.gameId == view.focusedId then
      focusedIndex = index
      break
    end
  end
  if count > 0 and view.revealFocused ~= false then
    offset = ScrollViewport.reveal(offset, viewport.height, (focusedIndex - 1) * stride, ROW_HEIGHT)
  end
  offset = ScrollViewport.clamp(offset, extent, viewport.height)
  local rows = {}
  for index, game in ipairs(view.games) do
    local row = rect(x, y + (index - 1) * stride - offset, width, ROW_HEIGHT)
    rows[#rows + 1] = row
    rows[game.gameId] = row
  end
  return { viewport = viewport, rows = rows, offset = offset, maxOffset = maxOffset, extent = extent }
end

function LauncherLayout._modal(_, width, height)
  local boxWidth = math.min(360, width - MARGIN * 2)
  local boxHeight = math.min(160, height - MARGIN * 2)
  local box = rect((width - boxWidth) / 2, (height - boxHeight) / 2, boxWidth, boxHeight)
  local actionWidth = math.floor((box.width - 30) / 2)
  return {
    box = box,
    back = rect(box.x + 10, box.y + box.height - 54, actionWidth, ACTION_HEIGHT),
    pick = rect(box.x + 20 + actionWidth, box.y + box.height - 54, actionWidth, ACTION_HEIGHT),
  }
end

function LauncherLayout._graph(view, rows, actions, cancelRect)
  local graph, targets = {}, {}
  local function node(id, _, target)
    graph[id] = { up = {}, down = {}, left = {}, right = {} }
    targets[id] = target
    return id
  end
  if view.modal ~= nil then
    local back = node("back", nil, { kind = "back" })
    local pick = node("pick", nil, { kind = "pick" })
    for _, direction in ipairs({ "up", "down", "left", "right" }) do
      graph[back][direction] = { pick }
      graph[pick][direction] = { back }
    end
    return { graph = graph, targets = targets, fallbacks = { "back", "pick" } }
  end
  local add = node("add-game", actions.addGame, { kind = "add-game" })
  local play = node("play", actions.play, { kind = "play" })
  local cancel = cancelRect ~= nil and node("cancel", cancelRect, { kind = "cancel" }) or nil
  graph[add].right = { play }
  graph[play].left = { add }
  local first, previous
  for _, game in ipairs(view.games) do
    local id = node("game:" .. game.gameId, rows[game.gameId], { kind = "game", gameId = game.gameId })
    if first == nil then
      first = id
    end
    if previous ~= nil then
      graph[previous].down = { id }
      graph[id].up = { previous }
    end
    previous = id
  end
  if first ~= nil then
    graph[add].up = { first }
    graph[play].up = { first }
    graph[previous].down = { add }
  end
  if cancel ~= nil then
    graph[add].up = { cancel }
    graph[play].up = { cancel }
    graph[cancel].up = { add }
    graph[cancel].down = { first or add }
    if first ~= nil then
      graph[first].up = { cancel }
    end
  end
  return { graph = graph, targets = targets, fallbacks = { "add-game", first or "play", "play" } }
end

function LauncherLayout.hitTest(layout, view, x, y)
  assert(type(layout) == "table" and type(x) == "number" and type(y) == "number")
  if layout.modal ~= nil then
    if contains(layout.modal.back, x, y) then
      return { kind = "back" }
    elseif contains(layout.modal.pick, x, y) then
      return { kind = "pick" }
    end
    return { kind = "modal-backdrop" }
  end
  if layout.cancelRect ~= nil and contains(layout.cancelRect, x, y) then
    return { kind = "cancel" }
  end
  if contains(layout.actions.addGame, x, y) then
    return { kind = "add-game" }
  end
  if contains(layout.actions.play, x, y) then
    return { kind = "play" }
  end
  if contains(layout.list.viewport, x, y) then
    for _, game in ipairs(view.games) do
      local row = layout.list.rows[game.gameId]
      if contains(row, x, y) then
        return { kind = "game", gameId = game.gameId }
      end
    end
  end
  return { kind = "none" }
end

function LauncherLayout.hitTestLoading(layout, x, y)
  assert(type(layout) == "table" and type(x) == "number" and type(y) == "number")
  if contains(layout.cancelRect, x, y) then
    return { kind = "cancel" }
  end
  return { kind = "none" }
end

return LauncherLayout
