-- A missing desktop bridge is explicit and never reports a chosen path.

local Assert = require("tests.support.Assert")
local NativeRomPicker = require("app.src.launcher.NativeRomPicker")
local PICKER_MODULE = "app.src.launcher.NativeRomPicker"

local T = {}

-- A capability probe answers whether a native dialog can open without
-- opening one. It returns a plain boolean, never a dialog result, and it
-- must not leave native initialization behind.
local function withAvailabilityProbe(spec, fn)
  local calls = { cdef = 0, load = 0, init = 0, quit = 0, open = 0 }
  local library = {}
  function library.NFD_Init()
    calls.init = calls.init + 1
    if spec.initResult ~= nil then
      return spec.initResult
    end
    return 1
  end
  function library.NFD_Quit()
    calls.quit = calls.quit + 1
  end
  function library.NFD_OpenDialogU8(_)
    calls.open = calls.open + 1
    return 2
  end
  function library.NFD_GetError()
    return "injected dialog error"
  end
  function library.NFD_FreePathU8() end

  local ffi = { arch = spec.arch or "x64" }
  function ffi.cdef(_)
    calls.cdef = calls.cdef + 1
  end
  function ffi.load(_)
    calls.load = calls.load + 1
    if spec.loadError ~= nil then
      error(spec.loadError)
    end
    return library
  end
  function ffi.new(_)
    return {}
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
    return spec.os or "Linux"
  end
  local ok, err = pcall(fn, require(PICKER_MODULE), calls)
  love.system.getOS = originalGetOS
  package.loaded.ffi = previousFfi
  package.loaded[PICKER_MODULE] = previousPicker
  if not ok then
    error(err, 0)
  end
end

function T.unsupported_platform_has_no_native_bridge()
  withAvailabilityProbe({ os = "iOS" }, function(picker, calls)
    Assert.equal(picker.available(), false)
    Assert.equal(calls.init, 0)
    Assert.equal(calls.quit, 0)
    Assert.equal(calls.open, 0)
  end)
end

function T.unsupported_architecture_has_no_native_bridge()
  withAvailabilityProbe({ os = "Linux", arch = "x86" }, function(picker, calls)
    Assert.equal(picker.available(), false)
    Assert.equal(calls.init, 0)
    Assert.equal(calls.quit, 0)
    Assert.equal(calls.open, 0)
  end)
end

function T.missing_library_has_no_native_bridge_without_initializing()
  withAvailabilityProbe({ loadError = "injected load error" }, function(picker, calls)
    Assert.equal(picker.available(), false)
    Assert.equal(calls.init, 0)
    Assert.equal(calls.quit, 0)
    Assert.equal(calls.open, 0)
  end)
end

function T.failing_native_init_has_no_bridge_and_balances_init_quit()
  withAvailabilityProbe({ initResult = 0 }, function(picker, calls)
    Assert.equal(picker.available(), false)
    Assert.equal(calls.init, 1)
    Assert.equal(calls.quit, 1)
    Assert.equal(calls.open, 0)
  end)
end

function T.loadable_bridge_reports_available_without_opening_a_dialog()
  withAvailabilityProbe({}, function(picker, calls)
    Assert.equal(picker.available(), true)
    Assert.equal(calls.open, 0)
    Assert.equal(calls.init, calls.quit)
  end)
end

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

-- The probe and the dialog share one bridge binding: declarations apply once,
-- the probe never opens a dialog, and init/quit stay balanced across both.
function T.probe_and_dialog_share_one_bridge_binding()
  withFakeBridge(1, false, function(picker, calls)
    Assert.equal(picker.available(), true)
    Assert.equal(calls.open, 0, "the probe never opens a dialog")
    local result = picker.openSingle()
    Assert.equal(result.kind, "path")
    Assert.equal(result.path, "/tmp/game.nds")
    Assert.equal(calls.cdef, 1, "probe and dialog share one declaration")
    Assert.equal(calls.open, 1)
    Assert.equal(calls.init, calls.quit, "every init is balanced by a quit")
  end)
end

local ANDROID_REQUEST = "123e4567-e89b-12d3-a456-426614174000"
local ANDROID_OTHER = "223e4567-e89b-12d3-a456-426614174000"

local function withAndroidHost(spec, fn)
  spec = spec or {}
  local results = {}
  for _, result in ipairs(spec.results or {}) do
    results[#results + 1] = result
  end
  local calls = { open = 0, poll = 0 }
  local previousFfi = package.loaded.ffi
  local previousPicker = package.loaded[PICKER_MODULE]
  local originalGetOS = love.system.getOS
  local originalOpen = love.system.openRomPicker
  local originalPoll = love.system.pollRomPicker
  package.loaded[PICKER_MODULE] = nil
  love.system.getOS = function()
    return "Android"
  end
  love.system.openRomPicker = function()
    calls.open = calls.open + 1
    if spec.openBusy == true then
      return nil, "the previous picker operation is still finishing"
    end
    return spec.requestId or ANDROID_REQUEST
  end
  love.system.pollRomPicker = function()
    calls.poll = calls.poll + 1
    return table.remove(results, 1)
  end
  if spec.missingPoll == true then
    love.system.pollRomPicker = nil
  end
  local ok, err = pcall(function()
    fn(require(PICKER_MODULE), calls)
  end)
  love.system.getOS = originalGetOS
  love.system.openRomPicker = originalOpen
  love.system.pollRomPicker = originalPoll
  package.loaded.ffi = previousFfi
  package.loaded[PICKER_MODULE] = previousPicker
  if not ok then
    error(err, 0)
  end
end

local function writeAndroidStage(requestId, extension, validate)
  if validate ~= false then
    Assert.isTrue(requestId:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil)
  end
  Assert.isTrue(love.filesystem.createDirectory("imports"), "Android stage root setup failed")
  local path = "imports/" .. requestId .. "." .. (extension or "nds")
  Assert.isTrue(love.filesystem.write(path, "completed private copy"), "Android stage setup failed")
  return path
end

function T.android_bridge_availability_and_open_return_one_pending_request()
  withAndroidHost({}, function(picker, calls)
    Assert.equal(picker.available(), true, "both private Android bindings are required")
    Assert.deepEqual(picker.openSingle(), { kind = "pending", requestId = ANDROID_REQUEST })
    Assert.deepEqual(calls, { open = 1, poll = 0 }, "opening the chooser never polls or blocks")
  end)
  withAndroidHost({ missingPoll = true }, function(picker)
    Assert.equal(picker.available(), false, "a half-present bridge is not an Android picker")
  end)
  withAndroidHost({ openBusy = true }, function(picker, calls)
    local result = picker.openSingle()
    Assert.equal(result.kind, "error")
    Assert.isTrue(result.message:find("still finishing", 1, true) ~= nil, "native busy errors stay actionable")
    Assert.deepEqual(calls, { open = 1, poll = 0 }, "a busy reattempt opens no second chooser")
  end)
end

function T.android_terminal_path_is_consumed_once_and_remains_caller_owned()
  withAndroidHost({
    results = {
      {
        requestId = ANDROID_REQUEST,
        kind = "path",
        relativePath = "imports/" .. ANDROID_REQUEST .. ".nds",
        displayName = "My game.NDS",
      },
    },
  }, function(picker, calls)
    Assert.equal(type(picker.poll), "function", "Android completion needs nonblocking result polling")
    local path = writeAndroidStage(ANDROID_REQUEST)
    local ok, err = pcall(function()
      local result = picker.poll(ANDROID_REQUEST)
      Assert.deepEqual(result, {
        requestId = ANDROID_REQUEST,
        kind = "path",
        relativePath = path,
        displayName = "My game.NDS",
      })
      Assert.notNil(love.filesystem.getInfo(path), "a matching result transfers no file ownership to the adapter")
      Assert.isNil(picker.poll(ANDROID_REQUEST), "the native terminal result is one-shot")
      Assert.deepEqual(calls, { open = 0, poll = 2 })
    end)
    pcall(love.filesystem.remove, path)
    if not ok then
      error(err, 0)
    end
  end)
end

function T.android_stale_results_are_drained_and_removed_without_a_current_request()
  withAndroidHost({
    results = {
      {
        requestId = ANDROID_REQUEST,
        kind = "path",
        relativePath = "imports/" .. ANDROID_REQUEST .. ".zip",
        displayName = "cloud copy.zip",
      },
    },
  }, function(picker, calls)
    Assert.equal(type(picker.poll), "function", "stale cleanup needs nonblocking result polling")
    local path = writeAndroidStage(ANDROID_REQUEST, "zip")
    local ok, err = pcall(function()
      Assert.isNil(picker.poll(nil), "no current token never navigates or imports")
      Assert.isNil(love.filesystem.getInfo(path), "an abandoned completed stage is removed")
      Assert.isNil(picker.poll(ANDROID_OTHER), "a different token cannot adopt the stale result")
      Assert.deepEqual(calls, { open = 0, poll = 2 })
    end)
    pcall(love.filesystem.remove, path)
    if not ok then
      error(err, 0)
    end
  end)
end

function T.android_uuid_mismatch_consumes_and_removes_the_stale_stage()
  withAndroidHost({
    results = {
      {
        requestId = ANDROID_REQUEST,
        kind = "path",
        relativePath = "imports/" .. ANDROID_REQUEST .. ".nds",
        displayName = "old request.nds",
      },
    },
  }, function(picker, calls)
    Assert.equal(type(picker.poll), "function", "UUID correlation needs nonblocking result polling")
    local path = writeAndroidStage(ANDROID_REQUEST)
    local ok, err = pcall(function()
      Assert.isNil(picker.poll(ANDROID_OTHER), "a mismatched UUID never adopts a terminal result")
      Assert.isNil(love.filesystem.getInfo(path), "the mismatched completed stage is removed as stale")
      Assert.deepEqual(calls, { open = 0, poll = 1 })
    end)
    pcall(love.filesystem.remove, path)
    if not ok then
      error(err, 0)
    end
  end)
end

function T.android_cancel_and_error_are_distinct_one_shot_results()
  withAndroidHost({
    results = {
      { requestId = ANDROID_REQUEST, kind = "cancel" },
      { requestId = ANDROID_REQUEST, kind = "error", message = "copy failed" },
    },
  }, function(picker, calls)
    Assert.equal(type(picker.poll), "function", "Android completion needs nonblocking result polling")
    Assert.deepEqual(picker.poll(ANDROID_REQUEST), { requestId = ANDROID_REQUEST, kind = "cancel" })
    Assert.deepEqual(picker.poll(ANDROID_REQUEST), {
      requestId = ANDROID_REQUEST,
      kind = "error",
      message = "copy failed",
    })
    Assert.isNil(picker.poll(ANDROID_REQUEST))
    Assert.deepEqual(calls, { open = 0, poll = 3 })
  end)
end

function T.android_malformed_or_unsafe_terminal_results_fail_before_removal()
  for _, result in ipairs({
    { requestId = ANDROID_REQUEST, kind = "unknown" },
    {
      requestId = ANDROID_REQUEST,
      kind = "path",
      relativePath = "imports/not-a-uuid.nds",
      displayName = "unsafe.nds",
    },
    {
      requestId = ANDROID_REQUEST,
      kind = "path",
      relativePath = "imports/../outside.nds",
      displayName = "../outside.nds",
    },
  }) do
    withAndroidHost({ results = { result } }, function(picker)
      Assert.equal(type(picker.poll), "function", "Android protocol validation needs result polling")
      Assert.throws(function()
        picker.poll(ANDROID_REQUEST)
      end, "malformed native results are invariant failures, not empty selections")
    end)
  end
  withAndroidHost({
    results = {
      {
        requestId = ANDROID_REQUEST,
        kind = "path",
        relativePath = "imports/not-a-uuid.nds",
        displayName = "unsafe.nds",
      },
    },
  }, function(picker)
    Assert.equal(type(picker.poll), "function", "Android protocol validation needs result polling")
    local path = writeAndroidStage("not-a-uuid", "nds", false)
    local ok, err = pcall(function()
      Assert.throws(function()
        picker.poll(ANDROID_REQUEST)
      end, "an invalid stage name is rejected before removal")
      Assert.notNil(love.filesystem.getInfo(path), "protocol rejection never deletes an unvalidated path")
    end)
    pcall(love.filesystem.remove, path)
    if not ok then
      error(err, 0)
    end
  end)
end

return { tests = T }
