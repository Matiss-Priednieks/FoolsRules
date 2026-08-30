shader_type canvas_item;

// --- Pixel-art post-process ------------------------------------------------
// Chunky-pixel downsample + optional palette posterise / ordered dither.
// Independent of crt.gdshader. Sits on its own CanvasLayer BELOW the CRT one
// so the scanlines and curvature ride over the fat pixels, not the other way
// round. Toggle from game.gd via `pixelate_enabled`.

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;

uniform float pixel_size  : hint_range(1.0, 16.0, 1.0) = 4.0;  // real pixels per art pixel
uniform int   color_steps : hint_range(2, 64)          = 48;   // per-channel levels (64 ~= off)
uniform float dither_amt  : hint_range(0.0, 1.0)       = 0.0;   // ordered dithering strength
uniform float saturation  : hint_range(0.0, 2.0)       = 1.0;   // <1 mutes colour, >1 punches it

// 4x4 Bayer matrix, values 0..15
const float BAYER[16] = float[](
	 0.0,  8.0,  2.0, 10.0,
	12.0,  4.0, 14.0,  6.0,
	 3.0, 11.0,  1.0,  9.0,
	15.0,  7.0, 13.0,  5.0
);

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;             // viewport resolution, px
	vec2 grid = max(res / pixel_size, vec2(1.0));   // art-pixel grid resolution
	vec2 cell = floor(SCREEN_UV * grid);
	vec2 uv = (cell + 0.5) / grid;                  // sample each fat pixel's centre

	vec3 col = texture(screen_tex, uv).rgb;

	// saturation
	float luma = dot(col, vec3(0.299, 0.587, 0.114));
	col = clamp(mix(vec3(luma), col, saturation), 0.0, 1.0);

	// ordered dither + posterise
	int bx = int(mod(cell.x, 4.0));
	int by = int(mod(cell.y, 4.0));
	float threshold = (BAYER[by * 4 + bx] + 0.5) / 16.0 - 0.5;  // -0.5..0.5
	float steps = float(color_steps);
	col = floor(col * steps + 0.5 + threshold * dither_amt) / steps;

	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
