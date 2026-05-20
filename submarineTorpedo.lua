SubmarineTorpedo = {}
SubmarineTorpedo.__index = SubmarineTorpedo

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
-- name: Identifier (e.g. "Kursk-Torpedo-1")
-- x, z: DCS world coordinates at launch (submarine position)
-- heading: Initial heading in degrees (submarine heading)
-- ownerCoalition: coalition that fired the torpedo (e.g. RED)
-- targetCoalition: coalition whose ships to target (e.g. BLUE)
-- buoys: table of Sonarbuoy instances (for launch detection alert)
function SubmarineTorpedo:new(name, x, z, heading, ownerCoalition, targetCoalition, buoys)
    local obj = {
        name = name,
        x = x,
        z = z,
        heading = heading,
        speed = 20.58,              -- 40 knots in m/s
        turnRate = 3,               -- degrees per second
        maxDetectionRange = 10000,  -- 10 km sonar range
        coneHalfAngle = 30,         -- ±30° forward sonar cone
        killRadius = 50,            -- meters
        armingTime = 5,             -- seconds before warhead arms
        batteryLife = 300,          -- 5 minutes
        explosionPower = 5000,      -- DCS explosion power
        ownerCoalition = ownerCoalition,
        targetCoalition = targetCoalition,
        active = true,
        armed = false,
        hasTarget = false,
        lastContactX = nil,
        lastContactZ = nil,
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
    setmetatable(obj, SubmarineTorpedo)

    -- Alert any buoys in range about the torpedo launch
    obj:alertBuoys(buoys)

    obj:startUpdateLoop()
    obj:markLaunchPosition()
    log(name .. " launched! Heading: " .. string.format("%.0f", heading) .. "°", ownerCoalition)
    return obj
end

-- Check all buoys: if launch position is within a buoy's detection range,
-- mark the exact launch position with 100% confidence for the buoy's coalition
function SubmarineTorpedo:alertBuoys(buoys)
    if not buoys then return end
    for _, buoy in ipairs(buoys) do
        if buoy:isActive() then
            local dx = self.x - buoy.x
            local dz = self.z - buoy.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist <= buoy.maxDetectionRange then
                local coord = COORDINATE:New(self.x, 0, self.z)
                local text = buoy.name .. " | TORPEDO LAUNCH DETECTED | Confidence: 100%"
                local marker = MARKER:New(coord, text):ReadOnly():ToCoalition(buoy.ownerCoalition)
                timer.scheduleFunction(function()
                    marker:Remove()
                end, nil, timer.getTime() + 30)
                log(buoy.name .. " detected TORPEDO LAUNCH at close range!", buoy.ownerCoalition)
            end
        end
    end
end

-- Mark launch position on F10 map
function SubmarineTorpedo:markLaunchPosition()
    local point = {x = self.x, y = 0, z = self.z}
    local green = {0, 1, 0, 1}
    local circleId = nextMarkId()
    trigger.action.circleToAll(-1, circleId, point, 100, green, {0, 1, 0, 0.3}, 1, true)
    local textPoint = {x = self.x + 150, y = 0, z = self.z}
    local textId = nextMarkId()
    trigger.action.textToAll(-1, textId, textPoint, green, {0, 0, 0, 0}, 10, true, "Submarine Torpedo Launch")
end

-- Main update loop: runs every second
function SubmarineTorpedo:startUpdateLoop()
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

        -- Check arming
        if not self.armed and self.elapsedTime >= self.armingTime then
            self.armed = true
            debugMessage(self.name .. " ARMED")
        end

        -- If armed, check proximity kill against all enemy ships
        if self.armed then
            local killed = self:checkProximityKill()
            if killed then return end
        end

        -- Detect in sonar cone and home
        self:detectAndHome(dt)

        -- Move forward
        self:move(dt)

        -- Update map marker (visible to all)
        self:updateMarker()

        debugMessage(string.format("%s | Battery: %.0fs | Hdg: %.0f° | %s",
            self.name, remaining, self.heading,
            self.armed and "ARMED" or "ARMING..."), 1)

        self.updateScheduleId = timer.scheduleFunction(function()
            update()
        end, nil, timer.getTime() + 1)
    end

    update()
end

-- Move the torpedo forward
function SubmarineTorpedo:move(dt)
    local headingRad = math.rad(self.heading)
    local distance = self.speed * dt
    self.x = self.x + distance * math.cos(headingRad)
    self.z = self.z + distance * math.sin(headingRad)
end

-- Find all ship units in the target coalition
function SubmarineTorpedo:findShipTargets()
    local targets = {}
    local groups = coalition.getGroups(self.targetCoalition, Group.Category.SHIP)
    if groups then
        for _, group in ipairs(groups) do
            if group and group:isExist() then
                local units = group:getUnits()
                if units then
                    for _, unit in ipairs(units) do
                        if unit and unit:isExist() then
                            targets[#targets + 1] = unit
                        end
                    end
                end
            end
        end
    end
    return targets
end

-- Check if any enemy ship is within kill radius (proximity fuse, no cone needed)
function SubmarineTorpedo:checkProximityKill()
    local targets = self:findShipTargets()
    for _, unit in ipairs(targets) do
        local pos = unit:getPoint()
        local dx = pos.x - self.x
        local dz = pos.z - self.z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist <= self.killRadius then
            self:hitTarget(unit)
            return true
        end
    end
    return false
end

-- Detect ships in sonar cone and home on nearest contact
function SubmarineTorpedo:detectAndHome(dt)
    local targets = self:findShipTargets()
    local detected = false
    local nearestContact = nil
    local nearestDist = self.maxDetectionRange + 1

    for _, unit in ipairs(targets) do
        local contact = self:tryDetectShip(unit)
        if contact and contact.distance < nearestDist then
            nearestDist = contact.distance
            nearestContact = contact
        end
    end

    if nearestContact then
        if not self.hasTarget then
            log(self.name .. " SONAR CONTACT! Homing on target: " .. nearestContact.unitName .. " at distance " .. string.format("%.0f", nearestContact.distance) .. "m", self.ownerCoalition, 30)
        end
        self.hasTarget = true
        detected = true
        -- Homing ping sound every 3 seconds (both coalitions)
        local now = timer.getTime()
        if now - self.lastHomingPingTime >= 3 then
            self.lastHomingPingTime = now
            if ASW_SOUND then
                ASW_SOUND:playForCoalition(self.ownerCoalition, "torpedo_homing")
                ASW_SOUND:playForCoalition(self.targetCoalition, "torpedo_homing")
            end
        end
        self.lastContactX = nearestContact.x
        self.lastContactZ = nearestContact.z
        self:homeOnPosition(nearestContact.x, nearestContact.z, dt)
    end

    -- No detection this tick: turn toward last known position
    if not detected and self.hasTarget and self.lastContactX then
        self:homeOnPosition(self.lastContactX, self.lastContactZ, dt)
    end
end

-- Sonar detection: forward cone with probability based on distance
function SubmarineTorpedo:tryDetectShip(unit)
    local pos = unit:getPoint()
    local dx = pos.x - self.x
    local dz = pos.z - self.z
    local distance = math.sqrt(dx * dx + dz * dz)

    if distance > self.maxDetectionRange then return nil end

    -- Check sonar cone (±30° from heading)
    local bearingToTarget = math.deg(math.atan2(dz, dx))
    if bearingToTarget < 0 then bearingToTarget = bearingToTarget + 360 end
    local angleDiff = bearingToTarget - self.heading
    if angleDiff > 180 then angleDiff = angleDiff - 360 end
    if angleDiff < -180 then angleDiff = angleDiff + 360 end
    if math.abs(angleDiff) > self.coneHalfAngle then return nil end

    -- Probability based on distance (ships are loud surface targets)
    local distanceFactor = 1 - (distance / self.maxDetectionRange)
    local probability = 0.8 * distanceFactor
    probability = math.min(0.95, math.max(0, probability))

    debugMessage(self.name .. " sonar -> " .. unit:getName() .. " dist=" .. string.format("%.0f", distance) .. "m prob=" .. string.format("%.2f", probability))

    if math.random() > probability then return nil end

    return {
        x = pos.x,
        z = pos.z,
        distance = distance,
        unitName = unit:getName()
    }
end

-- Turn toward a target position
function SubmarineTorpedo:homeOnPosition(targetX, targetZ, dt)
    local dx = targetX - self.x
    local dz = targetZ - self.z
    local desiredHeading = math.deg(math.atan2(dz, dx))
    if desiredHeading < 0 then desiredHeading = desiredHeading + 360 end

    local headingDiff = desiredHeading - self.heading
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

    if self.heading >= 360 then self.heading = self.heading - 360 end
    if self.heading < 0 then self.heading = self.heading + 360 end
end

-- Torpedo hit: explode on the ship and destroy it
function SubmarineTorpedo:hitTarget(unit)
    self.active = false
    self:stopUpdateLoop()

    local pos = unit:getPoint()
    local unitName = unit:getName()

    -- Explosion for visual effect and damage
    trigger.action.explosion(pos, self.explosionPower)

    -- Ensure destruction
    if unit:isExist() then
        unit:destroy()
    end

    -- Global message
    logAll("*** TORPEDO IMPACT! " .. self.name .. " has hit " .. unitName .. "! ***", 30)

    -- Remove all trail lines and text
    self:clearMarker()

    -- Place impact marker at hit position
    local impactPoint = {x = pos.x, y = 0, z = pos.z}
    local text = self.name .. " | IMPACT | " .. unitName .. " DESTROYED"
    local coord = COORDINATE:New(pos.x, 0, pos.z)
    self.impactMarker = MARKER:New(coord, text):ReadOnly():ToAll()
end

-- Battery expired
function SubmarineTorpedo:expire()
    self.active = false
    self:stopUpdateLoop()
    self:clearMarker()
    log(self.name .. " battery depleted. Torpedo lost.", self.ownerCoalition)
end

-- Remove torpedo
function SubmarineTorpedo:remove()
    self.active = false
    self:stopUpdateLoop()
    self:clearMarker()
end

function SubmarineTorpedo:isActive()
    return self.active
end

function SubmarineTorpedo:stopUpdateLoop()
    if self.updateScheduleId then
        timer.removeFunction(self.updateScheduleId)
        self.updateScheduleId = nil
    end
end

-- Update F10 map marker as line trail (visible to all coalitions)
function SubmarineTorpedo:updateMarker()
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
    local status = "SEARCHING"
    if not self.armed then
        status = "ARMING"
    elseif self.hasTarget then
        status = "HOMING"
    end
    local text = string.format("%s | %s | Hdg: %.0f° | Battery: %.0fs",
        self.name, status, self.heading, remaining)
    local textId = nextMarkId()
    trigger.action.textToAll(-1, textId, endPoint, {1, 0, 0, 1}, {0, 0, 0, 0}, 12, true, text)
    self.textMarkerId = textId
    self.markerIds[#self.markerIds + 1] = textId

    -- Update previous position
    self.prevMarkerX = self.x
    self.prevMarkerZ = self.z
end

-- Remove all map markers (lines and text)
function SubmarineTorpedo:clearMarker()
    for _, id in ipairs(self.markerIds) do
        trigger.action.removeMark(id)
    end
    self.markerIds = {}
    self.textMarkerId = nil
end
