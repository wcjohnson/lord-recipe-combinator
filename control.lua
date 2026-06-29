local events = require("lib.core.event")
local strace = require("lib.core.strace")
local tlib = require("lib.core.table")
local scheduler = require("lib.core.scheduler")

local EMPTY = tlib.EMPTY
strace.set_handler(strace.standard_log_handler)

local gui = require("lualib.gui")
local circuit = require("lualib.circuit")
local disable_picker_dollies = require("lualib.disable_picker_dollies")
local myutil = require("lualib.util")

circuit.init()

events.bind(
	"on_load",
	function() disable_picker_dollies.disable_picker_dollies() end
)

local function on_gui_opened(ev)
	if ev.gui_type ~= defines.gui_type.entity then return end
	local entity = ev.entity
	local player = game.get_player(ev.player_index)
	if not player then return end

	-- Cribbed from Cybersyn combinator
	if
		entity.valid
		and myutil.name_or_ghost_name(entity) == "recipe-combinator-main"
	then
		gui.open(ev.player_index, entity)
	elseif player.gui.screen[gui.WINDOW_ID] then
		gui.close(ev.player_index)
		return
	end
end

local function on_gui_closed(ev)
	-- TODO: this only supports closing of one window; need to support sub-windows for pickers etc.
	if not ev.element then return end
	if ev.element.name ~= gui.WINDOW_ID then return end
	local player = game.get_player(ev.player_index)
	if not player then return end
	if player.gui.screen[gui.WINDOW_ID] then gui.close(ev.player_index) end
end

local function rebuild_all_combinators(force)
	local _, things = remote.call(
		"things-metadata-v1",
		"get_things",
		{ name = "recipe-combinator-main" }
	) --[[@as nil, things.ThingShortSummary[] ]]
	for _, thing in ipairs(things) do
		if thing.entity and thing.entity.valid then
			circuit.rebuild_combinator(thing.entity)
		end
	end
end

scheduler.register_handler("rebuild_all_combinators", rebuild_all_combinators)

local function schedule_rebuild_all_combinators(ev)
	scheduler.after(1, "rebuild_all_combinators")
end

events.bind(defines.events.on_gui_opened, on_gui_opened)
events.bind(defines.events.on_gui_closed, on_gui_closed)
events.bind(
	defines.events.on_research_finished,
	schedule_rebuild_all_combinators
)
events.bind(
	defines.events.on_technology_effects_reset,
	schedule_rebuild_all_combinators
)

remote.add_interface("lord-recipe-combinator", {
	initial_tags = function(entity) return circuit.DEFAULT_ROLLUP end,
})

events.bind(
	"lord-recipe-combinator-on_initialized",
	---@param thing things.EventData.on_initialized
	function(thing)
		if thing.status == "real" then
			circuit.rebuild_combinator(thing.entity --[[@as LuaEntity]])
		end
	end
)

---@param thing_id int64?
local function destroy_children(thing_id)
	if not thing_id then return end
	local n_destroyed = 0
	local _, children =
		remote.call("things", "get_transient_data", thing_id, "children")
	for i, child in ipairs(children or EMPTY) do
		if child.valid then
			child.destroy()
			n_destroyed = n_destroyed + 1
		end
	end
	strace.debug(
		"lord-recipe-combinator.destroy_children destroyed",
		n_destroyed,
		"/",
		#children,
		"children of thing",
		thing_id
	)
end

local function close_windows()
	-- Close players' windows
	for _, player in pairs(game.players) do
		if player.gui.screen[gui.WINDOW_ID] then gui.close(player.index, true) end
	end
end

events.bind(
	"lord-recipe-combinator-on_status",
	---@param ev things.EventData.on_status
	function(ev)
		local old_status = ev.old_status
		local new_status = ev.new_status

		if new_status == "destroyed" then
			destroy_children(ev.thing.id)
			close_windows()
			return
		end

		-- Unlink if void or ghosted
		if new_status == "void" or new_status == "ghost" then
			destroy_children(ev.thing.id)
			close_windows()
		end

		-- Link if real
		if new_status == "real" then
			circuit.rebuild_combinator(ev.thing.entity --[[@as LuaEntity]])
		end
	end
)

events.bind(
	"lord-recipe-combinator-on_tags_changed",
	---@param ev things.EventData.on_tags_changed
	function(ev)
		local entity = ev.thing.entity
		if entity and entity.valid then circuit.rebuild_combinator(entity) end
	end
)
