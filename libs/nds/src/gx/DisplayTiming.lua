-- Nintendo DS LCD refresh timing.
--
-- Reference: GBATEK "DS LCD Dimensions and Timings": the 33513982 Hz system
-- clock drives 6 cycles per dot, 355 dots per line, and 263 lines per frame,
-- so the display refreshes at about 59.8261 Hz.

local DisplayTiming = {}

DisplayTiming.REFRESH_HZ = 33513982 / (263 * 355 * 6)

return DisplayTiming
