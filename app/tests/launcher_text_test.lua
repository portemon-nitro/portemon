-- Launcher-local display normalization: valid multibyte passes through,
-- invalid UTF-8 and C0 controls become "?", newlines preserved for
-- diagnostics, and the source path is never mutated.

local Assert = require("tests.support.Assert")
local LauncherText = require("app.src.launcher.LauncherText")

local T = {}

function T.sanitize_keeps_valid_multibyte_and_replaces_invalid()
  Assert.equal(LauncherText.sanitize("SoulSilver.nds"), "SoulSilver.nds")
  Assert.equal(LauncherText.sanitize("Pok\195\169mon.nds"), "Pok\195\169mon.nds")
  Assert.equal(LauncherText.sanitize("bad\255name.nds"), "bad?name.nds")
  Assert.equal(LauncherText.sanitize("a\0b"), "a?b")
  Assert.equal(LauncherText.sanitize("line1\nline2"), "line1\nline2")
  Assert.equal(LauncherText.sanitize(""), "")
end

function T.fit_text_stays_on_codepoint_boundaries()
  local font = {
    getWidth = function(_, text)
      return #text
    end,
  }
  -- 10 ASCII bytes fit in 10px.
  Assert.equal(LauncherText.fitText(font, "1234567890", 10), "1234567890")
  -- 11 bytes need truncation with ellipsis on a boundary.
  local fitted = LauncherText.fitText(font, "12345678901", 10)
  Assert.isTrue(fitted:sub(-3) == "…", "truncation appends an ellipsis")
  -- Valid multibyte name truncates without splitting the sequence.
  local multibyte = "Pok\195\169mon-" .. string.rep("x", 40)
  local wide = {
    getWidth = function(_, text)
      return #text * 2
    end,
  }
  local result = LauncherText.fitText(wide, multibyte, 30)
  Assert.isTrue(result:sub(-3) == "…", "multibyte truncation keeps the ellipsis")
  Assert.isNil(result:find("\195$"), "no split lead byte at the truncation edge")
end

return { tests = T }
