-- The one HGSS source tick: the cadence at which the retail application
-- advances its field, scripts, covers, and intro timelines. It is one tick per
-- two display frames, and the display refreshes at
-- 33513982 Hz / (263 lines * 355 dots * 6 cycles) = 59.8261 Hz, so the tick
-- runs at about 29.913 Hz. The sound sequencer keeps real time, so a timeline
-- paced at exactly 30 Hz would drift against its music.

local SourceTick = {}

SourceTick.HZ = 33513982 / (2 * 263 * 355 * 6)
SourceTick.DT = 1 / SourceTick.HZ

return SourceTick
