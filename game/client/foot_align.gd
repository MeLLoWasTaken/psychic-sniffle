class_name FootAlign
extends SkeletonModifier3D
## Last of the foot modifiers (see FootGrounding): after TwoBoneIK3D has bent the legs, turns
## each foot to the rotation FootGrounding chose (skeleton space), so bending the knee does not
## tip the toes up. Influence blends between the solver's result and that rotation.

var grounding: FootGrounding


func _process_modification() -> void:
	var sk: Skeleton3D = get_skeleton()
	if sk == null or grounding == null:
		return
	for i: int in FootGrounding.SIDES:
		var foot: int = grounding._bones[i * 3 + 2]
		sk.set_bone_global_pose(foot, Transform3D(grounding.foot_basis[i], sk.get_bone_global_pose(foot).origin))
