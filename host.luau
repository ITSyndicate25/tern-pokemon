--!strict
-- vscode-pokemon ported to Tern: a pane that shows Pokemon walking on a
-- themed scene, spawned from jakobhoeg/vscode-pokemon's sprites.
--
-- The scene is one image (beach/forest/castle background) with absolute rows
-- of sprites over it and the theme's foreground image last, so feet hide
-- behind the sand. Each Pokemon is a row whose flex spacers place its sprite
-- at x; a 100 ms tick walks it like the extension's state machine does.
-- Sprite GIFs and backgrounds are fetched once from the extension's GitHub
-- repo, cached as files under the plugin's data directory, and replayed into
-- each pane's blob store so later panes and restarts need no network.

local ui = tern.ui

type Pokemon = {
	name: string,
	label: string,
	id: number,
	gen: number,
	shiny: boolean, -- shiny sprites exist for it
	left: boolean, -- walk_left sprites exist for it
	size: number, -- native sprite size in px (32 or 64)
}

type Mon = {
	name: string,
	shiny: boolean,
	x: number, -- left edge, fraction of the stage width
	dir: number, -- -1 walking left, 1 walking right
	moving: boolean,
	hold: number, -- ticks left in the current state
	speed: number, -- px per tick while walking
	heart_until: number, -- ms clock deadline of the pet heart
}

type Picker = {
	q: string,
	sel: string?,
	matches: { Pokemon },
}

type State = {
	mons: { Mon },
	theme: string, -- beach | forest | castle | none
	day: boolean, -- light background instead of dark
	all_shiny: boolean,
	blobs: { [string]: string }, -- asset url -> blob id sent to this pane
	pending: { [string]: boolean },
	late: { [string]: string }, -- cached assets: url -> mime, sent by the tick
	err: string?,
	picker: Picker?,
	stopped: boolean,
	fit_px: number?, -- the stage's width in pane pixels, for the walk math
}

local POKEMON: { Pokemon } = require("./data/pokemon")

local RAW = "https://raw.githubusercontent.com/jakobhoeg/vscode-pokemon/main/media"

local TICK_MS = 100
local MAX_MONS = 8
local SHINY_ODDS = 8192 -- vscode-pokemon.shinyOdds default
local IDLE_TICKS = 50 -- 5 s at 10 fps, as the extension
local WALK_TICKS = 60
local SPEED_PX = 3 -- px per tick before the 0.7-1.3 spread, as the extension
local MARGIN = 0.02
local EDGE = 0.96
local HEART_MS = 2600
local PX_PER_COL = 8 -- rough cell width, for px speed in pane fraction terms
local SHEET_ROWS = 18 -- under this, the picker fills the pane: the md sheet
-- needs about 14 rows (72px top offset + head + bar + a few rows), and in a
-- picture in picture it would otherwise collapse to its head alone.

-- The scene keeps its 1422x800 ratio, so its height is 56.25% of its width.
-- A pane cell is about 0.59 lines tall, so the full width fits the height
-- while cols <= lines * 3.0; past that the stage is set to whole "ch" units
-- (3.35 per line: 1.7775 x 1.91 lines per ch, rounded down) so the picture
-- letterboxes instead of spilling below the pane.
local WIDE_LINES = 3.0
local FIT_CH_PER_LINE = 3.35
local CELL_PER_CH = 1.12 -- pane cells per "ch", to size walking from the stage

local THEMES = { "beach", "forest", "castle", "none" }
local THEME_SET: { [string]: boolean } = {}
for _, t in THEMES do
	THEME_SET[t] = true
end

local BY_NAME: { [string]: Pokemon } = {}
for _, p in POKEMON do
	BY_NAME[p.name] = p
end

local HEART_URL = RAW .. "/heart.png"

-- A random seed per VM; open panes in the same second still differ by clock.
local seeded = false
local function seed()
	if seeded then
		return
	end
	seeded = true
	pcall(function()
		math.randomseed((os.time() % 1000000000) * 1000 + math.floor((os.clock() % 1) * 1000000))
	end)
end

local function sprite_url(p: Pokemon, shiny: boolean, face: string): string
	local color = if shiny then "shiny" else "default"
	return RAW .. "/gen" .. p.gen .. "/" .. p.name .. "/" .. color .. "_" .. face .. "_8fps.gif"
end

local function bg_url(theme: string, day: boolean, layer: string): string
	local kind = if day then "light" else "dark"
	return RAW .. "/backgrounds/" .. theme .. "/" .. layer .. "-" .. kind .. "-large.png"
end

local function basename(url: string): string
	return url:match("[^/]+$") or url
end

-- The download cache: files under the plugin's data directory, one per asset
-- url (its path below the media root, slashes to underscores). Blob ids are
-- content-addressed, so a pane gets its bytes from here — or the network on
-- the first use — and every later pane replays them without the network.
local CACHE_DIR = tern.plugin.data .. "/cache"

local function cache_path(url: string): string
	return CACHE_DIR .. "/" .. url:sub(#RAW + 2):gsub("/", "_")
end

-- Reads a cached asset's bytes; nil when it is not cached.
local function read_cached(url: string): string?
	local ok, bytes = pcall(tern.fs.read, cache_path(url), 16 * 1024 * 1024)
	if not ok or bytes == "" then
		return nil
	end
	return bytes
end

-- Sends `url`'s bytes through the blob store once per pane, from the file
-- cache or the network; the id lands in `state.blobs` for the view. Cached
-- bytes are not sent from here: a blob frame sent inside a handler is
-- dropped by the pane (its node arrives in the same batch), while one sent
-- from a callback — the tick, or a fetch completion — lands. So the cache
-- read stashes the url in `state.late` and the tick sends it.
local function ensure_blob(state: State, cx: any, url: string, mime: string)
	if state.blobs[url] ~= nil or state.pending[url] or state.late[url] ~= nil then
		return
	end
	state.pending[url] = true
	if read_cached(url) ~= nil then
		state.pending[url] = nil
		state.late[url] = mime
		return
	end
	tern.fetch(url, { timeout_ms = 20000 }, function(r)
		state.pending[url] = nil
		if r.error ~= nil or r.status ~= 200 or r.body == "" then
			state.err = (r.error or ("HTTP " .. tostring(r.status))) .. " · " .. basename(url)
			cx:toast("warn", "Pokémon image fetch failed", basename(url))
			cx:render()
			return
		end
		pcall(tern.fs.write, cache_path(url), r.body)
		state.blobs[url] = cx:blob(r.body, mime)
		state.err = nil
		cx:render()
	end)
end

local function ensure_scene(state: State, cx: any)
	if state.theme ~= "none" then
		ensure_blob(state, cx, bg_url(state.theme, state.day, "background"), "image/png")
		ensure_blob(state, cx, bg_url(state.theme, state.day, "foreground"), "image/png")
	end
	ensure_blob(state, cx, HEART_URL, "image/png")
end

local function desired_face(m: Mon): string
	local p = BY_NAME[m.name]
	if not m.moving then
		return "idle"
	end
	if m.dir < 0 and p.left then
		return "walk_left"
	end
	return "walk"
end

local function load_face(state: State, cx: any, m: Mon, face: string)
	local p = BY_NAME[m.name]
	if p ~= nil then
		ensure_blob(state, cx, sprite_url(p, m.shiny, face), "image/gif")
	end
end

local function load_mon(state: State, cx: any, m: Mon)
	load_face(state, cx, m, "idle")
	if m.moving then
		load_face(state, cx, m, desired_face(m))
	end
end

local function new_mon(p: Pokemon): Mon
	return {
		name = p.name,
		shiny = false,
		x = 0.15 + math.random() * 0.7,
		dir = if math.random(2) == 1 then -1 else 1,
		moving = false,
		hold = 20 + math.random(30),
		speed = 0,
		heart_until = 0,
	}
end

local function spawn(state: State, cx: any, p: Pokemon)
	if #state.mons >= MAX_MONS then
		cx:toast("info", "Pokémon", "Up to " .. MAX_MONS .. " Pokemon in one pane")
		return
	end
	local m = new_mon(p)
	m.shiny = p.shiny and (state.all_shiny or math.random(SHINY_ODDS) == 1)
	table.insert(state.mons, m)
	load_mon(state, cx, m)
end

local function spawn_random(state: State, cx: any)
	spawn(state, cx, POKEMON[math.random(#POKEMON)])
end

local function remove_last(state: State, cx: any)
	if #state.mons == 0 then
		state.stopped = true
		cx:exit(0)
		return
	end
	table.remove(state.mons)
end

local function shuffle(state: State, cx: any)
	for _, m in state.mons do
		local p = POKEMON[math.random(#POKEMON)]
		m.name = p.name
		m.shiny = p.shiny and (state.all_shiny or math.random(SHINY_ODDS) == 1)
		m.moving = false
		m.hold = 20 + math.random(30)
		m.heart_until = 0
		load_mon(state, cx, m)
	end
end

local function set_shiny(state: State, cx: any, on: boolean)
	state.all_shiny = on
	for _, m in state.mons do
		local p = BY_NAME[m.name]
		m.shiny = on and p.shiny
		load_mon(state, cx, m)
	end
end

local function cycle_theme(state: State, cx: any)
	local i = 1
	for n, t in THEMES do
		if t == state.theme then
			i = n
		end
	end
	state.theme = THEMES[i % #THEMES + 1]
	ensure_scene(state, cx)
end

-- Picker rows: every species whose label or directory name contains the query.
local function filter_pokemon(q: string): { Pokemon }
	local out: { Pokemon } = {}
	local needle = q:lower()
	for _, p in POKEMON do
		if needle == "" or (p.label .. " " .. p.name):lower():find(needle, 1, true) ~= nil then
			table.insert(out, p)
		end
	end
	return out
end

local function open_picker(state: State)
	state.picker = { q = "", sel = POKEMON[1].name, matches = filter_pokemon("") }
end

--------------------------------------------------------------------- view --

local function button(name: string, act: string, tip: string, tone: string?): any
	local n = ui.node("icon", { name = name, role = "btn", title = tip })
	local p: { [string]: any } = n.p or {}
	p.actions = { click = act }
	if tone ~= nil then
		p.tone = tone
	end
	n.p = p
	return n
end

local function mon_row(state: State, m: Mon, i: number): any
	local p = BY_NAME[m.name]
	local face = desired_face(m)
	local blob = state.blobs[sprite_url(p, m.shiny, face)] or state.blobs[sprite_url(p, m.shiny, "idle")]
	local size = p.size * 2 -- the extension's "medium": 2x the native sprite
	local flip = m.moving and m.dir < 0 and not p.left
	local sprite = ui.node("image", {
		blob = blob,
		alt = p.label,
		role = if flip then "sprite-flip" else "sprite",
		w = size,
		h = size,
		key = "s",
		title = p.label .. " #" .. p.id,
		actions = { click = "pet=" .. i },
	})
	local body: { any } = {}
	if m.heart_until > tern.now() then
		table.insert(body, ui.node("image", {
			blob = state.blobs[HEART_URL],
			alt = "heart",
			role = "heart",
			w = 30,
			h = 32,
			key = "h",
		}))
	end
	table.insert(body, sprite)
	-- The sprite's own click action replaces image zoom; the row takes no
	-- pointer, so rows of lower Pokemon do not swallow clicks aimed at them.
	return ui.node("row", { role = "mon", key = "mon-" .. i }, {
		ui.node("spacer", { key = "l", grow = math.max(0.001, m.x) }),
		ui.node("col", { key = "c" }, body),
		ui.node("spacer", { key = "r", grow = math.max(0.001, 1 - m.x) }),
	})
end

local function scene(state: State, ch: number): any
	local children: { any } = {}
	if state.theme ~= "none" then
		table.insert(children, ui.node("image", {
			blob = state.blobs[bg_url(state.theme, state.day, "background")],
			alt = state.theme .. " background",
			role = "scene",
			key = "bg",
		}))
	end
	for i, m in state.mons do
		table.insert(children, mon_row(state, m, i))
	end
	if state.theme ~= "none" then
		table.insert(children, ui.node("image", {
			blob = state.blobs[bg_url(state.theme, state.day, "foreground")],
			alt = state.theme .. " foreground",
			role = "scene-fg",
			key = "fg",
		}))
	end
	-- Two boxes: the stage carries the width — the picture's columns in "ch"
	-- when the pane is too short, else the whole pane (1 = 100% of it) — and
	-- the frame keeps the picture's 56.25% ratio off that width. The width is
	-- set here because CSS alone cannot know how many lines the pane has.
	-- Both bounds force it, since a flex parent would stretch or shrink it
	-- otherwise.
	local p: { [string]: any } = { role = "stage-" .. state.theme, key = "stage" }
	local w: any = if ch > 0 then ch .. "ch" else 1
	p.min = { w = w }
	p.max = { w = w }
	local stage = ui.node("col", p, {
		ui.node("col", { role = "scene-frame", key = "frame" }, children),
	})
	return ui.col({ stage })
end

local function dock(state: State): any
	local kids: { any } = {
		button("plus", "pick", "Add a Pokémon (n)"),
		button("swap", "shuffle", "Shuffle all (r)"),
		button("trash", "remove", "Remove the last one (x)"),
		button("sparkle", "shiny", "Shiny (s)", if state.all_shiny then "warning" else nil),
		button("image", "theme", "Scene: " .. state.theme .. " (t)"),
		button(if state.day then "sun" else "moon", "daylight", if state.day then "Light background (d)" else "Dark background (d)"),
	}
	if state.err ~= nil then
		table.insert(kids, button("revert", "retry", "Retry failed images: " .. state.err, "error"))
	end
	local label
	if #state.mons == 0 then
		label = "empty — n adds one"
	elseif #state.mons == 1 then
		local p = BY_NAME[state.mons[1].name]
		label = p.label .. " #" .. p.id .. (if state.mons[1].shiny then " ✦" else "")
	else
		label = #state.mons .. " Pokémon"
	end
	table.insert(kids, ui.text(ui.span(label, "muted")))
	return ui.col({ ui.row(kids) })
end

-- The stage's width in "ch" when the pane is too short for the picture at
-- full width; 0 means it fits, and the stage then fills the pane's width.
-- The dock takes the pane's last line.
local function stage_ch(cx: any): number
	local lines = math.max(1, cx.rows - 1)
	if cx.cols <= lines * WIDE_LINES then
		return 0
	end
	return math.max(6, math.floor(lines * FIT_CH_PER_LINE))
end

local function picker_layer(state: State, cx: any): any
	local pk = state.picker :: Picker
	local items: { any } = {}
	local order: { any } = {}
	for _, p in pk.matches do
		table.insert(items, {
			id = p.name,
			label = p.label,
			detail = "#" .. p.id .. " · gen " .. p.gen,
		})
		table.insert(order, p.name)
	end
	return ui.col({
		ui.node("picker", {
			key = "picker",
			-- md is top-centered and leaves 72px above itself; a short pane
			-- (a picture in picture) would clip it to the head. screen fills
			-- the pane instead, and its default preview pane would waste the
			-- little room there is, so it is off.
			size = if cx.rows < SHEET_ROWS then "screen" else "md",
			preview = "none",
			title = "Add a Pokémon",
			noun = "Pokémon",
			query = pk.q,
			items = items,
			order = order,
			selected = pk.sel,
			total = #POKEMON,
			empty = { ui.span("No Pokémon match", "muted") },
			actions = {
				{ id = "close", label = "Cancel", keys = { "esc" } },
				{ id = "spawn", label = "Spawn", keys = { "enter" }, primary = true },
			},
		}),
	})
end

--------------------------------------------------------------------- loop --

-- The block's pane still runs; the worker drops it when the block ended.
local function alive(cx: any): boolean
	for _, p in tern.pane.list() do
		if p.pane == cx.pane then
			return true
		end
	end
	return false
end

local function start_loop(state: State, cx: any)
	if state.stopped then
		return
	end
	tern.timer(TICK_MS, function()
		if state.stopped or not alive(cx) then
			state.stopped = true
			return
		end
		local now = tern.now()
		local changed = false
		local width = state.fit_px or math.max(1, cx.cols) * PX_PER_COL
		-- Blob sends for cached assets: a frame sent inside a handler is
		-- dropped, one sent from here lands (like a fetch completion).
		if next(state.late) ~= nil then
			local late = state.late
			state.late = {}
			for url, mime in late do
				local bytes = read_cached(url)
				if bytes ~= nil then
					state.blobs[url] = cx:blob(bytes, mime)
					changed = true
				end
			end
		end
		for _, m in state.mons do
			if m.heart_until ~= 0 and now >= m.heart_until then
				m.heart_until = 0
				changed = true
			end
			-- The picker is modal: the walk pauses while it is open.
			if state.picker == nil then
				local p = BY_NAME[m.name]
				if m.moving then
					m.x = m.x + m.dir * m.speed / width
					local sprite_frac = (p.size * 2) / width
					local stop = false
					if m.x <= MARGIN then
						m.x = MARGIN
						stop = true
					elseif m.x >= EDGE - sprite_frac then
						m.x = math.max(MARGIN, EDGE - sprite_frac)
						stop = true
					elseif math.random() < 0.01 then
						stop = true
					end
					m.hold = m.hold - 1
					if m.hold <= 0 then
						stop = true
					end
					if stop then
						m.moving = false
						m.hold = IDLE_TICKS + math.random(30)
					end
					changed = true
				elseif m.hold > 0 then
					m.hold = m.hold - 1
					if m.hold == 0 then
						m.moving = true
						local wall = (p.size * 2) / width
						if m.x <= MARGIN then
							m.dir = 1 -- at a wall, walk away from it
						elseif m.x >= EDGE - wall then
							m.dir = -1
						else
							m.dir = if math.random(2) == 1 then -1 else 1
						end
						m.hold = WALK_TICKS
						m.speed = SPEED_PX * (0.7 + math.random() * 0.6)
						load_face(state, cx, m, desired_face(m))
						changed = true
					end
				end
			end
		end
		if changed then
			cx:render()
		end
		start_loop(state, cx)
	end)
end

------------------------------------------------------------------- block --

local function picker_key(state: State, k: any, cx: any): boolean
	local pk = state.picker :: Picker
	local function refilter()
		pk.matches = filter_pokemon(pk.q)
		pk.sel = if pk.matches[1] ~= nil then pk.matches[1].name else nil
	end
	if k.name == "escape" then
		state.picker = nil
		return true
	end
	if k.name == "enter" then
		local p = (if pk.sel ~= nil then BY_NAME[pk.sel] else nil) or pk.matches[1]
		if p ~= nil then
			spawn(state, cx, p)
			state.picker = nil
		end
		return true
	end
	if k.name == "up" or k.name == "down" then
		local idx = 0
		for i, p in pk.matches do
			if p.name == pk.sel then
				idx = i
				break
			end
		end
		idx = if k.name == "down" then math.min(idx + 1, #pk.matches) else math.max(idx - 1, 1)
		if pk.matches[idx] ~= nil then
			pk.sel = pk.matches[idx].name
		end
		return true
	end
	if k.name == "backspace" then
		if #pk.q > 0 then
			pk.q = pk.q:sub(1, #pk.q - 1)
			refilter()
		end
		return true
	end
	if k.text ~= nil and k.text ~= "" and not (k.ctrl or k.alt or k.meta) then
		pk.q = pk.q .. k.text
		refilter()
		return true
	end
	return false
end

tern.block.define("pokemon", {
	init = function(cx, args, saved)
		seed()
		local state: State = {
			mons = {},
			theme = "beach",
			day = false,
			all_shiny = false,
			blobs = {},
			pending = {},
			late = {},
			err = nil,
			picker = nil,
			stopped = false,
			fit_px = nil,
		}
		pcall(tern.fs.mkdir, CACHE_DIR)
		pcall(tern.kv.set, "urls", nil) -- the pre-file-cache kv key, cleared on sight
		if type(saved) == "table" then
			if type(saved.theme) == "string" and THEME_SET[saved.theme] then
				state.theme = saved.theme
			end
			state.day = saved.day == true
			state.all_shiny = saved.shiny == true
			if type(saved.mons) == "table" then
				for _, sm in saved.mons do
					local p = if type(sm) == "table" and type(sm.name) == "string" then BY_NAME[sm.name] else nil
					if p ~= nil then
						local m = new_mon(p)
						m.shiny = sm.s == true and p.shiny
						if type(sm.x) == "number" then
							m.x = math.clamp(sm.x, MARGIN, EDGE)
						end
						m.dir = if sm.d == -1 then -1 else 1
						m.hold = 20 + math.random(30)
						table.insert(state.mons, m)
					end
				end
			end
		end
		if #state.mons == 0 then
			spawn(state, cx, BY_NAME[args[1] or ""] or POKEMON[math.random(#POKEMON)])
		end
		ensure_scene(state, cx)
		for _, m in state.mons do
			load_mon(state, cx, m)
		end
		start_loop(state, cx)
		return state
	end,

	title = function(state)
		if #state.mons == 0 then
			return "Pokémon"
		end
		local first = BY_NAME[state.mons[1].name]
		local label = first.label .. (if state.mons[1].shiny then " ✦" else "")
		if #state.mons > 1 then
			return "Pokémon — " .. label .. " +" .. (#state.mons - 1)
		end
		return "Pokémon — " .. label
	end,

	view = function(state, cx)
		local ch = stage_ch(cx)
		local cells = if ch > 0 then ch / CELL_PER_CH else cx.cols
		state.fit_px = math.max(1, cells) * PX_PER_COL
		local view: any = { main = scene(state, ch) }
		view.dock = dock(state)
		if state.picker ~= nil then
			view.layer = picker_layer(state, cx)
		end
		return view
	end,

	key = function(state, k, cx)
		if state.picker ~= nil then
			return picker_key(state, k, cx)
		end
		if k.ctrl or k.alt or k.meta then
			return false
		end
		local n = k.name
		if n == "n" or k.text == "+" then
			spawn_random(state, cx)
			return true
		elseif n == "r" then
			shuffle(state, cx)
			return true
		elseif n == "s" then
			set_shiny(state, cx, not state.all_shiny)
			return true
		elseif n == "t" then
			cycle_theme(state, cx)
			return true
		elseif n == "d" then
			state.day = not state.day
			ensure_scene(state, cx)
			return true
		elseif n == "x" or n == "delete" then
			remove_last(state, cx)
			return true
		end
		return false
	end,

	event = function(state, ev, cx)
		if ev.ev == "action" then
			local act = ev.act
			if act == "pet" then
				local i = ev.value ~= nil and tonumber(ev.value) or nil
				if i ~= nil and state.mons[i] ~= nil then
					state.mons[i].heart_until = tern.now() + HEART_MS
				end
			elseif act == "pick" then
				-- The dock sits outside the picker's layer, so its + toggles.
				if state.picker ~= nil then
					state.picker = nil
				else
					open_picker(state)
				end
			elseif act == "shuffle" then
				shuffle(state, cx)
			elseif act == "remove" then
				remove_last(state, cx)
			elseif act == "shiny" then
				set_shiny(state, cx, not state.all_shiny)
			elseif act == "theme" then
				cycle_theme(state, cx)
			elseif act == "daylight" then
				state.day = not state.day
				ensure_scene(state, cx)
			elseif act == "retry" and state.err ~= nil then
				state.err = nil
				-- Drop the cached files this pane used, so a bad download or a
				-- truncated write cannot stick; the panes still showing good
				-- blobs keep them.
				for url in state.blobs do
					pcall(tern.fs.remove, cache_path(url))
				end
				state.blobs = {}
				state.pending = {}
				state.late = {}
				ensure_scene(state, cx)
				for _, m in state.mons do
					load_mon(state, cx, m)
				end
			elseif state.picker ~= nil then
				if act == "close" then
					state.picker = nil
				elseif act == "spawn" then
					local pk = state.picker :: Picker
					local p = if pk.sel ~= nil then BY_NAME[pk.sel] else nil
					if p ~= nil then
						spawn(state, cx, p)
						state.picker = nil
					end
				end
			end
		elseif ev.ev == "select" and state.picker ~= nil then
			state.picker.sel = ev.item
		elseif ev.ev == "activate" and state.picker ~= nil then
			local p = BY_NAME[ev.item]
			if p ~= nil then
				spawn(state, cx, p)
			end
			state.picker = nil
		end
	end,

	save = function(state)
		local mons: { any } = {}
		for i, m in state.mons do
			mons[i] = { name = m.name, s = m.shiny, x = m.x, d = m.dir, mv = m.moving }
		end
		return {
			v = 1,
			theme = state.theme,
			day = state.day,
			shiny = state.all_shiny,
			mons = mons,
		}
	end,
})
