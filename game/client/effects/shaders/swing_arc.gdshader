// Weapon swing trail on a crescent mesh (UV.x along the swing 0..1, UV.y across the blade):
// the head sweeps with progress and the tail fades behind it.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 color : source_color = vec4(1.0);
uniform vec4 core_color : source_color = vec4(1.0);
instance uniform float progress = 1.0;  // 0..1.4: head position along the arc (past 1 the tail runs out)
uniform float tail = 0.55;
uniform float intensity = 1.6;
instance uniform float alpha = 1.0;

void fragment() {
	float behind = progress - UV.x;
	float a = step(0.0, behind) * clamp(1.0 - behind / tail, 0.0, 1.0);
	float across = 1.0 - abs(UV.y * 2.0 - 1.0);
	float edge = smoothstep(0.0, 0.35, across) * mix(0.5, 1.0, UV.y);
	ALBEDO = mix(color.rgb, core_color.rgb, pow(a, 3.0) * UV.y) * intensity;
	ALPHA = clamp(a * a * edge * alpha, 0.0, 1.0);
}
