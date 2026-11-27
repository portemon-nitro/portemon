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
  Assert.isTrue(font:getWidth(fitted) <= 10, "the truncated row fits its pixel budget")
  Assert.equal(LauncherText.sanitize(fitted), fitted, "the truncated row stays valid UTF-8")
  -- Valid multibyte names truncate without splitting any sequence: strip
  -- the ellipsis and the remainder must be an intact prefix of the input.
  local cases = {
    { text = "Pok\195\169mon-" .. string.rep("x", 40), label = "2-byte é" },
    { text = "price 100\226\130\172!" .. string.rep("y", 40), label = "3-byte €" },
    { text = "dig \240\159\152\128!" .. string.rep("z", 40), label = "4-byte emoji" },
  }
  local wide = {
    getWidth = function(_, text)
      return #text * 2
    end,
  }
  for _, case in ipairs(cases) do
    local result = LauncherText.fitText(wide, case.text, 30)
    Assert.isTrue(result:sub(-3) == "…", case.label .. " truncation keeps the ellipsis")
    Assert.isTrue(wide:getWidth(result) <= 30, case.label .. " fits its pixel budget")
    Assert.isNil(result:find("\n"), case.label .. " carries no line break")
    Assert.equal(
      LauncherText.sanitize(result),
      result,
      case.label .. " never splits a lead byte before the ellipsis"
    )
    local prefix = result:sub(1, -4)
    Assert.equal(case.text:sub(1, #prefix), prefix, case.label .. " keeps an intact prefix")
    Assert.isTrue(#prefix < #case.text, case.label .. " actually truncated")
  end
end

function T.fit_text_folds_newlines_for_single_row_callers()
  local font = {
    getWidth = function(_, text)
      return #text
    end,
  }
  Assert.equal(LauncherText.fitText(font, "a\nb", 10), "a b", "a legal filename newline folds to a space")
  local folded = LauncherText.fitText(font, "line1\nline2", 11)
  Assert.isNil(folded:find("\n"), "single-row fit never paints a line break")
  Assert.equal(folded, "line1 line2", "folding preserves the surrounding text")
  Assert.equal(
    LauncherText.sanitize("line1\nline2"),
    "line1\nline2",
    "diagnostics keep their intentional breaks"
  )
end

return { tests = T }
