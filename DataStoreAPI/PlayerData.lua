-- Author: Pavalineox
-- This is my mediocre rewrite of Kampfkarren's Datastore2 module
-- I say rewrite but almost all of this is derived from his work just with edits for ds2 and removing some extraneous functions

-- In DS2 this class inherits stuff like saving method, but since i was removing a lot of functions it had a lot less content and i just put everything in one class
-- May not be the best design but IMO it is simple and clear since we only use one saving method anyways

-- This has some hard-baked stuff for convenience, like autosaving, which should really be nested in options

-- BUT This isn't an open-source module so i took some liberties/practicalities

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local DataStoreService = game:GetService("DataStoreService")

local SaveInStudioObject = ServerStorage:FindFirstChild("SaveInStudio")
local SaveInStudio = SaveInStudioObject and SaveInStudioObject.Value

local ModuleContainer = require(game:GetService("ReplicatedStorage").ModuleScriptLookup)
local ReplicatedConnectionLookup = require(game:GetService("ReplicatedStorage").ReplicatedConnectionLookup)
local ObjectOrientation = require(ModuleContainer.ObjectOrientation)
local Promise = require(ModuleContainer.Promise)
local Verifier = require(ModuleContainer.Verifier)

--Build v2 datastore + global settings
local GlobalSettings = {
    backupRetries = 6;
    autosaveInterval = 300;
}
local options = Instance.new("DataStoreOptions")
options:SetExperimentalFeatures({["v2"] = true})

local PlayerData = {
    className = "PlayerData";
    heartbeatConnection = false;
    lastAutosaveTime = false;

    dataStore = false;
    playerName = "N/A";
    UserId = false;

    key = false;
    keyInfo = false;
    keyMetadata = {};
    value = false;
    isBackup = false;

    valueUpdated = false;
    valueRetrieveStatus = false;
    promiseConnections = {};

    debugEnabled = true;
    softDebugEnabled = false;
}
--ObjectOrientation.inheritClass(module,<CLASS TO INHERIT>)

local function tableClone(tbl)
	local clone = {}

	for key, value in pairs(tbl) do
		if typeof(value) == "table" then
			clone[key] = tableClone(value)
		else
			clone[key] = value
		end
	end

	return clone
end

local function clone(value)
	if typeof(value) == "table" then
		return tableClone(value)
	else
		return value
	end
end

function PlayerData:new(Key,Player)
    self = ObjectOrientation.instantiate(self)
    self.key = Key
    self.playerName = Player.Name
    self.UserId = Player.UserId
    self.dataStore = DataStoreService:GetDataStore(Key, nil, options)
    self.heartbeatConnection = game:GetService("RunService").Heartbeat:Connect(function(step) self:OnHeartbeat(step) end)
    return self
end

function PlayerData:OnHeartbeat(step)
    --Check for autosave
    if not self.lastAutosaveTime then self.lastAutosaveTime = os.clock() end
    if (os.clock()-GlobalSettings.autosaveInterval) > self.lastAutosaveTime then
        self:Debug("Autosaving: ", self.playerName)
        self.lastAutosaveTime = os.clock()
        --Autosave by forcing it to think we updated its metadata
        self:OnKeyUpdated(true)
        --very talented programmer
    end
end

function PlayerData:Debug(...)
	if self.debugEnabled then
		print(...)
	end
end

function PlayerData:SoftDebug(...)
	if self.softDebugEnabled then
		print(...)
	end
end

function PlayerData:InternalPrintDSV2()
    self:Debug("Printing DSV2 Key Info...")
    self:Debug(self.keyInfo.UpdatedTime)
    self:Debug(self.keyInfo.Version)
end

function PlayerData:DSV2GetAsync()
	return Promise.defer(function(resolve)
		resolve(self.dataStore:GetAsync(self.UserId))
	end)
end

function PlayerData:DSV2SetAsync(value)
	return Promise.defer(function(resolve)
        --build setoptions from stored metadata
        local setOptions = Instance.new("DataStoreSetOptions")
        setOptions:SetMetadata(self.keyMetadata)
        self.dataStore:SetAsync(self.UserId, value, {self.UserId}, setOptions)

		resolve()
	end)
end

function PlayerData:GetDatastoreAsync()
    if self.promiseConnections.getDatastorePromise then
        warn("GetDatastoreAsync returning existing promise!")
        return self.promiseConnections.getDatastorePromise
    end

	self.promiseConnections.getDatastorePromise = self:DSV2GetAsync():andThen(function(value, keyInfo)
        if value then
            self.value = value
            if keyInfo then
                self.keyInfo = keyInfo
                self.keyMetadata = keyInfo:GetMetadata()
                if not self.keyMetadata then self.keyMetadata = {} end
                self:Debug("Version: ", tostring(keyInfo.Version))
                self:Debug(keyInfo:GetMetadata())
            end
        end
		self.valueRetrieveStatus = true
	end):finally(function()
        self.promiseConnections.getDatastorePromise = nil
    end)

	return self.promiseConnections.getDatastorePromise
end

function PlayerData:GetKeyInfoAsync()
    --this is grug
	if self.promiseConnections.getKeyInfoPromise then
        warn("KeyInfo returning existing promise!")
		return self.promiseConnections.getKeyInfoPromise
	end

	self.promiseConnections.getKeyInfoPromise = self:DSV2GetAsync():andThen(function(value, keyInfo)
        if keyInfo then
            self.keyInfo = keyInfo
            self.keyMetadata = keyInfo:GetMetadata()
            if not self.keyMetadata then self.keyMetadata = {} end
        end
    end):finally(function()
        self.promiseConnections.getKeyInfoPromise = nil
	end)

	return self.promiseConnections.getKeyInfoPromise
end

function PlayerData:Get(defaultValue, dontAttemptGet)
    if (not defaultValue) then error("PlayerData Error: Default Value may not be false or nil") end
	if dontAttemptGet then
		return self.value
	end

	local backupCount = 0
	if not self.valueRetrieveStatus then
		while not self.valueRetrieveStatus do
			local success, error = self:GetDatastoreAsync():await()
			if not success then
                self:Debug("No Success: ", tostring(error))
				if GlobalSettings.backupRetries then
					backupCount = backupCount + 1
                    self:Debug("Get request failed, backup count: ", backupCount)
					if backupCount >= GlobalSettings.backupRetries then
						self.isBackup = true
						self.valueRetrieveStatus = true
						self.value = self.backupValue
						break
					end
				end
			end
            self:SoftDebug("Get had success, backup count: ", backupCount)
		end
	end

	local value
	if (self.value == false) and (defaultValue) then
		value = defaultValue
	else
		value = self.value
	end

	value = clone(value)

	self.value = value
	return value
end

function PlayerData:InternalSave()
    self:SaveAsync():andThen(function()
        print(self.playerName .. ": Internal Saved " .. self.key)
    end):catch(function(error)
        warn("Internal Error on save! " .. error)
    end):finally(function()
        --Attempt to fetch new key info inst for convenience
        local success, error = self:GetKeyInfoAsync():await()
        if not success then
            self:Debug("InternalSave error upon get request: ", tostring(error))
        else 
            self:SoftDebug("InternalSave Success: ", self.playerName)
        end
    end)
end

function PlayerData:OnKeyUpdated(saveOnUpdate)
    self.valueUpdated = true
    if saveOnUpdate then
        --This could be much more elegant, but for now we're just going to avoid any additional thread yield
        Promise.try(function()
            self:InternalSave()
        end):catch(function(error)
            self:Debug("OnKeyUpdated save failed : ", tostring(error))
        end)
    end
end

function PlayerData:Set(value)
    self.value = clone(value)
    self:OnKeyUpdated()
end

function PlayerData:SaveAsync()
    return Promise.defer(function(resolve, reject)
		if not self.valueUpdated then
			warn(("Data store %s was not saved as it was not updated."):format(self.key))
			resolve(false)
			return
		end

        if RunService:IsStudio() and not SaveInStudio then
			warn(("Data store %s attempted to save in studio while SaveInStudio is false."):format(self.key))
			if not SaveInStudioObject then
				warn("You can set the value of this by creating a BoolValue named SaveInStudio in ServerStorage.")
			end
			resolve(false)
			return
		end

		if self.isBackup then
            warn(("Data store %s is a backup store, and thus will not be saved."):format(self.key))
			resolve(false)
			return
		end

        if self.value ~= false then
			local save = clone(self.value)

			local problem = Verifier.testValidity(save)
			if problem then
				reject(problem)
				return
			end

			return self:DSV2SetAsync(save):andThen(function()
				resolve(true, save)
			end)
		end
    end):andThen(function(saved, save)
		if saved then
            --after save
			self.valueUpdated = false
		end
	end)
end

function PlayerData:SetMetadata(newDict,overwriteMetadata)
    --TODO: This really needs to be a promise lol
    if overwriteMetadata then
        warn("Overwriting metadata for " .. self.key .. " (dangerous)")
        self.keyMetadata = newDict
        if not self.keyMetadata then warn("Unacceptable input into set metadata. you should feel ashamed.") self.keyMetadata = {} end
    else
        local mergedDict = self.keyMetadata
        for key,metadata in pairs(newDict) do
            mergedDict[key] = metadata
        end
        self.keyMetadata = mergedDict
    end
    --metadata needs to be consistent in the datastore because we store keyinfo
    self:OnKeyUpdated(true)
end

function PlayerData:GetMetadata(index)
    if index then
        return self.keyMetadata[index]
    end
    return self.keyMetadata
end

function PlayerData:ClearConnections()
    self.promiseConnections = {}
    self.heartbeatConnection:Disconnect()
    self.heartbeatConnection = false;
end

function PlayerData:Destroy()
    --Note that this does NOT save the playerdata
    self:ClearConnections()
    self.dataStore = false
    self.keyInfo = false
    self = ObjectOrientation.primeForGarbageCollection(self)
end

PlayerData = ObjectOrientation.solidifyClass(PlayerData)
return PlayerData