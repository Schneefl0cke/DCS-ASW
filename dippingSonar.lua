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

local debug = trigger.misc.getUserFlag("Debug")

local function debugMessage(message, duration)
    if debug == 1 then
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
        maxCableDepth = 100,         -- max depth in meters
        cableRate = 5,               -- meters per second lower/raise
        maxSpeed = 15,               -- m/s before cable breaks
        warnSpeed = 5,               -- m/s speed warning threshold
        maxAltitude = 100,           -- AGL before cable breaks
        warnAltitude = 50,           -- AGL altitude warning threshold
        detectInterval = 3,          -- seconds between pings
        targetDepth = 50,            -- current set depth
        currentDepth = 0,            -- actual cable depth
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

-- Set target cable depth
function DippingSonar:setDepth(depth)
    self.targetDepth = math.max(0, math.min(depth, self.maxCableDepth))
end

-- Lower the sonar
function DippingSonar:lower()
    if not self.operational then return false, "Dipping sonar is broken! Return to rearm." end
    if self.state ~= "stowed" then return false, "Sonar is already deployed!" end

    self.state = "lowering"
    self.currentDepth = 0
    self:startUpdateLoop()
    return true, "Lowering dipping sonar to " .. self.targetDepth .. "m..."
end

-- Raise the sonar
function DippingSonar:raise()
    if self.state ~= "active" and self.state ~= "lowering" then
        return false, "Sonar is not deployed!"
    end

    self.state = "raising"
    return true, "Raising dipping sonar..."
end

-- Repair the sonar (at rearm point)
function DippingSonar:repair()
    self.operational = true
    self.state = "stowed"
    self.currentDepth = 0
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

        -- Update cable depth
        if self.state == "lowering" then
            self.currentDepth = self.currentDepth + self.cableRate
            if self.currentDepth >= self.targetDepth then
                self.currentDepth = self.targetDepth
                self.state = "active"
                self:messageToGroup("Dipping sonar active at " .. self.currentDepth .. "m depth.", 5)
            else
                self:messageToGroup(string.format("Lowering... %.0fm / %dm", self.currentDepth, self.targetDepth), 1)
            end
        elseif self.state == "raising" then
            self.currentDepth = self.currentDepth - self.cableRate
            if self.currentDepth <= 0 then
                self.currentDepth = 0
                self.state = "stowed"
                self:messageToGroup("Dipping sonar stowed.", 5)
                return -- Stop the loop
            else
                self:messageToGroup(string.format("Raising... %.0fm", self.currentDepth), 1)
            end
        elseif self.state == "active" then
            -- Adjust depth if target changed while active
            local depthDiff = self.targetDepth - self.currentDepth
            if math.abs(depthDiff) > 0.1 then
                local change = self.cableRate
                if math.abs(depthDiff) <= change then
                    self.currentDepth = self.targetDepth
                elseif depthDiff > 0 then
                    self.currentDepth = self.currentDepth + change
                else
                    self.currentDepth = self.currentDepth - change
                end
                self:messageToGroup(string.format("Adjusting depth... %.0fm / %dm", self.currentDepth, self.targetDepth), 1)
            end

            -- Ping for submarines
            self:ping(unit)
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

    -- Alert enemy coalition about active sonar ping with position
    local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
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

-- Detection using same model as buoy but with higher scale factor
function DippingSonar:tryDetect(sub, sonarX, sonarZ)
    local dx = sub.x - sonarX
    local dz = sub.z - sonarZ
    local distance = math.sqrt(dx * dx + dz * dz)

    if distance > self.maxDetectionRange then return nil end

    local effectiveNoise = sub.speed * sub.noiseFactor
    if effectiveNoise < 0.1 then return nil end

    local maxEffectiveDepth = 500
    local depthPenalty = math.max(0.1, 1 - (sub.depth / maxEffectiveDepth))

    local thermalPenalty = 1.0
    if sub.depth > self.thermalLayerDepth and self.currentDepth <= self.thermalLayerDepth then
        -- Sonar above layer, sub below: reduced
        thermalPenalty = 0.2
    elseif sub.depth > self.thermalLayerDepth and self.currentDepth > self.thermalLayerDepth then
        -- Both below layer: no penalty (sonar is down there with the sub)
        thermalPenalty = 1.0
    end

    local distanceFactor = 1 - (distance / self.maxDetectionRange)

    local probability = effectiveNoise * depthPenalty * thermalPenalty * distanceFactor * self.scaleFactor
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
    self.currentDepth = 0
    self:stopUpdateLoop()
    self:clearContactMarkers()
    self:messageToGroup("DIPPING SONAR LOST! " .. reason, 10)
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
