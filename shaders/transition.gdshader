shader_type canvas_item;
// Scene-change swipe: a diagonal soot wipe with a torn paper edge and a thin
// faded-red stencil stripe riding the leading edge. `progress` 0 -> 1 covers
// the screen, 1 -> 2 carries on off the far side, uncovering the new scene.

uniform float progress = 0.0;
uniform vec4 fill : source_color = vec4(0.07, 0.065, 0.055, 1.0);
uniform vec4 stripe : source_color = vec4(0.62, 0.18, 0.14, 1.0);
const float EDGE = 0.08; // how far the torn edge wanders / the stripe's run-up

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
		mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	// 0 at the top-left corner -> 1 at the bottom-right, a slight diagonal
	float d = uv.x * 0.8 + uv.y * 0.2;
	// torn edge: coarse wobble plus fine fibres along the edge
	d += (vnoise(vec2(uv.y * 6.0, 0.0)) - 0.5) * EDGE + (vnoise(uv * vec2(40.0, 160.0)) - 0.5) * 0.012;
	float covered;
	float near_edge;
	if (progress <= 1.0) {
		float e = progress * (1.0 + 2.0 * EDGE) - EDGE; // leading edge moving right
		covered = step(d, e);
		near_edge = step(e - 0.018, d) * covered;
	} else {
		float e = (progress - 1.0) * (1.0 + 2.0 * EDGE) - EDGE; // trailing edge moving right
		covered = step(e, d);
		near_edge = step(d, e + 0.018) * covered;
	}
	COLOR = vec4(mix(fill.rgb, stripe.rgb, near_edge), covered);
}
