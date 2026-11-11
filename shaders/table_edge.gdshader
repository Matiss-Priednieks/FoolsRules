shader_type canvas_item;
// The table's edge: a worn chalk / stencil line around the drop zone, broken up
// by noise so it reads as hand-marked rather than a UI box. On a ColorRect
// sized to game.gd's table_drop_rect (rect_size is set from there).

uniform vec2 rect_size = vec2(1120.0, 540.0);
uniform vec4 line_color : source_color = vec4(0.82, 0.76, 0.58, 0.4);
uniform float thickness = 5.0; // px
uniform float radius = 36.0;   // corner rounding, px

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
		mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void fragment() {
	vec2 p = (UV - 0.5) * rect_size;
	vec2 q = abs(p) - (rect_size * 0.5 - radius - thickness);
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius; // 0 on the line
	// wobble the line a hair and break it into worn gaps
	d += (vnoise(p * 0.02) - 0.5) * 2.5;
	float line = step(abs(d), thickness * 0.5);
	line *= step(0.32, vnoise(p * 0.04) * 0.7 + vnoise(p * 0.35) * 0.3);
	COLOR = vec4(line_color.rgb, line_color.a * line);
}
