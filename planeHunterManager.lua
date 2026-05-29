PlaneHunterManager = setmetatable({}, {__index = OrdnanceManager})
PlaneHunterManager.__index = PlaneHunterManager

-- ASW fixed-wing hunter management.
-- Capabilities: sonarbuoy deployment, torpedo launch, MAD detector.
-- No dipping sonar. No buoy recovery.
-- Higher default altitude and speed limits than helicopters.

function PlaneHunterManager:new(config)
    config.maxAltitude = config.maxAltitude or 200
    config.maxSpeed    = config.maxSpeed    or 120
    local obj = OrdnanceManager.new(self, config)
    obj.madConfig = config.madConfig or {}
    return obj
end

function PlaneHunterManager:initGroup(groupName)
    local unit = self:getGroupUnit(groupName)
    if unit and unit:getDesc().category ~= Unit.Category.AIRPLANE then
        self.trackedGroups[groupName] = true
        self:log("ASW WARNING: Group '" .. groupName .. "' has fixed-wing prefix but is not a plane — skipping.")
        return
    end

    OrdnanceManager.initGroup(self, groupName)

    local data = self.groupData[groupName]
    if not data then return end

    local mooseGroup = GROUP:FindByName(groupName)
    if not mooseGroup then return end

    -- MAD Detector
    data.madDetector = MADDetector:new(groupName, self.ownerCoalition, self.submarines, self.madConfig)

    -- MAD submenu
    local madMenu = MENU_GROUP:New(mooseGroup, "MAD Detector", data.menus.root)
    MENU_GROUP_COMMAND:New(mooseGroup, "Activate MAD",   madMenu, self.activateMAD,   self, groupName)
    MENU_GROUP_COMMAND:New(mooseGroup, "Deactivate MAD", madMenu, self.deactivateMAD, self, groupName)
    local depthMenu = MENU_GROUP:New(mooseGroup, "Set Search Depth", madMenu)
    for _, d in ipairs({50, 100, 150, 200}) do
        MENU_GROUP_COMMAND:New(mooseGroup, d .. "m", depthMenu, self.setMADDepth, self, groupName, d)
    end
    MENU_GROUP_COMMAND:New(mooseGroup, "MAD Status", madMenu, self.showMADStatus, self, groupName)
end

-- ===== MAD ACTIONS =====

function PlaneHunterManager:activateMAD(groupName)
    local data = self.groupData[groupName]
    if not data or not data.madDetector then return end
    local _, msg = data.madDetector:activate()
    self:messageToGroup(groupName, msg, 8)
end

function PlaneHunterManager:deactivateMAD(groupName)
    local data = self.groupData[groupName]
    if not data or not data.madDetector then return end
    local _, msg = data.madDetector:deactivate()
    self:messageToGroup(groupName, msg, 8)
end

function PlaneHunterManager:setMADDepth(groupName, depth)
    local data = self.groupData[groupName]
    if not data or not data.madDetector then return end
    local msg = data.madDetector:setSearchDepth(depth)
    self:messageToGroup(groupName, msg, 5)
end

function PlaneHunterManager:showMADStatus(groupName)
    local data = self.groupData[groupName]
    if not data or not data.madDetector then return end
    local mad = data.madDetector
    local timeRemaining = mad.state == "active"
        and string.format(" | ~%.0fs remaining", mad.charge / mad:getDrainRate())
        or  string.format(" | ~%.0fs to full", (100 - mad.charge) / mad.rechargeRate)
    self:messageToGroup(groupName, mad:getStatusText() .. timeRemaining, 10)
end
