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

local debug = trigger.misc.getUserFlag("Debug")

local function debugMessage(message, duration)
    if debug == 1 then
        duration = duration or 10
        trigger.action.outText(message, duration, false)
        env.info(message, false)
    end
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
        marker = nil,
        updateScheduleId = nil
    }
    setmetatable(obj, AntiSubmarineTorpedo)
    obj:startUpdateLoop()
    log("Torpedo " .. name .. " launched! Search depth: " .. obj.targetDepth .. "m | Battery: " .. obj.batteryLife .. "s", obj.ownerCoalition)

    -- Alert enemy coalition about torpedo launch
    local enemyCoalition = obj.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
    trigger.action.outTextForCoalition(enemyCoalition, "WARNING: Enemy ASW torpedo in the water!", 10, false)

    return obj
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

-- Detect submarines and home in on contacts
function AntiSubmarineTorpedo:detectAndHome(dt)
    local detected = false

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

            -- Try sonar detection (same formula as buoy)
            local contact = self:tryDetect(sub)
            if contact then
                if not self.hasTarget then
                    log(self.name .. " SONAR CONTACT! Homing on target!", self.ownerCoalition)
                end
                self.hasTarget = true
                detected = true
                -- Store last known position
                self.lastContactX = contact.x
                self.lastContactZ = contact.z
                self.lastContactDepth = contact.depth
                -- Home toward estimated position
                self:homeOnContact(contact, dt)
                return -- Only home on first detected contact
            end
        end
    end

    -- No detection this tick: if we had a target, turn back toward last known position
    if not detected and self.hasTarget and self.lastContactX then
        self:homeOnContact({
            x = self.lastContactX,
            z = self.lastContactZ,
            depth = self.lastContactDepth
        }, dt)
    end
end

-- Sonar detection: same probability model as Sonarbuoy
function AntiSubmarineTorpedo:tryDetect(sub)
    local dx = sub.x - self.x
    local dz = sub.z - self.z
    local distance = math.sqrt(dx * dx + dz * dz)

    if distance > self.maxDetectionRange then return nil end

    local effectiveNoise = sub.speed * sub.noiseFactor
    if effectiveNoise < 0.1 then return nil end

    local maxEffectiveDepth = 500
    local depthPenalty = math.max(0.1, 1 - (sub.depth / maxEffectiveDepth))

    local thermalPenalty = 1.0
    if sub.depth > self.thermalLayerDepth then
        thermalPenalty = 0.2
    end

    local distanceFactor = 1 - (distance / self.maxDetectionRange)

    local scaleFactor = 0.15
    local probability = effectiveNoise * depthPenalty * thermalPenalty * distanceFactor * scaleFactor
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

    if isDecoy then
        -- Hit a noise maker
        sub:remove()
        logAll("*** TORPEDO IMPACT! " .. self.name .. " hit a decoy! ***", 15)
        self:clearMarker()
        local coord = COORDINATE:New(sub.x, 0, sub.z)
        local text = self.name .. " | IMPACT | DECOY DESTROYED"
        self.marker = MARKER:New(coord, text):ReadOnly():ToAll()
    else
        -- Hit a real submarine
        local point = {x = sub.x, y = 0, z = sub.z}
        trigger.action.explosion(point, 1000)
        sub:destroy()
        logAll("*** TORPEDO IMPACT! " .. self.name .. " has destroyed " .. sub.name .. "! ***", 30)
        self:clearMarker()
        local coord = COORDINATE:New(sub.x, 0, sub.z)
        local text = self.name .. " | IMPACT | " .. sub.name .. " DESTROYED"
        self.marker = MARKER:New(coord, text):ReadOnly():ToAll()
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

-- Update F10 map marker showing torpedo position
function AntiSubmarineTorpedo:updateMarker()
    local currentTime = timer.getTime()
    -- Only create new marker every 20 seconds
    if currentTime - self.lastMarkerTime < 20 then
        return
    end
    self.lastMarkerTime = currentTime

    local coord = COORDINATE:New(self.x, 0, self.z)
    local remaining = math.max(0, self.batteryLife - self.elapsedTime)
    local status = self.hasTarget and "HOMING" or "SEARCHING"
    local text = string.format("%s | %s | Depth: %.0fm | Hdg: %.0f° | Battery: %.0fs",
        self.name, status, self.depth, self.heading, remaining)

    -- Create a new marker that persists for 20 seconds
    local marker = MARKER:New(coord, text):ReadOnly():ToAll()
    timer.scheduleFunction(function()
        marker:Remove()
    end, nil, timer.getTime() + 20)
end

-- Remove map marker
function AntiSubmarineTorpedo:clearMarker()
    if self.marker then
        self.marker:Remove()
        self.marker = nil
    end
end
