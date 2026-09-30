// Animated fire tongue for map fixtures (braziers, torches): a quad that turns to face the
// camera around the vertical axis, shaped into a flickering teardrop by scrolling value noise.
// Colors and speed come from data/ambient_effects/<id>.json (backlog F-05). Additive, so it
// reads as light without writing depth.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 core_color : source_color = vec4(1.0, 0.86, 0.5, 1.0);
uniform vec4 outer_color : source_color = vec4(1.0, 0.36, 0.07, 1.0);
uniform float intensity = 2.0;
uniform float speed = 1.0;
instance uniform float phase = 0.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	return vnoise(p) * 0.55 + vnoise(p * 2.13) * 0.3 + vnoise(p * 4.37) * 0.15;
}

void vertex() {
	// cylindrical billboard (as StandardMaterial3D's BILLBOARD_FIXED_Y), keeping the node's scale
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz)), 0.0),
			vec4(0.0, 1.0, 0.0, 0.0), vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))), 0.0),
			MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	float y = 1.0 - UV.y;  // 0 at the base, 1 at the tip
	float t = TIME * speed + phase;
	float n = fbm(vec2(UV.x * 2.6 + phase, y * 2.2 - t * 2.4));
	float n2 = vnoise(vec2(UV.x * 5.0 - phase, y * 4.0 - t * 3.7));
	float x = (UV.x - 0.5) * 2.0 + (n - 0.5) * 1.1 * y;  // tongues sway more toward the tip
	float width = mix(0.92, 0.06, pow(y, 0.75)) * (0.7 + 0.6 * n);
	float body = 1.0 - smoothstep(width * 0.45, width, abs(x));
	float tip = 1.0 - smoothstep(0.35 + 0.4 * n2, 1.0, y);
	float base = smoothstep(0.0, 0.12, y);
	float m = clamp(body * tip * base, 0.0, 1.0);
	float core = smoothstep(0.45, 0.95, m) * (1.0 - y * 0.8);
	ALBEDO = mix(outer_color.rgb, core_color.rgb, core) * intensity;
	ALPHA = m;
}
