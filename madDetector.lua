MADDetector = {}
MADDetector.__index = MADDetector

local function nextMADMarkId()
    if not _madMarkIdCounter then _madMarkIdCounter = 600000 end
    _madMarkIdCounter = _madMarkIdCounter + 1
    return _madMarkIdCounter
end

-- Magnetic Anomaly Detector for fixed-wing ASW aircraft.
-- Detects ferromagnetic submarine hulls by sensing distortions in Earth's
-- magnetic field. Requires low flight directly over the search area.
-- MAD is a close-range precision tool — use sonobuoys first to cue the area,
-- then overfly for a MAD confirmation before torpedo delivery.
--
-- Detection degrades with depth and altitude (inverse-cube physics).
-- Submarines below the searchDepth threshold are undetectable.
-- The charge system represents continuous power draw and sensor heating;
-- deeper search settings require more power and drain faster.
--
-- config table:
--   detectionRange:   horizontal range at optimal altitude (default 500m)
--   maxSearchDepth:   deepest available search depth setting (default 200m)
--   maxAltitude:      max AGL for operation (default 150m)
--   drainBase:        charge drain %/sec at minimum depth (default 0.4)
--   drainPerMeter:    additional drain %/sec per meter of search depth (default 0.004)
--   rechargeRate:     charge recovery %/sec when inactive (default 0.25)
function MADDetector:new(groupName, ownerCoalition, submarines, config)
    config = config or {}
    local obj = {
        groupName       = groupName,
        ownerCoalition  = ownerCoalition,
        submarines      = submarines,
        detectionRange  = config.detectionRange or 500,
        maxSearchDepth  = config.maxSearchDepth  or 200,
        maxAltitude     = config.maxAltitude     or 150,
        drainBase       = config.drainBase       or 0.4,
        drainPerMeter   = config.drainPerMeter   or 0.004,
        rechargeRate    = config.rechargeRate    or 0.25,
        searchDepth     = 100,   -- current setting, default 100m
        charge          = 100,   -- 0-100%
        state           = "inactive",
        scanTick        = 0,
        updateScheduleId = nil,
    }
    setmetatable(obj, MADDetector)
    obj:startUpdateLoop()
    return obj
end

-- ===== CONTROLS =====

function MADDetector:activate()
    if self.state == "active" then
        return false, "MAD already active."
    end
    if self.charge <= 0 then
        return false, "MAD charge depleted — wait for recharge."
    end
    self.state = "active"
    return true, string.format("MAD activated. Search depth: %dm | Drain: %.1f%%/s | Fly below %dm AGL.",
        self.searchDepth, self:getDrainRate(), self.maxAltitude)
end

function MADDetector:deactivate()
    if self.state == "inactive" then
        return false, "MAD already inactive."
    end
    self.state = "inactive"
    return true, string.format("MAD deactivated. Charge: %d%% | Recharging at %.2f%%/s.", math.floor(self.charge), self.rechargeRate)
end

function MADDetector:setSearchDepth(depth)
    self.searchDepth = math.min(depth, self.maxSearchDepth)
    return string.format("MAD search depth: %dm | Drain rate: %.1f%%/s", self.searchDepth, self:getDrainRate())
end

-- ===== INTERNALS =====

function MADDetector:getDrainRate()
    return self.drainBase + self.searchDepth * self.drainPerMeter
end

function MADDetector:getStatusText()
    return string.format("MAD: %s | Charge: %d%% | Depth: %dm | Drain: %.1f%%/s | Max alt: %dm AGL",
        string.upper(self.state), math.floor(self.charge), self.searchDepth,
        self:getDrainRate(), self.maxAltitude)
end

function MADDetector:getUnit()
    local dcsGroup = Group.getByName(self.groupName)
    if not dcsGroup or not dcsGroup:isExist() then return nil end
    local units = dcsGroup:getUnits()
    if units and #units > 0 and units[1]:isExist() then return units[1] end
    return nil
end

function MADDetector:startUpdateLoop()
    local function update()
        if self.state == "active" then
            local unit = self:getUnit()

            -- Drain charge
            self.charge = math.max(0, self.charge - self:getDrainRate())

            if self.charge <= 0 then
                self.state = "inactive"
                local dcsGroup = Group.getByName(self.groupName)
                if dcsGroup and dcsGroup:isExist() then
                    trigger.action.outTextForGroup(dcsGroup:getID(),
                        "MAD charge depleted — system offline. Recharging.", 10, false)
                end
            elseif unit then
                -- Scan every 2 seconds
                self.scanTick = self.scanTick + 1
                if self.scanTick >= 2 then
                    self.scanTick = 0
                    self:scan(unit)
                end
            end
        else
            -- Recharge while inactive
            self.charge = math.min(100, self.charge + self.rechargeRate)
        end

        self.updateScheduleId = timer.scheduleFunction(function() update() end, nil, timer.getTime() + 1)
    end

    timer.scheduleFunction(function() update() end, nil, timer.getTime() + 1)
end

function MADDetector:scan(unit)
    local pos = unit:getPoint()
    local altAGL = pos.y - land.getHeight({x = pos.x, y = pos.z})

    -- MAD range degrades with altitude (inverse cube: range ∝ 1/alt^(1/3))
    -- Reference range at 50m AGL; above maxAltitude the signal is too weak.
    if altAGL > self.maxAltitude then return end
    local altFactor = math.max(0.1, (50 / math.max(altAGL, 10)) ^ (1/3))
    local effectiveRange = self.detectionRange * altFactor

    for _, sub in ipairs(self.submarines) do
        -- Only real submarines (VirtualSubmarine has maxDepth; NoiseMakers do not)
        if sub.maxDepth then
            local dx = sub.x - pos.x
            local dz = sub.z - pos.z
            local dist = math.sqrt(dx * dx + dz * dz)

            if dist <= effectiveRange and sub.depth <= self.searchDepth then
                -- Probability drops off linearly with depth toward searchDepth
                local depthFactor = 1 - (sub.depth / (self.searchDepth + 1))
                local distFactor  = 1 - (dist / effectiveRange) * 0.3
                local probability = 0.9 * depthFactor * distFactor

                if math.random() < probability then
                    self:reportContact(sub, dist, altAGL)
                end
            end
        end
    end
end

function MADDetector:reportContact(sub, dist, altAGL)
    -- MAD gives precise horizontal position but cannot determine depth
    local errM = math.max(15, dist * 0.06)
    local contactPoint = {
        x = sub.x + (math.random() - 0.5) * 2 * errM,
        y = 0,
        z = sub.z + (math.random() - 0.5) * 2 * errM,
    }

    local orange     = {1, 0.6, 0, 1}
    local orangeFill = {1, 0.6, 0, 0.2}
    local circleId   = nextMADMarkId()
    local textId     = nextMADMarkId()

    trigger.action.circleToAll(self.ownerCoalition, circleId, contactPoint, 80, orange, orangeFill, 1, true)
    trigger.action.textToAll(self.ownerCoalition, textId,
        {x = contactPoint.x + 100, y = 0, z = contactPoint.z},
        orange, {0, 0, 0, 0}, 10, true,
        "MAD CONTACT | depth unknown | alt " .. math.floor(altAGL) .. "m")

    timer.scheduleFunction(function()
        trigger.action.removeMark(circleId)
        trigger.action.removeMark(textId)
    end, nil, timer.getTime() + 30)

    -- Give submarine side a vague warning (gameplay concession)
    local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
    trigger.action.outTextForCoalition(enemyCoalition, sub.name .. ": magnetic sweep overhead!", 8, false)

    env.info("MAD: contact on " .. (sub.name or "?") .. " dist=" .. math.floor(dist) .. "m depth=" .. math.floor(sub.depth) .. "m", false)

    if ASW_SOUND then
        ASW_SOUND:playForCoalition(self.ownerCoalition, "warning_sonar")
    end
end

function MADDetector:stopUpdateLoop()
    if self.updateScheduleId then
        timer.removeFunction(self.updateScheduleId)
        self.updateScheduleId = nil
    end
end
