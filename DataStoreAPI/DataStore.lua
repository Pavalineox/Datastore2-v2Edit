-- Author: Pavalineox
-- This is my mediocre rewrite of Kampfkarren's Datastore2 module, focused on keeping simplicity while integrating new roblox datastore stuff
local ModuleContainer = require(game:GetService("ReplicatedStorage").ModuleScriptLookup)
local ReplicatedConnectionLookup = require(game:GetService("ReplicatedStorage").ReplicatedConnectionLookup)
local ObjectOrientation = require(ModuleContainer.ObjectOrientation)
local PlayerDataStruct = require(ModuleContainer.PlayerData)
local Promise = require(ModuleContainer.Promise)

local DataStore = {
    Cache = {};
}

function DataStore:InstantiatePlayerData(Key,Player)
    local PlayerData = PlayerDataStruct:new(Key,Player)
    return PlayerData
end

function DataStore:Fetch(Key,Player)
    print("Fetching data for: " .. Key)
    if self.Cache[Player] then
        if self.Cache[Player][Key] then
            return self.Cache[Player][Key]
        end
    end
    --Create and cache a datastore
    local PlayerData = self:InstantiatePlayerData(Key,Player)
    if not self.Cache[Player] then
        self.Cache[Player] = {}
    end
    self.Cache[Player][Key] = PlayerData
    --Attach close events

    local function AttemptCacheRelease()
        if not self.Cache[Player] then return end
        local CacheReleaseAllowed = true
        for Key,PlayerData in pairs(self.Cache[Player]) do
            if PlayerData then
                CacheReleaseAllowed = false
            end
        end
        if CacheReleaseAllowed then
            print("Releasing cache on " .. Player.Name)
            self.Cache[Player] = nil
        end
    end

    local saveFinishedEvent, isSaveFinished = Instance.new("BindableEvent"), false
	local bindToCloseEvent = Instance.new("BindableEvent")

    local bindToCloseCallback = function()
		if not isSaveFinished then
			-- Defer to avoid a race between connecting and firing "saveFinishedEvent"
			task.defer(function()
				bindToCloseEvent:Fire() -- Resolves the Promise.race to save the data
			end)

			saveFinishedEvent.Event:Wait() -- Prevent game shutdown until data is saved
		end
    end

    local success,error = pcall(function()
        game:BindToClose(function()
            if bindToCloseCallback == nil then
                return
            end
    
            bindToCloseCallback()
        end)
    end)
    if not success then warn("BindToClose failed to connect! ", error) end

	Promise.race({
		Promise.fromEvent(bindToCloseEvent.Event),
		Promise.fromEvent(Player.AncestryChanged, function()
			return not Player:IsDescendantOf(game)
		end),
	}):andThen(function()
        PlayerData:SaveAsync():andThen(function()
            print(Player.Name .. ": Saved " .. Key)
        end):catch(function(error)
            warn("Error on data release! ", error)
        end):finally(function()
            isSaveFinished = true
            saveFinishedEvent:Fire()
            PlayerData:Destroy()
            self.Cache[Player][Key] = nil
            bindToCloseCallback = nil
        end)
        return Promise.delay(5):andThen(function()
            AttemptCacheRelease()
        end)
    end)

    return self.Cache[Player][Key]
end

return DataStore