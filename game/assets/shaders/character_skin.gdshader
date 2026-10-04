shader_type spatial;
// Overhaul body (backlog G-05): the neutral baked skin recoloured by the character's look.
// mask: R iris, G skin, B lips; marks_a / marks_b: one scar or paint layer per channel
// (tools/blender/appearance_bake.py). skin_ratio = chosen tone / neutral bake tone.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_disable;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap, repeat_disable;
uniform sampler2D mask_tex : hint_default_black, filter_linear_mipmap, repeat_disable;
uniform sampler2D marks_a_tex : hint_default_black, filter_linear_mipmap, repeat_disable;
uniform sampler2D marks_b_tex : hint_default_black, filter_linear_mipmap, repeat_disable;
uniform vec3 skin_ratio = vec3(1.0);
uniform vec3 iris_color : source_color = vec3(0.29, 0.17, 0.09);
uniform vec3 mark_weights_a = vec3(0.0);
uniform vec3 mark_weights_b = vec3(0.0);
uniform vec3 mark_color : source_color = vec3(0.17, 0.23, 0.32);

void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb;
	vec3 m = texture(mask_tex, UV).rgb;
	vec3 col = mix(base, base * skin_ratio, m.g);
	// the baked iris is a dark neutral grey: scale it toward the chosen colour
	col = mix(col, base * iris_color * 4.5, m.r);
	float mark = dot(texture(marks_a_tex, UV).rgb, mark_weights_a) + dot(texture(marks_b_tex, UV).rgb, mark_weights_b);
	col = mix(col, mark_color, clamp(mark, 0.0, 1.0));
	ALBEDO = col;
	vec3 orm = texture(orm_tex, UV).rgb;
	ROUGHNESS = orm.g;
	METALLIC = orm.b;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
}
