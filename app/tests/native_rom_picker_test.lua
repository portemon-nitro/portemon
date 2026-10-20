-- A missing desktop bridge is explicit and never reports a chosen path.

local Assert = require("tests.support.Assert")
local NativeRomPicker = require("app.src.launcher.NativeRomPicker")
local PICKER_MODULE = "app.src.launcher.NativeRomPicker"

local T = {}

function T.unsupported_platform_reports_drop_fallback()
  local system = love.system
  local originalGetOS = system.getOS
  system.getOS = function()
    return "iOS"
  end
  local result = NativeRomPicker.openSingle()
  system.getOS = originalGetOS

  Assert.equal(result.kind, "error")
  Assert.isTrue(result.message:match("drag and drop") ~= nil)
end

local function withFakeBridge(status, failLoad, fn)
  local calls = { cdef = 0, init = 0, quit = 0, free = 0, open = 0 }
  local library = {}
  function library.NFD_Init()
    calls.init = calls.init + 1
    return 1
  end
  function library.NFD_Quit()
    calls.quit = calls.quit + 1
  end
  function library.NFD_OpenDialogU8(path)
    calls.open = calls.open + 1
    if status == 1 then
      path[0] = "/tmp/game.nds"
    end
    return status
  end
  function library.NFD_FreePathU8()
    calls.free = calls.free + 1
  end
  function library.NFD_GetError()
    return "injected dialog error"
  end

  local ffi = { arch = "x64" }
  function ffi.cdef(_)
    calls.cdef = calls.cdef + 1
  end
  function ffi.load(_)
    if failLoad then
      error("injected load error")
    end
    return library
  end
  function ffi.new(ctype)
    if ctype == "nfdu8char_t *[1]" then
      return {}
    end
    return { [0] = {}, [1] = {} }
  end
  function ffi.string(value)
    return value
  end

  local previousFfi = package.loaded.ffi
  local previousPicker = package.loaded[PICKER_MODULE]
  local originalGetOS = love.system.getOS
  package.loaded.ffi = ffi
  package.loaded[PICKER_MODULE] = nil
  love.system.getOS = function()
    return "Linux"
  end
  local ok, err = pcall(function()
    fn(require(PICKER_MODULE), calls)
  end)
  love.system.getOS = originalGetOS
  package.loaded.ffi = previousFfi
  package.loaded[PICKER_MODULE] = previousPicker
  if not ok then
    error(err, 0)
  end
end

function T.native_path_is_copied_and_each_owned_pointer_is_released_once()
  withFakeBridge(1, false, function(picker, calls)
    local result = picker.openSingle()
    Assert.equal(result.kind, "path")
    Assert.equal(result.path, "/tmp/game.nds")
    Assert.deepEqual(calls, { cdef = 1, init = 1, quit = 1, free = 1, open = 1 })
  end)
end

function T.ffi_declarations_are_not_repeated_between_dialogs()
  withFakeBridge(2, false, function(picker, calls)
    picker.openSingle()
    picker.openSingle()
    Assert.equal(calls.cdef, 1)
    Assert.equal(calls.init, 2)
    Assert.equal(calls.quit, 2)
  end)
end

function T.cancel_and_dialog_error_balance_initialization_without_freeing_missing_paths()
  for _, status in ipairs({ 2, 0 }) do
    withFakeBridge(status, false, function(picker, calls)
      local result = picker.openSingle()
      Assert.equal(result.kind, status == 2 and "cancel" or "error")
      Assert.equal(calls.init, 1)
      Assert.equal(calls.quit, 1)
      Assert.equal(calls.free, 0)
      Assert.equal(calls.open, 1)
    end)
  end
end

function T.invalid_library_load_reports_fallback_without_initializing()
  withFakeBridge(1, true, function(picker, calls)
    local result = picker.openSingle()
    Assert.equal(result.kind, "error")
    Assert.equal(calls.init, 0)
    Assert.equal(calls.quit, 0)
    Assert.equal(calls.free, 0)
  end)
end

return { tests = T }
