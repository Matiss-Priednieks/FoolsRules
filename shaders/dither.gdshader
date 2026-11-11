shader_type canvas_item;
// Whole-screen ordered (Bayer 4x4) dither + per-channel posterise.
// Lives on the Dither autoload's CanvasLayer, below the game's CRT layer.

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;

uniform float dot_size    : hint_range(1.0, 8.0, 1.0) = 2.0; // screen px per dither cell
uniform float color_steps : hint_range(2.0, 32.0, 1.0) = 16.0; // levels per channel
uniform float strength    : hint_range(0.0, 1.0) = 1.0;       // 0 = plain posterise

const float BAYER[16] = float[](
	 0.0,  8.0,  2.0, 10.0,
	12.0,  4.0, 14.0,  6.0,
	 3.0, 11.0,  1.0,  9.0,
	15.0,  7.0, 13.0,  5.0
);

void fragment() {
	vec3 col = texture(screen_tex, SCREEN_UV).rgb;
	ivec2 cell = ivec2(floor(FRAGCOORD.xy / dot_size)) % 4;
	float t = (BAYER[cell.y * 4 + cell.x] + 0.5) / 16.0 - 0.5; // -0.5..0.5
	float s = color_steps - 1.0;
	col = floor(col * s + 0.5 + t * strength) / s;
	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
