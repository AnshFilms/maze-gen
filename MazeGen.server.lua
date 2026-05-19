local SS = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

-- maze config stuff
local MAZE_W = 25 -- grid width in cells
local MAZE_H = 25 -- grid height
local WALL_THICK = 1 -- how thick each wall part is
local WALL_HEIGHT = 10 -- wall height in studs
local ANIM_DUR = 1.5 -- how long each piece takes to rise
local ANIM_STAGGER = 0.01 -- delay between each part animating
local BASE_Y = 1 -- offset so floor doesnt z-fight with baseplate

local grid = {} -- stores all the cell data (walls, visited, etc)
local floorTiles = {} -- keep track of floor parts for coloring the solution later
local generated = false

-- checks all 4 directions and returns any neighbours that havent been carved yet
-- each entry has the grid coords, the direction label, and the opposite direction
-- opposite is needed so we can remove the wall from the other cells side too
local function getUnvisited(x, y)
	local out = {}

	-- check north (make sure we're not at the top edge and it hasnt been visited)
	if y > 1 and not grid[x][y - 1].visited then
		table.insert(out, { x = x, y = y - 1, dir = "N", opp = "S" })
	end
	-- check south (same idea but bottom edge)
	if y < MAZE_H and not grid[x][y + 1].visited then
		table.insert(out, { x = x, y = y + 1, dir = "S", opp = "N" })
	end
	-- check east (right edge)
	if x < MAZE_W and not grid[x + 1][y].visited then
		table.insert(out, { x = x + 1, y = y, dir = "E", opp = "W" })
	end
	-- check west (left edge)
	if x > 1 and not grid[x - 1][y].visited then
		table.insert(out, { x = x - 1, y = y, dir = "W", opp = "E" })
	end

	return out
end

-- recursive backtracker algo
-- picks a random unvisited neighbour, removes the wall, then recurses into it
-- when it hits a dead end it backtracks automatically bc of the recursion
function carvePassage(x, y)
	grid[x][y].visited = true
	local neighbours = getUnvisited(x, y)

	-- keep going as long as theres somewhere to go
	while #neighbours > 0 do
		-- pick one at random and pull it out of the list
		local idx = math.random(1, #neighbours)
		local pick = table.remove(neighbours, idx)

		if not grid[pick.x][pick.y].visited then
			-- knock down wall on both sides so theres a passage between them
			grid[x][y].walls[pick.dir] = false
			grid[pick.x][pick.y].walls[pick.opp] = false
			-- recurse into the picked cell
			carvePassage(pick.x, pick.y)
		end
	end
end

-- takes the grid data and actually creates parts in the workspace
-- also handles the rising animation where everything tweens up
function buildMaze(folder, template, size)
	local allParts = {} -- collect every part so we can animate them all
	local sx, sz = size.X, size.Z -- cell dimensions from the template

	for x = 1, MAZE_W do
		for y = 1, MAZE_H do
			-- figure out world position from grid coords
			-- centers the whole maze around origin
			local px = (x - MAZE_W / 2 - 0.5) * sx
			local pz = (y - MAZE_H / 2 - 0.5) * sz

			-- floor tile for this cell
			local tile = Instance.new("Part")
			tile.Anchored = true
			tile.Size = Vector3.new(sx, 1, sz)
			tile.Material = Enum.Material.Concrete
			tile.Color = Color3.fromRGB(120, 120, 120)
			tile.Position = Vector3.new(px, BASE_Y - WALL_HEIGHT, pz) -- starts below ground for the animation
			tile.Parent = folder

			-- save ref so we can color it later when showing the path
			floorTiles[x][y] = tile
			table.insert(allParts, tile)

			local cell = grid[x][y]

			-- we only need to place N and W walls per cell
			-- the S and E walls come from the neighbouring cells so we skip those
			-- this avoids placing duplicate walls on shared edges
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

	-- tween everything upward to make it look like its growing out of the ground
	-- each part gets a slight delay so it looks like a wave
	task.spawn(function()
		for _, part in ipairs(allParts) do
			local tween = TweenService:Create(
				part,
				TweenInfo.new(ANIM_DUR, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ Position = part.Position + Vector3.new(0, WALL_HEIGHT, 0) }
			)
			tween:Play()
			task.wait(ANIM_STAGGER) -- small gap so they dont all pop up at once
		end
	end)

	-- outer border walls along south and east edges
	-- the N/W loop above handles the top and left borders already
	-- but we still need to close off the bottom and right side
	-- these dont animate, they just pop in at the right height
	local totalW = MAZE_W * sx
	local totalH = MAZE_H * sz

	-- south border
	local south = template:Clone()
	south.Size = Vector3.new(totalW + WALL_THICK, WALL_HEIGHT, WALL_THICK)
	south.Position = Vector3.new(0, BASE_Y + WALL_HEIGHT / 2, totalH / 2)
	south.Parent = folder

	-- east border
	local east = template:Clone()
	east.Size = Vector3.new(WALL_THICK, WALL_HEIGHT, totalH + WALL_THICK)
	east.Position = Vector3.new(totalW / 2, BASE_Y + WALL_HEIGHT / 2, 0)
	east.Parent = folder
end

-- basic a* pathfinder
-- not the most optimized but works fine for a grid this size
-- uses cost (steps taken), est (estimated distance left), and total (cost + est)
function solveMaze(from, to)
	-- start with just the starting cell in the open set
	local openSet = {
		{ x = from.x, y = from.y, cost = 0, est = 0, total = 0, prev = nil }
	}
	local visited = {} -- cells weve already fully processed

	-- manhattan distance for the heuristic
	-- just adds up how far we are in x and y, no diagonals
	local function dist(a, b)
		return math.abs(a.x - b.x) + math.abs(a.y - b.y)
	end

	-- searches a list for a node at the given position
	-- returns the node if found, nil otherwise
	local function getFrom(list, pos)
		for _, v in ipairs(list) do
			if v.x == pos.x and v.y == pos.y then return v end
		end
	end

	while #openSet > 0 do
		-- grab the node with lowest total cost
		-- this is what makes it a* instead of just dijkstra
		local best = 1
		for i = 1, #openSet do
			if openSet[i].total < openSet[best].total then best = i end
		end

		-- pull it out of the open set so we can process it
		local cur = table.remove(openSet, best)

		-- done? if we reached the target, build the path by following prev links
		if cur.x == to.x and cur.y == to.y then
			-- walk backwards through prev links to build the path
			local path = {}
			while cur do
				table.insert(path, 1, cur) -- insert at front so its in the right order
				cur = cur.prev
			end
			return path
		end

		-- mark this cell as done so we dont revisit it
		table.insert(visited, cur)

		-- check which directions we can actually move (no wall in the way)
		local cell = grid[cur.x][cur.y]
		local adj = {} -- neighbouring cells we can reach from here
		if not cell.walls.N then table.insert(adj, {x = cur.x, y = cur.y - 1}) end
		if not cell.walls.S then table.insert(adj, {x = cur.x, y = cur.y + 1}) end
		if not cell.walls.E then table.insert(adj, {x = cur.x + 1, y = cur.y}) end
		if not cell.walls.W then table.insert(adj, {x = cur.x - 1, y = cur.y}) end

		-- go through each reachable neighbour
		for _, pos in ipairs(adj) do
			-- skip if weve already fully processed this cell
			if not getFrom(visited, pos) then
				local newCost = cur.cost + 1 -- each step costs 1
				local found = getFrom(openSet, pos) -- check if this neighbour is already queued

				-- update if we found a cheaper path or its a new node we havent seen
				if not found or newCost < found.cost then
					local e = dist(pos, to) -- estimated remaining distance
					-- pack everything into a node table
					local entry = { x = pos.x, y = pos.y, cost = newCost, est = e, total = newCost + e, prev = cur }

					if not found then
						-- brand new node, add it to open set
						table.insert(openSet, entry)
					else
						-- already in open set but we found a better route to it
						-- so just overwrite the old values
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

-- colors the floor tiles along the solution path
-- goes from red to blue-ish using HSV so it looks like a gradient
-- the delay makes it animate tile by tile which looks cool
function showPath(path)
	for i, node in ipairs(path) do
		task.wait(0.05) -- small delay so you can see it drawing out
		local tile = floorTiles[node.x][node.y] -- grab the floor part at this grid pos
		if tile then
			-- i / #path gives us 0 to 1 as we move along the path
			-- multiply by 0.6 so the hue goes from red through green to blue
			-- saturation at 0.8 and value at 1 keeps it bright
			tile.Color = Color3.fromHSV((i / #path) * 0.6, 0.8, 1)
		end
	end
end

-- main function, only runs once
-- sets up the grid, carves the maze, builds it, then solves it
local function generateMaze()
	if generated then return end -- make sure we dont run this twice
	generated = true

	print("generating maze...")

	-- grab the wall template from server storage
	-- this is what gets cloned for every wall segment
	local wallTemplate = SS:WaitForChild("WallTemplate")

	-- everything goes into a folder to keep the workspace clean
	local folder = Instance.new("Folder")
	folder.Name = "GeneratedMaze"
	folder.Parent = workspace

	-- init the grid with all walls up and nothing visited
	-- each cell starts with N S E W walls all set to true
	for x = 1, MAZE_W do
		grid[x] = {} -- new column
		floorTiles[x] = {} -- matching column for floor part refs
		for y = 1, MAZE_H do
			grid[x][y] = { visited = false, walls = { N = true, S = true, E = true, W = true } }
		end
	end

	-- first carve out the passages in the grid data
	carvePassage(1, 1) -- start from top-left corner
	-- then turn that data into actual parts you can see
	buildMaze(folder, wallTemplate, wallTemplate.Size)

	-- run the solver on a separate thread so it doesnt block
	-- we wait for the build animation to finish first tho
	task.spawn(function()
		task.wait(ANIM_DUR) -- let the rise animation play out
		-- solve from top-left to bottom-right
		local path = solveMaze({x = 1, y = 1}, {x = MAZE_W, y = MAZE_H})
		if path then
			print("path found, " .. #path .. " steps")
			showPath(path) -- light up the tiles along the solution
		end
	end)
end

-- fire off maze generation when the first player joins the server
Players.PlayerAdded:Connect(function()
	if not generated then
		generateMaze()
	end
end)

-- edge case: if a player was already in before the script loaded
-- can happen in studio testing or if the script loads late
if #Players:GetPlayers() > 0 and not generated then
	generateMaze()
end
