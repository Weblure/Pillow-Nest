SUBSYSTEM_DEF(mapping)
	name = "Mapping"
	init_order = INIT_ORDER_MAPPING
	flags = SS_NO_FIRE

	var/list/nuke_tiles = list()
	var/list/nuke_threats = list()

	var/datum/map_config/config
	var/datum/map_config/next_map_config

	var/map_voted = FALSE

	var/list/map_templates = list()

	var/list/planet_templates = list()

	var/list/ruins_templates = list()
	var/list/space_ruins_templates = list()
	var/list/lava_ruins_templates = list()
	var/list/ice_ruins_templates = list()
	var/list/ice_ruins_underground_templates = list()
	var/list/planet_ruins_templates = list()

	var/datum/space_level/isolated_ruins_z //Created on demand during ruin loading.

	var/list/shuttle_templates = list()
	var/list/shelter_templates = list()
	var/list/holodeck_templates = list()

	var/list/areas_in_z = list()

	var/loading_ruins = FALSE
	var/list/turf/unused_turfs = list() //Not actually unused turfs they're unused but reserved for use for whatever requests them. "[zlevel_of_turf]" = list(turfs)
	var/list/datum/turf_reservations //list of turf reservations
	var/list/used_turfs = list() //list of turf = datum/turf_reservation

	var/list/reservation_ready = list()
	var/clearing_reserved_turfs = FALSE

	///All possible biomes in assoc list as type || instance
	var/list/biomes = list()

	// Z-manager stuff
	var/station_start  // should only be used for maploading-related tasks
	var/space_levels_so_far = 0
	var/list/z_list
	var/datum/space_level/transit
	var/datum/space_level/empty_space
	var/num_of_res_levels = 1
	/// True when in the process of adding a new Z-level, global locking
	var/adding_new_zlevel = FALSE


	/// The map zone of the main loaded station, for easy access
	var/datum/map_zone/station_map_zone
	/// List of all map zones
	var/list/map_zones = list()

/datum/controller/subsystem/mapping/New()
	..()
#ifdef FORCE_MAP
	config = load_map_config(FORCE_MAP)
#else
	config = load_map_config(error_if_missing = FALSE)
#endif

/datum/controller/subsystem/mapping/Initialize(timeofday)
	if(initialized)
		return
	if(config.defaulted)
		var/old_config = config
		config = global.config.defaultmap
		if(!config || config.defaulted)
			to_chat(world, SPAN_BOLDANNOUNCE("Unable to load next or default map config, defaulting to Meta Station"))
			config = old_config
	initialize_biomes()
	preloadTemplates()
	loadWorld()
	repopulate_sorted_areas()
	process_teleport_locs() //Sets up the wizard teleport locations

#ifndef LOWMEMORYMODE
	empty_space = add_new_zlevel("Empty Area [space_levels_so_far]")

	// Pick a random away mission.
	if(CONFIG_GET(flag/roundstart_away))
		createRandomZlevel()

	// Load the virtual reality hub
	if(CONFIG_GET(flag/virtual_reality))
		to_chat(world, SPAN_BOLDANNOUNCE("Loading virtual reality..."))
		load_new_z_level("_maps/RandomZLevels/VR/vrhub.dmm", "Virtual Reality Hub")
		to_chat(world, SPAN_BOLDANNOUNCE("Virtual reality loaded."))

	// Generate mining ruins
	loading_ruins = TRUE

	var/list/ice_ruins = sub_zones_by_trait(ZTRAIT_ICE_RUINS)
	if (ice_ruins.len)
		// needs to be whitelisted for underground too so place_below ruins work
		seedRuins(ice_ruins, CONFIG_GET(number/icemoon_budget), list(/area/icemoon/surface/outdoors/unexplored, /area/icemoon/underground/unexplored), ice_ruins_templates)
		for (var/datum/sub_map_zone/ice_sub in ice_ruins)
			spawn_rivers(ice_sub, 4, /turf/open/openspace/icemoon, /area/icemoon/surface/outdoors/unexplored/rivers)

	var/list/ice_ruins_underground = sub_zones_by_trait(ZTRAIT_ICE_RUINS_UNDERGROUND)
	if (ice_ruins_underground.len)
		seedRuins(ice_ruins_underground, CONFIG_GET(number/icemoon_budget), list(/area/icemoon/underground/unexplored), ice_ruins_underground_templates)
		for (var/datum/sub_map_zone/ice_sub in ice_ruins_underground)
			spawn_rivers(ice_sub, 4, ice_sub.get_trait(ZTRAIT_BASETURF), /area/icemoon/underground/unexplored/rivers)

	// Generate deep space ruins
	var/list/space_ruins = sub_zones_by_trait(ZTRAIT_SPACE_RUINS)
	if (space_ruins.len)
		seedRuins(space_ruins, CONFIG_GET(number/space_budget), list(/area/space), space_ruins_templates)
	loading_ruins = FALSE
#endif
	// Run map generation after ruin generation to prevent issues
	run_map_generation()
	// Add the transit level
	transit = add_new_zlevel("Transit/Reserved")
	var/datum/map_zone/mapzone = new("Transit/Reserved")
	new /datum/sub_map_zone("Transit/Reserved", list(ZTRAIT_RESERVED = TRUE), mapzone, 1, 1, world.maxx, world.maxy, world.maxz)
	repopulate_sorted_areas()
	generate_station_area_list()
	initialize_reserved_level(transit.z_value)
	return ..()

/datum/controller/subsystem/mapping/proc/wipe_reservations(wipe_safety_delay = 100)
	if(clearing_reserved_turfs || !initialized) //in either case this is just not needed.
		return
	clearing_reserved_turfs = TRUE
	SSshuttle.transit_requesters.Cut()
	message_admins("Clearing dynamic reservation space.")
	var/list/obj/docking_port/mobile/in_transit = list()
	for(var/i in SSshuttle.transit)
		var/obj/docking_port/stationary/transit/T = i
		if(!istype(T))
			continue
		in_transit[T] = T.get_docked()
	var/go_ahead = world.time + wipe_safety_delay
	if(in_transit.len)
		message_admins("Shuttles in transit detected. Attempting to fast travel. Timeout is [wipe_safety_delay/10] seconds.")
	var/list/cleared = list()
	for(var/i in in_transit)
		INVOKE_ASYNC(src, .proc/safety_clear_transit_dock, i, in_transit[i], cleared)
	UNTIL((go_ahead < world.time) || (cleared.len == in_transit.len))
	do_wipe_turf_reservations()
	clearing_reserved_turfs = FALSE

/datum/controller/subsystem/mapping/proc/safety_clear_transit_dock(obj/docking_port/stationary/transit/T, obj/docking_port/mobile/M, list/returning)
	M.setTimer(0)
	var/error = M.initiate_docking(M.destination, M.preferred_direction)
	if(!error)
		returning += M
		qdel(T, TRUE)

/* Nuke threats, for making the blue tiles on the station go RED
Used by the AI doomsday and the self-destruct nuke.
*/

/datum/controller/subsystem/mapping/proc/add_nuke_threat(datum/nuke)
	nuke_threats[nuke] = TRUE
	check_nuke_threats()

/datum/controller/subsystem/mapping/proc/remove_nuke_threat(datum/nuke)
	nuke_threats -= nuke
	check_nuke_threats()

/datum/controller/subsystem/mapping/proc/check_nuke_threats()
	for(var/datum/d in nuke_threats)
		if(!istype(d) || QDELETED(d))
			nuke_threats -= d

	for(var/N in nuke_tiles)
		var/turf/open/floor/circuit/C = N
		C.update_appearance()

/datum/controller/subsystem/mapping/Recover()
	flags |= SS_NO_INIT
	initialized = SSmapping.initialized
	map_templates = SSmapping.map_templates
	ruins_templates = SSmapping.ruins_templates
	space_ruins_templates = SSmapping.space_ruins_templates
	lava_ruins_templates = SSmapping.lava_ruins_templates
	ice_ruins_templates = SSmapping.ice_ruins_templates
	ice_ruins_underground_templates = SSmapping.ice_ruins_underground_templates
	planet_ruins_templates = SSmapping.planet_ruins_templates
	shuttle_templates = SSmapping.shuttle_templates
	shelter_templates = SSmapping.shelter_templates
	unused_turfs = SSmapping.unused_turfs
	turf_reservations = SSmapping.turf_reservations
	used_turfs = SSmapping.used_turfs
	holodeck_templates = SSmapping.holodeck_templates

	config = SSmapping.config
	next_map_config = SSmapping.next_map_config

	clearing_reserved_turfs = SSmapping.clearing_reserved_turfs

	z_list = SSmapping.z_list

#define INIT_ANNOUNCE(X) to_chat(world, SPAN_BOLDANNOUNCE("[X]")); log_world(X)
/datum/controller/subsystem/mapping/proc/LoadGroup(
		list/errorList,
		name,
		path,
		files,
		list/traits,
		list/default_traits,
		silent = FALSE,
		datum/overmap_object/ov_obj = null,
		weather_controller_type,
		atmosphere_type,
		day_night_controller_type,
		rock_color,
		plant_color,
		grass_color,
		water_color,
		ore_node_seeder_type,
		map_margin,
		self_looping
	)
	. = list()
	var/start_time = REALTIMEOFDAY
	var/datum/map_zone/mapzone = new(name, ov_obj)

	if (!islist(files))  // handle single-level maps
		files = list(files)

	// check that the total z count of all maps matches the list of traits
	var/total_z = 0
	var/list/parsed_maps = list()
	for (var/file in files)
		var/full_path = "_maps/[path]/[file]"
		var/datum/parsed_map/pm = new(file(full_path))
		var/bounds = pm?.bounds
		if (!bounds)
			errorList |= full_path
			continue
		parsed_maps[pm] = total_z  // save the start Z of this file
		total_z += bounds[MAP_MAXZ] - bounds[MAP_MINZ] + 1

	if (!length(traits))  // null or empty - default
		for (var/i in 1 to total_z)
			traits += list(default_traits)
	else if (total_z != traits.len)  // mismatch
		INIT_ANNOUNCE("WARNING: [traits.len] trait sets specified for [total_z] z-levels in [path]!")
		if (total_z < traits.len)  // ignore extra traits
			traits.Cut(total_z + 1)
		while (total_z > traits.len)  // fall back to defaults on extra levels
			traits += list(default_traits)

	// preload the relevant space_level datums
	var/start_z = world.maxz + 1
	var/i = 0
	var/list/space_levels = list()
	var/list/ordered_subzones = list()
	for (var/list/level as anything in traits)
		var/level_name = "[name][i ? " [i + 1]" : ""]"
		var/datum/space_level/space_lev = add_new_zlevel(level_name)
		space_levels += space_lev
		var/datum/sub_map_zone/subzone = new(level_name, level.Copy(), mapzone, 1, 1, world.maxx, world.maxy, space_lev.z_value)
		ordered_subzones += subzone
		++i
	var/subi = 0
	for(var/datum/sub_map_zone/subzone as anything in ordered_subzones)
		subi++
		var/list/subzone_traits = subzone.traits
		var/up_value = subzone_traits["Up"]
		var/down_value = subzone_traits["Down"]
		if(!isnull(up_value))
			subzone.up_linkage = ordered_subzones[subi+up_value]
		if(!isnull(down_value))
			subzone.down_linkage = ordered_subzones[subi+down_value]
	if(atmosphere_type)
		var/datum/atmosphere/atmos = new atmosphere_type()
		mapzone.set_planetary_atmos(atmos)
		qdel(atmos)
	var/datum/ore_node_seeder/ore_node_seeder
	if(ore_node_seeder_type)
		ore_node_seeder = new ore_node_seeder_type
	for(var/datum/sub_map_zone/iterated_subzone in mapzone.sub_map_zones)
		if(ore_node_seeder)
			ore_node_seeder.SeedToLevel(iterated_subzone.z_value)
	if(rock_color)
		mapzone.rock_color = rock_color
	if(plant_color)
		mapzone.plant_color = plant_color
	if(grass_color)
		mapzone.grass_color = grass_color
	if(water_color)
		mapzone.water_color = water_color
	if(ore_node_seeder)
		qdel(ore_node_seeder)
	//Apply the weather controller to the levels if able
	if(weather_controller_type)
		new weather_controller_type(mapzone)
	if(day_night_controller_type)
		new day_night_controller_type(mapzone)
	space_levels = null

	// load the maps
	for (var/P in parsed_maps)
		var/datum/parsed_map/pm = P
		if (!pm.load(1, 1, start_z + parsed_maps[P], no_changeturf = TRUE))
			errorList |= pm.original_path
	for(var/datum/sub_map_zone/subzone as anything in ordered_subzones)
		if(map_margin)
			subzone.reserve_margin(map_margin)
		if(self_looping)
			subzone.selfloop()
	if(!silent)
		INIT_ANNOUNCE("Loaded [name] in [(REALTIMEOFDAY - start_time)/10]s!")
	return parsed_maps

/datum/controller/subsystem/mapping/proc/loadWorld()
	//if any of these fail, something has gone horribly, HORRIBLY, wrong
	var/list/FailedZs = list()

	// ensure we have space_level datums for compiled-in maps
	InitializeDefaultZLevels()

	//Load overmap
	SSovermap.MappingInit()

	// load the station
	station_start = world.maxz + 1
	INIT_ANNOUNCE("Loading [config.map_name]...")
	var/station_overmap_object = new config.overmap_object_type(SSovermap.main_system, rand(3,10), rand(3,10))
	var/picked_rock_color = CHECK_AND_PICK_OR_NULL(config.rock_color)
	var/picked_plant_color = CHECK_AND_PICK_OR_NULL(config.plant_color)
	var/picked_grass_color = CHECK_AND_PICK_OR_NULL(config.grass_color)
	var/picked_water_color = CHECK_AND_PICK_OR_NULL(config.water_color)
	LoadGroup(FailedZs,
			"Station",
			config.map_path,
			config.map_file,
			config.traits,
			ZTRAITS_STATION,
			ov_obj = station_overmap_object,
			weather_controller_type = config.weather_controller_type,
			atmosphere_type = config.atmosphere_type,
			day_night_controller_type = config.day_night_controller_type,
			rock_color = picked_rock_color,
			plant_color = picked_plant_color,
			grass_color = picked_grass_color,
			water_color = picked_water_color,
			ore_node_seeder_type = config.ore_node_seeder_type,
			map_margin = config.map_margin,
			self_looping = config.self_looping)
	station_map_zone = map_zones[map_zones.len]

	if(SSdbcore.Connect())
		var/datum/db_query/query_round_map_name = SSdbcore.NewQuery({"
			UPDATE [format_table_name("round")] SET map_name = :map_name WHERE id = :round_id
		"}, list("map_name" = config.map_name, "round_id" = GLOB.round_id))
		query_round_map_name.Execute()
		qdel(query_round_map_name)

#ifndef LOWMEMORYMODE
	// TODO: remove this when the DB is prepared for the z-levels getting reordered
	if(config.space_ruin_levels)
		for(var/i in 1 to config.space_ruin_levels)
			++space_levels_so_far
			var/ruins_name = "Ruins Area [i]"
			add_new_zlevel(ruins_name)
			var/overmap_obj = new /datum/overmap_object/ruins(SSovermap.main_system, rand(5,25), rand(5,25))
			var/datum/map_zone/mapzone = new(ruins_name, overmap_obj)
			new /datum/sub_map_zone(ruins_name, ZTRAITS_SPACE, mapzone, 1, 1, world.maxx, world.maxy, world.maxz)
	//Load planets
	if(config.minetype == "lavaland")
		var/datum/planet_template/lavaland_template = planet_templates[/datum/planet_template/lavaland]
		lavaland_template.LoadTemplate(SSovermap.main_system, rand(3,10), rand(3,10))
	else if (!isnull(config.minetype) && config.minetype != "none")
		INIT_ANNOUNCE("WARNING: An unknown minetype '[config.minetype]' was set! This is being ignored! Update the maploader code!")

	var/list/planet_list = SPAWN_PLANET_WEIGHT_LIST
	if(config.amount_of_planets_spawned)
		for(var/i in 1 to config.amount_of_planets_spawned)
			if(!length(planet_list))
				break
			var/picked_planet_type = pickweight(planet_list)
			planet_list -= picked_planet_type
			var/datum/planet_template/picked_template = planet_templates[picked_planet_type]
			picked_template.LoadTemplate(SSovermap.main_system, rand(5,25), rand(5,25))
#endif

	if(LAZYLEN(FailedZs)) //but seriously, unless the server's filesystem is messed up this will never happen
		var/msg = "RED ALERT! The following map files failed to load: [FailedZs[1]]"
		if(FailedZs.len > 1)
			for(var/I in 2 to FailedZs.len)
				msg += ", [FailedZs[I]]"
		msg += ". Yell at your server host!"
		INIT_ANNOUNCE(msg)
#undef INIT_ANNOUNCE

	// Custom maps are removed after station loading so the map files does not persist for no reason.
	if(config.map_path == "custom")
		fdel("_maps/custom/[config.map_file]")
		// And as the file is now removed set the next map to default.
		next_map_config = load_map_config(default_to_box = TRUE)

GLOBAL_LIST_EMPTY(the_station_areas)

/datum/controller/subsystem/mapping/proc/generate_station_area_list()
	var/list/station_areas_blacklist = typecacheof(list(/area/space, /area/mine, /area/ruin, /area/asteroid/nearstation))
	for(var/area/A in world)
		if (is_type_in_typecache(A, station_areas_blacklist))
			continue
		if (!A.contents.len || !(A.area_flags & UNIQUE_AREA))
			continue
		var/turf/picked = A.contents[1]
		if (is_station_level(picked))
			GLOB.the_station_areas += A.type

	if(!GLOB.the_station_areas.len)
		log_world("ERROR: Station areas list failed to generate!")

/datum/controller/subsystem/mapping/proc/run_map_generation()
	for(var/area/A in world)
		A.RunGeneration()

/datum/controller/subsystem/mapping/proc/maprotate()
	if(map_voted || SSmapping.next_map_config) //If voted or set by other means.
		return

	var/players = GLOB.clients.len
	var/list/mapvotes = list()
	//count votes
	var/pmv = CONFIG_GET(flag/preference_map_voting)
	if(pmv)
		for (var/client/c in GLOB.clients)
			var/vote = c.prefs.preferred_map
			if (!vote)
				if (global.config.defaultmap)
					mapvotes[global.config.defaultmap.map_name] += 1
				continue
			mapvotes[vote] += 1
	else
		for(var/M in global.config.maplist)
			mapvotes[M] = 1

	//filter votes
	for (var/map in mapvotes)
		if (!map)
			mapvotes.Remove(map)
			continue
		if (!(map in global.config.maplist))
			mapvotes.Remove(map)
			continue
		if(map in SSpersistence.blocked_maps)
			mapvotes.Remove(map)
			continue
		var/datum/map_config/VM = global.config.maplist[map]
		if (!VM)
			mapvotes.Remove(map)
			continue
		if (VM.voteweight <= 0)
			mapvotes.Remove(map)
			continue
		if (VM.config_min_users > 0 && players < VM.config_min_users)
			mapvotes.Remove(map)
			continue
		if (VM.config_max_users > 0 && players > VM.config_max_users)
			mapvotes.Remove(map)
			continue

		if(pmv)
			mapvotes[map] = mapvotes[map]*VM.voteweight

	var/pickedmap = pickweight(mapvotes)
	if (!pickedmap)
		return
	var/datum/map_config/VM = global.config.maplist[pickedmap]
	message_admins("Randomly rotating map to [VM.map_name]")
	. = changemap(VM)
	if (. && VM.map_name != config.map_name)
		to_chat(world, SPAN_BOLDANNOUNCE("Map rotation has chosen [VM.map_name] for next round!"))

/datum/controller/subsystem/mapping/proc/mapvote()
	if(map_voted || SSmapping.next_map_config) //If voted or set by other means.
		return
	if(SSvote.mode) //Theres already a vote running, default to rotation.
		maprotate()
	SSvote.initiate_vote("map", "automatic map rotation")

/datum/controller/subsystem/mapping/proc/changemap(datum/map_config/VM)
	if(!VM.MakeNextMap())
		next_map_config = load_map_config(default_to_box = TRUE)
		message_admins("Failed to set new map with next_map.json for [VM.map_name]! Using default as backup!")
		return

	next_map_config = VM
	return TRUE

/datum/controller/subsystem/mapping/proc/preloadTemplates(path = "_maps/templates/") //see master controller setup
	var/list/filelist = flist(path)
	for(var/map in filelist)
		var/datum/map_template/T = new(path = "[path][map]", rename = "[map]")
		map_templates[T.name] = T

	preloadPlanetTemplates()
	preloadRuinTemplates()
	preloadShuttleTemplates()
	preloadShelterTemplates()
	preloadHolodeckTemplates()

/datum/controller/subsystem/mapping/proc/preloadPlanetTemplates()
	for(var/path in subtypesof(/datum/planet_template))
		planet_templates[path] = new path()

/datum/controller/subsystem/mapping/proc/preloadRuinTemplates()
	// Still supporting bans by filename
	var/list/banned = generateMapList("[global.config.directory]/lavaruinblacklist.txt")
	banned += generateMapList("[global.config.directory]/spaceruinblacklist.txt")
	banned += generateMapList("[global.config.directory]/iceruinblacklist.txt")

	for(var/item in sortList(subtypesof(/datum/map_template/ruin), /proc/cmp_ruincost_priority))
		var/datum/map_template/ruin/ruin_type = item
		// screen out the abstract subtypes
		if(!initial(ruin_type.id))
			continue
		var/datum/map_template/ruin/R = new ruin_type()

		if(banned.Find(R.mappath))
			continue

		map_templates[R.name] = R
		ruins_templates[R.name] = R

		if(istype(R, /datum/map_template/ruin/lavaland))
			lava_ruins_templates[R.name] = R
		else if(istype(R, /datum/map_template/ruin/icemoon/underground))
			ice_ruins_underground_templates[R.name] = R
		else if(istype(R, /datum/map_template/ruin/icemoon))
			ice_ruins_templates[R.name] = R
		else if(istype(R, /datum/map_template/ruin/space))
			space_ruins_templates[R.name] = R
		else if (istype(R, /datum/map_template/ruin/planetary))
			planet_ruins_templates[R.name] = R

/datum/controller/subsystem/mapping/proc/preloadShuttleTemplates()
	var/list/unbuyable = generateMapList("[global.config.directory]/unbuyableshuttles.txt")

	for(var/item in subtypesof(/datum/map_template/shuttle))
		var/datum/map_template/shuttle/shuttle_type = item
		if(!(initial(shuttle_type.suffix)))
			continue

		var/datum/map_template/shuttle/S = new shuttle_type()
		if(unbuyable.Find(S.mappath))
			S.who_can_purchase = null

		shuttle_templates[S.shuttle_id] = S
		map_templates[S.shuttle_id] = S

/datum/controller/subsystem/mapping/proc/preloadShelterTemplates()
	for(var/item in subtypesof(/datum/map_template/shelter))
		var/datum/map_template/shelter/shelter_type = item
		if(!(initial(shelter_type.mappath)))
			continue
		var/datum/map_template/shelter/S = new shelter_type()

		shelter_templates[S.shelter_id] = S
		map_templates[S.shelter_id] = S

/datum/controller/subsystem/mapping/proc/preloadHolodeckTemplates()
	for(var/item in subtypesof(/datum/map_template/holodeck))
		var/datum/map_template/holodeck/holodeck_type = item
		if(!(initial(holodeck_type.mappath)))
			continue
		var/datum/map_template/holodeck/holo_template = new holodeck_type()

		holodeck_templates[holo_template.template_id] = holo_template

//Manual loading of away missions.
/client/proc/admin_away()
	set name = "Load Away Mission"
	set category = "Admin.Events"

	if(!holder ||!check_rights(R_FUN))
		return


	if(!GLOB.the_gateway)
		if(tgui_alert(usr, "There's no home gateway on the station. You sure you want to continue ?", "Uh oh", list("Yes", "No")) != "Yes")
			return

	var/list/possible_options = GLOB.potentialRandomZlevels + "Custom"
	var/away_name
	var/datum/space_level/away_level

	var/answer = tgui_input_list(usr, "What kind ? ", "Away", possible_options)
	switch(answer)
		if("Custom")
			var/mapfile = input("Pick file:", "File") as null|file
			if(!mapfile)
				return
			away_name = "[mapfile] custom"
			to_chat(usr,SPAN_NOTICE("Loading [away_name]..."))
			var/datum/map_template/template = new(mapfile, "Away Mission")
			away_level = template.load_new_z()
		else
			if(answer in GLOB.potentialRandomZlevels)
				away_name = answer
				to_chat(usr,SPAN_NOTICE("Loading [away_name]..."))
				var/datum/map_template/template = new(away_name, "Away Mission")
				away_level = template.load_new_z()
			else
				return

	message_admins("Admin [key_name_admin(usr)] has loaded [away_name] away mission.")
	log_admin("Admin [key_name(usr)] has loaded [away_name] away mission.")
	if(!away_level)
		message_admins("Loading [away_name] failed!")
		return

/datum/controller/subsystem/mapping/proc/RequestBlockReservation(width, height, z, type = /datum/turf_reservation, turf_type_override)
	UNTIL((!z || reservation_ready["[z]"]) && !clearing_reserved_turfs)
	var/datum/turf_reservation/reserve = new type
	if(turf_type_override)
		reserve.turf_type = turf_type_override
	if(!z)
		for(var/datum/sub_map_zone/iterated_subzonesubzone in sub_zones_by_trait(ZTRAIT_RESERVED))
			if(reserve.Reserve(width, height, iterated_subzonesubzone.z_value))
				return reserve
		//If we didn't return at this point, theres a good chance we ran out of room on the exisiting reserved z levels, so lets try a new one
		num_of_res_levels += 1
		var/transit_name = "Transit/Reserved [num_of_res_levels]"
		var/datum/space_level/newReserved = add_new_zlevel(transit_name)
		var/datum/map_zone/mapzone = new(transit_name)
		new /datum/sub_map_zone(transit_name, list(ZTRAIT_RESERVED = TRUE), mapzone, 1, 1, world.maxx, world.maxy, world.maxz)
		initialize_reserved_level(newReserved.z_value)
		if(reserve.Reserve(width, height, newReserved.z_value))
			return reserve
	else
		if(!sub_zone_trait(locate(1,1,z), ZTRAIT_RESERVED))
			qdel(reserve)
			return
		else
			if(reserve.Reserve(width, height, z))
				return reserve
	QDEL_NULL(reserve)

//This is not for wiping reserved levels, use wipe_reservations() for that.
/datum/controller/subsystem/mapping/proc/initialize_reserved_level(z)
	UNTIL(!clearing_reserved_turfs) //regardless, lets add a check just in case.
	clearing_reserved_turfs = TRUE //This operation will likely clear any existing reservations, so lets make sure nothing tries to make one while we're doing it.
	if(!sub_zone_trait(locate(1,1,z),ZTRAIT_RESERVED))
		clearing_reserved_turfs = FALSE
		CRASH("Invalid z level prepared for reservations.")
	var/turf/A = get_turf(locate(SHUTTLE_TRANSIT_BORDER,SHUTTLE_TRANSIT_BORDER,z))
	var/turf/B = get_turf(locate(world.maxx - SHUTTLE_TRANSIT_BORDER,world.maxy - SHUTTLE_TRANSIT_BORDER,z))
	var/block = block(A, B)
	for(var/t in block)
		// No need to empty() these, because it's world init and they're
		// already /turf/open/space/basic.
		var/turf/T = t
		T.flags_1 |= UNUSED_RESERVATION_TURF
	unused_turfs["[z]"] = block
	reservation_ready["[z]"] = TRUE
	clearing_reserved_turfs = FALSE

/datum/controller/subsystem/mapping/proc/reserve_turfs(list/turfs)
	for(var/i in turfs)
		var/turf/T = i
		T.empty(RESERVED_TURF_TYPE, RESERVED_TURF_TYPE, null, TRUE)
		LAZYINITLIST(unused_turfs["[T.z]"])
		unused_turfs["[T.z]"] |= T
		T.flags_1 |= UNUSED_RESERVATION_TURF
		GLOB.areas_by_type[world.area].contents += T
		CHECK_TICK

//DO NOT CALL THIS PROC DIRECTLY, CALL wipe_reservations().
/datum/controller/subsystem/mapping/proc/do_wipe_turf_reservations()
	PRIVATE_PROC(TRUE)
	UNTIL(initialized) //This proc is for AFTER init, before init turf reservations won't even exist and using this will likely break things.
	for(var/i in turf_reservations)
		var/datum/turf_reservation/TR = i
		if(!QDELETED(TR))
			qdel(TR, TRUE)
	UNSETEMPTY(turf_reservations)
	var/list/clearing = list()
	for(var/l in unused_turfs) //unused_turfs is an assoc list by z = list(turfs)
		if(islist(unused_turfs[l]))
			clearing |= unused_turfs[l]
	clearing |= used_turfs //used turfs is an associative list, BUT, reserve_turfs() can still handle it. If the code above works properly, this won't even be needed as the turfs would be freed already.
	unused_turfs.Cut()
	used_turfs.Cut()
	reserve_turfs(clearing)

///Initialize all biomes, assoc as type || instance
/datum/controller/subsystem/mapping/proc/initialize_biomes()
	for(var/biome_path in subtypesof(/datum/biome))
		var/datum/biome/biome_instance = new biome_path()
		biomes[biome_path] += biome_instance

/datum/controller/subsystem/mapping/proc/reg_in_areas_in_z(list/areas)
	for(var/B in areas)
		var/area/A = B
		A.reg_in_areas_in_z()

/datum/controller/subsystem/mapping/proc/get_isolated_ruin_z()
	if(!isolated_ruins_z)
		isolated_ruins_z = add_new_zlevel("Isolated Ruins/Reserved")
		var/datum/map_zone/mapzone = new("Isolated Ruins/Reserved")
		new /datum/sub_map_zone("Isolated Ruins/Reserved", list(ZTRAIT_RESERVED = TRUE), mapzone, 1, 1, world.maxx, world.maxy, world.maxz)
		initialize_reserved_level(isolated_ruins_z.z_value)
	return isolated_ruins_z.z_value

/datum/controller/subsystem/mapping/proc/GetMapZoneWeatherController(atom/Atom)
	var/datum/map_zone/mapzone = get_map_zone(Atom)
	if(!mapzone)
		return
	mapzone.AssertWeatherController()
	return mapzone.weather_controller

/datum/controller/subsystem/mapping/proc/get_map_zone_id(mapzone_id)
	var/datum/map_zone/returned_mapzone
	for(var/datum/map_zone/iterated_mapzone as anything in map_zones)
		if(iterated_mapzone.id == mapzone_id)
			returned_mapzone = iterated_mapzone
			break
	return returned_mapzone
