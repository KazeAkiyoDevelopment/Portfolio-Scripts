-- Connected Discord-GitHub

-- RoundService
-- Handles the entire round loop: voting -> map load -> countdown -> round -> winner display -> intermission

local roundService = {}

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

-- Configs
local RoundConfig = require(ReplicatedStorage.Shared.Configs.RoundConfig) -- round durations, win messages, etc.

-- Shared data (Server)
local RoundData = require(ServerScriptService.Data.RoundData) -- stores ActivePlayers, RoleRegistry, VoteRegistry, RoundState

-- Required in Init() instead of here to avoid circular dependencies between services
local SpectateService

local RoundRemotes = ReplicatedStorage.Shared.Remotes.RoundRemotes -- fires UI updates to clients
local Weapons = ReplicatedStorage.Shared.Assets.Weapons -- knife, gun, gun drop models
local Maps = ServerStorage.Maps -- all playable map models

local RNG = Random.new() -- used for weighted role selection and map tiebreaking

-- Turns a character model into a ragdoll by swapping every Motor6D joint
-- with a BallSocketConstraint, then letting physics take over.
-- Always call this on a clone, never the real character.
function roundService:_ragdollCharacter(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		humanoid.PlatformStand = true -- disables animation so physics controls the limbs
	end

	-- Swap each Motor6D out for a BallSocketConstraint so limbs fall naturally
	for _, motor in ipairs(character:GetDescendants()) do
		if motor:IsA("Motor6D") then
			local attachment0 = Instance.new("Attachment")
			local attachment1 = Instance.new("Attachment")

			-- preserve the original joint offsets so limbs stay in the right place
			attachment0.CFrame = motor.C0
			attachment1.CFrame = motor.C1

			attachment0.Parent = motor.Part0
			attachment1.Parent = motor.Part1

			local constraint = Instance.new("BallSocketConstraint")
			constraint.Attachment0 = attachment0
			constraint.Attachment1 = attachment1
			constraint.LimitsEnabled = true
			constraint.TwistLimitsEnabled = true
			constraint.UpperAngle = 45 -- stops limbs bending into unnatural angles
			constraint.TwistUpperAngle = 45
			constraint.TwistLowerAngle = -45
			constraint.Parent = motor.Part0

			motor.Enabled = false -- motor would fight the constraint if left enabled
		end
	end

	for _, v in ipairs(character:GetDescendants()) do
		if v:IsA("BasePart") then
			v.Anchored = false
			v.CollisionGroup = "Ragdoll" -- separate collision group so ragdolls don't clip through the floor
		elseif v:IsA("LuaSourceContainer") then
			v:Destroy() -- remove any scripts so they don't run on the cloned model
		end
	end

	-- nudge the ragdoll up slightly so it doesn't spawn inside the floor
	character:PivotTo(character:GetPivot() + Vector3.new(0, 3, 0))
end

-- Resets everything back to a clean state at the end of a round:
-- strips weapons, destroys ragdolls, resets vote buttons, removes the map, ends spectating, wipes round data
function roundService:_cleanUpRound()
	for _, player in pairs(RoundData.ActivePlayers) do
		local weapon = if player.Character then player.Character:FindFirstChildOfClass("Tool") else nil

		if weapon then
			weapon:Destroy()
		end

		player.Backpack:ClearAllChildren()
	end

	for _, ragdollModel in ipairs(CollectionService:GetTagged("Ragdoll")) do
		ragdollModel:Destroy()
	end

	-- reset vote buttons so they're ready for the next voting phase
	for _, button in ipairs(CollectionService:GetTagged("VoteButton")) do
		button:SetAttribute("AssignedMap", "None")
		button:SetAttribute("Votes", 0)
	end

	if next(CollectionService:GetTagged("GunDrop")) then
		CollectionService:GetTagged("GunDrop")[1]:Destroy()
	end

	if next(CollectionService:GetTagged("ActiveMap")) then
		CollectionService:GetTagged("ActiveMap")[1]:Destroy()
	end

	for _, player in Players:GetPlayers() do
		if player:GetAttribute("Spectating") then
			SpectateService:EndSpectate(player)
		end
	end

	RoundData:Wipe()
end

-- Kicks a player out of the round mid-game.
-- ragdoll: whether to leave a ragdoll corpse at their position
-- dropGun: whether to drop the sheriff's gun (only pass true if the dying player is the sheriff)
function roundService:RemovePlayerFromRound(player: Player, ragdoll: boolean, dropGun: boolean)
	local playerIndex = table.find(RoundData.ActivePlayers, player)
	if not playerIndex then return end

	local character = player.Character
	if not character then player:Kick("Error loading character, please rejoin!") return end

	local lastCFrame = character:GetPivot() -- save position before the character gets replaced

	local weapon = player.Character:FindFirstChildOfClass("Tool")
	if weapon then
		weapon:Destroy()
	end

	table.remove(RoundData.ActivePlayers, playerIndex)
	RoundData.RoleRegistry[player] = nil

	player:LoadCharacterAsync()

	task.spawn(function()
		-- clone the old character into a ragdoll while LoadCharacterAsync runs in parallel
		if ragdoll then
			character.Archivable = true

			local ragdollModel = character:Clone()
			ragdollModel.Name = "RagdollModel"
			ragdollModel:PivotTo(lastCFrame)
			ragdollModel.Parent = workspace

			self:_ragdollCharacter(ragdollModel)

			CollectionService:AddTag(ragdollModel, "Ragdoll") -- tagged so _cleanUpRound can find it
			character.Archivable = false
		end
	end)

	-- drop the sheriff's gun so an innocent can pick it up
	if dropGun then
		self:_processGunDrop(player, character)
	end
end

-- Returns the vote button that has the given map name assigned to it
function roundService:_getButtonFromAssignedMap(assignedMap: string)
	for _, button in ipairs(CollectionService:GetTagged("VoteButton")) do
		if button:GetAttribute("AssignedMap") == assignedMap then
			return button
		end
	end
end

-- Randomly assigns a unique map to each vote button at the start of the voting phase.
-- Uses a shrinking pool so no two buttons ever get the same map.
function roundService:_assignMapsToVoteButtons()
	RoundData.MapOptions = Maps:GetChildren()
	RoundData.AvailableMaps = table.clone(RoundData.MapOptions) -- clone so removals don't affect MapOptions

	for index, button in ipairs(CollectionService:GetTagged("VoteButton")) do
		local map = RoundData.AvailableMaps[math.random(1, #RoundData.AvailableMaps)]
		if not map then continue end

		button:SetAttribute("AssignedMap", map.Name)
		button:SetAttribute("Votes", 0)

		-- remove from the pool so this map can't be picked again
		table.remove(RoundData.AvailableMaps, table.find(RoundData.AvailableMaps, map))
	end
end

-- Sets up touch detection on each vote button and wires up the billboard GUI updates.
-- Only runs once at startup — connections persist for the lifetime of the server.
function roundService:_monitorVotes()
	for index, button in ipairs(CollectionService:GetTagged("VoteButton")) do
		button.Touched:Connect(function(hit)
			if RoundData.RoundState ~= "Vote" then return end -- ignore touches outside the voting phase

			local player = Players:GetPlayerFromCharacter(hit.Parent)
			if not player then return end

			if RoundData.VoteRegistry[player] == button:GetAttribute("AssignedMap") then return end -- already voted for this map

			-- if they're switching their vote, undo the previous one first
			if RoundData.VoteRegistry[player] ~= nil then
				local previousButton = self:_getButtonFromAssignedMap(RoundData.VoteRegistry[player])
				if previousButton then
					previousButton:SetAttribute("Votes", previousButton:GetAttribute("Votes") - 1)
				end
			end

			RoundData.VoteRegistry[player] = button:GetAttribute("AssignedMap")
			button:SetAttribute("Votes", button:GetAttribute("Votes") + 1)
		end)

		-- keep the billboard GUI labels in sync with the button's attributes
		local mapInfo = button.MapDisplay.MapInfo

		button:GetAttributeChangedSignal("AssignedMap"):Connect(function()
			mapInfo.MapName.Text = button:GetAttribute("AssignedMap")
		end)

		button:GetAttributeChangedSignal("Votes"):Connect(function()
			mapInfo.Votes.Text = string.format("Votes: %d", button:GetAttribute("Votes"))
		end)
	end
end

-- Listens for character deaths and removes the player from the round when it happens.
-- Uses a guard table so each player only ever gets one listener attached.
function roundService:_monitorPlayerDeaths()
	local monitoredPlayers = {}

	local function monitor(player: Player)
		if monitoredPlayers[player] then return end
		monitoredPlayers[player] = true

		player.CharacterAdded:Connect(function(character)
			-- set all new character parts to the Player collision group
			for _, v in ipairs(character:GetDescendants()) do
				if v:IsA("BasePart") then
					v.CollisionGroup = "Player"
				end
			end

			-- WaitForChild prevents a race condition where Humanoid hasn't loaded yet
			character:WaitForChild("Humanoid").Died:Connect(function()
				if RoundData.RoundState == "Round" then
					if RoundData.RoleRegistry[player] == "Sheriff" then
						self:RemovePlayerFromRound(player, true, true) -- drop the gun when the sheriff dies
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

-- Counts up the votes and returns the name of the winning map.
-- If there's a tie it picks randomly between the tied maps.
-- Falls back to a random map if nobody voted.
function roundService:_getWinningMap()
	local voteTally = {} -- { [mapName] = voteCount }

	for _, mapName in pairs(RoundData.VoteRegistry) do
		voteTally[mapName] = (voteTally[mapName] or 0) + 1
	end

	if next(voteTally) == nil then -- nobody voted, just pick randomly
		return RoundData.MapOptions[math.random(1, #RoundData.MapOptions)].Name
	end

	local highestVotes = 0
	for _, count in pairs(voteTally) do
		if count > highestVotes then
			highestVotes = count
		end
	end

	-- gather all maps that hit the highest count to handle ties
	local mapsRanked = {}
	for mapName, count in pairs(voteTally) do
		if count == highestVotes then
			table.insert(mapsRanked, mapName)
		end
	end

	return mapsRanked[math.random(1, #mapsRanked)]
end

-- Spawns the sheriff's gun as a pickup at their death position.
-- Only one gun drop can exist at a time, so this returns early if one is already out.
function roundService:_processGunDrop(player: Player, character: Model)
	if next(CollectionService:GetTagged("GunDrop")) then return end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		warn("Could not create gun drop for: " .. player.Name)
		return
	end

	local gunDrop = Weapons.GunDrop:Clone()
	gunDrop:PivotTo(rootPart.CFrame + Vector3.new(0, 1, 0)) -- slight upward offset so it doesn't clip the floor
	gunDrop.Parent = workspace

	CollectionService:AddTag(gunDrop, "GunDrop") -- tagged so _cleanUpRound can destroy it later
end

-- Assigns Murderer and Sheriff using a weighted random system, then marks everyone else as Innocent.
-- Players who have gone more rounds without a special role get a higher chance of receiving one,
-- which prevents the same people from always being Murderer/Sheriff.
function roundService:_assignRoles()
	local weightPool = {}
	local unassignedRoles = {"Murderer", "Sheriff"}

	for _, player in RoundData.ActivePlayers do
		local chanceMultiplier = RoundData.RoundsPlayed[player] -- more rounds played = higher weight
		local baseWeight = 1 / #RoundData.ActivePlayers

		weightPool[player] = baseWeight * chanceMultiplier
	end

	-- for each role, do a weighted random pick then remove the winner from the pool
	for _, role in ipairs(unassignedRoles) do
		local total = 0
		for _, weight in pairs(weightPool) do
			total += weight
		end

		local roll = RNG:NextNumber(0, total)

		for player, weight in pairs(weightPool) do
			roll -= weight

			if roll <= 0 then
				RoundData.RoleRegistry[player] = role
				weightPool[player] = nil -- remove so they can't also get the next role
				break
			end
		end
	end

	-- everyone left over is an innocent
	for _, player in RoundData.ActivePlayers do
		if not RoundData.RoleRegistry[player] then
			RoundData.RoleRegistry[player] = "Innocent"
		end
	end
end

-- Fires the round state label update to all clients.
-- If filterPlayers is true, passes ActivePlayers so the client only shows
-- the label to players currently in the round (not lobby players).
function roundService:_updateRoundStateLabel(state: string, filterPlayers: boolean)
	if filterPlayers then
		RoundRemotes.UpdateRoundStateLabel:FireAllClients(state, RoundData.ActivePlayers)
	else
		RoundRemotes.UpdateRoundStateLabel:FireAllClients(state)
	end
end

-- Moves all player characters to the map's TeleportPoint.
-- Offset by 3 studs upward so they don't spawn inside the floor.
function roundService:_teleportPlayersToMap(map: Model)
	local teleportPoint = map.TeleportPoint

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then continue end

		character:PivotTo(teleportPoint.CFrame + Vector3.new(0, 3, 0))
	end
end

-- Gives the player the weapon for their role. Murderer gets the knife, sheriff gets the gun.
-- Innocents get nothing. Returns true on success, nil if character isn't loaded yet.
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

-- Main entry point for the round loop. Sets up the persistent vote/death monitors once,
-- then runs the round cycle (vote -> map display -> countdown -> round -> winner -> intermission) forever.
function roundService:_start()
	local roundDuration        = RoundConfig.RoundDuration
	local roundCountdown       = RoundConfig.RoundCountdown
	local intermissionDuration = RoundConfig.IntermissionDuration
	local votingDuration       = RoundConfig.VotingDuration
	local mapDisplayDuration   = RoundConfig.MapDisplayDuration

	-- these only get called once — they set up connections that last the whole server session
	self:_monitorVotes()
	self:_monitorPlayerDeaths()

	task.spawn(function()
		while true do
			if #Players:GetPlayers() < 2 then -- wait until there are enough players
				self:_updateRoundStateLabel("Not enough players to start")
				task.wait(0.1)
				continue
			end

			-- Voting phase: assign maps to buttons and let players vote by touching them
			RoundData.RoundState = "Vote"

			self:_assignMapsToVoteButtons()

			for i = votingDuration, 0, -1 do
				self:_updateRoundStateLabel(string.format("Vote for a map: %ds", i))
				task.wait(1)
			end

			-- Load the winning map into the workspace
			local selectedMapName = self:_getWinningMap()

			RoundData.RoundState = "MapDisplay"

			local map = Maps:FindFirstChild(selectedMapName):Clone()
			map.Parent = workspace

			CollectionService:AddTag(map, "ActiveMap") -- tagged so cleanup can find it later

			self:_updateRoundStateLabel(string.format("Selected map: %s", selectedMapName))

			task.wait(mapDisplayDuration)

			-- Countdown phase: teleport players, assign roles, fire role reveal animations
			RoundData.RoundState = "Countdown"

			self:_teleportPlayersToMap(map)

			for _, player in Players:GetPlayers() do
				table.insert(RoundData.ActivePlayers, player)
				RoundData.RoundsPlayed[player] = (RoundData.RoundsPlayed[player] or 0) + 1 -- tracked for role weighting
			end

			self:_assignRoles()

			for player, role in pairs(RoundData.RoleRegistry) do
				RoundRemotes.AnimateRoleAssign:FireClient(player, role) -- play the role card animation on the client
			end

			for i = roundCountdown, 0, -1 do
				self:_updateRoundStateLabel(string.format("Round starts in: %ds", i), true)
				task.wait(1)
			end

			-- Round start: hand out weapons and begin checking win conditions each second
			RoundData.RoundState = "Round"

			for player, roleName in RoundData.RoleRegistry do
				-- if weapon assignment fails, abort the round for critical roles or just remove the player
				if not self:_assignRoleWeapon(player, roleName) then
					warn("Failed to assign role for player: " .. player.Name)
					if roleName == "Murderer" or roleName == "Sheriff" then
						self:_cleanUpRound()
					else
						self:RemovePlayerFromRound(player)
					end
				end
			end

			local roundWinner = "Innocents" -- innocents win by default if the timer runs out
			local roundWinnerPlayer = nil

			for i = roundDuration, 1, -1 do
				local minutes = math.floor(i / 60)
				local seconds = i % 60

				if minutes > 0 then
					self:_updateRoundStateLabel(string.format("Round ends in: %d:%02d", minutes, seconds), true)
				else
					self:_updateRoundStateLabel(string.format("Round ends in: %02ds", seconds), true)
				end

				-- murderer is gone (shot by sheriff or left the game)
				if not RoundData:GetMurderer() then
					roundWinner = "Sheriff"
					break
				end

				-- only one player left, determine winner by their role
				if #RoundData.ActivePlayers <= 1 then
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

			-- show the win message and figure out which player to spectate
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

			-- make everyone spectate the winner (skip if innocents won since there's no single winner)
			if roundWinner ~= "Innocents" and roundWinnerPlayer then
				for _, player in Players:GetPlayers() do
					SpectateService:SpectatePlayer(player, roundWinnerPlayer)
				end
			end

			task.wait(RoundConfig.WinnerDisplayDuration)

			self:_teleportPlayersToMap(workspace.Lobby)
			self:_cleanUpRound()

			-- Intermission: short cooldown before the next vote starts
			RoundData.RoundState = "Intermission"

			for i = 0, intermissionDuration do
				self:_updateRoundStateLabel(string.format("Voting starts in: %ds", intermissionDuration - i))
				task.wait(1)
			end
		end
	end)

	-- clean up the player's data when they leave so stale entries don't linger
	Players.PlayerRemoving:Connect(function(player)
		local playerIndex = table.find(RoundData.ActivePlayers, player)

		if playerIndex then
			table.remove(RoundData.ActivePlayers, playerIndex)
		end

		RoundData.RoleRegistry[player] = nil
		RoundData.VoteRegistry[player] = nil
		RoundData.RoundsPlayed[player] = nil
	end)
end

-- SpectateService is required here instead of the top to avoid circular dependency issues
function roundService:Init()
	SpectateService = require(ServerScriptService.Services.SpectateService)

	self:_start()
end

return roundService
