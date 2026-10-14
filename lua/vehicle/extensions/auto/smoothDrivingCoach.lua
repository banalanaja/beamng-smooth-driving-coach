-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Smooth Driving Coach (Vehicle Extension)
-- Analyzes slope-compensated horizontal G-forces, linear & pitch jerk (trancos/solavancos),
-- road inclination (pitch/roll) vs. suspension dive/squat, and pedal/gear/steering inputs
-- to coach real-life smooth driving with wheel, pedals, and H-shifter.

local M = {}

local abs = math.abs
local sqrt = math.sqrt
local min = math.min
local max = math.max
local asin = math.asin
local deg = math.deg

-- Thresholds tuned for real-life passenger comfort coaching
local G_GREEN_MAX = 0.25          -- <= 0.25 G is comfortable everyday driving
local G_AMBER_MAX = 0.40          -- > 0.40 G is harsh acceleration/braking/cornering
local JERK_GREEN_MAX = 0.80       -- <= 0.80 G/s is smooth transition
local JERK_AMBER_MAX = 1.50       -- > 1.50 G/s is a noticeable jolt/tranco

local HILL_PITCH_DEG_MIN = 3.0    -- Uphill/downhill threshold in degrees
local ROLLBACK_VEL_THRESHOLD = -0.18 -- m/s (~ -0.65 km/h) backward velocity on uphill

local UI_UPDATE_INTERVAL = 1 / 30 -- 30 Hz UI telemetry stream
local DIAGNOSIS_HOLD_TIME = 4.0   -- Seconds to keep last jolt diagnosis visible on HUD
local BEEP_COOLDOWN = 0.65        -- Minimum seconds between audio alerts

-- Consolidated state table (keeps LuaJIT upvalues well below the 60-upvalue limit)
local S = {}
local payload = {}

local function clampVal(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function lowPass(current, target, dt, tau)
  if tau <= 0 or dt <= 0 then return target end
  local alpha = dt / (tau + dt)
  return current + alpha * (target - current)
end

local function decayPeak(val, dt, halfLife)
  local factor = max(0, 1 - (dt / max(halfLife, 0.05)))
  return val * factor
end

local function resetScore()
  S.smoothnessScore = 100.0
  S.joltCount = 0
  S.diagText = "Condução suave"
  S.diagCategory = "OK"
  S.diagSeverity = "green"
  S.diagTimer = 0
end

local function reset()
  S.uiTimer = 0
  S.simTime = 0
  S.prevVelX, S.prevVelY, S.prevVelZ = 0, 0, 0
  S.hasPrevVel = false
  S.gLonSmooth = 0
  S.gLatSmooth = 0
  S.gHoriz = 0
  S.sensorLonLP = 0
  S.sensorLatLP = 0
  S.prevGLon = 0
  S.prevGLat = 0
  S.jerkLonSmooth = 0
  S.jerkLatSmooth = 0
  S.jerkPitchEquiv = 0
  S.jerkTotal = 0
  S.pitchDeg = 0
  S.rollDeg = 0
  S.roadPitchDeg = 0
  S.roadRollDeg = 0
  S.suspPitchDeg = 0
  S.suspRollDeg = 0
  S.hasRoadFilterInit = false
  S.pitchAVSmooth = 0
  S.rollAVSmooth = 0
  S.prevPitchAV = 0
  S.pitchAccSmooth = 0
  S.prevClutch = 0
  S.prevBrake = 0
  S.prevThrottle = 0
  S.prevSteering = 0
  S.prevGearIndex = 0
  S.wasEngineRunning = false
  S.recentClutchReleaseRate = 0
  S.recentBrakeApplyRate = 0
  S.recentThrottleRate = 0
  S.recentSteeringRate = 0
  S.timeSinceGearShift = 999
  S.lastShiftDirection = 0
  S.wasBrakingFromSpeed = false
  S.maxBrakeNearStop = 0
  S.timeSinceStopped = 999
  S.wasStopped = true
  S.hillStartCandidate = false
  S.hillStartHadRollback = false
  S.hillStartMaxJerk = 0
  S.eventSeq = 0
  S.lastBeepTime = -10
  resetScore()
end

local function triggerDiagnosis(text, category, severity, penalty, shouldBeep)
  S.diagText = text
  S.diagCategory = category
  S.diagSeverity = severity
  S.diagTimer = DIAGNOSIS_HOLD_TIME

  if penalty and penalty > 0 then
    S.smoothnessScore = clampVal(S.smoothnessScore - penalty, 0, 100)
  end

  if shouldBeep and (S.simTime - S.lastBeepTime) >= BEEP_COOLDOWN then
    S.lastBeepTime = S.simTime
    S.eventSeq = S.eventSeq + 1
    if severity == "red" or severity == "amber" then
      S.joltCount = S.joltCount + 1
    end
  end
end

local function getEngineAndGearboxState()
  local isStalled = false
  local isGrinding = false
  local engineRunning = true

  if powertrain and powertrain.getDevice then
    local eng = powertrain.getDevice("mainEngine")
    if eng then
      isStalled = eng.isStalled == true
      engineRunning = (eng.ignitionCoef or 1) >= 1 and not isStalled and not eng.isDisabled
    end
    local gb = powertrain.getDevice("gearbox")
    if gb then
      isGrinding = gb.isGrindingShift == true
    end
  end

  return engineRunning, isStalled, isGrinding
end

local function updateGFX(dtSim)
  if not dtSim or dtSim <= 0 or dtSim > 0.5 then
    return
  end

  if not S.simTime then
    reset()
  end

  S.simTime = S.simTime + dtSim

  -- 1. Orientation vectors & Pitch / Roll angles
  local dirFwd = obj:getDirectionVector()
  local dirUp = obj:getDirectionVectorUp()
  if not dirFwd or not dirUp then return end

  local fwdLen = sqrt(dirFwd.x * dirFwd.x + dirFwd.y * dirFwd.y + dirFwd.z * dirFwd.z)
  if fwdLen < 1e-6 then return end
  local fx, fy, fz = dirFwd.x / fwdLen, dirFwd.y / fwdLen, dirFwd.z / fwdLen

  local upLen = sqrt(dirUp.x * dirUp.x + dirUp.y * dirUp.y + dirUp.z * dirUp.z)
  if upLen < 1e-6 then return end
  local ux, uy, uz = dirUp.x / upLen, dirUp.y / upLen, dirUp.z / upLen

  -- Right vector = Forward x Up
  local rx = fy * uz - fz * uy
  local ry = fz * ux - fx * uz
  local rz = fx * uy - fy * ux
  local rightLen = sqrt(rx * rx + ry * ry + rz * rz)
  if rightLen > 1e-6 then
    rx, ry, rz = rx / rightLen, ry / rightLen, rz / rightLen
  end

  local pitchRad = asin(clampVal(fz, -1, 1))
  local rollRad = -asin(clampVal(rz, -1, 1))
  S.pitchDeg = deg(pitchRad)
  S.rollDeg = deg(rollRad)

  -- Separate steady road slope (tau = 1.2s) from dynamic suspension pitch/roll (dive/squat/lean)
  if not S.hasRoadFilterInit then
    S.roadPitchDeg = S.pitchDeg
    S.roadRollDeg = S.rollDeg
    S.hasRoadFilterInit = true
  else
    S.roadPitchDeg = lowPass(S.roadPitchDeg, S.pitchDeg, dtSim, 1.2)
    S.roadRollDeg = lowPass(S.roadRollDeg, S.rollDeg, dtSim, 1.2)
  end
  S.suspPitchDeg = S.pitchDeg - S.roadPitchDeg
  S.suspRollDeg = S.rollDeg - S.roadRollDeg

  -- Angular velocity & suspension pitch acceleration (captures brake dive / squat / rebound head-toss)
  local rollAV, pitchAV = 0, 0
  if obj.getRollPitchYawAngularVelocity then
    local rAV, pAV = obj:getRollPitchYawAngularVelocity()
    rollAV = rAV or 0
    pitchAV = pAV or 0
  end
  S.pitchAVSmooth = lowPass(S.pitchAVSmooth, pitchAV, dtSim, 0.05)
  S.rollAVSmooth = lowPass(S.rollAVSmooth, rollAV, dtSim, 0.05)
  local rawPitchAcc = (S.pitchAVSmooth - S.prevPitchAV) / dtSim
  S.prevPitchAV = S.pitchAVSmooth
  S.pitchAccSmooth = lowPass(S.pitchAccSmooth, rawPitchAcc, dtSim, 0.06)

  -- 2. Slope-compensated horizontal G-force calculation
  local vel = obj:getVelocity()
  local vx, vy, vz = vel.x or 0, vel.y or 0, vel.z or 0
  local vLon = vx * fx + vy * fy + vz * fz
  local vLat = vx * rx + vy * ry + vz * rz
  local speedMs = sqrt(vx * vx + vy * vy + vz * vz)

  if not S.hasPrevVel then
    S.prevVelX, S.prevVelY, S.prevVelZ = vx, vy, vz
    S.hasPrevVel = true
  end

  local axWorld = (vx - S.prevVelX) / dtSim
  local ayWorld = (vy - S.prevVelY) / dtSim
  local azWorld = (vz - S.prevVelZ) / dtSim
  S.prevVelX, S.prevVelY, S.prevVelZ = vx, vy, vz

  local aKinLon = axWorld * fx + ayWorld * fy + azWorld * fz
  local aKinLat = axWorld * rx + ayWorld * ry + azWorld * rz

  -- High-pass filtered local chassis sensors to capture rapid drivetrain lash / clutch judder
  local sensorLon = sensors and sensors.gy2 and (-sensors.gy2) or aKinLon
  local sensorLat = sensors and sensors.gx2 and (-sensors.gx2) or aKinLat
  S.sensorLonLP = lowPass(S.sensorLonLP, sensorLon, dtSim, 0.30)
  S.sensorLatLP = lowPass(S.sensorLatLP, sensorLat, dtSim, 0.30)
  local sensorLonHP = sensorLon - S.sensorLonLP
  local sensorLatHP = sensorLat - S.sensorLatLP

  local gravityMag = 9.81
  if obj.getGravity then
    local gVal = abs(obj:getGravity() or -9.81)
    if gVal > 0.5 then gravityMag = gVal end
  end

  local rawGLon = (aKinLon + 0.35 * sensorLonHP) / gravityMag
  local rawGLat = (aKinLat + 0.35 * sensorLatHP) / gravityMag

  S.gLonSmooth = lowPass(S.gLonSmooth, rawGLon, dtSim, 0.075)
  S.gLatSmooth = lowPass(S.gLatSmooth, rawGLat, dtSim, 0.075)
  S.gHoriz = sqrt(S.gLonSmooth * S.gLonSmooth + S.gLatSmooth * S.gLatSmooth)

  -- 3. Jerk (dG/dt) + Suspension pitch rock equivalent jerk
  local rawJerkLon = (S.gLonSmooth - S.prevGLon) / dtSim
  local rawJerkLat = (S.gLatSmooth - S.prevGLat) / dtSim
  S.prevGLon = S.gLonSmooth
  S.prevGLat = S.gLatSmooth

  S.jerkLonSmooth = lowPass(S.jerkLonSmooth, rawJerkLon, dtSim, 0.07)
  S.jerkLatSmooth = lowPass(S.jerkLatSmooth, rawJerkLat, dtSim, 0.07)
  S.jerkPitchEquiv = min(abs(S.pitchAccSmooth) * 0.16, 2.5)

  local linearJerkMag = sqrt(S.jerkLonSmooth * S.jerkLonSmooth + S.jerkLatSmooth * S.jerkLatSmooth)
  S.jerkTotal = linearJerkMag + S.jerkPitchEquiv

  -- 4. Read Driver Controls (Pedals, Steering, Gear)
  local ev = electrics and electrics.values or {}
  local throttle = ev.throttle_input or ev.throttle or 0
  local brake = ev.brake_input or ev.brake or 0
  local clutch = ev.clutch_input or ev.clutch or 0
  local steering = ev.steering_input or ev.steering or 0
  local gearIndex = ev.gearIndex or 0
  local rpm = ev.rpm or 0

  local clutchReleaseRate = max(0, (S.prevClutch - clutch) / dtSim)
  local brakeApplyRate = max(0, (brake - S.prevBrake) / dtSim)
  local throttleRate = abs(throttle - S.prevThrottle) / dtSim
  local steeringRate = abs(steering - S.prevSteering) / dtSim

  S.prevClutch = clutch
  S.prevBrake = brake
  S.prevThrottle = throttle
  S.prevSteering = steering

  S.recentClutchReleaseRate = max(decayPeak(S.recentClutchReleaseRate, dtSim, 0.40), clutchReleaseRate)
  S.recentBrakeApplyRate = max(decayPeak(S.recentBrakeApplyRate, dtSim, 0.35), brakeApplyRate)
  S.recentThrottleRate = max(decayPeak(S.recentThrottleRate, dtSim, 0.35), throttleRate)
  S.recentSteeringRate = max(decayPeak(S.recentSteeringRate, dtSim, 0.35), steeringRate)

  if gearIndex ~= S.prevGearIndex then
    if gearIndex ~= 0 and S.prevGearIndex ~= 0 then
      S.lastShiftDirection = (gearIndex > S.prevGearIndex) and 1 or -1
      S.timeSinceGearShift = 0
    elseif abs(gearIndex) > 1 and S.prevGearIndex == 0 and speedMs > 2.5 then
      S.lastShiftDirection = 1
      S.timeSinceGearShift = 0
    end
    S.prevGearIndex = gearIndex
  else
    S.timeSinceGearShift = S.timeSinceGearShift + dtSim
  end

  local engineRunning, isStalled, isGrinding = getEngineAndGearboxState()

  -- 5. Track braking-to-stop and hill-start maneuvers
  if speedMs > 1.8 and brake > 0.12 then
    S.wasBrakingFromSpeed = true
  end
  if speedMs < 1.2 and speedMs > 0.15 and S.wasBrakingFromSpeed then
    S.maxBrakeNearStop = max(S.maxBrakeNearStop, brake)
  end

  local isStoppedNow = speedMs < 0.25
  if isStoppedNow and not S.wasStopped then
    S.timeSinceStopped = 0
  elseif not isStoppedNow then
    S.timeSinceStopped = S.timeSinceStopped + dtSim
    if speedMs > 2.2 then
      S.wasBrakingFromSpeed = false
      S.maxBrakeNearStop = 0
    end
  else
    S.timeSinceStopped = S.timeSinceStopped + dtSim
  end

  -- Hill-start tracking
  if isStoppedNow and S.pitchDeg >= HILL_PITCH_DEG_MIN and gearIndex > 0 then
    S.hillStartCandidate = true
    S.hillStartHadRollback = false
    S.hillStartMaxJerk = 0
  elseif S.hillStartCandidate then
    S.hillStartMaxJerk = max(S.hillStartMaxJerk, S.jerkTotal)
    if vLon < ROLLBACK_VEL_THRESHOLD then
      S.hillStartHadRollback = true
    end
    if vLon > 2.0 then
      if not S.hillStartHadRollback and S.hillStartMaxJerk <= JERK_GREEN_MAX * 1.15 then
        triggerDiagnosis("Boa! Arrancada na ladeira limpa e sem voltar", "LADEIRA", "green", 0, false)
      end
      S.hillStartCandidate = false
    elseif gearIndex <= 0 or S.pitchDeg < 1.5 then
      S.hillStartCandidate = false
    end
  end

  -- 6. Root-Cause Diagnosis & Severity Classification
  local instantZone = "green"
  if S.gHoriz > G_AMBER_MAX or S.jerkTotal > JERK_AMBER_MAX then
    instantZone = "red"
  elseif S.gHoriz > G_GREEN_MAX or S.jerkTotal > JERK_GREEN_MAX then
    instantZone = "amber"
  end

  local faultTriggered = false

  -- (A) Engine Stall
  if S.wasEngineRunning and isStalled then
    triggerDiagnosis(
      "Motor morreu! Pise na embreagem ao parar ou dê mais giro na saída",
      "EMBREAGEM / MOTOR",
      "red",
      8.0,
      true
    )
    instantZone = "red"
    faultTriggered = true
  end
  S.wasEngineRunning = engineRunning

  -- (B) Gear Grinding (H-shifter without full clutch)
  if not faultTriggered and isGrinding then
    triggerDiagnosis(
      "Marcha arranhou! Pise até o fundo na embreagem antes de engatar",
      "CÂMBIO",
      "red",
      6.0,
      true
    )
    instantZone = "red"
    faultTriggered = true
  end

  -- (C) Hill Rollback
  if not faultTriggered then
    local uphillRollback = (S.pitchDeg >= HILL_PITCH_DEG_MIN and gearIndex > 0 and vLon < ROLLBACK_VEL_THRESHOLD)
    local downhillForwardInReverse = (S.pitchDeg <= -HILL_PITCH_DEG_MIN and gearIndex < 0 and vLon > -ROLLBACK_VEL_THRESHOLD)
    if uphillRollback or downhillForwardInReverse then
      triggerDiagnosis(
        "Carro voltou na ladeira! Ache o ponto da embreagem antes de soltar o freio",
        "LADEIRA",
        "red",
        4.5 * dtSim * 3.0,
        true
      )
      instantZone = "red"
      faultTriggered = true
    end
  end

  -- (D) Brake Stop Head-Toss ("Cabeçada na parada")
  if not faultTriggered and S.wasBrakingFromSpeed and isStoppedNow and S.timeSinceStopped < 0.35 then
    local stopPitchJolt = abs(S.pitchAccSmooth) > 1.15 or abs(S.suspPitchDeg) > 0.85 or S.jerkTotal > 0.72
    if S.maxBrakeNearStop >= 0.28 and stopPitchJolt then
      local sev = (S.jerkTotal > 1.35 or S.maxBrakeNearStop > 0.65) and "red" or "amber"
      local pen = (sev == "red") and 4.5 or 2.5
      triggerDiagnosis(
        "Cabeçada na parada: alivie o freio suavemente nos últimos centímetros",
        "FREIO",
        sev,
        pen,
        true
      )
      instantZone = sev
      S.wasBrakingFromSpeed = false
      S.maxBrakeNearStop = 0
      faultTriggered = true
    elseif S.maxBrakeNearStop < 0.25 and S.jerkTotal <= 0.60 then
      triggerDiagnosis(
        "Parada perfeita! Aliviou o freio no fim sem dar cabeçada",
        "FREIO",
        "green",
        0,
        false
      )
      S.wasBrakingFromSpeed = false
      S.maxBrakeNearStop = 0
    end
  end
  S.wasStopped = isStoppedNow

  -- (E) Dynamic Jolts (Clutch, Gear Shift, Steering, Pedals) when entering Amber/Red
  if not faultTriggered and (instantZone == "amber" or instantZone == "red") then
    local penaltyScale = (instantZone == "red") and 3.8 or 1.8

    if S.timeSinceGearShift < 0.70 and abs(S.jerkLonSmooth) > 0.65 then
      if S.lastShiftDirection < 0 or S.gLonSmooth < -0.10 then
        triggerDiagnosis(
          "Tranco na redução: sincronize o giro (rev-match) ou solte a embreagem devagar",
          "TROCA DE MARCHA",
          instantZone,
          penaltyScale,
          true
        )
      else
        triggerDiagnosis(
          "Tranco na troca de marcha: alivie o acelerador e solte a embreagem suave",
          "TROCA DE MARCHA",
          instantZone,
          penaltyScale,
          true
        )
      end
      faultTriggered = true
    elseif S.recentClutchReleaseRate > 1.35 and clutch < 0.80 and abs(S.jerkLonSmooth) > 0.60 then
      triggerDiagnosis(
        "Tranco de embreagem: segure 1s no ponto de contato antes de soltar o pedal",
        "EMBREAGEM",
        instantZone,
        penaltyScale,
        true
      )
      faultTriggered = true
    elseif abs(S.jerkLatSmooth) > 0.80 or (abs(S.gLatSmooth) > G_GREEN_MAX and abs(S.gLatSmooth) > abs(S.gLonSmooth)) then
      triggerDiagnosis(
        "Volante brusco: gire a direção de forma progressiva na entrada da curva",
        "VOLANTE",
        instantZone,
        penaltyScale * 0.85,
        true
      )
      faultTriggered = true
    elseif S.gLonSmooth < -0.15 or S.recentBrakeApplyRate > 1.4 then
      triggerDiagnosis(
        "Frenagem brusca: inicie a pressão no pedal de freio progressivamente",
        "FREIO",
        instantZone,
        penaltyScale * 0.9,
        true
      )
      faultTriggered = true
    elseif S.gLonSmooth > 0.15 or S.recentThrottleRate > 1.6 then
      triggerDiagnosis(
        "Tranco no acelerador: aplique ou solte o pedal de forma progressiva",
        "ACELERADOR",
        instantZone,
        penaltyScale * 0.85,
        true
      )
      faultTriggered = true
    elseif S.jerkPitchEquiv > 0.55 then
      triggerDiagnosis(
        "Solavanco de suspensão: passe mais devagar pela ondulação ou desnível",
        "SUSPENSÃO",
        instantZone,
        penaltyScale * 0.6,
        true
      )
      faultTriggered = true
    end
  end

  -- 7. Score recovery during smooth driving & diagnosis timer decay
  if instantZone == "green" and speedMs > 0.8 and not faultTriggered then
    S.smoothnessScore = min(100.0, S.smoothnessScore + dtSim * 1.6)
  elseif instantZone ~= "green" then
    local excessG = max(0, S.gHoriz - G_GREEN_MAX)
    S.smoothnessScore = max(0.0, S.smoothnessScore - excessG * dtSim * 2.5)
  end

  if S.diagTimer > 0 then
    S.diagTimer = max(0, S.diagTimer - dtSim)
    if S.diagTimer == 0 then
      S.diagText = "Condução suave"
      S.diagCategory = "OK"
      S.diagSeverity = "green"
    end
  end

  -- 8. Stream telemetry to UI App at 30 Hz
  S.uiTimer = S.uiTimer + dtSim
  if S.uiTimer >= UI_UPDATE_INTERVAL then
    S.uiTimer = S.uiTimer - UI_UPDATE_INTERVAL
    if S.uiTimer >= UI_UPDATE_INTERVAL then S.uiTimer = 0 end

    payload.gLon = S.gLonSmooth
    payload.gLat = S.gLatSmooth
    payload.gHoriz = S.gHoriz
    payload.jerkLon = S.jerkLonSmooth
    payload.jerkLat = S.jerkLatSmooth
    payload.jerkPitch = S.jerkPitchEquiv
    payload.jerkTotal = S.jerkTotal
    payload.pitchDeg = S.pitchDeg
    payload.rollDeg = S.rollDeg
    payload.roadPitchDeg = S.roadPitchDeg
    payload.roadRollDeg = S.roadRollDeg
    payload.suspPitchDeg = S.suspPitchDeg
    payload.suspRollDeg = S.suspRollDeg
    payload.speedKmh = speedMs * 3.6
    payload.vLon = vLon
    payload.rpm = rpm
    payload.gearIndex = gearIndex
    payload.clutch = clutch
    payload.brake = brake
    payload.throttle = throttle
    payload.score = S.smoothnessScore
    payload.joltCount = S.joltCount
    payload.zone = instantZone
    payload.diagnosis = S.diagText
    payload.category = S.diagCategory
    payload.diagSeverity = S.diagSeverity
    payload.eventSeq = S.eventSeq

    if guihooks and guihooks.trigger then
      guihooks.trigger("SmoothDrivingCoachData", payload)
    end
  end
end

local function onExtensionLoaded()
  reset()
  return true
end

-- Public interface
M.onExtensionLoaded = onExtensionLoaded
M.onReset = reset
M.reset = reset
M.resetScore = resetScore
M.updateGFX = updateGFX
M.getState = function() return payload end

return M
