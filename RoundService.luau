-- Connected Discord-GitHub

local roundService = {}

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

-- Configs
local RoundConfig = require(ReplicatedStorage.Shared.Configs.RoundConfig)

-- Shared data (Server)
local RoundData  = require(ServerScriptService.Data.RoundData)

local SpectateService

local RoundRemotes = ReplicatedStorage.Shared.Remotes.RoundRemotes
local Weapons = ReplicatedStorage.Shared.Assets.Weapons

local Maps = ServerStorage.Maps

local RNG = Random.new()

function roundService:_ragdollCharacter(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		humanoid.PlatformStand = true
	end

	for _, motor in ipairs(character:GetDescendants()) do
		if motor:IsA("Motor6D") then
			local attachment0 = Instance.new("Attachment")
			local attachment1 = Instance.new("Attachment")

			attachment0.CFrame = motor.C0
			attachment1.CFrame = motor.C1

			attachment0.Parent = motor.Part0
			attachment1.Parent = motor.Part1

			-- Create the constraint to ragdoll the cloned character
			local constraint = Instance.new("BallSocketConstraint")
			constraint.Attachment0 = attachment0
			constraint.Attachment1 = attachment1
			constraint.LimitsEnabled = true
			constraint.TwistLimitsEnabled = true
			constraint.UpperAngle = 45
			constraint.TwistUpperAngle = 45
			constraint.TwistLowerAngle = -45
			constraint.Parent = motor.Part0

			motor.Enabled = false
		end
	end

	-- Set up the cloned character 
	for _, v in ipairs(character:GetDescendants()) do
		if v:IsA("BasePart") then
			v.Anchored = false
			v.CollisionGroup = "Ragdoll"
		elseif v:IsA("LuaSourceContainer") then
			v:Destroy()
		end
	end
	
	character:PivotTo(character:GetPivot() + Vector3.new(0, 3, 0)) -- Set the cloned character above the ground to prevent no-clipping
end

function roundService:_cleanUpRound()
	-- Clean up all players' weapons
	for _, player in pairs(RoundData.ActivePlayers) do
		local weapon = if player.Character then player.Character:FindFirstChildOfClass("Tool") else nil  

		if weapon then
			weapon:Destroy()
		end

		player.Backpack:ClearAllChildren()
	end

	-- Clean up all ragdoll models
	for _, ragdollModel in ipairs(CollectionService:GetTagged("Ragdoll")) do
		ragdollModel:Destroy()
	end

	-- Reset voting variables to default
	for _, button in ipairs(CollectionService:GetTagged("VoteButton")) do
		button:SetAttribute("AssignedMap", "None")
		button:SetAttribute("Votes", 0)
	end

	-- Clean up gun drop
	if next(CollectionService:GetTagged("GunDrop")) then
		CollectionService:GetTagged("GunDrop")[1]:Destroy()
	end

	-- Clean up active map
	if next(CollectionService:GetTagged("ActiveMap")) then
		CollectionService:GetTagged("ActiveMap")[1]:Destroy()
	end

	-- Disable all players' spectating
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("Spectating") then
			SpectateService:EndSpectate(player)
		end
	end

	-- Wipe the current round data 
	RoundData:Wipe()
end

function roundService:RemovePlayerFromRound(player: Player, ragdoll: boolean, dropGun: boolean) -- Removes a player from the active round, optionally spawning a ragdoll and dropping the sheriff's gun at their last position
	-- Get the player's index
	local playerIndex = table.find(RoundData.ActivePlayers, player)
	if not playerIndex then return end
	
	local character = player.Character 
	if not character then player:Kick("Error loading character, please rejoin!") return end

	-- Save the last CFrame
	local lastCFrame = character:GetPivot()
	
	local weapon = player.Character:FindFirstChildOfClass("Tool")

	if weapon then
		weapon:Destroy()
	end
	
	table.remove(RoundData.ActivePlayers, playerIndex)
	RoundData.RoleRegistry[player] = nil
	
	player:LoadCharacterAsync()
	
	task.spawn(function() -- Create the cloned character for the ragdoll effect
		if ragdoll then
			character.Archivable = true

			local ragdollModel = character:Clone()
			ragdollModel.Name = "RagdollModel"
			ragdollModel:PivotTo(lastCFrame)
			ragdollModel.Parent = workspace

			self:_ragdollCharacter(ragdollModel)

			CollectionService:AddTag(ragdollModel, "Ragdoll")	
			character.Archivable = false
		end
	end)

	-- If the player is the sheriff then we will run the gun drop function
	if dropGun then
		self:_processGunDrop(player, character)
	end
end

function roundService:_getButtonFromAssignedMap(assignedMap: string)
	for _, button in ipairs(CollectionService:GetTagged("VoteButton")) do -- Loop through all the vote buttons and return the button with the specified map
		if button:GetAttribute("AssignedMap") == assignedMap then
			return button
		end
	end
end

function roundService:_assignMapsToVoteButtons()
	RoundData.MapOptions = Maps:GetChildren()
	RoundData.AvailableMaps = RoundData.MapOptions 
	
	for index, button in ipairs(CollectionService:GetTagged("VoteButton")) do
		local map = RoundData.AvailableMaps[math.random(1, #RoundData.AvailableMaps)]
		if not map then continue end

		button:SetAttribute("AssignedMap", map.Name)
		button:SetAttribute("Votes", 0)
		
		table.remove(RoundData.AvailableMaps, table.find(RoundData.AvailableMaps, map))
	end
end

function roundService:_monitorVotes()
	for index, button in ipairs(CollectionService:GetTagged("VoteButton")) do
		button.Touched:Connect(function(hit)
			if RoundData.RoundState ~= "Vote" then return end -- Guard to check if the round is in the voting phase

			local player = Players:GetPlayerFromCharacter(hit.Parent)
			if not player then return end
			
			if RoundData.VoteRegistry[player] == button:GetAttribute("AssignedMap") then return end -- Guard to check if the player is trying to vote for the same map
			if RoundData.VoteRegistry[player] ~= nil then -- If they are voting for a new map then we remove their previous vote before registering their new vote
				local previousButton = self:_getButtonFromAssignedMap(RoundData.VoteRegistry[player])
				if previousButton then
					previousButton:SetAttribute("Votes", previousButton:GetAttribute("Votes") - 1)
				end
			end

			RoundData.VoteRegistry[player] = button:GetAttribute("AssignedMap")
			button:SetAttribute("Votes", button:GetAttribute("Votes") + 1)
		end)
		-- BillBoard GUI related
		local mapInfo = button.MapDisplay.MapInfo

		button:GetAttributeChangedSignal("AssignedMap"):Connect(function()
			mapInfo.MapName.Text = button:GetAttribute("AssignedMap") 
		end)

		button:GetAttributeChangedSignal("Votes"):Connect(function()
			mapInfo.Votes.Text = string.format("Votes: %d", button:GetAttribute("Votes"))
		end)
	end
end

function roundService:_monitorPlayerDeaths()
	local monitoredPlayers = {}
	
	local function monitor(player: Player)
		if monitoredPlayers[player] then return end
		monitoredPlayers[player] = true

		player.CharacterAdded:Connect(function(character)	
			for _, v in ipairs(character:GetDescendants()) do 
				if v:IsA("BasePart") then
					v.CollisionGroup = "Player"
				end
			end
			
			character.Humanoid.Died:Connect(function()
				if RoundData.RoundState == "Round" then
					if RoundData.RoleRegistry[player] == "Sheriff" then 
						self:RemovePlayerFromRound(player, true, true) -- Run the gun drop function
					else
						self:RemovePlayerFromRound(player, true)
					end
				end
			end)
		end)
	end
	
	for _, player in Players:GetPlayers() do
		monitor(player)
	end
	
	Players.PlayerAdded:Connect(monitor)
end

function roundService:_getWinningMap()
	local voteTally = {} -- {[Map_Name] = Vote_Number}
	
	for _, mapName in pairs(RoundData.VoteRegistry) do
		voteTally[mapName] = (voteTally[mapName] or 0) +1
	end

	if next(voteTally) == nil then -- No map was selected
		return RoundData.MapOptions[math.random(1, #RoundData.MapOptions)].Name
	end

	local highestVotes = 0
	
	for _, count in pairs(voteTally) do 
		if count > highestVotes then
			highestVotes = count
		end
	end

	local mapsRanked = {} -- {Map_Name1, Map_Name2}
	
	for mapName, count in pairs(voteTally) do
		if count == highestVotes then
			table.insert(mapsRanked, mapName)
		end
	end

	return mapsRanked[math.random(1, #mapsRanked)] -- Returns the map at index 1 (the highest voted as its an array)
end

function roundService:_processGunDrop(player: Player, character: Model)
	if next(CollectionService:GetTagged("GunDrop")) then return end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then 
		warn("Could not create gun drop for: " .. player.Name) 
		return 
	end

	local gunDrop = Weapons.GunDrop:Clone()
	gunDrop:PivotTo(rootPart.CFrame + Vector3.new(0, 1, 0))
	gunDrop.Parent = workspace

	CollectionService:AddTag(gunDrop, "GunDrop")
end

function roundService:_assignRoles()
	local weightPool = {}
	local unassignedRoles = {"Murderer", "Sheriff"} --

	for _, player in RoundData.ActivePlayers do
		local chanceMultiplier = RoundData.RoundsPlayed[player] -- Increases the probability of getting a role based on the amount of rounds played
		local baseWeight = 1  /#RoundData.ActivePlayers
		
		weightPool[player] = baseWeight * chanceMultiplier
	end

	for _, role in ipairs(unassignedRoles) do --Weight assigning 
		local total = 0
		
		for _, weight in pairs(weightPool) do
			total += weight
		end

		local roll = RNG:NextNumber(0, total)

		for player, weight in pairs(weightPool) do
			roll -= weight
			
			if roll <= 0 then
				RoundData.RoleRegistry[player] = role
				weightPool[player] = nil
				break
			end
		end
	end
	
	for _, player in RoundData.ActivePlayers do -- Sets the role for the rest of the players to the default
		if not RoundData.RoleRegistry[player] then
			RoundData.RoleRegistry[player] = "Innocent"
		end
	end
end

function roundService:_updateRoundStateLabel(state: string, filterPlayers: boolean) -- Fires a client event to update the round label GUI
	if filterPlayers then
		RoundRemotes.UpdateRoundStateLabel:FireAllClients(state, RoundData.ActivePlayers) -- Only shows to the Round ActivePlayers (Such as not showing the timer for player's in the Lobby)
	else
		RoundRemotes.UpdateRoundStateLabel:FireAllClients(state)
	end
end

function roundService:_teleportPlayersToMap(map: Model)
	local teleportPoint = map.TeleportPoint
	
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then continue end
		
		character:PivotTo(teleportPoint.CFrame + Vector3.new(0, 3, 0))
	end
end

function roundService:_assignRoleWeapon(player: Player, roleName: string)
	local character = player.Character
	
	if not character then return end
	
	if roleName == "Murderer" then	
		Weapons.Knife:Clone().Parent = player.Backpack
	elseif roleName == "Sheriff" then
		Weapons.Gun:Clone().Parent = player.Backpack
	end
	
	return true
end

function roundService:_start()
	local roundDuration = RoundConfig.RoundDuration
	local roundCountdown = RoundConfig.RoundCountdown
	local intermissionDuration = RoundConfig.IntermissionDuration
	local votingDuration = RoundConfig.VotingDuration
	local mapDisplayDuration = RoundConfig.MapDisplayDuration

	self:_monitorVotes()
	self:_monitorPlayerDeaths()

	task.spawn(function()
		while true do
			if #Players:GetPlayers() < 2 then -- Check if there are more than 2 players
				self:_updateRoundStateLabel("Not enough players to start")
				task.wait(0.1)
				continue
			end
			
			-- Voting
			RoundData.RoundState = "Vote"
			
			self:_assignMapsToVoteButtons() -- Refresh the vote buttons with new maps
			
			for i = votingDuration, 0, -1 do
				self:_updateRoundStateLabel(string.format("Vote for a map: %ds", i))
				task.wait(1)
			end

			-- Countdown
			local selectedMapName = self:_getWinningMap()
		
			RoundData.RoundState = "MapDisplay"
			
			local map = Maps:FindFirstChild(selectedMapName):Clone()
			map.Parent = workspace
			
			CollectionService:AddTag(map, "ActiveMap")
			
			self:_updateRoundStateLabel(string.format("Selected map: %s", selectedMapName))
			
			task.wait(mapDisplayDuration)
			
			RoundData.RoundState = "Countdown"
			
			self:_teleportPlayersToMap(map)
			
			for _, player in Players:GetPlayers() do
				table.insert(RoundData.ActivePlayers, player)
				RoundData.RoundsPlayed[player] = (RoundData.RoundsPlayed[player] or 0) + 1
			end

			self:_assignRoles()
			
			for player, role in pairs(RoundData.RoleRegistry) do
				RoundRemotes.AnimateRoleAssign:FireClient(player, role)
			end
		
			for i = roundCountdown, 0, -1 do
				self:_updateRoundStateLabel(string.format("Round starts in: %ds", i), true)
				task.wait(1)
			end

			-- Start round
			RoundData.RoundState = "Round"
			
			for player, roleName in RoundData.RoleRegistry do
				if not self:_assignRoleWeapon(player, roleName) then -- Assign the role weapons
					warn("Failed to assign role for player: "..player.Name)
					if roleName == "Murderer" or roleName == "Sheriff" then self:_cleanUpRound() else self:RemovePlayerFromRound(player) end 
				end
			end
			
			local roundWinner = "Innocents" -- Default winner
			local roundWinnerPlayer = nil
			
			for i = roundDuration, 1, -1 do
				local minutes = math.floor(i / 60)
				local seconds = i % 60

				if minutes > 0 then
					self:_updateRoundStateLabel(string.format("Round ends in: %d:%02d", minutes, seconds), true)
				else
					self:_updateRoundStateLabel(string.format("Round ends in: %02ds", seconds), true)
				end

				if not RoundData:GetMurderer() then -- If the murderer could not be found (Shot by the sheriff or left the game)
					roundWinner = "Sheriff"
					break
				end

				if #RoundData.ActivePlayers <= 1 then -- If there is only one player remaining 
					local lastPlayer = RoundData.ActivePlayers[1]
					
					if lastPlayer then
						if RoundData.RoleRegistry[lastPlayer] == "Innocent" then
							roundWinner = "Innocents"
						else
							roundWinner = RoundData.RoleRegistry[lastPlayer]
						end				
					end			
					break
				end

				task.wait(1)
			end

			if roundWinner == "Murderer" then
				self:_updateRoundStateLabel(RoundConfig.WinMessages.Murderer)
				roundWinnerPlayer = RoundData:GetMurderer()
			elseif roundWinner == "Sheriff" then
				self:_updateRoundStateLabel(RoundConfig.WinMessages.Sheriff)
				roundWinnerPlayer = RoundData:GetSheriff()
			elseif roundWinner == "Innocents" then
				self:_updateRoundStateLabel(RoundConfig.WinMessages.Innocents)
			end
			
			RoundData.RoundState = "DisplayWinner" 
			
			-- Round ended here
			if roundWinner ~= "Innocents" and roundWinnerPlayer then
				for _, player in Players:GetPlayers() do
					SpectateService:SpectatePlayer(player, roundWinnerPlayer) -- Display the winner with spectate service 
				end
			end
			
			task.wait(RoundConfig.WinnerDisplayDuration)
			
			self:_teleportPlayersToMap(workspace.Lobby)
			self:_cleanUpRound()
			
			-- Intermission
			RoundData.RoundState = "Intermission"
			
			for i = 0, intermissionDuration do
				self:_updateRoundStateLabel(string.format("Voting starts in: %ds", intermissionDuration - i))
				task.wait(1)
			end
		end
	end)
	
	Players.PlayerRemoving:Connect(function(player) -- Clean up
		local playerIndex = table.find(RoundData.ActivePlayers, player)
		
		if playerIndex then
			table.remove(RoundData.ActivePlayers,playerIndex)
		end
	
		RoundData.RoleRegistry[player] = nil
		RoundData.VoteRegistry[player] = nil
		RoundData.RoundsPlayed[player] = nil
	end)
end

function roundService:Init()
	SpectateService = require(ServerScriptService.Services.SpectateService)
	
	self:_start()
end

return roundService
