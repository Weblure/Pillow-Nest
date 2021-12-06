/mob/living/silicon/robot
	var/robot_resting = FALSE
	var/robot_rest_style = ROBOT_REST_NORMAL
	var/dogborg = FALSE

/mob/living/silicon/robot/model/miner/horizon
	set_model = /obj/item/robot_model/miner/horizon

/mob/living/silicon/robot/model/butler/horizon
	set_model = /obj/item/robot_model/service/horizon
