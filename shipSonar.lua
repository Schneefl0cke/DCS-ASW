ShipSonar = {}
ShipSonar.__index = ShipSonar

if not _shipSonarMarkIdCounter then _shipSonarMarkIdCounter = 800000 end
local function nextShipSonarMarkId()
    _shipSonarMarkIdCounter = _shipSonarMarkIdCounter + 1
    return _shipSonarMarkIdCounter
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
-- groupName:        ship's DCS group name
-- ownerCoalition:   coalition.side.BLUE or RED
-- thermalLayerDepth depth of thermal layer in meters
-- submarines:       shared table of VirtualSubmarine instances
-- config:           optional overrides (passiveRange, activeRange)
function ShipSonar:new(groupName, ownerCoalition, thermalLayerDepth, submarines, config)
    config = config or {}
    local obj = {
        groupName          = groupName,
        ownerCoalition     = ownerCoalition or coalition.side.BLUE,
        thermalLayerDepth  = thermalLayerDepth or 90,
        submarines         = submarines or {},
        -- Passive sonar
        passiveRange       = config.passiveRange or 12000,
        passiveScaleFactor = 0.10,
        -- Active sonar
        activeRange        = config.activeRange or 20000,
        activeScaleFactor  = 0.20,
        -- Mode / battery
        mode               = "passive",
        charge             = 100,
        drainRate          = 100 / 900,   -- 15-minute battery (0.111 %/s)
        rechargeRate       = 0.25,        -- same as MAD
        -- Sweep
        sweepAngle         = 0,           -- current bearing in radians
        sweepSpeed         = (2 * math.pi) / 60,  -- full circle in 60 s
        sweepWidth         = math.rad(30),          -- 30° cone (±15°)
        sweepMarkIds       = {left = nil, right = nil},
        -- Contact tracking
        trackingContact    = nil,         -- {bearing} when locked on a return
        trackingLostTime   = nil,
        trackingOscPhase   = 0,
        -- Visuals
        rangeRingMarkId    = nil,
        contactMarkers     = {},
        -- Update
        detectInterval     = 3,
        updateScheduleId   = nil,
    }
    setmetatable(obj, ShipSonar)
    obj:startUpdateLoop()
    return obj
end

-- ===== CONTROLS =====

function ShipSonar:setMode(newMode)
    if newMode == self.mode then
        return string.format("Sonar already in %s mode.", newMode)
    end
    if newMode == "active" and self.charge <= 0 then
        return "Active sonar unavailable — charge depleted. Recharging."
    end
    self.mode = newMode
    if newMode == "passive" then
        self.trackingContact = nil
        self.trackingLostTime = nil
        self:clearSweepLines()
        return string.format("Passive sonar mode | Charge: %d%% | Recharging at %.2f%%/s",
            math.floor(self.charge), self.rechargeRate)
    else
        return string.format("Active sonar ON | Charge: %d%% | Drain: %.2f%%/s",
            math.floor(self.charge), self.drainRate)
    end
end

function ShipSonar:getStatusText()
    if self.mode == "active" then
        local timeRemaining = math.floor(self.charge / self.drainRate)
        local trackState = self.trackingContact and "TRACKING" or "SCANNING"
        return string.format("ACTIVE SONAR | %s | Charge: %d%% (~%ds) | Sweep: %.0f° | Range: %dm",
            trackState, math.floor(self.charge), timeRemaining,
            math.deg(self.sweepAngle) % 360, self.activeRange)
    else
        return string.format("PASSIVE SONAR | Charge: %d%% | Range: %dm",
            math.floor(self.charge), self.passiveRange)
    end
end

-- ===== INTERNALS =====

function ShipSonar:getUnit()
    local dcsGroup = Group.getByName(self.groupName)
    if not dcsGroup or not dcsGroup:isExist() then return nil end
    local units = dcsGroup:getUnits()
    if units and #units > 0 and units[1]:isExist() then return units[1] end
    return nil
end

function ShipSonar:startUpdateLoop()
    local function update()
        local unit = self:getUnit()
        if not unit then
            self.updateScheduleId = timer.scheduleFunction(function() update() end, nil, timer.getTime() + self.detectInterval)
            return
        end

        local pos  = unit:getPoint()
        local shipX = pos.x
        local shipZ = pos.z

        if self.mode == "active" then
            self.charge = math.max(0, self.charge - self.drainRate * self.detectInterval)
            if self.charge <= 0 then
                self.mode = "passive"
                self.trackingContact = nil
                self:clearSweepLines()
                log(self.groupName .. " active sonar charge depleted — switching to passive.", self.ownerCoalition)
            else
                self:runActiveScan(shipX, shipZ)
            end
        else
            self.charge = math.min(100, self.charge + self.rechargeRate * self.detectInterval)
            self:runPassiveScan(shipX, shipZ)
        end

        self:updateVisuals(shipX, shipZ)

        self.updateScheduleId = timer.scheduleFunction(function() update() end, nil, timer.getTime() + self.detectInterval)
    end

    timer.scheduleFunction(function() update() end, nil, timer.getTime() + self.detectInterval)
end

-- ===== PASSIVE SCAN =====

function ShipSonar:runPassiveScan(shipX, shipZ)
    for _, sub in ipairs(self.submarines) do
        if sub:isAlive() then
            local contact = self:tryDetectPassive(sub, shipX, shipZ)
            if contact then
                self:reportContact(contact, shipX, shipZ)
                log(string.format("%s passive sonar CONTACT | BRG %.0f° | Conf: %.0f%%",
                    self.groupName, math.deg(contact.bearing) % 360, contact.confidence * 100),
                    self.ownerCoalition)
            end
        end
    end
end

function ShipSonar:tryDetectPassive(sub, shipX, shipZ)
    local dx = sub.x - shipX
    local dz = sub.z - shipZ
    local distance = math.sqrt(dx * dx + dz * dz)

    if distance > self.passiveRange then return nil end

    local effectiveNoise = sub.speed * sub.noiseFactor
    if effectiveNoise < 0.1 then return nil end

    local depthPenalty   = math.max(0.1, 1 - (sub.depth / 500))
    local thermalPenalty = sub.depth > self.thermalLayerDepth and 0.2 or 1.0
    local distanceFactor = 1 - (distance / self.passiveRange)
    local probability    = effectiveNoise * depthPenalty * thermalPenalty * distanceFactor * self.passiveScaleFactor
    probability = math.min(0.95, math.max(0, probability))

    debugMessage(self.groupName .. " passive -> " .. sub.name
        .. " dist=" .. string.format("%.0f", distance)
        .. "m prob=" .. string.format("%.2f", probability))

    if probability < 0.05 then return nil end
    if math.random() > probability then return nil end

    local bearingTrue     = math.atan2(dz, dx)
    local bearingErrorMax = math.rad(30) * (1 - probability)
    local bearingError    = (math.random() * 2 - 1) * bearingErrorMax

    return { bearing = bearingTrue + bearingError, confidence = probability, subName = sub.name }
end

-- ===== ACTIVE SCAN =====

function ShipSonar:runActiveScan(shipX, shipZ)
    local sweepStep = self.sweepSpeed * self.detectInterval

    if self.trackingContact then
        -- Oscillate ±15° around the locked bearing
        self.trackingOscPhase = self.trackingOscPhase + sweepStep * 2
        self.sweepAngle = self.trackingContact.bearing + math.sin(self.trackingOscPhase) * math.rad(15)
        -- Lose the contact after 15 s without a return
        if self.trackingLostTime and timer.getTime() - self.trackingLostTime > 15 then
            self.trackingContact  = nil
            self.trackingLostTime = nil
            log(self.groupName .. " sonar: contact lost — resuming circle scan.", self.ownerCoalition)
        end
    else
        self.sweepAngle = self.sweepAngle + sweepStep
        if self.sweepAngle > 2 * math.pi then
            self.sweepAngle = self.sweepAngle - 2 * math.pi
        end
    end

    -- Warn the enemy side about an active ping
    local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
    if ASW_SOUND then
        ASW_SOUND:playForCoalition(enemyCoalition, "warning_sonar")
    end

    local halfWidth    = self.sweepWidth / 2
    local contactFound = false

    for _, sub in ipairs(self.submarines) do
        if sub:isAlive() then
            local contact = self:tryDetectActive(sub, shipX, shipZ, halfWidth)
            if contact then
                contactFound = true
                self.trackingContact  = { bearing = math.atan2(sub.z - shipZ, sub.x - shipX) }
                self.trackingLostTime = nil
                self:reportContact(contact, shipX, shipZ)
                log(string.format("%s active sonar CONTACT | BRG %.0f° | Conf: %.0f%%",
                    self.groupName, math.deg(contact.bearing) % 360, contact.confidence * 100),
                    self.ownerCoalition)
            end
        end
    end

    if not contactFound and self.trackingContact and not self.trackingLostTime then
        self.trackingLostTime = timer.getTime()
    end
end

function ShipSonar:tryDetectActive(sub, shipX, shipZ, halfWidth)
    local dx = sub.x - shipX
    local dz = sub.z - shipZ
    local distance = math.sqrt(dx * dx + dz * dz)

    if distance > self.activeRange then return nil end

    -- Cone check
    local bearingToSub = math.atan2(dz, dx)
    local angleDiff    = bearingToSub - self.sweepAngle
    while angleDiff >  math.pi do angleDiff = angleDiff - 2 * math.pi end
    while angleDiff < -math.pi do angleDiff = angleDiff + 2 * math.pi end
    if math.abs(angleDiff) > halfWidth then return nil end

    -- Active sonar: hull reflection + movement bonus
    local effectiveSignal = 1.0 + sub.speed * sub.noiseFactor * 0.3
    local depthPenalty    = math.max(0.1, 1 - (sub.depth / 500))
    local thermalPenalty  = sub.depth > self.thermalLayerDepth and 0.2 or 1.0
    local distanceFactor  = 1 - (distance / self.activeRange)
    local probability     = effectiveSignal * depthPenalty * thermalPenalty * distanceFactor * self.activeScaleFactor
    probability = math.min(0.95, math.max(0, probability))

    debugMessage(self.groupName .. " active -> " .. sub.name
        .. " dist=" .. string.format("%.0f", distance)
        .. "m prob=" .. string.format("%.2f", probability))

    if probability < 0.05 then return nil end
    if math.random() > probability then return nil end

    local bearingErrorMax  = math.rad(20) * (1 - probability)
    local bearingError     = (math.random() * 2 - 1) * bearingErrorMax
    local rangeErrorMax    = distance * 0.20 * (1 - probability)
    local rangeError       = (math.random() * 2 - 1) * rangeErrorMax
    local estimatedRange   = math.max(0, distance + rangeError)
    local estimatedBearing = bearingToSub + bearingError
    local estimatedX       = shipX + estimatedRange * math.cos(estimatedBearing)
    local estimatedZ       = shipZ + estimatedRange * math.sin(estimatedBearing)
    local depthError       = (math.random() * 2 - 1) * sub.depth * 0.25 * (1 - probability)
    local estimatedDepth   = math.max(0, sub.depth + depthError)

    return {
        x          = estimatedX,
        z          = estimatedZ,
        depth      = estimatedDepth,
        bearing    = estimatedBearing,
        confidence = probability,
        subName    = sub.name,
    }
end

-- ===== CONTACT REPORTING =====

function ShipSonar:reportContact(contact, shipX, shipZ)
    if self.mode == "passive" then
        -- Bearing line only
        local lineLength = self.passiveRange
        local startPt    = {x = shipX, y = 0, z = shipZ}
        local endPt      = {
            x = shipX + lineLength * math.cos(contact.bearing),
            y = 0,
            z = shipZ + lineLength * math.sin(contact.bearing),
        }
        local yellow = {1, 1, 0, 1}
        local lineId = nextShipSonarMarkId()
        local textId = nextShipSonarMarkId()

        trigger.action.lineToAll(self.ownerCoalition, lineId, startPt, endPt, yellow, 2, true)

        local labelPt = {
            x = shipX + lineLength * 0.25 * math.cos(contact.bearing),
            y = 0,
            z = shipZ + lineLength * 0.25 * math.sin(contact.bearing),
        }
        trigger.action.textToAll(self.ownerCoalition, textId, labelPt, yellow, {0, 0, 0, 0}, 10, true,
            string.format("%s PASSIVE | BRG %.0f° | Conf: %.0f%%",
                self.groupName, math.deg(contact.bearing) % 360, contact.confidence * 100))

        local m = {lineId = lineId, textId = textId}
        self.contactMarkers[#self.contactMarkers + 1] = m
        timer.scheduleFunction(function()
            trigger.action.removeMark(lineId)
            trigger.action.removeMark(textId)
            for i, cm in ipairs(self.contactMarkers) do
                if cm == m then table.remove(self.contactMarkers, i); break end
            end
        end, nil, timer.getTime() + 30)

    else
        -- Active: position fix
        local coord  = COORDINATE:New(contact.x, 0, contact.z)
        local text   = string.format("%s ACTIVE | CONTACT | Conf: %.0f%% | Est. Depth: %.0fm",
            self.groupName, contact.confidence * 100, contact.depth)
        local marker = MARKER:New(coord, text):ReadOnly():ToCoalition(self.ownerCoalition)

        local m = {marker = marker}
        self.contactMarkers[#self.contactMarkers + 1] = m
        timer.scheduleFunction(function()
            marker:Remove()
            for i, cm in ipairs(self.contactMarkers) do
                if cm == m then table.remove(self.contactMarkers, i); break end
            end
        end, nil, timer.getTime() + 30)

        local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
        trigger.action.outTextForCoalition(enemyCoalition,
            self.groupName .. ": active sonar contact detected!", 8, false)

        if ASW_SOUND then
            ASW_SOUND:playForCoalition(self.ownerCoalition, "warning_sonar")
        end
    end
end

-- ===== VISUALS =====

function ShipSonar:updateVisuals(shipX, shipZ)
    self:updateRangeRing(shipX, shipZ)
    if self.mode == "active" then
        self:updateSweepLines(shipX, shipZ)
    else
        self:clearSweepLines()
    end
end

function ShipSonar:updateRangeRing(shipX, shipZ)
    if self.rangeRingMarkId then
        trigger.action.removeMark(self.rangeRingMarkId)
        self.rangeRingMarkId = nil
    end
    local center = {x = shipX, y = 0, z = shipZ}
    self.rangeRingMarkId = nextShipSonarMarkId()
    if self.mode == "active" then
        trigger.action.circleToAll(self.ownerCoalition, self.rangeRingMarkId, center, self.activeRange,
            {1, 0.5, 0, 0.6}, {1, 0.5, 0, 0.03}, 1, true)
    else
        trigger.action.circleToAll(self.ownerCoalition, self.rangeRingMarkId, center, self.passiveRange,
            {0, 0.6, 1, 0.4}, {0, 0.6, 1, 0.03}, 1, true)
    end
end

function ShipSonar:updateSweepLines(shipX, shipZ)
    if self.sweepMarkIds.left  then trigger.action.removeMark(self.sweepMarkIds.left)  end
    if self.sweepMarkIds.right then trigger.action.removeMark(self.sweepMarkIds.right) end

    local range     = self.activeRange
    local halfWidth = self.sweepWidth / 2
    local startPt   = {x = shipX, y = 0, z = shipZ}
    local orange    = {1, 0.6, 0, 0.9}

    self.sweepMarkIds.left = nextShipSonarMarkId()
    trigger.action.lineToAll(self.ownerCoalition, self.sweepMarkIds.left, startPt, {
        x = shipX + range * math.cos(self.sweepAngle - halfWidth),
        y = 0,
        z = shipZ + range * math.sin(self.sweepAngle - halfWidth),
    }, orange, 2, true)

    self.sweepMarkIds.right = nextShipSonarMarkId()
    trigger.action.lineToAll(self.ownerCoalition, self.sweepMarkIds.right, startPt, {
        x = shipX + range * math.cos(self.sweepAngle + halfWidth),
        y = 0,
        z = shipZ + range * math.sin(self.sweepAngle + halfWidth),
    }, orange, 2, true)
end

function ShipSonar:clearSweepLines()
    if self.sweepMarkIds.left  then
        trigger.action.removeMark(self.sweepMarkIds.left)
        self.sweepMarkIds.left  = nil
    end
    if self.sweepMarkIds.right then
        trigger.action.removeMark(self.sweepMarkIds.right)
        self.sweepMarkIds.right = nil
    end
end

function ShipSonar:clearContactMarkers()
    for _, m in ipairs(self.contactMarkers) do
        if m.marker then
            m.marker:Remove()
        else
            if m.lineId then trigger.action.removeMark(m.lineId) end
            if m.textId then trigger.action.removeMark(m.textId) end
        end
    end
    self.contactMarkers = {}
end

function ShipSonar:destroy()
    self:clearSweepLines()
    if self.rangeRingMarkId then
        trigger.action.removeMark(self.rangeRingMarkId)
        self.rangeRingMarkId = nil
    end
    self:clearContactMarkers()
    if self.updateScheduleId then
        timer.removeFunction(self.updateScheduleId)
        self.updateScheduleId = nil
    end
end
