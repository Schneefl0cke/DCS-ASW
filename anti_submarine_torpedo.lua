AntiSubmarineTorpedo = {}
AntiSubmarineTorpedo.__index = AntiSubmarineTorpedo

local function log(message, logCoalition, duration)
    duration = duration or 10
    trigger.action.outTextForCoalition(logCoalition, message, duration, false)
    env.info(message, false)
end

local function logAll(message, duration)
    duration = duration or 10
    trigger.action.outText(message, duration, false)
    env.info(message, false)
end

local function debugMessage(message, duration)
    if trigger.misc.getUserFlag("Debug") == 1 then
        duration = duration or 10
        trigger.action.outText(message, duration, false)
        env.info(message, false)
    end
end

if not _torpedoMarkIdCounter then _torpedoMarkIdCounter = 100000 end
local function nextMarkId()
    _torpedoMarkIdCounter = _torpedoMarkIdCounter + 1
    return _torpedoMarkIdCounter
end

-- Constructor
-- name: Identifier (e.g. "Hunter1-Torpedo-1")
-- x, z: DCS world coordinates at launch
-- heading: Initial heading in degrees (player's heading)
-- searchDepth: Depth to run at in meters (0, 100, 200, 300, 400, 500)
-- ownerCoalition: coalition side
-- submarines: table of VirtualSubmarine instances to hunt
-- thermalLayerDepth: thermal layer depth for detection (default 90)
function AntiSubmarineTorpedo:new(name, x, z, heading, searchDepth, ownerCoalition, submarines, thermalLayerDepth)
    local obj = {
        name = name,
        x = x,
        z = z,
        heading = heading,
        depth = 0,
        targetDepth = searchDepth or 100,
        depthRate = 20,              -- meters per second depth change
        speed = 15.43,               -- 30 knots in m/s
        turnRate = 3,                -- degrees per second
        maxDetectionRange = 1500,    -- 1.5 km sonar range
        thermalLayerDepth = thermalLayerDepth or 90,
        killRadius = 150,            -- meters
        depthTolerance = 50,         -- meters
        batteryLife = 300,           -- seconds
        ownerCoalition = ownerCoalition or coalition.side.BLUE,
        submarines = submarines or {},
        active = true,
        hasTarget = false,
        lastContactX = nil,
        lastContactZ = nil,
        lastContactDepth = nil,
        elapsedTime = 0,
        lastUpdateTime = timer.getTime(),
        lastMarkerTime = 0,         -- Track when last marker was created
        lastHomingPingTime = 0,      -- Track homing ping interval
        prevMarkerX = x,
        prevMarkerZ = z,
        markerIds = {},
        textMarkerId = nil,
        updateScheduleId = nil
    }
    setmetatable(obj, AntiSubmarineTorpedo)
    obj:startUpdateLoop()
    obj:markLaunchPosition()
    log("Torpedo " .. name .. " launched! Search depth: " .. obj.targetDepth .. "m | Battery: " .. obj.batteryLife .. "s", obj.ownerCoalition)

    -- Alert enemy coalition about torpedo launch
    local enemyCoalition = obj.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
    trigger.action.outTextForCoalition(enemyCoalition, "WARNING: Enemy ASW torpedo in the water!", 10, false)

    return obj
end

-- Mark launch position on F10 map
function AntiSubmarineTorpedo:markLaunchPosition()
    local point = {x = self.x, y = 0, z = self.z}
    local green = {0, 1, 0, 1}
    local circleId = nextMarkId()
    trigger.action.circleToAll(-1, circleId, point, 100, green, {0, 1, 0, 0.3}, 1, true)
    local textPoint = {x = self.x + 150, y = 0, z = self.z}
    local textId = nextMarkId()
    trigger.action.textToAll(-1, textId, textPoint, green, {0, 0, 0, 0}, 10, true, "ASW Torpedo Launch")
end

-- Main update loop: runs every second
function AntiSubmarineTorpedo:startUpdateLoop()
    local function update()
        if not self.active then return end

        local currentTime = timer.getTime()
        local dt = currentTime - self.lastUpdateTime
        self.lastUpdateTime = currentTime
        self.elapsedTime = self.elapsedTime + dt

        -- Battery check
        local remaining = self.batteryLife - self.elapsedTime
        if remaining <= 0 then
            self:expire()
            return
        end

        -- Move depth toward target
        self:updateDepth(dt)

        -- Try to detect submarines
        self:detectAndHome(dt)

        -- Move forward on current heading
        self:move(dt)

        -- Update map marker
        self:updateMarker()

        -- Log battery timer
        debugMessage(string.format("%s | Battery: %.0fs | Depth: %.0fm | Hdg: %.0f°",
            self.name, remaining, self.depth, self.heading), 1)

        self.updateScheduleId = timer.scheduleFunction(function()
            update()
        end, nil, timer.getTime() + 1)
    end

    update()
end

-- Move the torpedo forward
function AntiSubmarineTorpedo:move(dt)
    local headingRad = math.rad(self.heading)
    local distance = self.speed * dt
    self.x = self.x + distance * math.cos(headingRad)
    self.z = self.z + distance * math.sin(headingRad)
end

-- Adjust depth toward targetDepth
function AntiSubmarineTorpedo:updateDepth(dt)
    local depthDiff = self.targetDepth - self.depth
    if math.abs(depthDiff) > 0.1 then
        local maxChange = self.depthRate * dt
        if math.abs(depthDiff) <= maxChange then
            self.depth = self.targetDepth
        elseif depthDiff > 0 then
            self.depth = self.depth + maxChange
        else
            self.depth = self.depth - maxChange
        end
    end
end

-- Detect submarines and home in on nearest contact
function AntiSubmarineTorpedo:detectAndHome(dt)
    local bestContact = nil
    local bestDist = math.huge

    for _, sub in ipairs(self.submarines) do
        if sub:isAlive() then
            -- Check for kill first (using true positions)
            local dx = sub.x - self.x
            local dz = sub.z - self.z
            local horizontalDist = math.sqrt(dx * dx + dz * dz)
            local depthDiff = math.abs(sub.depth - self.depth)

            if horizontalDist <= self.killRadius and depthDiff <= self.depthTolerance then
                self:hitTarget(sub)
                return
            end

            -- Try sonar detection
            local contact = self:tryDetect(sub)
            if contact then
                local cdx = contact.x - self.x
                local cdz = contact.z - self.z
                local contactDist = math.sqrt(cdx * cdx + cdz * cdz)
                if contactDist < bestDist then
                    bestDist = contactDist
                    bestContact = contact
                end
            end
        end
    end

    if bestContact then
        if not self.hasTarget then
            log(self.name .. " SONAR CONTACT! Homing on target!", self.ownerCoalition)
        end
        self.hasTarget = true
        -- Homing ping sound every 3 seconds (both coalitions)
        local now = timer.getTime()
        if now - self.lastHomingPingTime >= 3 then
            self.lastHomingPingTime = now
            if ASW_SOUND then
                local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
                ASW_SOUND:playForCoalition(self.ownerCoalition, "torpedo_homing")
                ASW_SOUND:playForCoalition(enemyCoalition, "torpedo_homing")
            end
        end
        -- Store last known position
        self.lastContactX = bestContact.x
        self.lastContactZ = bestContact.z
        self.lastContactDepth = bestContact.depth
        -- Home toward nearest detected contact
        self:homeOnContact(bestContact, dt)
    elseif self.hasTarget and self.lastContactX then
        -- No detection: turn toward last known position
        self:homeOnContact({
            x = self.lastContactX,
            z = self.lastContactZ,
            depth = self.lastContactDepth
        }, dt)
    end
end

-- Active sonar detection: ping bounces off hull regardless of sub movement.
-- Movement adds a bonus (cavitation, Doppler) but a stationary sub is still detectable.
function AntiSubmarineTorpedo:tryDetect(sub)
    local dx = sub.x - self.x
    local dz = sub.z - self.z
    local distance = math.sqrt(dx * dx + dz * dz)

    if distance > self.maxDetectionRange then return nil end

    -- Active sonar: base reflection from hull + bonus from movement noise
    local baseReflection = 1.0  -- hull always reflects the ping
    local movementBonus = sub.speed * sub.noiseFactor * 0.5  -- moving subs are easier
    local effectiveSignal = baseReflection + movementBonus

    local maxEffectiveDepth = 500
    local depthPenalty = math.max(0.1, 1 - (sub.depth / maxEffectiveDepth))

    local thermalPenalty = 1.0
    local torpedoBelowLayer = self.depth > self.thermalLayerDepth
    local subBelowLayer = sub.depth > self.thermalLayerDepth
    if torpedoBelowLayer ~= subBelowLayer then
        thermalPenalty = 0.2
    end

    local distanceFactor = 1 - (distance / self.maxDetectionRange)

    local scaleFactor = 0.20
    local probability = effectiveSignal * depthPenalty * thermalPenalty * distanceFactor * scaleFactor
    probability = math.min(0.95, math.max(0, probability))

    debugMessage(self.name .. " sonar -> " .. sub.name .. " dist=" .. string.format("%.0f", distance) .. "m prob=" .. string.format("%.2f", probability))

    if math.random() > probability then return nil end

    -- Detection successful - estimate position with uncertainty
    local confidence = probability
    local bearingTrue = math.atan2(dz, dx)

    local bearingErrorMax = math.rad(30) * (1 - confidence)
    local bearingError = (math.random() * 2 - 1) * bearingErrorMax
    local estimatedBearing = bearingTrue + bearingError

    local rangeErrorMax = distance * 0.25 * (1 - confidence)
    local rangeError = (math.random() * 2 - 1) * rangeErrorMax
    local estimatedRange = math.max(0, distance + rangeError)

    local estimatedX = self.x + estimatedRange * math.cos(estimatedBearing)
    local estimatedZ = self.z + estimatedRange * math.sin(estimatedBearing)

    local depthErrorMax = sub.depth * 0.30 * (1 - confidence)
    local depthError = (math.random() * 2 - 1) * depthErrorMax
    local estimatedDepth = math.max(0, sub.depth + depthError)

    return {
        x = estimatedX,
        z = estimatedZ,
        depth = estimatedDepth,
        confidence = confidence
    }
end

-- Turn toward estimated contact position and adjust depth
function AntiSubmarineTorpedo:homeOnContact(contact, dt)
    -- Adjust target depth toward estimated contact depth
    self.targetDepth = contact.depth

    -- Turn toward estimated contact position
    local dx = contact.x - self.x
    local dz = contact.z - self.z
    local desiredHeading = math.deg(math.atan2(dz, dx))
    if desiredHeading < 0 then desiredHeading = desiredHeading + 360 end

    local headingDiff = desiredHeading - self.heading
    -- Normalize to -180..180
    if headingDiff > 180 then headingDiff = headingDiff - 360 end
    if headingDiff < -180 then headingDiff = headingDiff + 360 end

    local maxTurn = self.turnRate * dt
    if math.abs(headingDiff) <= maxTurn then
        self.heading = desiredHeading
    elseif headingDiff > 0 then
        self.heading = self.heading + maxTurn
    else
        self.heading = self.heading - maxTurn
    end

    -- Normalize heading to 0..360
    if self.heading >= 360 then self.heading = self.heading - 360 end
    if self.heading < 0 then self.heading = self.heading + 360 end
end

-- Torpedo hit: destroy the target (submarine or noise maker)
function AntiSubmarineTorpedo:hitTarget(sub)
    self.active = false
    self:stopUpdateLoop()

    -- Check if we hit a noise maker (decoy) instead of a real sub
    local isDecoy = (sub.remove ~= nil and sub.driftHeading ~= nil)

    -- Remove all trail lines and text
    self:clearMarker()

    if isDecoy then
        sub:remove()
        logAll("*** TORPEDO IMPACT! " .. self.name .. " hit a decoy! ***", 15)
        local text = self.name .. " | IMPACT | DECOY DESTROYED"
        local coord = COORDINATE:New(sub.x, 0, sub.z)
        self.impactMarker = MARKER:New(coord, text):ReadOnly():ToAll()
    else
        local point = {x = sub.x, y = 0, z = sub.z}
        trigger.action.explosion(point, 1000)
        sub:destroy()
        logAll("*** TORPEDO IMPACT! " .. self.name .. " has destroyed " .. sub.name .. "! ***", 30)
        local text = self.name .. " | IMPACT | " .. sub.name .. " DESTROYED"
        local coord = COORDINATE:New(sub.x, 0, sub.z)
        self.impactMarker = MARKER:New(coord, text):ReadOnly():ToAll()
    end
end

-- Battery expired
function AntiSubmarineTorpedo:expire()
    self.active = false
    self:stopUpdateLoop()
    self:clearMarker()
    log(self.name .. " battery depleted. Torpedo lost.", self.ownerCoalition)
end

-- Remove torpedo (e.g. on cleanup)
function AntiSubmarineTorpedo:remove()
    self.active = false
    self:stopUpdateLoop()
    self:clearMarker()
end

function AntiSubmarineTorpedo:isActive()
    return self.active
end

function AntiSubmarineTorpedo:stopUpdateLoop()
    if self.updateScheduleId then
        timer.removeFunction(self.updateScheduleId)
        self.updateScheduleId = nil
    end
end

-- Update F10 map marker as line trail showing torpedo position
function AntiSubmarineTorpedo:updateMarker()
    local currentTime = timer.getTime()
    -- Only create new marker every 20 seconds
    if currentTime - self.lastMarkerTime < 20 then
        return
    end
    self.lastMarkerTime = currentTime

    -- Draw line segment from previous position to current position
    local startPoint = {x = self.prevMarkerX, y = 0, z = self.prevMarkerZ}
    local endPoint = {x = self.x, y = 0, z = self.z}
    local lineId = nextMarkId()
    trigger.action.lineToAll(-1, lineId, startPoint, endPoint, {1, 0, 0, 1}, 1, true)
    self.markerIds[#self.markerIds + 1] = lineId

    -- Remove old text marker
    if self.textMarkerId then
        trigger.action.removeMark(self.textMarkerId)
    end

    -- Place text label at current position
    local remaining = math.max(0, self.batteryLife - self.elapsedTime)
    local status = self.hasTarget and "HOMING" or "SEARCHING"
    local text = string.format("%s | %s | Depth: %.0fm | Hdg: %.0f° | Battery: %.0fs",
        self.name, status, self.depth, self.heading, remaining)
    local textId = nextMarkId()
    trigger.action.textToAll(-1, textId, endPoint, {1, 0, 0, 1}, {0, 0, 0, 0}, 12, true, text)
    self.textMarkerId = textId
    self.markerIds[#self.markerIds + 1] = textId

    -- Update previous position
    self.prevMarkerX = self.x
    self.prevMarkerZ = self.z
end

-- Remove all map markers (lines and text)
function AntiSubmarineTorpedo:clearMarker()
    for _, id in ipairs(self.markerIds) do
        trigger.action.removeMark(id)
    end
    self.markerIds = {}
    self.textMarkerId = nil
end
