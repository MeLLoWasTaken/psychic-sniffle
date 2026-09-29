// Greybox surface: a flat color with a world-space grid (1 m lines, stronger every 5 m) so
// distances read at a glance in screenshots, plus darkening near the ground on walls as a
// cheap contact shadow. Replaced by art-kit materials in M1-15.
shader_type spatial;
render_mode blend_mix, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 base_color : source_color = vec3(0.4);
uniform vec3 line_color : source_color = vec3(0.08, 0.08, 0.09);
uniform float minor_spacing = 1.0;
uniform float major_spacing = 5.0;
uniform float minor_strength = 0.22;
uniform float major_strength = 0.55;
uniform float roughness_value = 0.9;
uniform vec3 emission_color : source_color = vec3(0.0);

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// 1 on a grid line, 0 between lines; antialiased with screen-space derivatives.
float grid_line(vec2 p, float spacing, float width_px) {
	vec2 c = p / spacing;
	vec2 d = fwidth(c);
	vec2 g = abs(fract(c - 0.5) - 0.5) / max(d, vec2(1e-5));
	return 1.0 - clamp(min(g.x, g.y) / width_px, 0.0, 1.0);
}

void fragment() {
	vec3 n = abs(world_normal);
	vec2 uv = n.y > max(n.x, n.z) ? world_pos.xz : (n.x > n.z ? world_pos.zy : world_pos.xy);
	float minor = grid_line(uv, minor_spacing, 1.0) * minor_strength;
	float major = grid_line(uv, major_spacing, 1.5) * major_strength;
	vec3 col = mix(base_color, line_color, max(minor, major));
	if (n.y < 0.5) {
		col *= mix(0.62, 1.0, smoothstep(0.0, 0.9, world_pos.y));  // darker where walls meet the floor
	}
	ALBEDO = col;
	ROUGHNESS = roughness_value;
	EMISSION = emission_color;
}
