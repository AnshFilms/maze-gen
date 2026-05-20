-- Discord: ansh_xdd, Roblox: AshhBRuhhh
local SS = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- config
local MAZE_W = 25 -- cells wide
local MAZE_H = 25 -- cells tall
local WALL_THICK = 1
local WALL_HEIGHT = 10
local ANIM_DUR = 1.5 -- rise animation length
local ANIM_STAGGER = 0.01 -- gap between each part tweening
local BASE_Y = 1 -- so floor tiles dont clip into the baseplate

local grid = {} -- cell data (walls, visited flag)
local floorTiles = {} -- refs for colouring the solution later
local generated = false
local mazeFolder = nil

-- player state tracker using metatables
-- tracks timer, completion, best time etc per player
local PlayerData = {}
PlayerData.__index = PlayerData

-- constructor, sets up default state for a new player
function PlayerData.new(player)
	local self = setmetatable({}, PlayerData)
	self.player = player
	self.startTime = nil -- gets set when they enter the maze
	self.finished = false
	self.bestTime = math.huge -- no best time yet
	return self
end

-- called when the player spawns at the maze entrance
function PlayerData:startTimer()
	self.startTime = os.clock()
	self.finished = false
end

-- stops the timer and returns how long they took
-- returns nil if they already finished or never started
function PlayerData:finish()
	if self.finished or not self.startTime then return nil end
	self.finished = true
	local elapsed = os.clock() - self.startTime
	-- update best time if this run was faster
	if elapsed < self.bestTime then
		self.bestTime = elapsed
	end
	return elapsed
end

-- how long theyve been in the maze so far
function PlayerData:getElapsed()
	if not self.startTime then return 0 end
	return os.clock() - self.startTime
end

-- clears the run but keeps best time saved
function PlayerData:reset()
	self.startTime = nil
	self.finished = false
end

-- checks if theyve completed the maze at least once
function PlayerData:getAttempts()
	-- math.huge means they havent finished once yet
	if self.bestTime == math.huge then return 0 end
	return 1
end

local playerStates = {}

-- grid coords -> world pos, centralised so we dont repeat the offset math
local function cellToWorld(x, y, sx, sz)
	local px = (x - MAZE_W / 2 - 0.5) * sx
	local pz = (y - MAZE_H / 2 - 0.5) * sz
	return px, pz
end

-- returns unvisited neighbours with direction info
-- opp is the reverse direction so we can remove the wall from both sides
local function getUnvisited(x, y)
	local out = {}

	if y > 1 and not grid[x][y - 1].visited then -- north
		table.insert(out, { x = x, y = y - 1, dir = "N", opp = "S" })
	end
	if y < MAZE_H and not grid[x][y + 1].visited then -- south
		table.insert(out, { x = x, y = y + 1, dir = "S", opp = "N" })
	end
	if x < MAZE_W and not grid[x + 1][y].visited then -- east
		table.insert(out, { x = x + 1, y = y, dir = "E", opp = "W" })
	end
	if x > 1 and not grid[x - 1][y].visited then -- west
		table.insert(out, { x = x - 1, y = y, dir = "W", opp = "E" })
	end

	return out
end

-- recursive backtracker - picks random neighbour, knocks wall, recurses
-- backtracks on its own when theres nowhere left to go
function carvePassage(x, y)
	grid[x][y].visited = true
	local neighbours = getUnvisited(x, y)

	while #neighbours > 0 do
		local idx = math.random(1, #neighbours)
		local pick = table.remove(neighbours, idx)

		if not grid[pick.x][pick.y].visited then
			grid[x][y].walls[pick.dir] = false -- remove wall from this side
			grid[pick.x][pick.y].walls[pick.opp] = false -- and the other side
			carvePassage(pick.x, pick.y)
		end
	end
end

-- neon pad at the finish cell, touching it = maze complete
local function createGoalZone(pos, parent)
	local pad = Instance.new("Part")
	pad.Name = "GoalZone"
	pad.Anchored = true
	pad.CanCollide = false
	pad.Size = Vector3.new(8, 1, 8)
	pad.Position = pos + Vector3.new(0, BASE_Y + 0.5, 0)
	pad.Material = Enum.Material.Neon
	pad.Color = Color3.fromRGB(0, 255, 100)
	pad.Transparency = 0.3
	pad.Parent = parent

	local light = Instance.new("PointLight") -- glow
	light.Brightness = 2
	light.Range = 16
	light.Color = Color3.fromRGB(0, 255, 100)
	light.Parent = pad

	-- particles so you can spot the goal from far away
	local particles = Instance.new("ParticleEmitter")
	particles.Rate = 15
	particles.Lifetime = NumberRange.new(1, 2)
	particles.Speed = NumberRange.new(2, 5)
	particles.SpreadAngle = Vector2.new(30, 30)
	particles.Color = ColorSequence.new(Color3.fromRGB(0, 255, 100))
	particles.Size = NumberSequence.new(0.5, 0)
	particles.Parent = pad

	return pad
end

-- confetti burst on finish
local function playVictoryEffect(position)
	local emitter = Instance.new("Part")
	emitter.Anchored = true
	emitter.CanCollide = false
	emitter.Transparency = 1
	emitter.Size = Vector3.new(1, 1, 1)
	emitter.Position = position + Vector3.new(0, 5, 0)
	emitter.Parent = workspace

	local confetti = Instance.new("ParticleEmitter")
	confetti.Rate = 0 -- manual emit
	confetti.Lifetime = NumberRange.new(2, 3)
	confetti.Speed = NumberRange.new(10, 20)
	confetti.SpreadAngle = Vector2.new(180, 180)
	confetti.Size = NumberSequence.new(0.3, 0.1)
	confetti.Parent = emitter

	local colors = {
		Color3.fromRGB(255, 50, 50),
		Color3.fromRGB(50, 255, 50),
		Color3.fromRGB(50, 50, 255),
		Color3.fromRGB(255, 255, 50),
	}
	confetti.Color = ColorSequence.new(colors[math.random(1, #colors)])
	confetti:Emit(50) -- one big burst

	task.delay(4, function()
		emitter:Destroy()
	end)
end

-- creates all the physical wall/floor parts from grid data
-- also does the rise-from-ground animation
function buildMaze(folder, template, size)
	local allParts = {}
	local sx, sz = size.X, size.Z

	for x = 1, MAZE_W do
		for y = 1, MAZE_H do
			local px, pz = cellToWorld(x, y, sx, sz)

			local tile = Instance.new("Part")
			tile.Anchored = true
			tile.Size = Vector3.new(sx, 1, sz)
			tile.Material = Enum.Material.Concrete
			tile.Color = Color3.fromRGB(120, 120, 120)
			tile.Position = Vector3.new(px, BASE_Y - WALL_HEIGHT, pz) -- starts underground
			tile.Parent = folder

			floorTiles[x][y] = tile
			table.insert(allParts, tile)

			local cell = grid[x][y]

			-- only doing N and W walls per cell, the S and E sides
			-- belong to the neighbouring cell so we skip them to avoid doubles
			if cell.walls.N then
				local w = template:Clone()
				w.Size = Vector3.new(sx + WALL_THICK, WALL_HEIGHT, WALL_THICK)
				w.Position = Vector3.new(px, BASE_Y + WALL_HEIGHT/2 - WALL_HEIGHT, pz - sz / 2)
				w.Parent = folder
				table.insert(allParts, w)
			end

			if cell.walls.W then
				local w = template:Clone()
				w.Size = Vector3.new(WALL_THICK, WALL_HEIGHT, sz + WALL_THICK)
				w.Position = Vector3.new(px - sx / 2, BASE_Y + WALL_HEIGHT/2 - WALL_HEIGHT, pz)
				w.Parent = folder
				table.insert(allParts, w)
			end
		end
	end

	-- tween everything upward with a stagger so it looks like a wave
	task.spawn(function()
		for _, part in ipairs(allParts) do
			local tween = TweenService:Create(
				part,
				TweenInfo.new(ANIM_DUR, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ Position = part.Position + Vector3.new(0, WALL_HEIGHT, 0) }
			)
			tween:Play()
			task.wait(ANIM_STAGGER)
		end
	end)

	-- south and east border walls
	-- the N/W loop already handles top + left edges
	local totalW = MAZE_W * sx
	local totalH = MAZE_H * sz

	local south = template:Clone()
	south.Size = Vector3.new(totalW + WALL_THICK, WALL_HEIGHT, WALL_THICK)
	south.Position = Vector3.new(0, BASE_Y + WALL_HEIGHT / 2, totalH / 2)
	south.Parent = folder

	local east = template:Clone()
	east.Size = Vector3.new(WALL_THICK, WALL_HEIGHT, totalH + WALL_THICK)
	east.Position = Vector3.new(totalW / 2, BASE_Y + WALL_HEIGHT / 2, 0)
	east.Parent = folder

	-- goal zone
	local endX, endZ = cellToWorld(MAZE_W, MAZE_H, sx, sz)
	local goalPad = createGoalZone(Vector3.new(endX, 0, endZ), folder)

	-- detect player touching the finish pad
	goalPad.Touched:Connect(function(hit)
		local player = Players:GetPlayerFromCharacter(hit.Parent)
		if not player then return end

		local state = playerStates[player]
		if not state or state.finished then return end

		local elapsed = state:finish()
		if not elapsed then return end

		local rounded = math.floor(elapsed * 100) / 100 -- 2 decimal places

		local ls = player:FindFirstChild("leaderstats")
		if ls then
			local timeStat = ls:FindFirstChild("Time")
			if timeStat then timeStat.Value = rounded end
		end

		print(player.Name .. " finished in " .. rounded .. "s")
		playVictoryEffect(hit.Parent:FindFirstChild("HumanoidRootPart").Position)
	end)
end

-- a* solver for finding the shortest path through the maze
-- TODO: could swap this for BFS since all edges cost the same, but a* works fine
function solveMaze(from, to)
	local openSet = {
		{ x = from.x, y = from.y, cost = 0, est = 0, total = 0, prev = nil }
	}
	local visited = {}

	local function dist(a, b) -- manhattan
		return math.abs(a.x - b.x) + math.abs(a.y - b.y)
	end

	local function getFrom(list, pos)
		for _, v in ipairs(list) do
			if v.x == pos.x and v.y == pos.y then return v end
		end
	end

	while #openSet > 0 do
		-- lowest total cost = best candidate
		local best = 1
		for i = 1, #openSet do
			if openSet[i].total < openSet[best].total then best = i end
		end

		local cur = table.remove(openSet, best)

		if cur.x == to.x and cur.y == to.y then
			-- retrace the path backwards
			local path = {}
			while cur do
				table.insert(path, 1, cur)
				cur = cur.prev
			end
			return path
		end

		-- done with this node, dont check it again
		table.insert(visited, cur)

		-- grab passable neighbours (only where theres no wall)
		local cell = grid[cur.x][cur.y]
		local adj = {}
		if not cell.walls.N then table.insert(adj, {x = cur.x, y = cur.y - 1}) end
		if not cell.walls.S then table.insert(adj, {x = cur.x, y = cur.y + 1}) end
		if not cell.walls.E then table.insert(adj, {x = cur.x + 1, y = cur.y}) end
		if not cell.walls.W then table.insert(adj, {x = cur.x - 1, y = cur.y}) end

		for _, pos in ipairs(adj) do
			-- skip already visited nodes
			if not getFrom(visited, pos) then
				local newCost = cur.cost + 1
				local found = getFrom(openSet, pos) -- already queued?

				-- only update if this path is cheaper or its a new node entirely
				if not found or newCost < found.cost then
					local e = dist(pos, to) -- heuristic estimate to goal
					local entry = { x = pos.x, y = pos.y, cost = newCost, est = e, total = newCost + e, prev = cur }

					if not found then
						table.insert(openSet, entry) -- new node
					else
						-- found a shorter route to an existing node
						found.cost = newCost
						found.est = e
						found.total = newCost + e
						found.prev = cur
					end
				end
			end
		end
	end
end

-- colours the solution tiles with a HSV gradient
function showPath(path)
	for i, node in ipairs(path) do
		task.wait(0.05)
		local tile = floorTiles[node.x][node.y]
		if tile then
			-- 0 -> 0.6 hue gives red through green to blue
			tile.Color = Color3.fromHSV((i / #path) * 0.6, 0.8, 1)
		end
	end
end

-- sets up the leaderboard entry for this player
local function setupLeaderstats(player)
	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	ls.Parent = player

	-- Time stat shows their completion time on the scoreboard
	local timeStat = Instance.new("NumberValue")
	timeStat.Name = "Time"
	timeStat.Value = 0
	timeStat.Parent = ls
end

-- teleport player to cell (1,1) facing into the maze
local function spawnPlayerAtStart(player)
	local char = player.Character or player.CharacterAdded:Wait()
	local hrp = char:WaitForChild("HumanoidRootPart")
	local wallTemplate = SS:FindFirstChild("WallTemplate")
	if not wallTemplate then return end

	local sx, sz = wallTemplate.Size.X, wallTemplate.Size.Z
	local startX, startZ = cellToWorld(1, 1, sx, sz)

	-- lookAt so they face east into the first corridor
	local spawnPos = Vector3.new(startX, BASE_Y + 3, startZ)
	local lookAt = Vector3.new(startX + sx, BASE_Y + 3, startZ)
	hrp.CFrame = CFrame.lookAt(spawnPos, lookAt)

	local state = playerStates[player]
	if state then
		state:reset()
		state:startTimer()
	end
end

-- main entry point, generates everything and only runs once
local function generateMaze()
	if generated then return end
	generated = true

	print("generating maze...")

	-- WallTemplate in ServerStorage is what gets cloned for every wall segment
	local wallTemplate = SS:WaitForChild("WallTemplate")

	-- put everything in a folder so its easy to find/cleanup
	local folder = Instance.new("Folder")
	folder.Name = "GeneratedMaze"
	folder.Parent = workspace
	mazeFolder = folder

	-- init grid, every cell starts fully walled off
	for x = 1, MAZE_W do
		grid[x] = {}
		floorTiles[x] = {}
		for y = 1, MAZE_H do
			grid[x][y] = { visited = false, walls = { N = true, S = true, E = true, W = true } }
		end
	end

	-- carve first, then build the actual parts from the result
	carvePassage(1, 1)
	buildMaze(folder, wallTemplate, wallTemplate.Size)

	-- solve after the animation finishes so you can see the solution draw out
	task.spawn(function()
		task.wait(ANIM_DUR)
		local path = solveMaze({x = 1, y = 1}, {x = MAZE_W, y = MAZE_H})
		if path then
			print("solved in " .. #path .. " steps")
			showPath(path)
		end
	end)
end

-- called for each player that joins
local function onPlayerAdded(player)
	setupLeaderstats(player)
	playerStates[player] = PlayerData.new(player)

	-- re-teleport to start every time they respawn
	player.CharacterAdded:Connect(function()
		if generated then
			task.wait(0.5) -- let character load in
			spawnPlayerAtStart(player)
		end
	end)

	-- first player to join triggers the maze build
	if not generated then
		generateMaze()
		task.wait(ANIM_DUR + 0.5) -- wait for rise anim to finish
		spawnPlayerAtStart(player)
	end
end

-- clean up state so we dont hold refs to players that left
local function onPlayerRemoving(player)
	playerStates[player] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- studio edge case, players might already be in
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end
