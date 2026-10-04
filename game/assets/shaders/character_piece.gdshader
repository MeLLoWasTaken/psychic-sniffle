shader_type spatial;
// Overhaul armor piece (backlog G-05): the neutral bake recoloured by dyes.
// dye_tex: R primary (cloth), G secondary (trim, emblems), B metal; black is undyed (leather).
// Each *_ratio is the chosen dye colour / the neutral colour the piece was baked in.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_disable;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap, repeat_disable;
uniform sampler2D dye_tex : hint_default_black, filter_linear_mipmap, repeat_disable;
uniform vec3 primary_ratio = vec3(1.0);
uniform vec3 secondary_ratio = vec3(1.0);
uniform vec3 metal_ratio = vec3(1.0);
uniform bool use_dye = true;
uniform vec3 tint_ratio = vec3(1.0);
uniform bool debug_dye = false;  // review: draw the dye mask itself  // hair and beards: the hair colour / the neutral bake colour

void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb;
	vec3 col = base;
	if (use_dye) {
		vec3 d = texture(dye_tex, UV).rgb;
		col = mix(col, col * primary_ratio, d.r);
		col = mix(col, col * secondary_ratio, d.g);
		col = mix(col, col * metal_ratio, d.b);
	}
	ALBEDO = debug_dye ? texture(dye_tex, UV).rgb : col * tint_ratio;
	vec3 orm = texture(orm_tex, UV).rgb;
	ROUGHNESS = orm.g;
	METALLIC = orm.b;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
}
