/// Throw an immovable rod at the target
/datum/smite/rod
	name = "Immovable Rod"
	var/force_looping = FALSE

/datum/smite/rod/configure(client/user)
	var/loop_input = tgui_alert(usr,"Would you like this rod to force-loop across space z-levels?", "Loopy McLoopface", list("Yes", "No"))

	force_looping = (loop_input == "Yes")

/datum/smite/rod/effect(client/user, mob/living/target)
	. = ..()
	var/turf/target_turf = get_turf(target)
	var/startside = pick(GLOB.cardinals)
	var/datum/sub_map_zone/subzone = SSmapping.get_sub_zone(target_turf)
	var/turf/start_turf = spaceDebrisStartLoc(startside, subzone)
	var/turf/end_turf = spaceDebrisFinishLoc(startside, subzone)
	new /obj/effect/immovablerod(start_turf, end_turf, target, force_looping)
