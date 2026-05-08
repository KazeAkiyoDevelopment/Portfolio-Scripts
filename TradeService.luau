local tradeService = {}

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")

-- OOP Class
local TradeClass = require(script.TradeClass)

local TradingRemotes = ReplicatedStorage.Shared.Remotes.TradingRemotes

-- CONFIG
local TRADE_REQUEST_TIMEOUT = 30
local MAX_TRADING_SLOTS = 9

local PendingTradeRequests = {} -- [playerName] = {[tradeID] = true}
local ActiveTradesByPlayer = {} -- [playerName] = tradeID
local Trades = {}               -- [tradeID] = TradeClass

function tradeService:_getTrade(tradeID: string) -- Find a trade based on a GUID
	return Trades[tradeID]
end

function tradeService:_snapshotInventory(petsFolder: Folder) -- Snapshot the players' inventory at the start of the trade (We will use this to "fact check" it later)
	local snapshot = {}
	for _, pet in ipairs(petsFolder:GetChildren()) do
		snapshot[pet:GetAttribute("ID")] = pet.Name
	end
	return snapshot
end

function tradeService:_cleanUp(tradeID: string) -- Clean up the trade
	local trade = Trades[tradeID]
	if not trade then return end

	ActiveTradesByPlayer[trade.Initiator] = nil
	ActiveTradesByPlayer[trade.Receiver]  = nil

	Trades[tradeID] = nil
end

function tradeService:_forceEnd(tradeID: string, ...) -- Force end the trade
	local trade = Trades[tradeID]
	if not trade then return end

	trade:ForceEnd(...)
	self:_cleanUp(tradeID)
end

function tradeService:_finalize(tradeID: string) -- Finalize the trade
	local trade = Trades[tradeID]
	if not trade then return end

	trade:Finalize(function(id, msg)
		self:_forceEnd(id, msg)
	end)

	self:_cleanUp(tradeID)
end

function tradeService:_removePendingRequest(playerName: string, tradeID: string) -- Clear the pending trade request
	local set = PendingTradeRequests[playerName]
	if set then set[tradeID] = nil end
end

function tradeService:_clearPendingForTrade(trade, tradeID: string) -- Clear all pending requests for BOTH players
	self:_removePendingRequest(trade.Initiator, tradeID)
	self:_removePendingRequest(trade.Receiver,  tradeID)
end

function tradeService:_pendingRequestExists(initiatorName: string, receiverName: string) -- Checks if the player has a pending trade request
	local set = PendingTradeRequests[initiatorName]
	if not set then return false end

	for tradeID in pairs(set) do
		local trade = Trades[tradeID]
		if trade and trade.Receiver == receiverName then return true end
	end

	return false
end

function tradeService:_onTradeRequest(player: Player, receiverName: string)
	if typeof(receiverName) ~= "string" then return end

	local playerName = player.Name

	if ActiveTradesByPlayer[playerName] then -- A guard to prevent getting new trade requests while in an active trade
		TradingRemotes.UpdateTradeGUI:FireClient(player, {
			UpdateType = "TradeError",
			Message    = "You are already in an active trade!",
		})
		return
	end

	if ActiveTradesByPlayer[receiverName] then -- Notify the "Sender" that the player they want to trade is in an active trade
		TradingRemotes.UpdateTradeGUI:FireClient(player, {
			UpdateType = "TradeError",
			Message    = receiverName .. " is already in an active trade!",
		})
		return
	end

	if self:_pendingRequestExists(playerName, receiverName) then -- Prevent spam trading the same player
		TradingRemotes.UpdateTradeGUI:FireClient(player, {
			UpdateType = "TradeError",
			Message    = "You already have a pending request with " .. receiverName .. "!",
		})
		return
	end

	local receiver = Players:FindFirstChild(receiverName)
	if not receiver or receiver == player then return end

	-- Set up the trade
	local tradeID = HttpService:GenerateGUID(false)
	local trade = TradeClass.new(tradeID, playerName, receiverName)
	Trades[tradeID] = trade

	PendingTradeRequests[playerName]   = PendingTradeRequests[playerName]   or {}
	PendingTradeRequests[receiverName] = PendingTradeRequests[receiverName] or {}

	PendingTradeRequests[playerName][tradeID]   = true
	PendingTradeRequests[receiverName][tradeID] = true

	TradingRemotes.TradeRequestReceived:FireClient(receiver, playerName, tradeID)

	task.delay(TRADE_REQUEST_TIMEOUT, function() -- Add a timeout for trade requests
		local trade = Trades[tradeID]
		if not trade or trade.Status ~= "Pending" then return end

		self:_clearPendingForTrade(trade, tradeID)
		Trades[tradeID] = nil

		local initiator = Players:FindFirstChild(playerName)
		if initiator then
			TradingRemotes.UpdateTradeGUI:FireClient(initiator, {
				UpdateType = "TradeError",
				Message    = "Your trade request to " .. receiverName .. " timed out",
			})
		end

		local recv = Players:FindFirstChild(receiverName)
		if recv then
			TradingRemotes.EndTrade:FireClient(recv, "Trade request from " .. playerName .. " expired")
		end
	end)
end

function tradeService:_onTradeRequestResponse(player: Player, accepted: boolean, tradeID: string)
	if typeof(tradeID) ~= "string" then return end

	local trade = self:_getTrade(tradeID)

	if not trade then
		TradingRemotes.UpdateTradeGUI:FireClient(player, {
			UpdateType = "TradeError",
			Message    = "This trade request is no longer valid",
		})
		return
	end

	if trade.Receiver ~= player.Name then return end

	self:_clearPendingForTrade(trade, tradeID)

	if not accepted then -- If the "Receiver" declinded the trade request
		Trades[tradeID] = nil

		local initiator = Players:FindFirstChild(trade.Initiator)
		if initiator then
			TradingRemotes.UpdateTradeGUI:FireClient(initiator, {
				UpdateType = "TradeError",
				Message    = trade.Receiver .. " declined your trade request!",
			})
		end
		return
	end

	local initiator = Players:FindFirstChild(trade.Initiator)
	if not initiator then -- Guard in case the "Sender" left the game by the time the "Receiver" accepted the trade
		Trades[tradeID] = nil
		TradingRemotes.UpdateTradeGUI:FireClient(player, {
			UpdateType = "TradeError",
			Message    = trade.Initiator .. " has left the game",
		})
		return
	end

	-- Cancel all other pending requests for initiator
	for otherID in pairs(PendingTradeRequests[trade.Initiator] or {}) do
		local otherTrade = Trades[otherID]
		if otherTrade then
			local otherReceiver = Players:FindFirstChild(otherTrade.Receiver)
			self:_removePendingRequest(otherTrade.Receiver, otherID)
			if otherReceiver then
				TradingRemotes.EndTrade:FireClient(otherReceiver, "Trade request was cancelled")
			end
			Trades[otherID] = nil
		end
	end
	PendingTradeRequests[trade.Initiator] = {}

	-- Cancel all other pending requests for receiver
	for otherID in pairs(PendingTradeRequests[trade.Receiver] or {}) do
		local otherTrade = Trades[otherID]
		if otherTrade then
			local otherInitiator = Players:FindFirstChild(otherTrade.Initiator)
			self:_removePendingRequest(otherTrade.Initiator, otherID)
			if otherInitiator then
				TradingRemotes.UpdateTradeGUI:FireClient(otherInitiator, {
					UpdateType = "TradeError",
					Message    = trade.Receiver .. " accepted another trade request",
				})
			end
			Trades[otherID] = nil
		end
	end
	PendingTradeRequests[trade.Receiver] = {}

	-- Inventory snapshotting
	trade.Inventories[trade.Initiator] = self:_snapshotInventory(initiator.Pets)
	trade.Inventories[trade.Receiver]  = self:_snapshotInventory(player.Pets)

	trade.Status = "Active"

	ActiveTradesByPlayer[trade.Initiator] = tradeID
	ActiveTradesByPlayer[trade.Receiver]  = tradeID

	-- Sync the clients' GUI
	trade:SyncGUI({
		UpdateType = "TradeRequestAccepted",
		TradeID    = tradeID,
		Initiator  = trade.Initiator,
		Receiver   = trade.Receiver,
	})

	return true
end

function tradeService:_onAcceptTrade(player: Player, tradeID: string) -- When a player accepts the trade offer
	if typeof(tradeID) ~= "string" then return end

	-- Guards
	local trade = self:_getTrade(tradeID)
	if not trade or trade.Status ~= "Active" then return end
	if ActiveTradesByPlayer[player.Name] ~= tradeID then return end
	if trade.Accepted[player.Name] then return end
	if trade.LockedFinalization then return end

	if trade:IsEmpty() then -- If the trade is empty
		TradingRemotes.UpdateTradeGUI:FireClient(player, {
			UpdateType = "TradeError",
			Message    = "At least one pet must be offered!",
		})
		return
	end

	trade.Accepted[player.Name] = true
	trade:SyncGUI({UpdateType = "PlayerAccepted", Player = player.Name})

	if trade:BothAccepted() then -- Once both players accept
		trade.LockedFinalization = true
		trade:StartCountdown(
			function(id) self:_finalize(id) end,
			function(id, msg) self:_forceEnd(id, msg) end
		)
	end
end

function tradeService:_onDeclineTrade(player: Player, tradeID: string) -- If the active trade offer was declined
	if typeof(tradeID) ~= "string" then return end

	local trade = self:_getTrade(tradeID)
	if not trade or ActiveTradesByPlayer[player.Name] ~= tradeID then return end

	self:_forceEnd(tradeID, player.Name .. " declined the trade!")
end

function tradeService:_onAddToTrade(player: Player, tradeID: string, petID: string) -- If a player adds a new pet to the trade offer
	if typeof(tradeID) ~= "string" or typeof(petID) ~= "string" then return end

	-- Guards
	local trade = self:_getTrade(tradeID)
	if not trade or trade.Status ~= "Active" then return end
	if ActiveTradesByPlayer[player.Name] ~= tradeID then return end
	if trade.LockedFinalization then return end

	local success, reason = trade:AddOffer(player.Name, petID)

	if not success then
		if reason == "full" then -- If the trade offer exceeds the MAX_TRADING_SLOTS we will prevent adding more pets
			TradingRemotes.UpdateTradeGUI:FireClient(player, {
				UpdateType = "TradeError",
				Message    = "You can only offer up to " .. MAX_TRADING_SLOTS .. " pets!",
			})
		end
		return
	end

	trade:ResetAccepted() -- Reset both players accept state if a new pet was added 

	-- GUI Update
	trade:SyncGUI({
		UpdateType = "AddPet",
		Player     = player.Name,
		PetName    = trade.Inventories[player.Name][petID],
		PetID      = petID,
	})

	return true
end

function tradeService:_onRemoveFromTrade(player: Player, tradeID: string, petID: string) -- If a player removes a pet from the trade offer
	if typeof(tradeID) ~= "string" or typeof(petID) ~= "string" then return end

	-- Guards
	local trade = self:_getTrade(tradeID)
	if not trade or trade.Status ~= "Active" then return end
	if ActiveTradesByPlayer[player.Name] ~= tradeID then return end
	if trade.LockedFinalization then return end

	if not trade:RemoveOffer(player.Name, petID) then return end

	trade:ResetAccepted() -- Reset both players accept state if a pet was removed

	-- GUI Update
	trade:SyncGUI({
		UpdateType = "RemovePet",
		Player     = player.Name,
		PetName    = trade.Inventories[player.Name][petID],
		PetID      = petID,
	})

	return true
end

function tradeService:_onPlayerRemoving(player: Player) -- When the player leaves the game
	local playerName = player.Name

	for tradeID in pairs(PendingTradeRequests[playerName] or {}) do -- Check if they have a pending trade request
		local trade = Trades[tradeID]
		if trade then
			local otherName   = trade.Initiator == playerName and trade.Receiver or trade.Initiator
			local otherPlayer = Players:FindFirstChild(otherName)

			self:_removePendingRequest(otherName, tradeID)

			if otherPlayer then -- Notify the sender 
				TradingRemotes.UpdateTradeGUI:FireClient(otherPlayer, {
					UpdateType = "TradeError",
					Message    = playerName .. " left the game.",
				})
			end

			Trades[tradeID] = nil
		end
	end

	PendingTradeRequests[playerName] = nil

	local activeID = ActiveTradesByPlayer[playerName]
	if activeID then -- Clear the active trade if there is one 
		self:_forceEnd(activeID, playerName .. " left the game!")
	end
end

function tradeService:IsInActiveTrade(player: Player) -- Get the active trade
	return ActiveTradesByPlayer[player.Name] ~= nil
end

function tradeService:Init()
	TradingRemotes.TradeRequest.OnServerEvent:Connect(function(player: Player, receiverName: string)
		self:_onTradeRequest(player, receiverName)
	end)

	TradingRemotes.TradeRequestResponse.OnServerInvoke = function(player: Player, accepted: boolean, tradeID: string)
		return self:_onTradeRequestResponse(player, accepted, tradeID)
	end

	TradingRemotes.AcceptTrade.OnServerEvent:Connect(function(player: Player, tradeID: string)
		self:_onAcceptTrade(player, tradeID)
	end)

	TradingRemotes.DeclineTrade.OnServerEvent:Connect(function(player: Player, tradeID: string)
		self:_onDeclineTrade(player, tradeID)
	end)

	TradingRemotes.AddToTrade.OnServerInvoke = function(player: Player, tradeID: string, petID: string)
		return self:_onAddToTrade(player, tradeID, petID)
	end

	TradingRemotes.RemoveFromTrade.OnServerInvoke = function(player: Player, tradeID: string, petID: string)
		return self:_onRemoveFromTrade(player, tradeID, petID)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_onPlayerRemoving(player)
	end)

	ServerStorage.IsInActiveTrade.OnInvoke = function(player: Player)
		return self:IsInActiveTrade(player)
	end
end

return tradeService
