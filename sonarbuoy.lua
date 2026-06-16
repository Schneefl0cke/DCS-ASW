Sonarbuoy = {}
Sonarbuoy.__index = Sonarbuoy

if not _buoyMarkIdCounter then _buoyMarkIdCounter = 300000 end
local function nextBuoyMarkId()
    _buoyMarkIdCounter = _buoyMarkIdCounter + 1
    return _buoyMarkIdCounter
end

local function log(message, logCoalition, duration)
    duration = duration or 10
    trigger.action.outTextForCoalition(logCoalition, message, duration, false)
    env.info(message, false)
end

local function debugMessage(message, duration)
    if trigger.misc.getUserFlag("Debug") == 1 then
        duration = duration or 10
        trigger.action.outText(message, duration, false)
        env.info(message, false)
    end
end

-- Constructor
-- name: Identifier for this buoy (e.g. "Buoy-1")
-- x, z: DCS world coordinates where the buoy is deployed
-- ownerCoalition: coalition.side.BLUE or coalition.side.RED
-- maxDetectionRange: Maximum detection range in meters (default 15000)
-- thermalLayerDepth: Depth of thermal layer in meters. Subs below this are harder to detect (default 90)
-- batteryLife: Battery lifetime in seconds (default 1800 = 30 min). nil = unlimited.
function Sonarbuoy:new(name, x, z, ownerCoalition, maxDetectionRange, thermalLayerDepth, batteryLife)
    local _, waterDepth = land.getSurfaceHeightWithSeabed({x = x, y = z})
    if waterDepth <= 0 then
        log("Sonarbuoy " .. name .. " deployment failed: position is over land!", ownerCoalition or coalition.side.BLUE)
        return nil
    end

    local life = batteryLife  -- may be nil (unlimited)
    local obj = {
        name              = name,
        x                 = x,
        z                 = z,
        ownerCoalition    = ownerCoalition or coalition.side.BLUE,
        maxDetectionRange = maxDetectionRange or 15000,
        thermalLayerDepth = thermalLayerDepth or 90,
        active            = true,
        circleMarkId      = nil,
        textMarkId        = nil,
        contactMarkers    = {},
        lastSmokeTime     = 0,
        -- battery
        batteryLife       = life,
        batteryRemaining  = life,   -- seconds remaining (nil = unlimited)
        deployedAt        = nil,    -- set on deploy/redeploy
        batteryDepleted   = false,
        halfWarningGiven  = false,
    }
    setmetatable(obj, Sonarbuoy)
    obj.deployedAt = timer.getTime()
    obj:markOwnPosition()
    obj:deploySmoke()
    log("Sonarbuoy " .. name .. " deployed", obj.ownerCoalition)

    -- Alert enemy coalition
    local enemyCoalition = obj.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
    trigger.action.outTextForCoalition(enemyCoalition, "WARNING: Enemy sonarbuoy detected in the water!", 10, false)

    return obj
end

-- Deploy from a DCS unit's current position
function Sonarbuoy:newFromUnit(name, unit, ownerCoalition, maxDetectionRange, thermalLayerDepth, batteryLife)
    local pos = unit:getPoint()
    return Sonarbuoy:new(name, pos.x, pos.z, ownerCoalition, maxDetectionRange, thermalLayerDepth, batteryLife)
end

-- Deploy from a trigger zone
function Sonarbuoy:newFromZone(name, zoneName, ownerCoalition, maxDetectionRange, thermalLayerDepth, batteryLife)
    local zone = trigger.misc.getZone(zoneName)
    if not zone then
        trigger.action.outText("SONARBUOY ERROR: Trigger zone '" .. zoneName .. "' could not be found!", 10)
        env.info("SONARBUOY ERROR: Trigger zone '" .. zoneName .. "' could not be found!", false)
        return nil
    end
    return Sonarbuoy:new(name, zone.point.x, zone.point.z, ownerCoalition, maxDetectionRange, thermalLayerDepth, batteryLife)
end

-- Deploy smoke at the buoy location. Orange = active, Red = depleted.
function Sonarbuoy:deploySmoke()
    local point = {x = self.x, y = 0, z = self.z}
    local color = self.batteryDepleted and trigger.smokeColor.Red or trigger.smokeColor.Orange
    trigger.action.smoke(point, color)
    self.lastSmokeTime = timer.getTime()
end

-- Refresh smoke if it has expired (~300 seconds). Works for active and depleted buoys.
function Sonarbuoy:refreshSmoke()
    if not self.active then return end
    if timer.getTime() - self.lastSmokeTime >= 300 then
        self:deploySmoke()
    end
end

-- ===== BATTERY SYSTEM =====

-- Returns whether this buoy can currently detect submarines.
function Sonarbuoy:canDetect()
    return self.active and not self.batteryDepleted
end

-- Returns a human-readable battery status string.
function Sonarbuoy:getBatteryText()
    if self.batteryLife == nil then return "unlimited" end
    if self.batteryDepleted then return "DEPLETED" end
    local remaining
    if self.deployedAt then
        remaining = math.max(0, self.batteryRemaining - (timer.getTime() - self.deployedAt))
    else
        remaining = self.batteryRemaining or 0
    end
    return string.format("%d:%02d", math.floor(remaining / 60), math.floor(remaining % 60))
end

-- Called each detection cycle. Decrements battery and expires the buoy if empty.
function Sonarbuoy:tickBattery()
    if not self.active then return end
    self:refreshSmoke()
    if self.batteryLife == nil or self.batteryDepleted or not self.deployedAt then return end
    local elapsed   = timer.getTime() - self.deployedAt
    local remaining = self.batteryRemaining - elapsed

    if not self.halfWarningGiven and remaining <= self.batteryRemaining * 0.5 then
        self.halfWarningGiven = true
        log(string.format("%s battery at 50%% — %d:%02d remaining",
            self.name, math.floor(remaining / 60), math.floor(remaining % 60)),
            self.ownerCoalition)
    end

    if elapsed >= self.batteryRemaining then
        self:expire()
    end
end

-- Battery reached zero: stop detecting, change visuals to gray/red.
function Sonarbuoy:expire()
    self.batteryDepleted = true
    self:clearContactMarkers()

    -- Redraw map markers in gray
    if self.circleMarkId then trigger.action.removeMark(self.circleMarkId) end
    if self.textMarkId  then trigger.action.removeMark(self.textMarkId)  end
    local point     = {x = self.x,       y = 0, z = self.z}
    local textPoint = {x = self.x + 200, y = 0, z = self.z}
    local gray      = {0.5, 0.5, 0.5, 1}
    self.circleMarkId = nextBuoyMarkId()
    trigger.action.circleToAll(-1, self.circleMarkId, point, 150, gray, {0.5, 0.5, 0.5, 0.3}, 1, true)
    self.textMarkId = nextBuoyMarkId()
    trigger.action.textToAll(-1, self.textMarkId, textPoint, gray, {0, 0, 0, 0}, 10, true, self.name .. " [DEAD]")

    -- Delay red smoke until the current orange smoke has burned out naturally
    local smokeAge   = timer.getTime() - self.lastSmokeTime
    local smokeDelay = math.max(0, 300 - smokeAge)
    local smokeX, smokeZ = self.x, self.z
    timer.scheduleFunction(function()
        if self.active then
            trigger.action.smoke({x = smokeX, y = 0, z = smokeZ}, trigger.smokeColor.Red)
            self.lastSmokeTime = timer.getTime()
        end
    end, nil, timer.getTime() + smokeDelay)

    log(self.name .. " battery depleted — buoy dead", self.ownerCoalition)
end

-- Remove all map presence (markers and contact lines). Does not set active = false.
function Sonarbuoy:clearMapPresence()
    if self.circleMarkId then
        trigger.action.removeMark(self.circleMarkId)
        self.circleMarkId = nil
    end
    if self.textMarkId then
        trigger.action.removeMark(self.textMarkId)
        self.textMarkId = nil
    end
    self:clearContactMarkers()
end

-- Permanently remove the buoy from the map (discard, not recovery).
function Sonarbuoy:remove()
    if not self.active then return end
    self.active = false
    self:clearMapPresence()
    log("Sonarbuoy " .. self.name .. " removed", self.ownerCoalition)
end

-- Recover the buoy: save remaining battery, clear map presence.
-- The buoy object is returned to the hunter's saved inventory.
-- Does NOT remove it from any external table — caller is responsible.
function Sonarbuoy:pickup()
    if not self.active then return end
    if not self.batteryDepleted and self.deployedAt then
        local elapsed = timer.getTime() - self.deployedAt
        self.batteryRemaining = math.max(0, self.batteryRemaining - elapsed)
    end
    self.deployedAt = nil
    self.active = false
    self:clearMapPresence()
end

-- Redeploy a previously picked-up buoy at a new position, resuming its saved battery.
-- Returns true on success, false + reason string on failure.
function Sonarbuoy:redeploy(x, z)
    local _, waterDepth = land.getSurfaceHeightWithSeabed({x = x, y = z})
    if waterDepth <= 0 then
        return false, "Position is over land"
    end
    self.x = x
    self.z = z
    self.active = true
    self.deployedAt = timer.getTime()
    self.halfWarningGiven = false
    self:markOwnPosition()
    self:deploySmoke()

    if self.batteryLife then
        log(string.format("%s redeployed (%s battery remaining)", self.name, self:getBatteryText()), self.ownerCoalition)
    else
        log(self.name .. " redeployed", self.ownerCoalition)
    end

    local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
    trigger.action.outTextForCoalition(enemyCoalition, "WARNING: Enemy sonarbuoy detected in the water!", 10, false)

    return true
end

-- Reset to full battery (called when rearming revives an expired buoy).
function Sonarbuoy:resetBattery()
    self.batteryRemaining = self.batteryLife
    self.batteryDepleted  = false
    self.deployedAt       = nil
end

function Sonarbuoy:isActive()
    return self.active
end

-- ===== POSITION MARKER =====

-- Mark buoy position on F10 map (visible to all coalitions).
function Sonarbuoy:markOwnPosition()
    local point     = {x = self.x,       y = 0, z = self.z}
    local textPoint = {x = self.x + 200, y = 0, z = self.z}
    local blue      = {0, 0, 1, 1}

    self.circleMarkId = nextBuoyMarkId()
    trigger.action.circleToAll(-1, self.circleMarkId, point, 150, blue, {0, 0, 1, 0.3}, 1, true)

    self.textMarkId = nextBuoyMarkId()
    trigger.action.textToAll(-1, self.textMarkId, textPoint, blue, {0, 0, 0, 0}, 10, true, self.name)
end

-- ===== DETECTION =====

-- Detect submarines from a table of VirtualSubmarine instances.
-- Returns a table of detected contacts: {bearing, confidence, subName, buoyName}
function Sonarbuoy:detect(submarines)
    if not self:canDetect() then return {} end

    local contacts = {}

    for _, sub in ipairs(submarines) do
        if sub:isAlive() then
            local contact = self:tryDetect(sub)
            if contact then
                contacts[#contacts + 1] = contact
                self:markContact(contact)
                log(self.name .. " bearing contact! BRG " .. string.format("%.0f", math.deg(contact.bearing) % 360) .. "° | Conf: " .. string.format("%.0f", contact.confidence * 100) .. "%", self.ownerCoalition)
            end
        end
    end

    return contacts
end

-- Internal: attempt detection of a single submarine
function Sonarbuoy:tryDetect(sub)
    local dx = sub.x - self.x
    local dz = sub.z - self.z
    local distance = math.sqrt(dx * dx + dz * dz)

    -- Out of range
    if distance > self.maxDetectionRange then return nil end

    -- Detection probability calculation
    -- effectiveNoise: faster and louder subs are easier to detect
    local effectiveNoise = sub.speed * sub.noiseFactor

    -- A stationary or very slow sub is nearly undetectable
    if effectiveNoise < 0.1 then return nil end

    -- Depth penalty: deeper subs are harder to detect (linear falloff)
    local maxEffectiveDepth = 500
    local depthPenalty = math.max(0.1, 1 - (sub.depth / maxEffectiveDepth))

    -- Thermal layer penalty: sub below the thermal layer is significantly harder to detect
    local thermalPenalty = 1.0
    if sub.depth > self.thermalLayerDepth then
        thermalPenalty = 0.2
    end

    -- Distance falloff: closer = much easier to detect
    local distanceFactor = 1 - (distance / self.maxDetectionRange)

    -- Final probability (scale factor tuned for gameplay)
    local scaleFactor = 0.15
    local probability = effectiveNoise * depthPenalty * thermalPenalty * distanceFactor * scaleFactor

    -- Clamp probability to [0, 0.95]
    probability = math.min(0.95, math.max(0, probability))

    debugMessage(self.name .. " -> " .. sub.name .. " dist=" .. string.format("%.0f", distance) .. "m prob=" .. string.format("%.2f", probability))

    -- Signal too weak to produce a reliable contact
    if probability < 0.05 then return nil end

    -- Roll for detection
    if math.random() > probability then return nil end

    -- Detection successful — passive buoys give bearing only, not range or depth
    local confidence = probability
    local bearingTrue = math.atan2(dz, dx)

    -- Bearing error: ±0 to ±30 degrees, worse at longer range and lower confidence
    local bearingErrorMax = math.rad(30) * (1 - confidence)
    local bearingError = (math.random() * 2 - 1) * bearingErrorMax
    local estimatedBearing = bearingTrue + bearingError

    return {
        bearing    = estimatedBearing,
        confidence = confidence,
        subName    = sub.name,
        buoyName   = self.name
    }
end

-- Draw a bearing line from the buoy outward, auto-removed after 30 seconds.
-- Passive buoys give bearing only — the sub is somewhere along this line.
function Sonarbuoy:markContact(contact)
    local lineLength = self.maxDetectionRange
    local endPt = {
        x = self.x + lineLength * math.cos(contact.bearing),
        y = 0,
        z = self.z + lineLength * math.sin(contact.bearing),
    }
    local startPt = {x = self.x, y = 0, z = self.z}

    local yellow = {1, 1, 0, 1}
    local lineId = nextBuoyMarkId()
    local textId = nextBuoyMarkId()

    trigger.action.lineToAll(self.ownerCoalition, lineId, startPt, endPt, yellow, 2, true)

    -- Label at 25% along the line
    local labelPt = {
        x = self.x + lineLength * 0.25 * math.cos(contact.bearing),
        y = 0,
        z = self.z + lineLength * 0.25 * math.sin(contact.bearing),
    }
    trigger.action.textToAll(self.ownerCoalition, textId, labelPt, yellow, {0, 0, 0, 0}, 10, true,
        string.format("%s | BRG %.0f° | Conf: %.0f%%",
            self.name, math.deg(contact.bearing) % 360, contact.confidence * 100))

    local m = {lineId = lineId, textId = textId}
    self.contactMarkers[#self.contactMarkers + 1] = m

    timer.scheduleFunction(function()
        trigger.action.removeMark(lineId)
        trigger.action.removeMark(textId)
        for i, cm in ipairs(self.contactMarkers) do
            if cm == m then table.remove(self.contactMarkers, i) break end
        end
    end, nil, timer.getTime() + 30)
end

-- Remove all contact markers
function Sonarbuoy:clearContactMarkers()
    for _, m in ipairs(self.contactMarkers) do
        trigger.action.removeMark(m.lineId)
        trigger.action.removeMark(m.textId)
    end
    self.contactMarkers = {}
end
