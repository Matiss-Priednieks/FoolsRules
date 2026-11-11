shader_type canvas_item;
render_mode blend_mix;

// Per-card effects, driven from game.gd (card.gd holds one ShaderMaterial per
// card and just sets these params):
//   rot_x / rot_y : fake-3D tilt in radians. + rot_x tips the TOP edge toward
//                   the viewer, + rot_y turns the RIGHT edge toward the viewer.
//                   The card is treated as a flat quad and the sample point is
//                   rotated + perspective-divided, so the far edge really
//                   foreshortens (a trapezoid, not a skewed parallelogram).
//   bend          : flex along the card's long axis - + bows the middle toward
//                   the viewer (ends fall away), - bows it away. Driven by the
//                   deal animation; 0 = flat.
//   invalid       : 0 or 1, "can't play this": the card goes dull and shadowed.
//   trump         : 0 or 1, cel-shaded rusted-copper tint + frame + sweeping glint for
//                   a trump-suited card (multiplied, so rank/suit stay legible).
uniform float rot_x = 0.0;
uniform float rot_y = 0.0;
uniform float cam_dist : hint_range(1.5, 10.0) = 4.0; // smaller = stronger perspective
uniform float bend = 0.0;
uniform float invalid = 0.0;
uniform float trump = 0.0;
uniform float back_procedural = 1.0; // backs: 1 = drawn pattern, 0 = recoloured back texture
uniform float joker = 0.0;   // 1 = the Joker: same metal treatment as trump, in semi-tarnished gold
uniform float face = 0.0;    // 1 = face-up card (paper tone); 0 = procedural card back
uniform float special = 0.0; // 1 = special card: family-colour frame + nameplate
uniform vec3 family_color : source_color = vec3(0.3, 0.6, 0.9);
uniform vec3 family_outline : source_color = vec3(0.1, 0.2, 0.3);
uniform sampler2D name_tex : filter_linear; // special's name, rendered by card.gd's NameView
uniform vec2 seed = vec2(0.0); // per-card offset so grime/rust/wear differ card to card
uniform float gold_bands : hint_range(2.0, 8.0, 1.0) = 4.0; // cel tone steps
uniform float shimmer_speed = 0.7;
uniform sampler2D rank_tex : filter_linear; // this card's rank in the UI font (card.gd's RankView)
uniform float use_rank = 0.0; // 1 = replace the printed corner ranks with rank_tex
uniform float print_inset : hint_range(0.7, 1.0) = 0.9; // face print drawn this much smaller, centred
uniform float ink_wear : hint_range(0.0, 1.0) = 0.6; // worn print: how faded the ink gets
uniform float stripes = 0.0;    // 1 = family frame drawn as black/ochre warning stripes (Hazards)
uniform float irradiated = 0.0; // status: sickly green, pulsing (Fallout)
uniform float frozen = 0.0;     // status: frost creeping in from the edges (Frostbite)
uniform float burn = 0.0;       // 0..1: the card burning away (Flame Hazard, Purge)
uniform float sticky = 0.0;     // 1 = stuck to the table edge (Spilt Samogon): amber glaze + drips
uniform float ink_fleck_light = 1.0; // flecks: 1 = paper showing through, 0 = dark dirt
uniform float print_damage : hint_range(0.0, 2.0) = 1.0; // the rare big stuff: rubbed-off patches, chips, scratches

// carry the CanvasItem's modulate (game.gd dims unplayable cards via modulate.a)
// past the fragment stage, which has no MODULATE built-in
varying vec4 v_modulate;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) { // value noise, 0..1
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
		mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

// signed distance to a 5-point star (Inigo Quilez), point up in +y
float sd_star5(vec2 p, float r, float rf) {
	const vec2 k1 = vec2(0.809016994375, -0.587785252292);
	const vec2 k2 = vec2(-k1.x, k1.y);
	p.x = abs(p.x);
	p -= 2.0 * max(dot(k1, p), 0.0) * k1;
	p -= 2.0 * max(dot(k2, p), 0.0) * k2;
	p.x = abs(p.x);
	p.y -= r;
	vec2 ba = rf * vec2(-k1.y, k1.x) - vec2(0.0, 1.0);
	float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, r);
	return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
}

// Ragged blobs scattered one-per-cell, only in a few cells: `cells` per unit,
// `odds` = share of cells that hold one, radius rmin..rmax. `p` is in
// card-aspect units (y already stretched), so blobs come out round. Returns
// 0..1 coverage (1 = dead centre), with `hard` sharpening the rim for chips.
float blobs(vec2 p, float cells, float odds, float rmin, float rmax, float hard) {
	float best = 0.0;
	vec2 cell = floor(p * cells);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 id = cell + vec2(float(x), float(y));
			if (hash(id * 1.37 + 4.1) > odds) {
				continue;
			}
			vec2 centre = (id + vec2(hash(id + 1.7), hash(id + 9.2))) / cells;
			float r = mix(rmin, rmax, hash(id + 5.3));
			vec2 d = p - centre;
			float a = hash(id + 2.9) * 6.283;
			d = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * d;
			d.x *= mix(0.55, 1.0, hash(id + 7.7)); // some smeared long, like a thumb dragged it
			float ragged = (vnoise(p * 45.0) - 0.5) * 0.45 + (vnoise(p * 11.0) - 0.5) * 0.7;
			float len = length(d) * (1.0 + ragged);
			best = max(best, 1.0 - smoothstep(r * mix(0.5, 0.92, hard), r, len));
		}
	}
	return best;
}

// how much ink the (inset) print has at art-uv `a`: 1 = ink, 0 = paper
float ink_at(sampler2D t, vec2 a) {
	vec3 c = texture(t, a).rgb;
	return 1.0 - smoothstep(0.55, 0.8, min(c.r, min(c.g, c.b)));
}

void vertex() {
	v_modulate = COLOR;
}

void fragment() {
	// card.gd pads the sprite quad (a region larger than the texture), so UV
	// runs past 0..1 at the quad's edge: that margin is the headroom the near
	// edge grows into under tilt/bend - the card itself never shrinks to fit.
	vec2 c = UV - 0.5;
	vec3 p = vec3(c, 0.0);

	// rotate the sampling plane by the inverse of the apparent card rotation
	float sx = sin(-rot_x);
	float cx = cos(-rot_x);
	float sy = sin(-rot_y);
	float cy = cos(-rot_y);
	p = vec3(p.x * cy + p.z * sy, p.y, -p.x * sy + p.z * cy); // yaw  (around Y)
	p = vec3(p.x, p.y * cx - p.z * sx, p.y * sx + p.z * cx);  // pitch (around X)

	float depth = p.z; // + = this point of the card tipped toward the viewer
	float w = cam_dist / (cam_dist - p.z); // perspective divide
	vec2 uv = p.xy * w + 0.5;

	// Bend: the card's surface bulges to z = bend * (1 - (2y)^2), so each point
	// is magnified by its own perspective factor. Screen -> card is the inverse
	// of that, solved by fixed-point iteration (converges fast for small bends).
	if (bend != 0.0) {
		vec2 q = uv - 0.5;
		vec2 src = q;
		for (int i = 0; i < 3; i++) {
			float z = bend * (1.0 - 4.0 * src.y * src.y);
			src = q * (cam_dist - z) / cam_dist;
		}
		uv = src + 0.5;
	}

	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		COLOR = vec4(0.0);
	} else {
		vec4 tex = texture(TEXTURE, uv);
		// Inset print: the face's printed art (pips, corner indices, court art)
		// is drawn print_inset smaller toward the centre, so it clears the
		// frames / wear at the edge; the card's size and silhouette (alpha) stay
		// put. The art's own outline + rounded corners are cropped off the
		// shrunk copy and the margin left is plain card stock - no seam.
		if (face > 0.5) {
			vec2 iuv = (uv - 0.5) / print_inset + 0.5;
			const float CROP = 0.022;
			bool in_print = all(greaterThan(iuv, vec2(CROP))) && all(lessThan(iuv, vec2(1.0 - CROP)));
			tex.rgb = in_print ? texture(TEXTURE, iuv).rgb : vec3(1.0);
			// Corner ranks in the game's own font: the printed rank glyph sits in
			// the same box on every og_set face (x 10-92, y 10-86 of 500x726; the
			// small suit pip starts just below, untouched). Paper over it, then
			// lay rank_tex in - upright top-left, turned 180 bottom-right. Done
			// before the ink-wear pass, so the new ranks wear like the rest.
			if (use_rank > 0.5) {
				const vec2 BOX_MIN = vec2(10.0 / 500.0, 10.0 / 726.0);
				const vec2 BOX_SIZE = vec2(82.0 / 500.0, 76.0 / 726.0);
				vec2 a = (iuv - BOX_MIN) / BOX_SIZE;              // top-left box
				vec2 b = (vec2(1.0) - iuv - BOX_MIN) / BOX_SIZE;  // bottom-right, rotated 180
				// the printed Q's tail runs a few px past the box, to the right of
				// the suit pip - paper over that strip too (both corners)
				const vec2 TAIL_MIN = vec2(70.0 / 500.0, 84.0 / 726.0);
				const vec2 TAIL_MAX = vec2(92.0 / 500.0, 93.0 / 726.0);
				vec2 flip = vec2(1.0) - iuv;
				if ((all(greaterThan(iuv, TAIL_MIN)) && all(lessThan(iuv, TAIL_MAX)))
						|| (all(greaterThan(flip, TAIL_MIN)) && all(lessThan(flip, TAIL_MAX)))) {
					tex.rgb = vec3(1.0);
				}
				for (int k = 0; k < 2; k++) {
					vec2 r = k == 0 ? a : b;
					if (all(greaterThanEqual(r, vec2(0.0))) && all(lessThanEqual(r, vec2(1.0)))) {
						vec4 g = texture(rank_tex, r);
						tex.rgb = mix(vec3(1.0), g.rgb, g.a);
					}
				}
			}
		}
		// Worn print, same idea as the UI text wear (text_wear.gdshader): the
		// ink (anything not paper-white) fades in hard-edged patches - red to
		// dull brick, black to charcoal - picks up small flecks, and gets its
		// outlines chewed. All of it follows a slow "handling" map, so some
		// stretches of a card stay nearly crisp and others are properly rubbed.
		// Paper is left to the grime pass further down.
		if (face > 0.5) {
			vec2 iuv = uv + seed;
			float ink_m = 1.0 - smoothstep(0.55, 0.8, min(tex.r, min(tex.g, tex.b)));
			float handled = vnoise(iuv * 2.2 + 7.3);                  // 0 = pristine .. 1 = rubbed
			float wear = clamp(ink_wear * mix(0.35, 1.6, handled), 0.0, 1.0);
			float patchy = step(0.55, vnoise(iuv * 9.0) * 0.6 + vnoise(iuv * 30.0) * 0.4);
			vec3 c = tex.rgb;
			vec3 faded_c = mix(c, vec3(dot(c, vec3(0.299, 0.587, 0.114))), 0.4) * 0.75 + vec3(0.2, 0.17, 0.13);
			c = mix(c, faded_c, patchy * wear);
			// rotated + warped so the specks scatter, not line up on the noise grid
			vec2 fp = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * iuv * 70.0;
			fp += vec2(vnoise(iuv * 18.0), vnoise(iuv * 18.0 + 3.1)) * 2.5;
			float fleck = step(1.0 - wear * 0.36, vnoise(fp) * 0.75 + vnoise(fp * 2.3) * 0.25);
			c = mix(c, mix(c * 0.55, vec3(0.86, 0.81, 0.68), ink_fleck_light), fleck * 0.8);
			// chewed outlines: ink that sits next to paper is an edge; bite into
			// it with fine noise, harder where the card is more handled
			vec2 auv = (uv - 0.5) / print_inset + 0.5;
			vec2 step_uv = vec2(2.5 / 500.0, 2.5 / 726.0) / print_inset;
			float around = min(min(ink_at(TEXTURE, auv + vec2(step_uv.x, 0.0)), ink_at(TEXTURE, auv - vec2(step_uv.x, 0.0))),
				min(ink_at(TEXTURE, auv + vec2(0.0, step_uv.y)), ink_at(TEXTURE, auv - vec2(0.0, step_uv.y))));
			float edge = ink_m * (1.0 - around);
			vec2 bp = mat2(vec2(0.6, -0.8), vec2(0.8, 0.6)) * iuv * 130.0 + vec2(vnoise(iuv * 25.0)) * 3.0;
			float bite = step(1.0 - wear * 0.75, vnoise(bp) * 0.7 + vnoise(iuv * 40.0) * 0.3);
			c = mix(c, vec3(1.0), step(0.5, edge) * bite);
			tex.rgb = mix(tex.rgb, c, ink_m);

			// Rare, bigger damage on top - most cards have none, some one or two:
			//  - rubbed patches: the print worn right through to paper, a faint
			//    ghost of the ink left in the middle, ragged at the rim
			//  - chips: a flake of the coated surface gone, bare grey-brown
			//    stock underneath with a dark broken rim (paper and ink alike)
			//  - the odd scratch dragged across the print
			if (print_damage > 0.0) {
				vec2 dp = vec2(uv.x, uv.y * 1.452) + seed; // card aspect, so blobs are round
				float rub = blobs(dp, 1.8, 0.2 * print_damage, 0.045, 0.12, 0.0);
				vec3 paper = vec3(0.9, 0.86, 0.76);
				tex.rgb = mix(tex.rgb, mix(paper, tex.rgb, 0.14), rub * ink_m);
				float chip = blobs(dp + 31.7, 6.0, 0.05 * print_damage, 0.01, 0.024, 1.0);
				float rim = chip * (1.0 - chip) * 4.0; // peaks at the broken edge
				tex.rgb = mix(tex.rgb, vec3(0.66, 0.6, 0.5) * mix(0.9, 1.05, vnoise(dp * 90.0)), step(0.5, chip));
				tex.rgb = mix(tex.rgb, tex.rgb * 0.55, rim * 0.7);
				float h = hash(floor(seed * 7.0) + 0.37);
				if (h < 0.3 * print_damage) { // about a third of cards carry one scratch
					float a = hash(seed + 3.3) * 3.1416;
					vec2 dir = vec2(cos(a), sin(a));
					vec2 from = dp - seed - vec2(0.2 + 0.6 * hash(seed + 1.1), 0.3 + 0.85 * hash(seed + 2.2));
					float along = dot(from, dir);
					float across = abs(dot(from, vec2(-dir.y, dir.x)) + sin(along * 9.0) * 0.006);
					float run = step(abs(along), 0.12 + 0.2 * hash(seed + 4.4)); // a segment, not the whole card
					float broken = step(0.4, vnoise(vec2(along * 60.0, h * 50.0)));
					float scratch = (1.0 - smoothstep(0.0012, 0.0032, across)) * run * broken;
					tex.rgb = mix(tex.rgb, paper, scratch * max(ink_m, 0.35));
				}
			}
		}

		vec3 art = tex.rgb; // untinted print, for the frames below
		// distance in from a rounded-rect edge (UV space; corner radius 0.08)
		vec2 q = abs(uv - 0.5) - (0.5 - 0.08);
		float edge_dist = 0.08 - length(max(q, 0.0)) - min(max(q.x, q.y), 0.0);

		// Wear, shared by every face: cel grime blotches, foxing spots, and
		// chipped paint where the edges get handled.
		vec2 nuv = uv + seed;
		float grime = step(0.62, vnoise(nuv * 3.5) * 0.7 + vnoise(nuv * 15.0) * 0.3);
		float fox = step(0.9, vnoise(nuv * 18.0)) * step(0.5, vnoise(nuv * 4.0)); // sparse clusters
		float chip = step(0.72, vnoise(nuv * 24.0)) * step(edge_dist, 0.032);
		// aged card stock: 3 cel bands, khaki -> yellowed cream toward the top-left
		float plv = floor(clamp(uv.x * 0.55 + (1.0 - uv.y) * 0.45, 0.0, 0.999) * 3.0) / 2.0;
		vec3 paper = mix(vec3(0.78, 0.71, 0.55), vec3(0.93, 0.88, 0.74), plv);
		paper *= 1.0 - 0.08 * grime;
		paper = mix(paper, vec3(0.62, 0.46, 0.28), fox * 0.5);
		paper *= 1.0 - 0.3 * (1.0 - smoothstep(0.0, 0.04, edge_dist)); // dirty rubbed edges

		if (trump > 0.5 || joker > 0.5) {
			bool gold = joker > 0.5;
			// Cel-shaded rusted copper (trump) / semi-tarnished gold (Joker). A diagonal light ramp (bright top-left) with a slow
			// crawl, posterised into hard tone bands, then MULTIPLIED onto the art:
			// the white face turns gold, black pips stay black, so it stays legible.
			float ramp = uv.x * 0.55 + (1.0 - uv.y) * 0.45;
			ramp += 0.12 * sin(TIME * 1.6 + (uv.x - uv.y) * 5.0);
			float lv = floor(clamp(ramp, 0.0, 0.999) * gold_bands) / (gold_bands - 1.0);
			vec3 tone = gold ? mix(vec3(0.80, 0.52, 0.10), vec3(1.0, 0.92, 0.55), lv)
				: mix(vec3(0.62, 0.26, 0.10), vec3(1.0, 0.74, 0.52), lv);
			// Rust: blotchy patches, hard-edged (cel), heavier toward the edges.
			float n = vnoise(nuv * 7.0) * 0.65 + vnoise(nuv * 19.0) * 0.35;
			float rust = step((gold ? 0.74 : 0.68) - (0.08 - min(edge_dist, 0.08)) * 2.0, n);
			vec3 patch = gold ? vec3(0.50, 0.44, 0.22) : vec3(0.50, 0.24, 0.12); // tarnish / rust
			tone = mix(tone, patch, rust * 0.8);
			tex.rgb *= tone;

			// Hard two-tone frame: dark copper outline, bright copper inside it.
			// Multiplied over the print, so corner rank/suit show through it.
			if (edge_dist < 0.045) {
				vec3 frame = gold
					? (edge_dist < 0.015 ? vec3(0.45, 0.28, 0.04) : vec3(1.0, 0.80, 0.25))
					: (edge_dist < 0.015 ? vec3(0.38, 0.14, 0.05) : vec3(0.90, 0.50, 0.28));
				tex.rgb = art * mix(frame, patch * 0.9, rust * 0.7);
			}

			// Glint: a fat stripe + a thin trailing one, hard-edged, sweeping fast,
			// then a short pause off-card before the next pass.
			float d = mod((uv.x + uv.y) * 0.5 - TIME * shimmer_speed, 1.7) - 0.5;
			float glint = max(step(abs(d), 0.07), step(abs(d + 0.14), 0.02));
			vec3 glint_col = gold ? vec3(1.0, 0.98, 0.82) : vec3(1.0, 0.86, 0.72);
			tex.rgb = mix(tex.rgb, glint_col, glint * 0.7 * (1.0 - rust * 0.7)); // rust/tarnish stays matte
		} else if (face < 0.5) {
			// Card back, all procedural: faded brick-red print on the aged stock -
			// border band, diamond lattice, and a star medallion in the middle.
			vec2 P = (uv - 0.5) * vec2(1.0, 1.452); // aspect-correct (500x726)
			float ink = 0.0;
			if (back_procedural < 0.5) {
				// reuse the back texture: its darkness becomes brick-red ink
				ink = clamp((1.0 - dot(art, vec3(0.299, 0.587, 0.114))) * 1.5, 0.0, 1.0);
			} else {
			ink = step(0.05, edge_dist) * step(edge_dist, 0.085); // border band
			ink = max(ink, step(0.1, edge_dist) * step(edge_dist, 0.11)); // inner rule
			float rr = length(P);
			if (edge_dist > 0.125 && rr > 0.27) { // lattice, cleared around the medallion
				vec2 g = abs(fract(vec2(P.x + P.y, P.x - P.y) * 7.0) - 0.5);
				ink = max(ink, step(min(g.x, g.y), 0.06));
			}
			ink = max(ink, step(0.235, rr) * step(rr, 0.255)); // medallion ring
			ink = max(ink, step(sd_star5(vec2(P.x, -P.y + 0.012), 0.19, 0.45), 0.0));
			}
			// worn print, same fade + flecks as the face ink
			vec3 brick = vec3(0.55, 0.16, 0.12) * (1.0 - 0.15 * grime);
			float patchy = step(0.55, vnoise(nuv * 9.0) * 0.6 + vnoise(nuv * 30.0) * 0.4);
			brick = mix(brick, vec3(0.5, 0.27, 0.21), patchy * ink_wear);
			float fleck = step(1.0 - ink_wear * 0.25, vnoise(nuv * 70.0));
			brick = mix(brick, mix(brick * 0.55, paper, ink_fleck_light), fleck * 0.8);
			tex.rgb = mix(paper, brick, ink);
		} else {
			tex.rgb *= paper;
			// Specials: the same two-tone rounded frame as trump, in family paint,
			// chipped through to the card stock along the worn edges.
			if (special > 0.5 && edge_dist < 0.045 && chip < 0.5) {
				vec3 paint = edge_dist < 0.015 ? family_outline : family_color;
				if (stripes > 0.5 && edge_dist >= 0.015) // Hazards: warning stripes, not a solid paint
					paint = mix(family_color, family_outline, step(0.5, fract((uv.x * 0.69 + uv.y) * 9.0)));
				paint *= 1.0 - 0.15 * grime;
				// Paint goes UNDER the print (paper -> paint, ink stays ink), so the
				// corner rank/suit survive dark frames. Ink too close to the paint
				// to read (black on soot, red on faded red) prints in light card
				// stock on a dark frame, or soot on a light one.
				float ink_m = 1.0 - smoothstep(0.55, 0.8, min(art.r, min(art.g, art.b)));
				vec3 ink = art;
				float paint_l = dot(paint, vec3(0.299, 0.587, 0.114));
				if (distance(ink, paint) < 0.45) {
					ink = paint_l < 0.35 ? vec3(0.86, 0.81, 0.68) : vec3(0.1, 0.08, 0.06);
				} else if (paint_l < 0.25) {
					ink = mix(ink, vec3(1.0, 0.8, 0.7), 0.45); // red on soot: keep the hue, lift it
				}
				tex.rgb = mix(paint, ink, ink_m);
			}
		}

		// Special nameplate: a stencilled paint strip across the bottom, ragged
		// edges and worn speckles showing the card underneath (the name itself
		// is card.tscn's SpecialLabel).
		if (special > 0.5 && face > 0.5 && joker < 0.5) {
			vec2 r = vec2(abs(uv.x - 0.5), abs(uv.y - 0.905));
			float inside = min(0.43 - r.x, 0.075 - r.y) + (vnoise(nuv * 45.0) - 0.5) * 0.01;
			if (inside > 0.0) {
				float worn = step(0.86, vnoise(nuv * 40.0));
				// a striped (Hazard) card's plate is its stripes' black, so the name reads
				vec3 plate_col = stripes > 0.5 ? family_outline * 1.6 + 0.04 : family_color * 0.85;
				tex.rgb = mix(plate_col * (1.0 - 0.15 * grime), art * paper, worn);
				tex.a = 1.0;
			}
			// name text over the plate (NameView is 430x109 = this uv box on a 500x726 card)
			vec2 tuv = (uv - vec2(0.07, 0.83)) / vec2(0.86, 0.15);
			if (all(greaterThanEqual(tuv, vec2(0.0))) && all(lessThanEqual(tuv, vec2(1.0)))) {
				vec4 t = texture(name_tex, tuv);
				tex.rgb = mix(tex.rgb, t.rgb, t.a * (1.0 - 0.6 * step(0.86, vnoise(nuv * 40.0))));
				tex.a = max(tex.a, t.a);
			}
		}

		// --- statuses a Hazard put on this card ---------------------------
		if (irradiated > 0.5) { // sickly green cast, glowing blotches + rim, pulsing
			float pulse = 0.75 + 0.25 * sin(TIME * 3.0);
			float blot = smoothstep(0.45, 0.7, vnoise(nuv * 4.0) * 0.7 + vnoise(nuv * 13.0) * 0.3);
			vec3 sick = vec3(0.55, 0.85, 0.18);
			tex.rgb = mix(tex.rgb, tex.rgb * vec3(0.75, 1.0, 0.55), 0.35);
			tex.rgb = mix(tex.rgb, sick, blot * 0.45 * pulse);
			tex.rgb += sick * (1.0 - smoothstep(0.0, 0.05, edge_dist)) * 0.35 * pulse;
		}
		if (frozen > 0.5) { // cold cast, frost creeping in from the edges, ice crystals
			float fr = 1.0 - smoothstep(0.0, 0.16, edge_dist + (vnoise(nuv * 18.0) - 0.5) * 0.06);
			tex.rgb = mix(tex.rgb, vec3(0.78, 0.88, 1.0), 0.18);
			tex.rgb = mix(tex.rgb, vec3(0.9, 0.96, 1.0), fr * 0.75);
			tex.rgb += step(0.72, vnoise(nuv * 45.0)) * fr * 0.15;
		}
		if (sticky > 0.5) { // a spill of homemade liquor: amber glaze, glossy drips from the top
			float drip = step(uv.y, 0.12 + 0.3 * vnoise(vec2(uv.x * 11.0 + seed.x, 0.5)) * step(0.4, vnoise(vec2(uv.x * 23.0, 1.5))));
			float puddle = smoothstep(0.55, 0.75, vnoise(nuv * 3.0));
			vec3 amber = vec3(0.78, 0.5, 0.14);
			tex.rgb = mix(tex.rgb, tex.rgb * amber * 1.35, 0.3 + 0.35 * max(drip, puddle));
			tex.rgb += vec3(0.25, 0.2, 0.1) * step(0.9, vnoise(nuv * 30.0 + TIME * 0.2)) * max(drip, puddle); // glints
		}
		if (burn > 0.0) { // burning away: gone behind an ember edge, scorched ahead of it
			float n = vnoise(nuv * 5.0) * 0.65 + vnoise(nuv * 17.0) * 0.35;
			float t = burn * 1.25 - 0.1;
			if (n < t - 0.05) {
				tex.a = 0.0;
			} else if (n < t) {
				tex.rgb = mix(vec3(1.0, 0.78, 0.25), vec3(0.9, 0.25, 0.05), (t - n) / 0.05);
			} else {
				tex.rgb *= 1.0 - 0.75 * (1.0 - smoothstep(t, t + 0.12, n));
			}
		}

		// Tilt light, cel style: the half tipped toward you steps up a band, the
		// far half steps down, and a hard-edged sheen slides across as the
		// angle changes (stronger on the trump copper / Joker gold).
		float tilt_amt = clamp(length(vec2(rot_x, rot_y)) * 4.0, 0.0, 1.0);
		tex.rgb *= 1.0 + 0.1 * tilt_amt * (step(0.04, depth) - step(depth, -0.04));
		float sheen_at = (uv.x + uv.y) * 0.5 - 0.5 - (rot_y - rot_x) * 1.6;
		float sheen = step(abs(sheen_at), 0.06) * tilt_amt;
		tex.rgb = mix(tex.rgb, vec3(1.0, 0.96, 0.86), sheen * (trump > 0.5 || joker > 0.5 ? 0.25 : 0.1));
		// Can't be played: drained of colour and pushed into shadow, like a card
		// left face-up under the lamp too long - reads at a glance, no overlay.
		float grey = dot(tex.rgb, vec3(0.3, 0.59, 0.11));
		tex.rgb = mix(tex.rgb, vec3(grey) * vec3(0.62, 0.6, 0.55), clamp(invalid, 0.0, 1.0) * 0.8);
		COLOR = tex * v_modulate; // keep game.gd's dimming (modulate.a)
	}
}
