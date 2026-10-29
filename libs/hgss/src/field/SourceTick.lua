-- The one HGSS source tick: the cadence at which the retail application
-- advances its field, scripts, covers, intro timelines, and sound frame. The
-- retail main loop waits two display refreshes per iteration, so the tick
-- runs at half the DS refresh, about 29.913 Hz. The sound sequencer keeps
-- real time, so a timeline paced at exactly 30 Hz would drift against its
-- music.

local DisplayTiming = require("libs.nds.src.gx.DisplayTiming")

local SourceTick = {}

SourceTick.HZ = DisplayTiming.REFRESH_HZ / 2
SourceTick.DT = 1 / SourceTick.HZ

return SourceTick
