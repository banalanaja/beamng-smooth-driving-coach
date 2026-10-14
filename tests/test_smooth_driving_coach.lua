-- Automated unit tests for smoothDrivingCoach.lua
-- Run with any standard Lua / LuaJIT interpreter

local mockState = {
  dirFwd = { x = 0, y = 1, z = 0 },
  dirUp = { x = 0, y = 0, z = 1 },
  vel = { x = 0, y = 0, z = 0 },
  rollAV = 0,
  pitchAV = 0,
  yawAV = 0,
  gravity = -9.81,
  gx2 = 0,
  gy2 = 0,
  gz2 = -9.81,
  throttle = 0,
  brake = 0,
  clutch = 0,
  steering = 0,
  gearIndex = 1,
  rpm = 850,
  isStalled = false,
  ignitionCoef = 1,
  isGrindingShift = false
}

local lastEventName = nil
local lastEventPayload = nil

-- Mock BeamNG Vehicle VM globals
_G.obj = {
  getDirectionVector = function() return mockState.dirFwd end,
  getDirectionVectorUp = function() return mockState.dirUp end,
  getVelocity = function() return mockState.vel end,
  getRollPitchYawAngularVelocity = function()
    return mockState.rollAV, mockState.pitchAV, mockState.yawAV
  end,
  getGravity = function() return mockState.gravity end
}

_G.sensors = {
  gx2 = 0,
  gy2 = 0,
  gz2 = -9.81
}

_G.electrics = {
  values = {
    throttle_input = 0,
    brake_input = 0,
    clutch_input = 0,
    steering_input = 0,
    gearIndex = 1,
    rpm = 850
  }
}

_G.powertrain = {
  getDevice = function(name)
    if name == "mainEngine" then
      return {
        isStalled = mockState.isStalled,
        ignitionCoef = mockState.ignitionCoef,
        isDisabled = false
      }
    elseif name == "gearbox" then
      return {
        isGrindingShift = mockState.isGrindingShift
      }
    end
    return nil
  end
}

_G.guihooks = {
  trigger = function(name, data)
    lastEventName = name
    lastEventPayload = data
  end
}

local function syncGlobals()
  _G.sensors.gx2 = mockState.gx2
  _G.sensors.gy2 = mockState.gy2
  _G.sensors.gz2 = mockState.gz2
  _G.electrics.values.throttle_input = mockState.throttle
  _G.electrics.values.brake_input = mockState.brake
  _G.electrics.values.clutch_input = mockState.clutch
  _G.electrics.values.steering_input = mockState.steering
  _G.electrics.values.gearIndex = mockState.gearIndex
  _G.electrics.values.rpm = mockState.rpm
end

local function setSlopeDeg(pitchDeg, rollDeg, speedLonMs, speedLatMs)
  local pRad = math.rad(pitchDeg)
  local rRad = math.rad(rollDeg or 0)
  local fx = 0
  local fy = math.cos(pRad)
  local fz = math.sin(pRad)
  mockState.dirFwd = { x = fx, y = fy, z = fz }
  mockState.dirUp = {
    x = math.sin(rRad),
    y = -math.sin(pRad) * math.cos(rRad),
    z = math.cos(pRad) * math.cos(rRad)
  }
  local vLon = speedLonMs or 0
  local vLat = speedLatMs or 0
  mockState.vel = {
    x = vLat,
    y = vLon * fy,
    z = vLon * fz
  }
  syncGlobals()
end

local coach = nil
if type(readFile) == "function" then
  local vfsContent = readFile("mods/unpacked/smooth_driving_coach/lua/vehicle/extensions/auto/smoothDrivingCoach.lua")
    or readFile("/mods/unpacked/smooth_driving_coach/lua/vehicle/extensions/auto/smoothDrivingCoach.lua")
  if vfsContent then
    local fn, err = (loadstring or load)(vfsContent, "smoothDrivingCoach.lua")
    if not fn then error(err) end
    coach = fn()
  end
end
if not coach then
  for _, p in ipairs({
    "lua/vehicle/extensions/auto/smoothDrivingCoach.lua",
    "mods/unpacked/smooth_driving_coach/lua/vehicle/extensions/auto/smoothDrivingCoach.lua"
  }) do
    local f = loadfile(p)
    if f then
      coach = f()
      break
    end
  end
end
if not coach then
  error("Could not load smoothDrivingCoach.lua from VFS or filesystem")
end

local function stepFrames(n, dt)
  dt = dt or (1 / 60)
  for _ = 1, n do
    syncGlobals()
    coach.updateGFX(dt)
  end
end

local function assertTrue(cond, msg)
  if not cond then
    error("ASSERTION FAILED: " .. tostring(msg), 2)
  end
end

-- Test 1: Steady uphill cruise (12 degrees at 14 m/s) should read ~0.00G and 100% score
coach.onExtensionLoaded()
setSlopeDeg(12.0, 0.0, 14.0, 0.0)
-- Simulate even if sensors.gy2 has static gravity offset on slope
mockState.gy2 = 9.81 * math.sin(math.rad(12.0))
stepFrames(120, 1 / 60)
local st = coach.getState()
assertTrue(lastEventName == "SmoothDrivingCoachData", "Expected SmoothDrivingCoachData event")
assertTrue(math.abs(st.pitchDeg - 12.0) < 0.2, "Expected pitchDeg ~ 12.0, got " .. tostring(st.pitchDeg))
assertTrue(st.gHoriz < 0.02, "Expected slope-compensated gHoriz < 0.02G on steady hill, got " .. tostring(st.gHoriz))
assertTrue(st.zone == "green", "Expected green zone on steady uphill, got " .. tostring(st.zone))
assertTrue(st.score >= 99.5, "Expected 100% score on steady uphill, got " .. tostring(st.score))
print("[PASS] Test 1: Steady uphill cruise slope compensation (0.00G on 12 deg incline)")

-- Test 2: Hill rollback detection on uphill in 1st gear
coach.reset()
mockState.gearIndex = 1
setSlopeDeg(10.0, 0.0, -0.45, 0.0) -- rolling backward at -0.45 m/s on 10 deg uphill
stepFrames(10, 1 / 60)
st = coach.getState()
assertTrue(st.category == "LADEIRA", "Expected LADEIRA category on rollback, got " .. tostring(st.category))
assertTrue(st.diagSeverity == "red", "Expected red severity on hill rollback")
assertTrue(st.score < 100, "Expected score penalty on hill rollback")
print("[PASS] Test 2: Hill rollback detection on uphill in forward gear")

-- Test 3: Clean hill start compliment
coach.reset()
mockState.gearIndex = 1
setSlopeDeg(8.0, 0.0, 0.0, 0.0)
stepFrames(15, 1 / 60)
-- Smoothly accelerate from 0 to 2.4 m/s over 2.5 seconds (a = 0.96 m/s^2 ~ 0.10G)
for i = 1, 150 do
  local v = (i / 150) * 2.4
  setSlopeDeg(8.0, 0.0, v, 0.0)
  coach.updateGFX(1 / 60)
end
st = coach.getState()
assertTrue(st.category == "LADEIRA" and st.diagSeverity == "green", "Expected positive LADEIRA compliment on clean hill start, got " .. tostring(st.category) .. " / " .. tostring(st.diagnosis))
print("[PASS] Test 3: Clean hill-start coaching compliment")

-- Test 4: Fast clutch dump jolt detection
coach.reset()
mockState.gearIndex = 1
mockState.clutch = 1.0
setSlopeDeg(0.0, 0.0, 0.5, 0.0)
stepFrames(20, 1 / 60)
-- Dump clutch in 0.1s while speed jumps abruptly
for i = 1, 8 do
  mockState.clutch = math.max(0, 1.0 - i * 0.18)
  local v = 0.5 + i * 0.45
  setSlopeDeg(0.0, 0.0, v, 0.0)
  coach.updateGFX(1 / 60)
end
st = coach.getState()
assertTrue(st.category == "EMBREAGEM", "Expected EMBREAGEM diagnosis on clutch dump, got " .. tostring(st.category))
assertTrue(st.joltCount >= 1, "Expected joltCount >= 1 after clutch dump")
print("[PASS] Test 4: Fast clutch release jolt diagnosis")

-- Test 5: Gear shift jolt (downshift without rev-match)
coach.reset()
mockState.gearIndex = 3
mockState.clutch = 0.0
setSlopeDeg(0.0, 0.0, 15.0, 0.0)
stepFrames(30, 1 / 60)
mockState.gearIndex = 2
for i = 1, 8 do
  local v = 15.0 - i * 0.42
  setSlopeDeg(0.0, 0.0, v, 0.0)
  coach.updateGFX(1 / 60)
end
st = coach.getState()
assertTrue(st.category == "TROCA DE MARCHA", "Expected TROCA DE MARCHA diagnosis on rough downshift, got " .. tostring(st.category))
print("[PASS] Test 5: Rough gear shift / downshift rev-match diagnosis")

-- Test 6: Brake stop head-toss ("Cabeçada na parada")
coach.reset()
mockState.gearIndex = 1
mockState.brake = 0.65
setSlopeDeg(0.0, 0.0, 5.0, 0.0)
stepFrames(20, 1 / 60)
for i = 1, 20 do
  local v = math.max(0, 5.0 - i * 0.26)
  mockState.brake = 0.70 -- keeping high brake pressure right to 0 km/h
  mockState.pitchAV = (i >= 18) and 0.45 or -0.15 -- suspension rebound at stop
  setSlopeDeg(0.0, 0.0, v, 0.0)
  coach.updateGFX(1 / 60)
end
st = coach.getState()
assertTrue(st.category == "FREIO", "Expected FREIO diagnosis on harsh brake stop head-toss, got " .. tostring(st.category))
print("[PASS] Test 6: Brake stop head-toss ('cabecada na parada') diagnosis")

-- Test 7: Engine stall & Gear grind
coach.reset()
mockState.isStalled = false
setSlopeDeg(0.0, 0.0, 0.0, 0.0)
stepFrames(10, 1 / 60)
mockState.isStalled = true
stepFrames(3, 1 / 60)
st = coach.getState()
assertTrue(st.category == "EMBREAGEM / MOTOR" and st.diagSeverity == "red", "Expected EMBREAGEM / MOTOR red diagnosis on stall, got " .. tostring(st.category))

coach.reset()
mockState.isStalled = false
mockState.isGrindingShift = true
stepFrames(3, 1 / 60)
st = coach.getState()
assertTrue(st.category == "CÂMBIO" and st.diagSeverity == "red", "Expected CÂMBIO red diagnosis on gear grind, got " .. tostring(st.category))
mockState.isGrindingShift = false
print("[PASS] Test 7: Engine stall and H-shifter gear grind detection")

-- Test 8: Edge cases (dt=0, negative dt, huge pause dt, zero vectors, resetScore)
coach.updateGFX(0)
coach.updateGFX(-0.05)
coach.updateGFX(2.5)
mockState.dirFwd = { x = 0, y = 0, z = 0 }
coach.updateGFX(1 / 60)
setSlopeDeg(0.0, 0.0, 0.0, 0.0)
coach.resetScore()
coach.updateGFX(1 / 30)
st = coach.getState()
assertTrue(st.score == 100 and st.joltCount == 0, "Expected resetScore to restore score=100 and joltCount=0")
print("[PASS] Test 8: Edge cases (invalid dt, zero vector, resetScore)")

print("\nALL 8 TEST SUITES PASSED SUCCESSFULLY!")
