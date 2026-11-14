-- Inspection runs against the same LÖVE save identity as romdump and the game.
function love.conf(t)
  t.identity = "portemon"
  t.version = "11.5"
  t.modules.physics = false
  t.modules.window = false
  t.modules.graphics = false
  t.modules.audio = false
  t.modules.sound = false
  t.modules.joystick = false
  t.modules.touch = false
end
