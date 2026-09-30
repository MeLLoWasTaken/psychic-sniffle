// Translucent ice that hides what is inside a little (encasing crowd control, ice block):
// mixed, not added, so it reads on bright ground too; rim and facets glow.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

uniform vec4 color : source_color = vec4(0.4, 0.85, 1.0, 1.0);
uniform vec4 core_color : source_color = vec4(0.9, 1.0, 1.0, 1.0);
uniform float intensity = 1.2;
instance uniform float alpha = 1.0;

void fragment() {
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = pow(1.0 - facing, 2.0);
	float glint = pow(max(0.0, sin(UV.y * 9.0 + UV.x * 5.0 + TIME * 0.8)), 24.0);
	ALBEDO = mix(color.rgb * 0.85, core_color.rgb, clamp(rim + glint, 0.0, 1.0)) * intensity;
	ALPHA = clamp(0.42 + 0.5 * rim + glint * 0.4, 0.0, 1.0) * alpha;
}
