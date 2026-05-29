HelicopterHunterManager = setmetatable({}, {__index = OrdnanceManager})
HelicopterHunterManager.__index = HelicopterHunterManager

-- Extends OrdnanceManager with helicopter-specific capabilities:
-- dipping sonar and buoy recovery. Uses the same low altitude/speed
-- limits as the base class defaults (50m AGL, 60 m/s).

function HelicopterHunterManager:initGroup(groupName)
    local unit = self:getGroupUnit(groupName)
    if unit and unit:getDesc().category ~= Unit.Category.HELICOPTER then
        self.trackedGroups[groupName] = true
        self:log("ASW WARNING: Group '" .. groupName .. "' has helicopter prefix but is not a helicopter — skipping.")
        return
    end

    OrdnanceManager.initGroup(self, groupName)

    local data = self.groupData[groupName]
    if not data then return end

    local mooseGroup = GROUP:FindByName(groupName)
    if not mooseGroup then return end

    -- Dipping sonar instance for this group
    data.dippingSonar = DippingSonar:new(groupName, self.ownerCoalition, self.thermalLayerDepth, self.submarines)
    self.dippingSonars[#self.dippingSonars + 1] = data.dippingSonar

    -- Add buoy recovery commands to the existing buoy menu
    MENU_GROUP_COMMAND:New(mooseGroup, "Prepare to Recover Buoy", data.menus.buoy, self.prepareToRecover, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Recover Buoy!", data.menus.buoy, self.recoverBuoy, self, groupName)

    -- Dipping sonar submenu
    local sonarMenu = MENU_GROUP:New(mooseGroup, "Dipping Sonar", data.menus.root)
    local extendMenu = MENU_GROUP:New(mooseGroup, "Extend Cable", sonarMenu)
    for _, d in ipairs({10, 25, 50, 100}) do
        MENU_GROUP_COMMAND:New(mooseGroup, "+" .. d .. "m", extendMenu, self.adjustSonarCable, self, groupName, d)
    end
    local retractMenu = MENU_GROUP:New(mooseGroup, "Retract Cable", sonarMenu)
    for _, d in ipairs({10, 25, 50, 100}) do
        MENU_GROUP_COMMAND:New(mooseGroup, "-" .. d .. "m", retractMenu, self.adjustSonarCable, self, groupName, -d)
    end
    MENU_GROUP_COMMAND:New(mooseGroup, "Lower Sonar", sonarMenu, self.lowerSonar, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Stop Sonar", sonarMenu, self.stopSonar, self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Raise Sonar", sonarMenu, self.raiseSonar, self, groupName)
end

-- ===== BUOY RECOVERY =====

function HelicopterHunterManager:prepareToRecover(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    if data.state ~= "idle" then
        self:messageToGroup(groupName, "Cancel current operation first!", 5)
        return
    end

    data.state = "preparing_recover"
    local maxSpeedKt = self.maxSpeed * 1.943844
    self:messageToGroup(groupName, "Preparing to recover buoy. Fly near a deployed buoy.\nAlt < " .. self.maxAltitude .. "m AGL | Speed < " .. string.format("%.0f", maxSpeedKt) .. " kt | Range < " .. self.recoveryRange .. "m", 5)
    self:startPrepareMessages(groupName)
end

function HelicopterHunterManager:recoverBuoy(groupName)
    local data = self.groupData[groupName]
    if not data then return end

    if data.state ~= "preparing_recover" then
        self:messageToGroup(groupName, "Use 'Prepare to Recover' first!", 5)
        return
    end

    local unit = self:getGroupUnit(groupName)
    local paramsOk, msg = self:checkFlightParams(unit)

    if not paramsOk then
        self:messageToGroup(groupName, "Cannot recover! " .. msg, 5)
        return
    end

    local pos = unit:getPoint()
    local nearestBuoy = nil
    local nearestDist = self.recoveryRange + 1

    for _, buoy in ipairs(self.buoys) do
        if buoy:isActive() then
            local dx = buoy.x - pos.x
            local dz = buoy.z - pos.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < nearestDist then
                nearestDist = dist
                nearestBuoy = buoy
            end
        end
    end

    if not nearestBuoy then
        self:messageToGroup(groupName, "No buoy within " .. self.recoveryRange .. "m range!", 5)
        return
    end

    nearestBuoy:remove()
    data.inventory = math.min(data.inventory + 1, self.maxBuoys)
    self:messageToGroup(groupName, nearestBuoy.name .. " recovered! Inventory: " .. data.inventory .. "/" .. self.maxBuoys, 5)

    if ASW_SOUND then
        local enemyCoalition = self.ownerCoalition == coalition.side.BLUE and coalition.side.RED or coalition.side.BLUE
        ASW_SOUND:playOnce(groupName, "recover_splash")
        ASW_SOUND:playForCoalition(self.ownerCoalition, "recover_splash")
        ASW_SOUND:playForCoalition(enemyCoalition, "recover_splash")
    end

    self:stopPrepareMessages(groupName)
    data.state = "idle"
end

-- ===== DIPPING SONAR =====

function HelicopterHunterManager:adjustSonarCable(groupName, delta)
    local data = self.groupData[groupName]
    if not data or not data.dippingSonar then return end
    local sonar = data.dippingSonar
    sonar:adjustCable(delta)
    local msg
    if sonar:isDeployed() then
        msg = string.format("Cable target: %dm (current: %.0fm) | Sonar depth: %.0fm",
            sonar.targetCableLength, sonar.currentCableLength, sonar:getWaterDepth())
    else
        msg = string.format("Cable target set to %dm (deploy with Lower Sonar)", sonar.targetCableLength)
    end
    self:messageToGroup(groupName, msg, 5)
end

function HelicopterHunterManager:lowerSonar(groupName)
    local data = self.groupData[groupName]
    if not data or not data.dippingSonar then return end
    local _, msg = data.dippingSonar:lower()
    self:messageToGroup(groupName, msg, 5)
end

function HelicopterHunterManager:stopSonar(groupName)
    local data = self.groupData[groupName]
    if not data or not data.dippingSonar then return end
    local _, msg = data.dippingSonar:stop()
    self:messageToGroup(groupName, msg, 5)
end

function HelicopterHunterManager:raiseSonar(groupName)
    local data = self.groupData[groupName]
    if not data or not data.dippingSonar then return end
    local _, msg = data.dippingSonar:raise()
    self:messageToGroup(groupName, msg, 5)
end
