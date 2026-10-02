shader_type spatial;
// A wading ripple (M2-09, WadeFx): a thin pale ring on the flood water, with a fainter second ring
// inside it. WadeFx grows the quad and lowers `fade` over the ring's life; one material is shared
// by every ring, so the per-ring values are instance uniforms.
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 ring_color : source_color = vec4(0.5, 0.58, 0.66, 1.0);
uniform float strength : hint_range(0.0, 1.0) = 0.38;
instance uniform float fade = 1.0;
instance uniform float width = 0.1;

float band(float d, float r, float w) {
	return smoothstep(r - w, r - w * 0.4, d) * (1.0 - smoothstep(r - w * 0.4, r, d));
}

void fragment() {
	vec2 c = UV - vec2(0.5);
	float ang = atan(c.y, c.x);
	// a wobbling, broken edge: real ripples are not drawn with a compass
	float wob = 0.035 * sin(ang * 5.0 + fade * 3.0) + 0.025 * sin(ang * 9.0 - fade * 5.0);
	float d = length(c) * 2.0 + wob;  // 0 at the centre, 1 at the quad's inscribed circle
	float broken = 0.55 + 0.45 * sin(ang * 3.0 + fade * 2.0 + 1.3);
	float a = (band(d, 0.97, width) + 0.35 * band(d, 0.7, width * 0.8)) * broken;
	ALBEDO = ring_color.rgb;
	ALPHA = clamp(a * fade * strength, 0.0, 1.0);
}
