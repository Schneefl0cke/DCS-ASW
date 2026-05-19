VirtualSubmarine = {}
VirtualSubmarine.__index = VirtualSubmarine

local function log(message, logCoalition, duration)
    duration = duration or 10
    trigger.action.outTextForCoalition(logCoalition, message, duration, false)
    env.info(message, false)
end

local debug = trigger.misc.getUserFlag("Debug")

local function debugMessage(message, duration)
    if debug == 1 then
        duration = duration or 10
        trigger.action.outText(message, duration, false)
        env.info(message, false) -- Removed the extra 'false' argument
    end
end

-- Base Constructor (Internal use)
-- noiseFactor: Acoustic signature multiplier (default 1.0)
--   < 1.0 = quieter (e.g. 0.5 small diesel, 0.8 modern SSN)
--   1.0   = standard submarine
--   > 1.0 = louder  (e.g. 1.4 large SSBN, 1.8 old noisy sub)
-- maxSpeed: Maximum speed in m/s (default 15)
-- maxDepth: Maximum operating depth in meters (default 300)
-- ownerCoalition: coalition.side.RED or coalition.side.BLUE (default RED)
-- thermalLayerDepth: Depth of the thermal layer in meters (default 90)
function VirtualSubmarine:new(name, x, z, depth, speed, heading, noiseFactor, maxSpeed, maxDepth, ownerCoalition, thermalLayerDepth)
    local obj = {
        name = name,
        x = x or 0,
        z = z or 0,
        depth = depth or 0,
        targetDepth = depth or 0,
        depthRate = 2,
        speed = speed or 0, 
        heading = heading or 0,
        noiseFactor = noiseFactor or 1.0,
        maxSpeed = maxSpeed or 15,
        maxDepth = maxDepth or 300,
        ownerCoalition = ownerCoalition or coalition.side.RED,
        thermalLayerDepth = thermalLayerDepth or 90,
        belowThermalLayer = false,
        alive = true,
        lastUpdateTime = timer.getTime(),
        lastMarkerTime = 0,
        marker = nil,
        maxTorpedoes = 6,
        torpedoCount = 6,
        maxNoiseMakers = 4,
        noiseMakerCount = 4,
        sonarRange = 15000,          -- passive sonar range in meters (default diesel)
        sonarThermalPenalty = 0.3,    -- detection multiplier when below thermal layer (diesel)
        contactMarkers = {},          -- per-unit markers for detected ships
        lastSonarScanTime = 0
    }
    setmetatable(obj, VirtualSubmarine)
    return obj
end

-- NEW Constructor: Pulls coordinates from a DCS Trigger Zone
-- zoneName: The string name of your circular trigger zone in the Mission Editor
-- randomize: If true, picks a random point inside the circular zone. If false, uses the exact center.
function VirtualSubmarine:newFromZone(name, zoneName, depth, speed, heading, noiseFactor, maxSpeed, maxDepth, ownerCoalition, thermalLayerDepth, randomize)
    local zone = trigger.misc.getZone(zoneName)
    
    if not zone then
        trigger.action.outText("VIRTUAL SUBMARINE ERROR: Trigger zone '" .. zoneName .. "' could not be found!", 10)
        env.info("VIRTUAL SUBMARINE ERROR: Trigger zone '" .. zoneName .. "' could not be found!", false)
        return nil
    end

    local spawnX = zone.point.x
    local spawnZ = zone.point.z

    -- If you want the sub to start anywhere inside the circle uniformly
    if randomize then
        local angle = math.random() * 2 * math.pi
        local radius = math.sqrt(math.random()) * zone.radius
        spawnX = spawnX + (radius * math.cos(angle))
        spawnZ = spawnZ + (radius * math.sin(angle))
    end

    return VirtualSubmarine:new(name, spawnX, spawnZ, depth, speed, heading, noiseFactor, maxSpeed, maxDepth, ownerCoalition, thermalLayerDepth)
end

-- Diesel-Electric Submarine Constructor
-- Quiet at low speeds, limited top speed and depth
-- noiseFactor=0.5, maxSpeed=10 m/s (~20 kts), maxDepth=250m
function VirtualSubmarine:newDiesel(name, x, z, depth, speed, heading, ownerCoalition, thermalLayerDepth)
    return VirtualSubmarine:new(name, x, z, depth, speed, heading, 0.5, 10, 250, ownerCoalition, thermalLayerDepth)
end

function VirtualSubmarine:newDieselFromZone(name, zoneName, depth, speed, heading, ownerCoalition, thermalLayerDepth, randomize)
    return VirtualSubmarine:newFromZone(name, zoneName, depth, speed, heading, 0.5, 10, 250, ownerCoalition, thermalLayerDepth, randomize)
end

-- Modern Nuclear Attack Submarine (SSN) Constructor
-- Quieter than old subs but faster and deeper-diving
-- noiseFactor=0.8, maxSpeed=18 m/s (~35 kts), maxDepth=500m
function VirtualSubmarine:newSSN(name, x, z, depth, speed, heading, ownerCoalition, thermalLayerDepth)
    local sub = VirtualSubmarine:new(name, x, z, depth, speed, heading, 0.8, 18, 500, ownerCoalition, thermalLayerDepth)
    sub.maxTorpedoes = 10
    sub.torpedoCount = 10
    sub.maxNoiseMakers = 6
    sub.noiseMakerCount = 6
    sub.sonarRange = 20000
    sub.sonarThermalPenalty = 0.5
    return sub
end

function VirtualSubmarine:newSSNFromZone(name, zoneName, depth, speed, heading, ownerCoalition, thermalLayerDepth, randomize)
    local sub = VirtualSubmarine:newFromZone(name, zoneName, depth, speed, heading, 0.8, 18, 500, ownerCoalition, thermalLayerDepth, randomize)
    sub.maxTorpedoes = 10
    sub.torpedoCount = 10
    sub.maxNoiseMakers = 6
    sub.noiseMakerCount = 6
    sub.sonarRange = 20000
    sub.sonarThermalPenalty = 0.5
    return sub
end

function VirtualSubmarine:update()
    if not self.alive then return end

    local currentTime = timer.getTime()
    local dt = currentTime - self.lastUpdateTime
    self.lastUpdateTime = currentTime

    if dt <= 0 then return end

    local headingRad = math.rad(self.heading)
    local distance = self.speed * dt

    -- DCS coordinate mapping: Cosine for North (X), Sine for East (Z)
    local dx = distance * math.cos(headingRad)
    local dz = distance * math.sin(headingRad)

    self.x = self.x + dx
    self.z = self.z + dz

    -- Gradually change depth toward targetDepth
    local depthDiff = self.targetDepth - self.depth
    if math.abs(depthDiff) > 0.01 then
        local maxChange = self.depthRate * dt
        if math.abs(depthDiff) <= maxChange then
            self.depth = self.targetDepth
            log(self.name .. " reached target depth: " .. self.targetDepth .. "m", self.ownerCoalition)
        elseif depthDiff > 0 then
            self.depth = self.depth + maxChange
        else
            self.depth = self.depth - maxChange
        end
    end

    -- Check thermal layer crossing
    local isBelowNow = self.depth > self.thermalLayerDepth
    if isBelowNow and not self.belowThermalLayer then
        log(self.name .. " has descended below the thermal layer (" .. self.thermalLayerDepth .. "m)", self.ownerCoalition)
        self.belowThermalLayer = true
    elseif not isBelowNow and self.belowThermalLayer then
        log(self.name .. " has ascended above the thermal layer (" .. self.thermalLayerDepth .. "m)", self.ownerCoalition)
        self.belowThermalLayer = false
    end

    debugMessage("VirtualSubmarine " .. self.name .. " pos: X=" .. string.format("%.1f", self.x) .. " Z=" .. string.format("%.1f", self.z) .. " depth=" .. string.format("%.1f", self.depth) .. "m heading=" .. self.heading .. "° speed=" .. self.speed .. " m/s", dt)

    self:markOwnPosition()

    -- Passive sonar scan every 30 seconds
    if currentTime - self.lastSonarScanTime >= 30 then
        self.lastSonarScanTime = currentTime
        self:passiveSonarScan()
    end
end

function VirtualSubmarine:markOwnPosition()
    if not self.alive then return end

    local currentTime = timer.getTime()
    if currentTime - self.lastMarkerTime < 5 then return end
    self.lastMarkerTime = currentTime

    local coord = COORDINATE:New(self.x, 0, self.z)
    local layerStatus = self.belowThermalLayer and "BELOW layer" or "ABOVE layer"
    local text = self.name .. " | Depth: " .. string.format("%.1f", self.depth) .. "m (" .. layerStatus .. ") | Hdg: " .. self.heading .. "° | Spd: " .. self.speed .. " m/s"

    if self.marker then
        self.marker:UpdateCoordinate(coord)
        self.marker:UpdateText(text)
    else
        self.marker = MARKER:New(coord, text):ReadOnly():ToCoalition(self.ownerCoalition)
    end
end

function VirtualSubmarine:setCourse(heading)
    if heading then
        self.heading = heading
        log(self.name .. " new heading: " .. heading .. "°", self.ownerCoalition)
    end
end

function VirtualSubmarine:setSpeed(speed)
    if speed then
        self.speed = math.min(speed, self.maxSpeed)
        log(self.name .. " new speed: " .. self.speed .. " m/s", self.ownerCoalition)
        if speed > self.maxSpeed then
            log(self.name .. " speed clamped to maximum: " .. self.maxSpeed .. " m/s", self.ownerCoalition)
        end
    end
end

function VirtualSubmarine:setTargetDepth(targetDepth)
    if targetDepth then
        self.targetDepth = math.max(0, math.min(targetDepth, self.maxDepth))
        log(self.name .. " new target depth: " .. self.targetDepth .. "m", self.ownerCoalition)
        if targetDepth > self.maxDepth then
            log(self.name .. " depth clamped to maximum: " .. self.maxDepth .. "m", self.ownerCoalition)
        elseif targetDepth < 0 then
            log(self.name .. " depth clamped to minimum: 0m (surface)", self.ownerCoalition)
        end
    end
end

function VirtualSubmarine:destroy()
    if not self.alive then return end
    self.alive = false
    self.speed = 0
    if self.marker then
        self.marker:Remove()
        self.marker = nil
    end
    self:clearContactMarkers()
    log(self.name .. " has been sunk!", self.ownerCoalition)
    debugMessage(self.name .. " has been sunk at X=" .. string.format("%.1f", self.x) .. " Z=" .. string.format("%.1f", self.z) .. " depth=" .. string.format("%.1f", self.depth) .. "m")
    self:markSunkPosition()
end

function VirtualSubmarine:isAlive()
    return self.alive
end

function VirtualSubmarine:markSunkPosition()
    local coord = COORDINATE:New(self.x, 0, self.z)
    local text = self.name .. " SUNK | Depth: " .. string.format("%.1f", self.depth) .. "m"
    MARKER:New(coord, text):ReadOnly():ToCoalition(self.ownerCoalition)
end

function VirtualSubmarine:getTelemetry()
    return {
        name = self.name,
        x = self.x,
        z = self.z,
        depth = self.depth,
        speed = self.speed,
        heading = self.heading
    }
end

-- ===== PASSIVE SONAR =====

-- Determine the enemy coalition
function VirtualSubmarine:getEnemyCoalition()
    if self.ownerCoalition == coalition.side.RED then
        return coalition.side.BLUE
    else
        return coalition.side.RED
    end
end

-- Scan for enemy surface ships and update contact markers
function VirtualSubmarine:passiveSonarScan()
    if not self.alive then return end

    local enemyCoalition = self:getEnemyCoalition()
    local groups = coalition.getGroups(enemyCoalition, Group.Category.SHIP)
    if not groups then return end

    local detectedUnits = {}

    for _, group in ipairs(groups) do
        if group and group:isExist() then
            local units = group:getUnits()
            if units then
                for _, unit in ipairs(units) do
                    if unit and unit:isExist() then
                        local contact = self:tryDetectShip(unit)
                        if contact then
                            detectedUnits[contact.unitName] = true
                            self:updateContactMarker(contact)
                        end
                    end
                end
            end
        end
    end

    -- Remove markers for ships no longer detected
    for unitName, marker in pairs(self.contactMarkers) do
        if not detectedUnits[unitName] then
            marker:Remove()
            self.contactMarkers[unitName] = nil
        end
    end
end

-- Attempt passive sonar detection of a single ship
function VirtualSubmarine:tryDetectShip(unit)
    local pos = unit:getPoint()
    local dx = pos.x - self.x
    local dz = pos.z - self.z
    local distance = math.sqrt(dx * dx + dz * dz)

    -- Effective range considers thermal layer
    local effectiveRange = self.sonarRange
    if self.belowThermalLayer then
        effectiveRange = effectiveRange * self.sonarThermalPenalty
    end

    if distance > effectiveRange then return nil end

    -- Probability: high at close range, drops with distance
    local distanceFactor = 1 - (distance / effectiveRange)
    local probability = 0.9 * distanceFactor
    probability = math.min(0.95, math.max(0, probability))

    debugMessage(self.name .. " sonar -> " .. unit:getName() .. " dist=" .. string.format("%.0f", distance) .. "m prob=" .. string.format("%.2f", probability))

    if math.random() > probability then return nil end

    -- Estimate position with uncertainty (worse at longer range)
    local confidence = distanceFactor
    local bearingTrue = math.atan2(dz, dx)

    local bearingErrorMax = math.rad(20) * (1 - confidence)
    local bearingError = (math.random() * 2 - 1) * bearingErrorMax
    local estimatedBearing = bearingTrue + bearingError

    local rangeErrorMax = distance * 0.20 * (1 - confidence)
    local rangeError = (math.random() * 2 - 1) * rangeErrorMax
    local estimatedRange = math.max(0, distance + rangeError)

    local estimatedX = self.x + estimatedRange * math.cos(estimatedBearing)
    local estimatedZ = self.z + estimatedRange * math.sin(estimatedBearing)

    -- Estimate contact heading from velocity
    local vel = unit:getVelocity()
    local contactHeading = math.deg(math.atan2(vel.z, vel.x))
    if contactHeading < 0 then contactHeading = contactHeading + 360 end

    return {
        x = estimatedX,
        z = estimatedZ,
        unitName = unit:getName(),
        heading = contactHeading,
        confidence = confidence
    }
end

-- Create or update a contact marker for a detected ship
function VirtualSubmarine:updateContactMarker(contact)
    local coord = COORDINATE:New(contact.x, 0, contact.z)
    local text = string.format("%s | CONTACT: %s | Hdg: %.0f\194\176 | Confidence: %.0f%%",
        self.name, contact.unitName, contact.heading, contact.confidence * 100)

    local existing = self.contactMarkers[contact.unitName]
    if existing then
        existing:UpdateCoordinate(coord)
        existing:UpdateText(text)
    else
        self.contactMarkers[contact.unitName] = MARKER:New(coord, text):ReadOnly():ToCoalition(self.ownerCoalition)
    end
end

-- Remove all contact markers (called on destroy)
function VirtualSubmarine:clearContactMarkers()
    for unitName, marker in pairs(self.contactMarkers) do
        marker:Remove()
        self.contactMarkers[unitName] = nil
    end
end