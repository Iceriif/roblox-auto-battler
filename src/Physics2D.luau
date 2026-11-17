--!strict
-- Minimal 2D (X/Y plane) collision for the arena fight.
-- Level geometry is a list of axis-aligned rects. Fighters are boxes whose origin is their
-- bottom-center (the feet). One-way rects are platforms you can jump up through and land on.

-- Broken: a destroyed platform (Destruction.luau takes it out of the level's list; anything
-- still holding on to it, like the AI's climb target, can check this)
export type Rect = { MinX: number, MinY: number, MaxX: number, MaxY: number, OneWay: boolean, Broken: boolean? }

export type Body = {
	X: number,
	Y: number,
	VX: number,
	VY: number,
	HalfW: number,
	Height: number,
	Grounded: boolean,
	OnOneWay: boolean,
	IgnoreOneWay: boolean, -- set while dropping down through a platform
}

local Physics2D = {}

local EPS = 1e-3

function Physics2D.Rect(minX: number, minY: number, maxX: number, maxY: number, oneWay: boolean?): Rect
	return { MinX = minX, MinY = minY, MaxX = maxX, MaxY = maxY, OneWay = oneWay == true }
end

local function overlaps(r: Rect, minX: number, minY: number, maxX: number, maxY: number): boolean
	return minX < r.MaxX - EPS and maxX > r.MinX + EPS and minY < r.MaxY - EPS and maxY > r.MinY + EPS
end

function Physics2D.BoxHitsSolid(minX: number, minY: number, maxX: number, maxY: number, rects: { Rect }): boolean
	for _, r in rects do
		if not r.OneWay and overlaps(r, minX, minY, maxX, maxY) then
			return true
		end
	end
	return false
end

function Physics2D.BoxesOverlap(a: Body, minX: number, minY: number, maxX: number, maxY: number): boolean
	return a.X - a.HalfW < maxX and a.X + a.HalfW > minX and a.Y < maxY and a.Y + a.Height > minY
end

-- Height of the highest surface (solid or platform) at or below (x, y).
function Physics2D.GroundBelow(x: number, y: number, rects: { Rect }): number
	local best = -math.huge
	for _, r in rects do
		if x > r.MinX and x < r.MaxX and r.MaxY <= y + 0.05 and r.MaxY > best then
			best = r.MaxY
		end
	end
	return if best == -math.huge then y else best
end

-- One move, resolving X then Y against the level (only overlaps at the end are seen: a body
-- moving further than a wall is thick in one go would pass it; Step splits fast moves up).
local function stepOnce(body: Body, rects: { Rect }, dt: number)
	local dirX = body.VX
	local x = body.X + body.VX * dt
	for _, r in rects do
		if not r.OneWay and overlaps(r, x - body.HalfW, body.Y, x + body.HalfW, body.Y + body.Height) then
			if dirX > 0 then
				x = r.MinX - body.HalfW
			elseif dirX < 0 then
				x = r.MaxX + body.HalfW
			end
			body.VX = 0
		end
	end
	body.X = x

	local dirY = body.VY
	local y = body.Y + body.VY * dt
	local minX, maxX = body.X - body.HalfW, body.X + body.HalfW
	body.Grounded = false
	body.OnOneWay = false
	for _, r in rects do
		if r.OneWay then
			if
				not body.IgnoreOneWay
				and dirY <= 0
				and body.Y >= r.MaxY - 0.05
				and y <= r.MaxY
				and minX < r.MaxX
				and maxX > r.MinX
			then
				y = r.MaxY
				body.VY = 0
				body.Grounded = true
				body.OnOneWay = true
			end
		elseif overlaps(r, minX, y, maxX, y + body.Height) then
			if dirY <= 0 then
				y = r.MaxY
				body.Grounded = true
			else
				y = r.MinY - body.Height
			end
			body.VY = 0
		end
	end
	body.Y = y
end

-- the furthest a body moves in one slice (the arena's walls and floor are 2 thick)
local MAX_SLICE = 0.8

-- Moves the body by its velocity, resolving X then Y against the level. A fast move (a big
-- knockback, a dash) goes in slices no longer than MAX_SLICE, so it can't skip through a wall or
-- the floor (it did, rarely: a fighter ended up outside the arena).
function Physics2D.Step(body: Body, rects: { Rect }, dt: number)
	local reach = math.max(math.abs(body.VX), math.abs(body.VY)) * dt
	local n = math.min(math.ceil(reach / MAX_SLICE), 40)
	if n <= 1 then
		stepOnce(body, rects, dt)
		return
	end
	local grounded, onOneWay = false, false
	local slice = dt / n
	for _ = 1, n do
		stepOnce(body, rects, slice)
		-- (once landed it stays landed this frame: the later slices just slide along)
		grounded = grounded or body.Grounded
		onOneWay = onOneWay or body.OnOneWay
	end
	body.Grounded = grounded
	body.OnOneWay = onOneWay
end

-- Returns the fraction (0..1) along the segment where it first enters the box, or nil.
function Physics2D.SegmentBox(
	x0: number,
	y0: number,
	x1: number,
	y1: number,
	minX: number,
	minY: number,
	maxX: number,
	maxY: number
): number?
	local tMin, tMax = 0, 1
	local dx, dy = x1 - x0, y1 - y0

	if math.abs(dx) < 1e-9 then
		if x0 < minX or x0 > maxX then
			return nil
		end
	else
		local t1, t2 = (minX - x0) / dx, (maxX - x0) / dx
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		tMin, tMax = math.max(tMin, t1), math.min(tMax, t2)
		if tMin > tMax then
			return nil
		end
	end

	if math.abs(dy) < 1e-9 then
		if y0 < minY or y0 > maxY then
			return nil
		end
	else
		local t1, t2 = (minY - y0) / dy, (maxY - y0) / dy
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		tMin, tMax = math.max(tMin, t1), math.min(tMax, t2)
		if tMin > tMax then
			return nil
		end
	end

	return tMin
end

-- Nearest hit of a segment against any level rect (platforms block shots too), and the rect.
function Physics2D.RaycastRect(x0: number, y0: number, x1: number, y1: number, rects: { Rect }): (number?, Rect?)
	local best: number?, hit: Rect? = nil, nil
	for _, r in rects do
		local t = Physics2D.SegmentBox(x0, y0, x1, y1, r.MinX, r.MinY, r.MaxX, r.MaxY)
		if t and (best == nil or t < best) then
			best, hit = t, r
		end
	end
	return best, hit
end

-- Nearest hit of a segment against any level rect (platforms block shots too).
function Physics2D.Raycast(x0: number, y0: number, x1: number, y1: number, rects: { Rect }): number?
	return (Physics2D.RaycastRect(x0, y0, x1, y1, rects))
end

-- True when only jump-through platforms (the breakable ones) or nothing stand between the two
-- points: shooters fire through those, chipping the platform until it shatters.
function Physics2D.ShotClear(x0: number, y0: number, x1: number, y1: number, rects: { Rect }): boolean
	for _, r in rects do
		if not r.OneWay and Physics2D.SegmentBox(x0, y0, x1, y1, r.MinX, r.MinY, r.MaxX, r.MaxY) then
			return false
		end
	end
	return true
end

return Physics2D
