// Additive glow with a bright rim (fresnel) and slow scrolling bands: shield bubbles, body
// glows, ice, burst shells, orb cores (invert = true puts the brightness in the middle).
// Spell effects v1 (backlog M1-25).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

uniform vec4 color : source_color = vec4(1.0);
uniform vec4 core_color : source_color = vec4(1.0);
uniform float intensity = 1.5;
uniform float power = 2.5;
instance uniform float alpha = 1.0;
uniform float base_alpha = 0.08;
uniform float pulse = 0.0;
uniform float bands = 0.0;
uniform bool invert = false;

void fragment() {
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float f = invert ? pow(facing, power) : pow(1.0 - facing, power);
	float band = 1.0 - bands * 0.5 * (1.0 + sin(UV.y * 20.0 - TIME * 3.0 + UV.x * 12.566));
	float p = 1.0 + pulse * sin(TIME * 5.0);
	ALBEDO = mix(color.rgb, core_color.rgb, f * f * 0.7) * intensity * p;
	ALPHA = clamp((f + base_alpha) * band * alpha, 0.0, 1.0);
}
