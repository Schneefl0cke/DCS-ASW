AISubmarineCommander = {}
AISubmarineCommander.__index = AISubmarineCommander

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
-- sub: VirtualSubmarine instance to command
-- config table:
--   waypointZones: table of trigger zone names for patrol route
--   patrolSpeed: speed in m/s while patrolling (default 5)
--   patrolDepth: depth in meters while patrolling (default 80)
--   attackRange: range to engage detected ships (default 12000)
--   evasionBuoyRange: distance to buoy that triggers evasion (default 7000)
--   evasionDuration: seconds to evade before resuming (default 180)
--   profile: "aggressive" or "cautious" (default "cautious")
--   targetCoalition: coalition whose ships to attack (default BLUE)
--   buoys: reference to buoys table for awareness
--   torpedoes: reference to ASW torpedoes table for awareness
--   detectableObjects: shared submarines table to insert noise makers into
local function nextAiMarkId()
    if not _aiSubMarkIdCounter then _aiSubMarkIdCounter = 400000 end
    _aiSubMarkIdCounter = _aiSubMarkIdCounter + 1
    return _aiSubMarkIdCounter
end

function AISubmarineCommander:new(sub, config)
    config = config or {}

    local profile = config.profile or "cautious"
    local isAggressive = profile == "aggressive"

    local obj = {
        sub = sub,
        waypointZones = config.waypointZones or {},
        patrolSpeed = config.patrolSpeed or 5,
        patrolDepth = config.patrolDepth or 80,
        attackRange = config.attackRange or (isAggressive and 15000 or 10000),
        evasionBuoyRange = config.evasionBuoyRange or 7000,
        evasionDuration = config.evasionDuration or (isAggressive and 120 or 240),
        profile = profile,
        targetCoalition = config.targetCoalition or coalition.side.BLUE,
        buoys = config.buoys or {},
        torpedoes = config.torpedoes or {},
        detectableObjects = config.detectableObjects or {},
        dippingSonars = config.dippingSonars or {},
        patrolMarks = {},

        -- Profile-specific settings
        attackSpeed = isAggressive and 8 or 4,
        attackTorpedoRange = isAggressive and 8000 or 5000,
        evasionSpeed = isAggressive and 3 or 1,
        silentChance = isAggressive and 0.3 or 0.7,  -- chance of going full stop during evasion

        -- State
        state = "patrol",      -- patrol, attack, evade
        currentWaypoint = nil,
        currentWaypointName = nil,
        waypointOrder = {},
        waypointIndex = 0,
        attackTarget = nil,
        torpedosFiredThisAttack = 0,
        evasionTimer = 0,
        lastUpdateTime = timer.getTime(),
        torpedoIdCounter = 0,
        noiseMakerIdCounter = 0,
        updateScheduleId = nil,
        aiStatusTextId = nil,
        planText = ""
    }
    setmetatable(obj, AISubmarineCommander)

    obj.aiStatusTextId = nextAiMarkId()
    obj:shuffleWaypoints()
    obj:nextWaypoint()
    obj:markPatrolPoints()
    obj:startPatrol()
    obj:startUpdateLoop()

    log("AI Commander (" .. profile .. ") active for " .. sub.name, sub.ownerCoalition)
    return obj
end

-- Shuffle waypoint order randomly
function AISubmarineCommander:shuffleWaypoints()
    self.waypointOrder = {}
    local indices = {}
    for i = 1, #self.waypointZones do
        indices[#indices + 1] = i
    end
    -- Fisher-Yates shuffle
    for i = #indices, 2, -1 do
        local j = math.random(1, i)
        indices[i], indices[j] = indices[j], indices[i]
    end
    self.waypointOrder = indices
    self.waypointIndex = 0
end

-- Advance to the next waypoint
function AISubmarineCommander:nextWaypoint()
    self.waypointIndex = self.waypointIndex + 1
    if self.waypointIndex > #self.waypointOrder then
        self:shuffleWaypoints()
        self.waypointIndex = 1
    end

    local zoneIndex = self.waypointOrder[self.waypointIndex]
    local zoneName = self.waypointZones[zoneIndex]
    local zone = trigger.misc.getZone(zoneName)
    if zone then
        self.currentWaypoint = {x = zone.point.x, z = zone.point.z}
        self.currentWaypointName = zoneName
        debugMessage(self.sub.name .. " AI: heading to waypoint " .. zoneName)
    end
end

function AISubmarineCommander:markPatrolPoints()
    local coalitionId = self.sub.ownerCoalition or -1
    local green = {0, 1, 0, 1}

    for idx, zoneName in ipairs(self.waypointZones) do
        local zone = trigger.misc.getZone(zoneName)
        if zone then
            local point = {x = zone.point.x, y = 0, z = zone.point.z}
            local circleId = nextAiMarkId()
            trigger.action.circleToAll(coalitionId, circleId, point, 150, green, {0, 1, 0, 0.3}, 1, true)

            local textPoint = {x = zone.point.x + 200, y = 0, z = zone.point.z}
            local textId = nextAiMarkId()
            local label = "patrol point " .. zoneName
            trigger.action.textToAll(coalitionId, textId, textPoint, green, {0, 0, 0, 0}, 12, true, label)

            self.patrolMarks[#self.patrolMarks + 1] = {circleId = circleId, textId = textId}
        else
            debugMessage(self.sub.name .. " AI: patrol zone not found: " .. tostring(zoneName))
        end
    end
end

function AISubmarineCommander:updateStatusDisplay()
    if not self.aiStatusTextId then return end

    local coalitionId = self.sub.ownerCoalition or -1
    local textPoint = {x = self.sub.x + 200, y = 0, z = self.sub.z}
    local color = {0, 1, 0, 1}
    local bg = {0, 0, 0, 0.5}
    local status = "AI: " .. string.upper(self.state or "UNKNOWN")
    local plan = self.planText or ""

    if plan ~= "" then
        status = status .. " | " .. plan
    end

    trigger.action.textToAll(coalitionId, self.aiStatusTextId, textPoint, color, bg, 12, true, status)
end

-- Start patrol state
function AISubmarineCommander:startPatrol()
    self.state = "patrol"
    self.torpedosFiredThisAttack = 0
    self.planText = "Heading to " .. tostring(self.currentWaypointName or "next waypoint")
    self.sub:setSpeed(self.patrolSpeed)
    self.sub:setTargetDepth(self.patrolDepth)
    self:steerToWaypoint()
    self:updateStatusDisplay()
end

-- Steer toward current waypoint
function AISubmarineCommander:steerToWaypoint()
    if not self.currentWaypoint then return end
    local dx = self.currentWaypoint.x - self.sub.x
    local dz = self.currentWaypoint.z - self.sub.z
    local heading = math.deg(math.atan2(dz, dx))
    if heading < 0 then heading = heading + 360 end
    self.sub:setCourse(heading)
end

-- Main update loop: runs every 5 seconds
function AISubmarineCommander:startUpdateLoop()
    local function update()
        if not self.sub:isAlive() then return end

        local currentTime = timer.getTime()
        local dt = currentTime - self.lastUpdateTime
        self.lastUpdateTime = currentTime

        -- Always check for ASW torpedo threat (highest priority)
        if self.state ~= "evade" and self:detectASWTorpedo() then
            self:startTorpedoEvasion()
        -- Check for active dipping sonar (high priority)
        elseif self.state == "patrol" and self:detectActiveDippingSonar() then
            self:startDippingSonarEvasion()
        -- Check for buoy proximity
        elseif self.state == "patrol" and self:detectNearbyBuoy() then
            self:startBuoyEvasion()
        end

        -- State machine
        if self.state == "patrol" then
            self:updatePatrol(dt)
        elseif self.state == "attack" then
            self:updateAttack(dt)
        elseif self.state == "evade" then
            self:updateEvade(dt)
        end

        self:updateStatusDisplay()

        self.updateScheduleId = timer.scheduleFunction(function()
            update()
        end, nil, timer.getTime() + 5)
    end

    -- Start after a short delay
    timer.scheduleFunction(function()
        update()
    end, nil, timer.getTime() + 5)
end

-- ===== PATROL STATE =====
function AISubmarineCommander:updatePatrol(dt)
    -- Check if we reached the waypoint (within 1km)
    if self.currentWaypoint then
        local dx = self.currentWaypoint.x - self.sub.x
        local dz = self.currentWaypoint.z - self.sub.z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist < 1000 then
            self:nextWaypoint()
            self:steerToWaypoint()
        end
    end

    -- Check for ship targets via passive sonar
    local target = self:findBestTarget()
    if target then
        self:startAttack(target)
    end
end

-- ===== ATTACK STATE =====
function AISubmarineCommander:startAttack(target)
    self.state = "attack"
    self.attackTarget = target
    self.torpedosFiredThisAttack = 0
    self.planText = "Engage " .. tostring(target.unitName)

    -- Turn toward target
    local dx = target.x - self.sub.x
    local dz = target.z - self.sub.z
    local heading = math.deg(math.atan2(dz, dx))
    if heading < 0 then heading = heading + 360 end
    self.sub:setCourse(heading)
    self.sub:setSpeed(self.attackSpeed)
    self.sub:setTargetDepth(20) -- periscope depth for torpedo launch

    self:updateStatusDisplay()
    log(self.sub.name .. " AI: Target detected! Moving to attack.", self.sub.ownerCoalition)
end

function AISubmarineCommander:updateAttack(dt)
    if not self.attackTarget then
        self:startPatrol()
        return
    end

    -- Re-check target still exists
    local unit = Unit.getByName(self.attackTarget.unitName)
    if not unit or not unit:isExist() then
        log(self.sub.name .. " AI: Target lost. Resuming patrol.", self.sub.ownerCoalition)
        self:abortAttackAndEvade()
        return
    end

    -- Update target position
    local pos = unit:getPoint()
    self.attackTarget.x = pos.x
    self.attackTarget.z = pos.z

    -- Steer toward target
    local dx = pos.x - self.sub.x
    local dz = pos.z - self.sub.z
    local dist = math.sqrt(dx * dx + dz * dz)
    local heading = math.deg(math.atan2(dz, dx))
    if heading < 0 then heading = heading + 360 end
    self.sub:setCourse(heading)

    -- Check if we can fire (at periscope depth and in range)
    if self.sub.depth <= 30 and dist <= self.attackTorpedoRange and self.torpedosFiredThisAttack < 2 then
        if self.sub.torpedoCount > 0 then
            self:fireTorpedo()
            self.torpedosFiredThisAttack = self.torpedosFiredThisAttack + 1

            -- After 2 torpedoes, dive and evade to random waypoint
            if self.torpedosFiredThisAttack >= 2 then
                self:abortAttackAndEvade()
            end
        else
            -- No torpedoes, abort
            log(self.sub.name .. " AI: No torpedoes remaining. Disengaging.", self.sub.ownerCoalition)
            self:abortAttackAndEvade()
        end
    end
end

function AISubmarineCommander:abortAttackAndEvade()
    self.attackTarget = nil
    self.state = "evade"
    self.evasionTimer = 0
    self.planText = "Disengage and dive deep"

    -- Dive deep, random heading toward a patrol point
    self.sub:setTargetDepth(self.sub.maxDepth)
    self.sub:setSpeed(self.evasionSpeed)
    self:nextWaypoint()
    self:steerToWaypoint()
    self:updateStatusDisplay()

    log(self.sub.name .. " AI: Disengaging. Diving deep.", self.sub.ownerCoalition)
end

-- ===== EVASION STATE =====

-- Evade because a buoy was detected nearby
function AISubmarineCommander:startBuoyEvasion()
    self.state = "evade"
    self.evasionTimer = 0
    self.attackTarget = nil
    self.planText = "Evade nearby buoy"

    -- Find the nearest buoy to flee from
    local nearestBuoy = self:findNearestBuoy()

    -- Dive deep, reduce speed
    self.sub:setTargetDepth(self.sub.maxDepth)
    self.sub:setSpeed(self.evasionSpeed)

    -- Head away from buoy in a 180° cone
    if nearestBuoy then
        local dx = self.sub.x - nearestBuoy.x
        local dz = self.sub.z - nearestBuoy.z
        local awayHeading = math.deg(math.atan2(dz, dx))
        if awayHeading < 0 then awayHeading = awayHeading + 360 end
        -- Add random offset ±90°
        local offset = (math.random() * 180) - 90
        local finalHeading = (awayHeading + offset) % 360
        self.sub:setCourse(finalHeading)
    end

    self:updateStatusDisplay()
    log(self.sub.name .. " AI: Buoy detected nearby! Evading.", self.sub.ownerCoalition)
end

-- Evade because an ASW torpedo was detected
function AISubmarineCommander:startTorpedoEvasion()
    self.state = "evade"
    self.evasionTimer = 0
    self.attackTarget = nil
    self.planText = "Evade incoming ASW torpedo"

    -- Deploy noise maker immediately (no delay for torpedo distraction)
    if self.sub.noiseMakerCount > 0 then
        self:deployNoiseMaker(0)
    end

    -- Random depth change: either go deep or go shallow
    if math.random() > 0.5 then
        self.sub:setTargetDepth(self.sub.maxDepth)
    else
        self.sub:setTargetDepth(math.max(0, self.sub.depth - 100))
    end

    -- Go silent or very slow
    if math.random() < self.silentChance then
        self.sub:setSpeed(0)
    else
        self.sub:setSpeed(self.evasionSpeed)
    end

    -- Random heading
    self.sub:setCourse(math.random(0, 359))

    self:updateStatusDisplay()
    log(self.sub.name .. " AI: ASW TORPEDO DETECTED! Emergency evasion!", self.sub.ownerCoalition)
end

function AISubmarineCommander:updateEvade(dt)
    self.evasionTimer = self.evasionTimer + dt

    -- Check for ASW torpedo during evasion (may need to re-deploy noise maker)
    if self:detectASWTorpedo() then
        -- Reset evasion timer, deploy another noise maker if available
        self.evasionTimer = 0
        if self.sub.noiseMakerCount > 0 then
            self:deployNoiseMaker(60)
        end
        -- Change heading again
        self.sub:setCourse(math.random(0, 359))
    end

    if self.evasionTimer >= self.evasionDuration then
        log(self.sub.name .. " AI: Evasion complete. Resuming patrol.", self.sub.ownerCoalition)
        self:nextWaypoint()
        self:startPatrol()
    end
end

-- ===== THREAT DETECTION =====

-- Check if any active buoy is within evasion range
function AISubmarineCommander:detectNearbyBuoy()
    for _, buoy in ipairs(self.buoys) do
        if buoy:isActive() then
            local dx = buoy.x - self.sub.x
            local dz = buoy.z - self.sub.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < self.evasionBuoyRange then
                return true
            end
        end
    end
    return false
end

-- Find nearest buoy for evasion heading
function AISubmarineCommander:findNearestBuoy()
    local nearest = nil
    local nearestDist = math.huge
    for _, buoy in ipairs(self.buoys) do
        if buoy:isActive() then
            local dx = buoy.x - self.sub.x
            local dz = buoy.z - self.sub.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < nearestDist then
                nearestDist = dist
                nearest = buoy
            end
        end
    end
    return nearest
end

-- Check if any active ASW torpedo is within 10km
function AISubmarineCommander:detectASWTorpedo()
    for _, torpedo in ipairs(self.torpedoes) do
        if torpedo:isActive() then
            local dx = torpedo.x - self.sub.x
            local dz = torpedo.z - self.sub.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < 10000 then
                return true
            end
        end
    end
    return false
end

-- Check if any active dipping sonar is within 10km
function AISubmarineCommander:detectActiveDippingSonar()
    for _, sonar in ipairs(self.dippingSonars) do
        if sonar.state == "active" then
            local unit = sonar:getUnit()
            if unit then
                local pos = unit:getPoint()
                local dx = pos.x - self.sub.x
                local dz = pos.z - self.sub.z
                local dist = math.sqrt(dx * dx + dz * dz)
                if dist < 10000 then
                    return true, pos
                end
            end
        end
    end
    return false
end

-- Evade active dipping sonar: dive deep, move away, deploy noise maker
function AISubmarineCommander:startDippingSonarEvasion()
    self.state = "evade"
    self.evasionTimer = 0
    self.attackTarget = nil
    self.planText = "Evade active dipping sonar"

    -- Find nearest active dipping sonar
    local nearestDist = math.huge
    local nearestPos = nil
    for _, sonar in ipairs(self.dippingSonars) do
        if sonar.state == "active" then
            local unit = sonar:getUnit()
            if unit then
                local pos = unit:getPoint()
                local dx = pos.x - self.sub.x
                local dz = pos.z - self.sub.z
                local dist = math.sqrt(dx * dx + dz * dz)
                if dist < nearestDist then
                    nearestDist = dist
                    nearestPos = pos
                end
            end
        end
    end

    -- Dive deep, reduce speed
    self.sub:setTargetDepth(self.sub.maxDepth)
    self.sub:setSpeed(self.evasionSpeed)

    -- Head away from the dipping sonar helicopter
    if nearestPos then
        local dx = self.sub.x - nearestPos.x
        local dz = self.sub.z - nearestPos.z
        local awayHeading = math.deg(math.atan2(dz, dx))
        if awayHeading < 0 then awayHeading = awayHeading + 360 end
        local jitter = math.random(-90, 90)
        self.sub:setCourse((awayHeading + jitter) % 360)
    end

    -- Deploy noise maker with short delay to confuse active sonar
    if self.sub.noiseMakerCount > 0 then
        self:deployNoiseMaker(60) -- 60 second delay
    end

    self:updateStatusDisplay()
    log(self.sub.name .. " AI: Active sonar detected! Evading deep.", self.sub.ownerCoalition)
end

-- ===== TARGET ACQUISITION =====

-- Find best ship target using passive sonar
function AISubmarineCommander:findBestTarget()
    local enemyGroups = coalition.getGroups(self.targetCoalition, Group.Category.SHIP)
    if not enemyGroups then return nil end

    local bestTarget = nil
    local bestDist = self.attackRange + 1

    for _, group in ipairs(enemyGroups) do
        if group and group:isExist() then
            local units = group:getUnits()
            if units then
                for _, unit in ipairs(units) do
                    if unit and unit:isExist() then
                        local pos = unit:getPoint()
                        local dx = pos.x - self.sub.x
                        local dz = pos.z - self.sub.z
                        local dist = math.sqrt(dx * dx + dz * dz)

                        -- Must be within sonar range (considering thermal layer)
                        local effectiveRange = self.sub.sonarRange
                        if self.sub.belowThermalLayer then
                            effectiveRange = effectiveRange * self.sub.sonarThermalPenalty
                        end

                        if dist < effectiveRange and dist < self.attackRange and dist < bestDist then
                            bestDist = dist
                            bestTarget = {
                                x = pos.x,
                                z = pos.z,
                                unitName = unit:getName(),
                                distance = dist
                            }
                        end
                    end
                end
            end
        end
    end

    return bestTarget
end

-- ===== ACTIONS =====

function AISubmarineCommander:fireTorpedo()
    if self.sub.torpedoCount <= 0 then return end
    if self.sub.depth > 30 then return end

    self.sub.torpedoCount = self.sub.torpedoCount - 1
    self.torpedoIdCounter = self.torpedoIdCounter + 1
    local torpedoName = self.sub.name .. "-AI-Torpedo-" .. self.torpedoIdCounter

    local torpedo = SubmarineTorpedo:new(
        torpedoName, self.sub.x, self.sub.z, self.sub.heading,
        self.sub.ownerCoalition, self.targetCoalition, self.buoys
    )

    log(self.sub.name .. " AI: Torpedo fired! Remaining: " .. self.sub.torpedoCount .. "/" .. self.sub.maxTorpedoes, self.sub.ownerCoalition)
end

function AISubmarineCommander:deployNoiseMaker(delay)
    if self.sub.noiseMakerCount <= 0 then return end

    self.sub.noiseMakerCount = self.sub.noiseMakerCount - 1
    self.noiseMakerIdCounter = self.noiseMakerIdCounter + 1
    local decoyName = self.sub.name .. "-AI-Decoy-" .. self.noiseMakerIdCounter

    local decoy = NoiseMaker:new(
        decoyName, self.sub.x, self.sub.z, self.sub.depth, delay,
        self.sub.ownerCoalition, self.sub.thermalLayerDepth
    )

    -- Add to shared detectable objects so buoys will pick it up
    self.detectableObjects[#self.detectableObjects + 1] = decoy

    log(self.sub.name .. " AI: Noise maker deployed! Activates in " .. delay .. "s | Remaining: " .. self.sub.noiseMakerCount .. "/" .. self.sub.maxNoiseMakers, self.sub.ownerCoalition)
end
