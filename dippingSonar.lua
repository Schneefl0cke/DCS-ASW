DippingSonar = {}
DippingSonar.__index = DippingSonar

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

-- Constructor
-- groupName: the ASW hunter group name that owns this sonar
-- ownerCoalition: coalition side
-- thermalLayerDepth: thermal layer depth for detection
-- submarines: shared table of detectable objects
function DippingSonar:new(groupName, ownerCoalition, thermalLayerDepth, submarines)
    local obj = {
        groupName = groupName,
        ownerCoalition = ownerCoalition or coalition.side.BLUE,
        thermalLayerDepth = thermalLayerDepth or 90,
        submarines = submarines or {},
        maxDetectionRange = 8000,    -- 8 km active sonar range
        scaleFactor = 0.25,          -- higher than buoy (0.15)
        maxCableLength = 450,        -- max cable length in meters
        cableRate = 5,               -- meters per second lower/raise
        maxSpeed = 15,               -- m/s before cable breaks
        warnSpeed = 5,               -- m/s speed warning threshold
        maxAltitude = 100,           -- AGL before cable breaks
        warnAltitude = 50,           -- AGL altitude warning threshold
        detectInterval = 3,          -- seconds between pings
        targetCableLength = 100,     -- cable length to pay out
        currentCableLength = 0,      -- cable length currently paid out
        state = "stowed",            -- stowed, lowering, active, raising, broken
        operational = true,          -- false if cable broke
        contactMarkers = {},
        updateScheduleId = nil
    }
    setmetatable(obj, DippingSonar)
    return obj
end

-- Get the DCS unit for this sonar's group
function DippingSonar:getUnit()
    local dcsGroup = Group.getByName(self.groupName)
    if not dcsGroup or not dcsGroup:isExist() then return nil end
    local units = dcsGroup:getUnits()
    if units and #units > 0 and units[1]:isExist() then
        return units[1]
    end
    return nil
end

-- Get unit's AGL altitude
function DippingSonar:getAGL(unit)
    local pos = unit:getPoint()
    local landHeight = land.getHeight({x = pos.x, y = pos.z})
    return pos.y - landHeight
end

-- Get unit's speed in m/s
function DippingSonar:getSpeed(unit)
    local velocity = unit:getVelocity()
    return math.sqrt(velocity.x^2 + velocity.y^2 + velocity.z^2)
end

-- Set target cable length
function DippingSonar:setDepth(length)
    self.targetCableLength = math.max(0, math.min(length, self.maxCableLength))
end

-- Adjust target cable length by a delta (+extend / -retract)
function DippingSonar:adjustCable(delta)
    self.targetCableLength = math.max(0, math.min(self.targetCableLength + delta, self.maxCableLength))
end

-- Get water (seabed) depth at the helicopter's current position
function DippingSonar:getSeabedDepth(unit)
    unit = unit or self:getUnit()
    if not unit then return 0 end
    local pos = unit:getPoint()
    local _, depth = land.getSurfaceHeightWithSeabed({x = pos.x, y = pos.z})
    return math.max(0, depth)
end

-- Get actual sonar depth in water = cable length - AGL (clamped >= 0)
function DippingSonar:getWaterDepth(unit)
    unit = unit or self:getUnit()
    if not unit then return 0 end
    local agl = self:getAGL(unit)
    return math.max(0, self.currentCableLength - agl)
end

-- Lower the sonar
function DippingSonar:lower()
    if not self.operational then return false, "Dipping sonar is broken! Return to rearm." end
    if self.state ~= "stowed" then return false, "Sonar is already deployed!" end

    local unit = self:getUnit()
    if unit and self:getSeabedDepth(unit) <= 0 then
        return false, "Cannot deploy dipping sonar over land!"
    end

    self.state = "lowering"
    self.currentCableLength = 0
    self:startUpdateLoop()
    return true, "Lowering dipping sonar, cable to " .. self.targetCableLength .. "m..."
end

-- Raise the sonar
function DippingSonar:raise()
    if self.state ~= "active" and self.state ~= "lowering" then
        return false, "Sonar is not deployed!"
    end

    self.state = "raising"
    return true, "Raising dipping sonar..."
end

-- Stop the sonar at current cable length
function DippingSonar:stop()
    if self.state ~= "lowering" and self.state ~= "raising" then
        return false, "Sonar is not moving!"
    end

    self.state = "active"
    self.targetCableLength = self.currentCableLength
    local waterDepth = self:getWaterDepth()
    return true, string.format("Sonar stopped. Cable: %.0fm | Sonar depth: %.0fm", self.currentCableLength, waterDepth)
end

-- Repair the sonar (at rearm point)
function DippingSonar:repair()
    self.operational = true
    self.state = "stowed"
    self.currentCableLength = 0
end

function DippingSonar:isDeployed()
    return self.state == "lowering" or self.state == "active" or self.state == "raising"
end

-- Main update loop
function DippingSonar:startUpdateLoop()
    local function update()
        if self.state == "stowed" or self.state == "broken" then return end

        local unit = self:getUnit()
        if not unit then
            self:breakCable("Aircraft lost!")
            return
        end

        -- Check speed and altitude limits
        local speed = self:getSpeed(unit)
        local agl = self:getAGL(unit)
        local seabedDepth = self:getSeabedDepth(unit)

        -- Speed warnings and break
        if speed > self.maxSpeed then
            self:breakCable("Cable snapped! Speed too high (" .. string.format("%.0f", speed) .. " m/s)!")
            return
        elseif speed > self.warnSpeed then
            self:messageToGroup("WARNING: Speed " .. string.format("%.0f", speed) .. " m/s! Cable breaks at " .. self.maxSpeed .. " m/s!", 1)
        end

        -- Altitude warnings and break
        if agl > self.maxAltitude then
            self:breakCable("Cable snapped! Altitude too high (" .. string.format("%.0f", agl) .. "m AGL)!")
            return
        elseif agl > self.warnAltitude then
            self:messageToGroup("WARNING: Altitude " .. string.format("%.0f", agl) .. "m AGL! Cable breaks at " .. self.maxAltitude .. "m!", 1)
        end

        -- Destroy sonar if helicopter flies over land while deployed
        if seabedDepth <= 0 then
            self:breakCable("Sonar destroyed! Helicopter flew over land!")
            return
        end

        -- Update cable length
        local cableStep = self.cableRate * self.detectInterval
        if self.state == "lowering" then
            self.currentCableLength = self.currentCableLength + cableStep
            if self.currentCableLength >= self.targetCableLength then
                self.currentCableLength = self.targetCableLength
                self.state = "active"
                local waterDepth = self:getWaterDepth(unit)
                self:messageToGroup(string.format("Dipping sonar active. Cable: %dm | Sonar depth: %.0fm", self.currentCableLength, waterDepth), 5)
                -- Splash sound when sonar enters water (hunter group + enemy coalition)
                if ASW_SOUND then
                    ASW_SOUND:playOnce(self.groupName, "sonar_splash")
                    local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
                    ASW_SOUND:playForCoalition(self.ownerCoalition, "sonar_splash")
                    ASW_SOUND:playForCoalition(enemyCoalition, "sonar_splash")
                end
            else
                self:messageToGroup(string.format("Lowering... Cable: %.0fm / %dm", self.currentCableLength, self.targetCableLength), 1)
                -- Cable extending sound (hunter group only)
                if ASW_SOUND then
                    ASW_SOUND:playOnce(self.groupName, "sonar_extend")
                end
            end
        elseif self.state == "raising" then
            self.currentCableLength = self.currentCableLength - cableStep
            if self.currentCableLength <= 0 then
                self.currentCableLength = 0
                self.state = "stowed"
                self:messageToGroup("Dipping sonar stowed.", 5)
                return -- Stop the loop
            else
                self:messageToGroup(string.format("Raising... Cable: %.0fm", self.currentCableLength), 1)
                -- Cable retrieving sound (hunter group only)
                if ASW_SOUND then
                    ASW_SOUND:playOnce(self.groupName, "sonar_retrieve")
                end
            end
        elseif self.state == "active" then
            -- Adjust cable if target changed while active
            local cableDiff = self.targetCableLength - self.currentCableLength
            if math.abs(cableDiff) > 0.1 then
                local change = cableStep
                if math.abs(cableDiff) <= change then
                    self.currentCableLength = self.targetCableLength
                elseif cableDiff > 0 then
                    self.currentCableLength = self.currentCableLength + change
                else
                    self.currentCableLength = self.currentCableLength - change
                end
                local waterDepth = self:getWaterDepth(unit)
                self:messageToGroup(string.format("Adjusting cable... %.0fm / %dm | Sonar depth: %.0fm", self.currentCableLength, self.targetCableLength, waterDepth), 1)
            end

            -- Ping for submarines
            self:ping(unit)
        end

        -- Clamp cable if water is shallower than current sonar depth
        local sonarWaterDepth = self.currentCableLength - agl
        if sonarWaterDepth > seabedDepth then
            self.currentCableLength = agl + seabedDepth
            self:messageToGroup(string.format("WARNING: Water depth (%.0fm) shallower than sonar depth (%.0fm). Cable adjusted to %.0fm.", seabedDepth, sonarWaterDepth, self.currentCableLength), 3)
        end

        self.updateScheduleId = timer.scheduleFunction(function()
            update()
        end, nil, timer.getTime() + self.detectInterval)
    end

    update()
end

-- Active sonar ping: detect submarines
function DippingSonar:ping(unit)
    local pos = unit:getPoint()
    local sonarX = pos.x
    local sonarZ = pos.z

    -- Sonar ping sound (hunter group + warning to enemy coalition)
    if ASW_SOUND then
        ASW_SOUND:playOnce(self.groupName, "sonar_ping")
        ASW_SOUND:playForCoalition(self.ownerCoalition, "sonar_ping")
    end

    -- Alert enemy coalition about active sonar ping with position
    local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
    if ASW_SOUND then
        ASW_SOUND:playForCoalition(enemyCoalition, "warning_sonar")
    end
    local coord = COORDINATE:New(sonarX, 0, sonarZ)
    local coordText = coord:ToStringLLDMS()
    trigger.action.outTextForCoalition(enemyCoalition,
        "ACTIVE SONAR PING DETECTED!\nPosition: " .. coordText, 5, false)

    for _, sub in ipairs(self.submarines) do
        if sub:isAlive() then
            local contact = self:tryDetect(sub, sonarX, sonarZ)
            if contact then
                self:markContact(contact)
                log(self.groupName .. " dipping sonar CONTACT! Confidence: " .. string.format("%.0f", contact.confidence * 100) .. "%", self.ownerCoalition)
            end
        end
    end
end

-- Active sonar detection: ping bounces off hull regardless of sub movement.
-- Movement adds a bonus (cavitation, Doppler) but a stationary sub is still detectable.
function DippingSonar:tryDetect(sub, sonarX, sonarZ)
    local dx = sub.x - sonarX
    local dz = sub.z - sonarZ
    local distance = math.sqrt(dx * dx + dz * dz)

    if distance > self.maxDetectionRange then return nil end

    -- Active sonar: base reflection from hull + bonus from movement noise
    local baseReflection = 1.0  -- hull always reflects the ping
    local movementBonus = sub.speed * sub.noiseFactor * 0.5  -- moving subs are easier
    local effectiveSignal = baseReflection + movementBonus

    local maxEffectiveDepth = 500
    local depthPenalty = math.max(0.1, 1 - (sub.depth / maxEffectiveDepth))

    local thermalPenalty = 1.0
    local waterDepth = self:getWaterDepth()
    if sub.depth > self.thermalLayerDepth and waterDepth <= self.thermalLayerDepth then
        -- Sonar above layer, sub below: reduced
        thermalPenalty = 0.2
    elseif sub.depth > self.thermalLayerDepth and waterDepth > self.thermalLayerDepth then
        -- Both below layer: no penalty (sonar is down there with the sub)
        thermalPenalty = 1.0
    end

    local distanceFactor = 1 - (distance / self.maxDetectionRange)

    local probability = effectiveSignal * depthPenalty * thermalPenalty * distanceFactor * self.scaleFactor
    probability = math.min(0.95, math.max(0, probability))

    debugMessage(self.groupName .. " dip sonar -> " .. sub.name .. " dist=" .. string.format("%.0f", distance) .. "m prob=" .. string.format("%.2f", probability))

    if math.random() > probability then return nil end

    -- Detection successful
    local confidence = probability
    local bearingTrue = math.atan2(dz, dx)

    local bearingErrorMax = math.rad(30) * (1 - confidence)
    local bearingError = (math.random() * 2 - 1) * bearingErrorMax
    local estimatedBearing = bearingTrue + bearingError

    local rangeErrorMax = distance * 0.25 * (1 - confidence)
    local rangeError = (math.random() * 2 - 1) * rangeErrorMax
    local estimatedRange = math.max(0, distance + rangeError)

    local estimatedX = sonarX + estimatedRange * math.cos(estimatedBearing)
    local estimatedZ = sonarZ + estimatedRange * math.sin(estimatedBearing)

    local depthErrorMax = sub.depth * 0.30 * (1 - confidence)
    local depthError = (math.random() * 2 - 1) * depthErrorMax
    local estimatedDepth = math.max(0, sub.depth + depthError)

    return {
        x = estimatedX,
        z = estimatedZ,
        depth = estimatedDepth,
        confidence = confidence,
        subName = sub.name,
        sonarGroup = self.groupName
    }
end

-- Place contact marker (30 second auto-remove, like buoys)
function DippingSonar:markContact(contact)
    local coord = COORDINATE:New(contact.x, 0, contact.z)
    local text = string.format("%s DIPPING SONAR | CONTACT | Confidence: %.0f%% | Est. Depth: %.0fm",
        self.groupName, contact.confidence * 100, contact.depth)
    local marker = MARKER:New(coord, text):ReadOnly():ToCoalition(self.ownerCoalition)
    self.contactMarkers[#self.contactMarkers + 1] = marker

    timer.scheduleFunction(function()
        marker:Remove()
        for i, m in ipairs(self.contactMarkers) do
            if m == marker then
                table.remove(self.contactMarkers, i)
                break
            end
        end
    end, nil, timer.getTime() + 30)
end

-- Cable break
function DippingSonar:breakCable(reason)
    self.state = "broken"
    self.operational = false
    self.currentCableLength = 0
    self:stopUpdateLoop()
    self:clearContactMarkers()
    self:messageToGroup("DIPPING SONAR LOST! " .. reason, 10)
    -- Cable break sound (hunter group only)
    if ASW_SOUND then
        ASW_SOUND:playOnce(self.groupName, "sonar_cable_break")
    end
end

function DippingSonar:stopUpdateLoop()
    if self.updateScheduleId then
        timer.removeFunction(self.updateScheduleId)
        self.updateScheduleId = nil
    end
end

function DippingSonar:clearContactMarkers()
    for _, m in ipairs(self.contactMarkers) do
        m:Remove()
    end
    self.contactMarkers = {}
end

function DippingSonar:messageToGroup(message, duration)
    local mooseGroup = GROUP:FindByName(self.groupName)
    if mooseGroup then
        trigger.action.outTextForGroup(mooseGroup:GetDCSObject():getID(), message, duration or 5, false)
    end
end
