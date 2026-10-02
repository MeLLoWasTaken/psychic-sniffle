shader_type spatial;
// Flood water (M2-09): dark, still-looking water with slow crossing ripples, a little see-through
// so the flagstones show faintly. At shallow viewing angles it takes on a pale sheen of the night
// sky (Schlick's Fresnel term with water's 2% head-on reflectance), which is what makes standing
// water read as water without reflection probes. Procedural normals, no textures.
render_mode blend_mix, cull_disabled, depth_draw_opaque, specular_schlick_ggx;

uniform vec4 deep_color : source_color = vec4(0.035, 0.07, 0.07, 1.0);
uniform float clarity : hint_range(0.0, 1.0) = 0.14;
uniform vec4 sheen_color : source_color = vec4(0.2, 0.25, 0.32, 1.0);  // the sky near the horizon
uniform float sheen_strength = 1.1;
uniform float ripple_scale = 0.55;
uniform float ripple_speed = 0.35;
uniform float ripple_strength : hint_range(0.0, 1.0) = 0.6;

float wave(vec2 p, vec2 dir, float freq, float t) {
	return sin(dot(p, dir) * freq + t);
}

void fragment() {
	vec3 world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 p = world.xz * ripple_scale;
	float t = TIME * ripple_speed;
	// the slope of a few crossing sine waves gives the surface normal
	float e = 0.05;
	float h0 = wave(p, vec2(0.8, 0.6), 2.1, t * 3.0) + 0.6 * wave(p, vec2(-0.5, 0.86), 3.7, t * 4.1)
		+ 0.3 * wave(p, vec2(0.2, -0.98), 6.3, t * 5.3);
	float hx = wave(p + vec2(e, 0.0), vec2(0.8, 0.6), 2.1, t * 3.0) + 0.6 * wave(p + vec2(e, 0.0), vec2(-0.5, 0.86), 3.7, t * 4.1)
		+ 0.3 * wave(p + vec2(e, 0.0), vec2(0.2, -0.98), 6.3, t * 5.3);
	float hz = wave(p + vec2(0.0, e), vec2(0.8, 0.6), 2.1, t * 3.0) + 0.6 * wave(p + vec2(0.0, e), vec2(-0.5, 0.86), 3.7, t * 4.1)
		+ 0.3 * wave(p + vec2(0.0, e), vec2(0.2, -0.98), 6.3, t * 5.3);
	vec3 n = normalize(vec3(-(hx - h0) / e * ripple_strength * 0.1, 1.0, -(hz - h0) / e * ripple_strength * 0.1));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fresnel = 0.02 + 0.98 * pow(1.0 - facing, 5.0);
	ALBEDO = deep_color.rgb;
	EMISSION = sheen_color.rgb * fresnel * sheen_strength;
	ROUGHNESS = 0.06;
	SPECULAR = 0.6;
	METALLIC = 0.0;
	ALPHA = mix(1.0 - clarity, 1.0, fresnel);
}
