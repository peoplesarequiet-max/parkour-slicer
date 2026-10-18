local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local NORMAL_WALK_SPEED = 16
local SPRINT_WALK_SPEED = 40
local SPRINT_ROOT_LEAN = math.rad(-3)
local SPRINT_WAIST_LEAN = math.rad(-7)
local DASH_IMPULSE_SPEED = 48
local DASH_COOLDOWN = 0.9
local DASH_POSE_DURATION = 0.28

local DASH_POSE_ANGLES = {
	root = Vector3.new(math.rad(-18), 0, 0),
	rootjoint = Vector3.new(math.rad(-18), 0, 0),
	waist = Vector3.new(math.rad(-12), 0, 0),
	leftshoulder = Vector3.new(math.rad(-52), 0, math.rad(-12)),
	rightshoulder = Vector3.new(math.rad(-66), 0, math.rad(12)),
	leftarm = Vector3.new(math.rad(-52), 0, math.rad(-12)),
	rightarm = Vector3.new(math.rad(-66), 0, math.rad(12)),
	lefthip = Vector3.new(math.rad(-18), 0, 0),
	righthip = Vector3.new(math.rad(28), 0, 0),
}

local characterConnections = {}
local activeCharacter = nil
local activeHumanoid = nil
local activeDash = nil
local activeNormalWalkSpeed = NORMAL_WALK_SPEED
local characterToken = 0
local sprintHeld = false
local activePoseConnection = nil
local activePoseMotors = {}

local function disconnectCharacterConnections()
	for _, connection in characterConnections do
		connection:Disconnect()
	end
	table.clear(characterConnections)
end

local function stopDashPose()
	if activePoseConnection then
		activePoseConnection:Disconnect()
		activePoseConnection = nil
	end

	for _, poseMotor in activePoseMotors do
		if poseMotor.motor.Parent then
			poseMotor.motor.Transform = poseMotor.baseTransform
		end
	end
	table.clear(activePoseMotors)
end

local function playDashPose(character)
	stopDashPose()

	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Motor6D") or descendant:IsA("AnimationConstraint") then
			local normalizedName = string.lower(string.gsub(descendant.Name, "%s+", ""))
			local angles = DASH_POSE_ANGLES[normalizedName]
			if angles then
				table.insert(activePoseMotors, {
					motor = descendant,
					baseTransform = descendant.Transform,
					angles = angles,
				})
			end
		end
	end

	if #activePoseMotors == 0 then
		return
	end

	local startTime = os.clock()
	activePoseConnection = RunService.PreSimulation:Connect(function()
		local progress = math.clamp((os.clock() - startTime) / DASH_POSE_DURATION, 0, 1)
		local weight = math.sin(progress * math.pi)

		for _, poseMotor in activePoseMotors do
			local angles = poseMotor.angles
			poseMotor.motor.Transform = poseMotor.baseTransform
				* CFrame.Angles(angles.X * weight, angles.Y * weight, angles.Z * weight)
		end

		if progress >= 1 then
			stopDashPose()
		end
	end)
end

local function flattenUnit(direction)
	local flattened = Vector3.new(direction.X, 0, direction.Z)
	if flattened.Magnitude > 0.001 then
		return flattened.Unit
	end
	return nil
end

local function getDashDirection(humanoid, rootPart)
	local camera = workspace.CurrentCamera
	if camera then
		local forward = flattenUnit(camera.CFrame.LookVector) or flattenUnit(rootPart.CFrame.LookVector)
		local right = flattenUnit(camera.CFrame.RightVector) or Vector3.xAxis
		local keyboardDirection = Vector3.zero

		if UserInputService:IsKeyDown(Enum.KeyCode.W) then
			keyboardDirection += forward
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then
			keyboardDirection -= forward
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then
			keyboardDirection += right
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then
			keyboardDirection -= right
		end

		local keyboardUnit = flattenUnit(keyboardDirection)
		if keyboardUnit then
			return keyboardUnit
		end
	end

	return flattenUnit(humanoid.MoveDirection)
		or flattenUnit(rootPart.CFrame.LookVector)
		or Vector3.new(0, 0, -1)
end

local function bindCharacter(character)
	characterToken += 1
	local token = characterToken
	disconnectCharacterConnections()
	stopDashPose()

	activeCharacter = character
	activeHumanoid = nil
	activeDash = nil

	local humanoid = character:WaitForChild("Humanoid")
	local rootPart = character:WaitForChild("HumanoidRootPart")
	if token ~= characterToken or character ~= player.Character then
		return
	end

	activeHumanoid = humanoid
	activeNormalWalkSpeed = humanoid.WalkSpeed
	local jumpCount = 0
	local nextDashTime = 0
	local sprintLeanJoints = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Motor6D") or descendant:IsA("AnimationConstraint") then
			local normalizedName = string.lower(string.gsub(descendant.Name, "%s+", ""))
			if normalizedName == "root" or normalizedName == "rootjoint" then
				table.insert(sprintLeanJoints, { joint = descendant, angle = SPRINT_ROOT_LEAN })
			elseif normalizedName == "waist" then
				table.insert(sprintLeanJoints, { joint = descendant, angle = SPRINT_WAIST_LEAN })
			end
		end
	end

	local leanWeight = 0
	table.insert(characterConnections, RunService.PreSimulation:Connect(function(deltaTime)
		local targetWeight = sprintHeld and humanoid.Health > 0 and humanoid.MoveDirection.Magnitude > 0.05 and 1 or 0
		local blend = math.min(deltaTime * 12, 1)
		leanWeight += (targetWeight - leanWeight) * blend
		if targetWeight == 0 and leanWeight < 0.001 then
			leanWeight = 0
		end

		for _, poseJoint in sprintLeanJoints do
			if poseJoint.joint.Parent then
				poseJoint.joint.Transform *= CFrame.Angles(poseJoint.angle * leanWeight, 0, 0)
			end
		end
	end))

	local function performJump()
		local verticalSpeed = humanoid.JumpPower
		if not humanoid.UseJumpPower then
			verticalSpeed = math.sqrt(2 * workspace.Gravity * humanoid.JumpHeight)
		end

		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		local currentVelocity = rootPart.AssemblyLinearVelocity
		rootPart.AssemblyLinearVelocity = Vector3.new(currentVelocity.X, verticalSpeed, currentVelocity.Z)
	end

	local function dash()
		if humanoid.Health <= 0 or humanoid.Sit or os.clock() < nextDashTime then
			return
		end

		nextDashTime = os.clock() + DASH_COOLDOWN
		local direction = getDashDirection(humanoid, rootPart)
		rootPart:ApplyImpulse(direction * rootPart.AssemblyMass * DASH_IMPULSE_SPEED)
		playDashPose(character)
	end
	activeDash = dash

	table.insert(characterConnections, UserInputService.JumpRequest:Connect(function()
		if humanoid.Health <= 0 or humanoid.Sit then
			return
		end

		if jumpCount == 0 then
			jumpCount = 1
			performJump()
			return
		end

		if jumpCount ~= 1 or humanoid.FloorMaterial ~= Enum.Material.Air then
			return
		end

		jumpCount = 2
		performJump()
	end))

	table.insert(characterConnections, humanoid.StateChanged:Connect(function(_, newState)
		if newState == Enum.HumanoidStateType.Landed then
			jumpCount = 0
		end
	end))
	table.insert(characterConnections, humanoid.Died:Connect(function()
		sprintHeld = false
		stopDashPose()
	end))

	humanoid.WalkSpeed = sprintHeld and SPRINT_WALK_SPEED or activeNormalWalkSpeed
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		sprintHeld = true
		if activeHumanoid then
			activeHumanoid.WalkSpeed = SPRINT_WALK_SPEED
		end
	elseif input.KeyCode == Enum.KeyCode.F and activeDash then
		activeDash()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		sprintHeld = false
		if activeHumanoid and activeHumanoid.Health > 0 then
			activeHumanoid.WalkSpeed = activeNormalWalkSpeed
		end
	end
end)

player.CharacterAdded:Connect(function(character)
	task.spawn(bindCharacter, character)
end)

player.CharacterRemoving:Connect(function(character)
	if character == activeCharacter then
		characterToken += 1
		activeCharacter = nil
		activeHumanoid = nil
		activeDash = nil
		disconnectCharacterConnections()
		stopDashPose()
	end
end)

if player.Character then
	task.spawn(bindCharacter, player.Character)
end
