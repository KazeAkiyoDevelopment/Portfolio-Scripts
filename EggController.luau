-- Connected Discord-GitHub

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Eggs = workspace:WaitForChild("Eggs")

local Shared = ReplicatedStorage:WaitForChild("Shared")

local EggRemotes = Shared:WaitForChild("Remotes"):WaitForChild("EggRemotes")
local PetModels = Shared:WaitForChild("Models"):WaitForChild("PetModels")

local UIAnimation = require(Shared:WaitForChild("Utils"):WaitForChild("UIAnimation"))

local EggConfig = require(Shared:WaitForChild("Configs"):WaitForChild("EggConfig"))
local EggDatabase = require(Shared:WaitForChild("Databases"):WaitForChild("EggDatabase"))

local player = game.Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local EggHatchGUI = playerGui:WaitForChild("EggHatchGUI")
local EggInfoGUIs = EggHatchGUI:WaitForChild("EggInfoGUIS") -- BillboardGuis parented under here, one per egg
local Container = EggHatchGUI:WaitForChild("Container")

-- Hide the floating egg UIs while the hatch animation plays, they overlap otherwise
local function toggleEggInfoGUIS(bool: boolean)
	for _, v in EggInfoGUIs:GetChildren() do
		if v.Name == "EggInfoGUITemplate" then continue end
		v.Enabled = bool
	end
end

local function getClosestEgg()
	local closestEgg
	local closestDistance = math.huge
	
	for _, egg in pairs(Eggs:GetChildren()) do
		local distance = (egg.PrimaryPart.Position - player.Character.HumanoidRootPart.Position).Magnitude
		
		if distance < closestDistance then
			closestDistance = distance
			closestEgg = egg
		end
	end
	
	return closestEgg
end

local function cleanUpHatchAnimation()
	for _, v in pairs(Container:GetChildren()) do
		if v.Name == "Template" then continue end
		
		if v:IsA("Frame") then
			v:Destroy()
		end
	end
	
	-- meshes and models get parented to the camera during the animation,
	-- nukes them all in one shot instead of tracking refs
	workspace.CurrentCamera:ClearAllChildren()
end

local function createNewTemplate(petName: string)
	local template = Container.Template:Clone()
	template.Name = petName
	template.Visible = true
	template.Parent = Container
	
	return template
end

-- Converts the center of a UI frame into a world CFrame at a fixed depth in front of the camera.
-- Uses ScreenPointToRay to get the direction, then offsets upward in camera space so the
-- 3D model sits above the name label instead of right on top of it.
local function getTemplateWorldCFrame(template)
	local camera = workspace.CurrentCamera
	local depth = EggConfig.Depth
	
	local screenPos = template.AbsolutePosition + template.AbsoluteSize / 2

	local ray = camera:ScreenPointToRay(screenPos.X, screenPos.Y, depth)
	local worldPos = ray.Origin + ray.Direction * depth
	
	local offset = camera.CFrame:VectorToWorldSpace(Vector3.new(0, EggConfig.PetYOffset, 0))
	
	return CFrame.lookAt(worldPos + offset, camera.CFrame.Position, camera.CFrame.UpVector)
end

-- Artists can set RotationOffsetX/Y/Z attributes on the model to fix alignment
-- without needing to touch any code, handy for weirdly oriented meshes
local function getRotationOffset(petModel: Model)
	local rx = math.rad(petModel:GetAttribute("RotationOffsetX") or 0)
	local ry = math.rad(petModel:GetAttribute("RotationOffsetY") or 0)
	local rz = math.rad(petModel:GetAttribute("RotationOffsetZ") or 0)

	return CFrame.Angles(rx, ry, rz)
end

local function tweenFOV(FOV: number)
	TweenService:Create(workspace.CurrentCamera, TweenInfo.new(EggConfig.FOVAnimationDuration, Enum.EasingStyle.Sine), {FieldOfView = FOV}):Play()
end

-- wobbles the egg on a sine curve, fades it out near the end, then shows the pet
-- for a bit before cleaning up. single and multi-pet results both go through the
-- same render step via HatchEntries so the loop doesnt care which hatch type fired
local function animateEggHatch(closestEgg: ObjectValue, pet: any)
	local wobbleDuration = EggConfig.EggWobbleDuration
	local wobbleSpeed = EggConfig.EggWobbleSpeed
	local wobbleAmount = math.rad(EggConfig.EggWobbleAmount)

	local fadeDuration = EggConfig.EggFadeDuration
	local fadeMultiplier = EggConfig.EggFadeSpeedMultiplier
	local fadeStartTime = wobbleDuration - fadeDuration -- start fading before wobble ends so it feels smooth

	local petDisplayDuration = EggConfig.PetDisplayDuration

	local timeElapsed = 0
	local fadeCompleted = false
	local petsInitialized = false
	local petDisplayElapsed = 0

	-- two separate dirty checks because egg and pet phases are independent,
	-- sharing one caused the pet to skip repositioning when the egg had already settled
	local lastCameraCFrameEgg = CFrame.new()
	local lastCameraCFramePet = CFrame.new()
	
	local camera = workspace.CurrentCamera

	local HatchEntries = {}
	
	-- single hatch gives one table, multi gives an array, wrapping it means the loop below
	-- doesn't need to care which one it got
	local petList = if typeof(pet) == "table" then pet else {pet}

	for _, pet in pairs(petList) do
		local eggMesh = closestEgg.PrimaryPart:Clone()
		eggMesh.Parent = camera -- parented to camera so it renders in front of the world

		local petModel = PetModels[closestEgg.Name]:FindFirstChild(pet.Name):Clone()
		local template = createNewTemplate(pet.Name)

		table.insert(HatchEntries, {
			EggMesh = eggMesh,
			PetModel = petModel,
			Template = template,
			BaseEggCFrame = CFrame.new(),
		})
	end

	toggleEggInfoGUIS(false)
	UIAnimation:ToggleInterface(false)
	tweenFOV(EggConfig.EggHatchFOV)
	Container.Visible = true

	RunService:BindToRenderStep("EggHatch", 300, function(dt)
		timeElapsed += dt
		
		local cameraCFrame = camera.CFrame

		if timeElapsed <= wobbleDuration then
			local angle = math.sin(timeElapsed * wobbleSpeed) * wobbleAmount
			
			-- this took a while to figure out: while the FOV tween is running, ScreenPointToRay
			-- returns different world positions every frame even if the camera hasnt moved,
			-- because the projection matrix is changing. have to force a recalc for that window
			-- otherwise the egg visibly drifts during the zoom in
			if not cameraCFrame:FuzzyEq(lastCameraCFrameEgg) or timeElapsed < EggConfig.FOVAnimationDuration then
				for _, data in ipairs(HatchEntries) do
					local worldCFrame = getTemplateWorldCFrame(data.Template)
					data.EggMesh:PivotTo(worldCFrame * CFrame.Angles(0, 0, angle))
					data.BaseEggCFrame = worldCFrame
				end

				lastCameraCFrameEgg = cameraCFrame
			else
				-- camera hasnt moved, skip the raycast and just apply the sine angle to the cached CFrame
				for _, data in ipairs(HatchEntries) do
					data.EggMesh:PivotTo(data.BaseEggCFrame * CFrame.Angles(0, 0, angle))
				end
			end
		end

		-- fade the egg out toward the end of the wobble
		if not fadeCompleted and timeElapsed >= fadeStartTime then
			-- fadeMultiplier controls how fast alpha hits 1 within the fade window,
			-- crank it up if you want it snappier without changing fadeDuration
			local alpha = ((timeElapsed - fadeStartTime) * fadeMultiplier) / fadeDuration
			
			for _, data in ipairs(HatchEntries) do
				data.EggMesh.Transparency = alpha
				
				for _, v in data.EggMesh:GetChildren() do
					if v:IsA("Decal") then
						v.Transparency = alpha -- decals dont inherit transparency from their parent part
					end
				end
			end
			
			fadeCompleted = alpha >= 1
		end

		if fadeCompleted then
			if not petsInitialized then
				petsInitialized = true
				
				for _, data in ipairs(HatchEntries) do
					data.Template.PetName.Text = data.PetModel.Name
					data.Template.PetName.Visible = true
					data.PetModel.Parent = camera
				end
			end

			petDisplayElapsed += dt
			
			-- only reposition if the camera actually moved, no point recalculating every frame
			if not cameraCFrame:FuzzyEq(lastCameraCFramePet) then
				for _, data in ipairs(HatchEntries) do
					local petModel = data.PetModel
					local worldCFrame = getTemplateWorldCFrame(data.Template)
					
					if petModel:GetAttribute("CustomRotation") then
						worldCFrame = worldCFrame * getRotationOffset(petModel)
					end
					
					petModel:PivotTo(worldCFrame)
				end
				
				lastCameraCFramePet = cameraCFrame
			end
			
			if petDisplayElapsed >= petDisplayDuration then
				RunService:UnbindFromRenderStep("EggHatch")
				cleanUpHatchAnimation()
				toggleEggInfoGUIS(true)
				UIAnimation:ToggleInterface(true)
				tweenFOV(70)
				Container.Visible = false
			end
		end
	end)
end

-- E = single, R = triple, T = octuple
-- server returns nil + reason on failure, reason gets shown as a notification
local hatchKeybinds = {
	[Enum.KeyCode.E] = function(closestEgg: ObjectValue)
		local pet, reason = EggRemotes.SingleHatch:InvokeServer(closestEgg)
		if not pet then if reason then UIAnimation:ShowNotification(reason) end return end
		animateEggHatch(closestEgg, pet)
	end,
	
	[Enum.KeyCode.R] = function(closestEgg: ObjectValue)
		local pets, reason = EggRemotes.TripleHatch:InvokeServer(closestEgg)
		if not pets then if reason then UIAnimation:ShowNotification(reason) end return end
		animateEggHatch(closestEgg, pets) 
	end,
	
	[Enum.KeyCode.T] = function(closestEgg: ObjectValue)
		local pets, reason = EggRemotes.OctupleHatch:InvokeServer(closestEgg)
		if not pets then if reason then UIAnimation:ShowNotification(reason) end return end
		animateEggHatch(closestEgg, pets) 
	end
}

-- gameProcessed stops hatch keys from firing while the player is typing in a text box
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	local action = not gameProcessed and hatchKeybinds[input.KeyCode]
	local closestEgg = action and getClosestEgg()

	if closestEgg then
		action(closestEgg)
	end
end)

-- Build a BillboardGui for each egg on startup. Every pet slot gets its own
-- Camera and ViewportFrame so models render cleanly without picking up scene lighting
for _, egg in Eggs:GetChildren() do
	local eggInfo = EggDatabase.Eggs[egg]

	local eggInfoGUI = EggInfoGUIs.EggInfoGUITemplate:Clone()
	eggInfoGUI.Name = egg.Name
	eggInfoGUI.Adornee = egg
	eggInfoGUI.Enabled = true
	eggInfoGUI.Parent = EggInfoGUIs

	eggInfoGUI.EggName.Text = eggInfo["DisplayName"]
	eggInfoGUI.EggPrice.Text = eggInfo["Price"]

	local container = eggInfoGUI.Container

	for _, v in ipairs(eggInfo["Pets"]) do
		local petTemplate = container.Template:Clone()
		petTemplate.Name = v.Name
		petTemplate.PetName.Text = v.Name
		petTemplate.PetChance.Text = string.format("%d%%", v.Chance)
		petTemplate.PetChance.TextColor3 = EggDatabase.RarityColors[v.Rarity]
		petTemplate.Visible = true
		petTemplate.Parent = container

		local viewportFrame = petTemplate.ViewportFrame

		local camera = Instance.new("Camera")
		camera.Parent = viewportFrame

		-- 5 studs in front of the viewport camera, rotated 180 so it faces forward
		local baseCFrame = camera.CFrame + camera.CFrame:VectorToWorldSpace(Vector3.new(0, 0, -5))

		local petModel = PetModels[egg.Name]:FindFirstChild(v.Name):Clone()
		petModel:PivotTo(baseCFrame * CFrame.Angles(0, math.pi, 0))
		petModel.Parent = camera
		
		if petModel:GetAttribute("CustomRotation") then
			petModel:PivotTo(petModel:GetPivot() * getRotationOffset(petModel))
		end

		viewportFrame.CurrentCamera = camera
	end
end

