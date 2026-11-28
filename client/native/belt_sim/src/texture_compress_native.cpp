// SPDX-License-Identifier: GPL-3.0-or-later
#include "texture_compress_native.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cstring>
#include <vector>

using namespace godot;

namespace {

inline int clamp_u8(int v) {
	return v < 0 ? 0 : (v > 255 ? 255 : v);
}

inline uint16_t pack_rgb565(int r, int g, int b) {
	const uint16_t r5 = static_cast<uint16_t>((clamp_u8(r) * 31 + 127) / 255);
	const uint16_t g6 = static_cast<uint16_t>((clamp_u8(g) * 63 + 127) / 255);
	const uint16_t b5 = static_cast<uint16_t>((clamp_u8(b) * 31 + 127) / 255);
	return static_cast<uint16_t>((r5 << 11) | (g6 << 5) | b5);
}

inline void expand_rgb565(uint16_t c, int &r, int &g, int &b) {
	const int r5 = (c >> 11) & 31;
	const int g6 = (c >> 5) & 63;
	const int b5 = c & 31;
	r = (r5 << 3) | (r5 >> 2);
	g = (g6 << 2) | (g6 >> 4);
	b = (b5 << 3) | (b5 >> 2);
}

inline void decode_bc1_palette(uint16_t c0, uint16_t c1, int pr[4], int pg[4], int pb[4]) {
	expand_rgb565(c0, pr[0], pg[0], pb[0]);
	expand_rgb565(c1, pr[1], pg[1], pb[1]);
	pr[2] = (2 * pr[0] + pr[1]) / 3;
	pg[2] = (2 * pg[0] + pg[1]) / 3;
	pb[2] = (2 * pb[0] + pb[1]) / 3;
	pr[3] = (pr[0] + 2 * pr[1]) / 3;
	pg[3] = (pg[0] + 2 * pg[1]) / 3;
	pb[3] = (pb[0] + 2 * pb[1]) / 3;
}

inline uint32_t match_bc1_indices(const uint8_t blk_r[16], const uint8_t blk_g[16], const uint8_t blk_b[16],
		const int pr[4], const int pg[4], const int pb[4], int64_t &out_err, uint8_t out_idx[16]) {
	uint32_t mask = 0;
	int64_t err_sum = 0;
	for (int i = 0; i < 16; i++) {
		const int r = blk_r[i];
		const int g = blk_g[i];
		const int b = blk_b[i];
		int best_k = 0;
		int best_d = 0x7fffffff;
		for (int k = 0; k < 4; k++) {
			const int dr = r - pr[k];
			const int dg = g - pg[k];
			const int db = b - pb[k];
			const int d = dr * dr + dg * dg + db * db;
			if (d < best_d) {
				best_d = d;
				best_k = k;
			}
		}
		out_idx[i] = static_cast<uint8_t>(best_k);
		mask |= static_cast<uint32_t>(best_k) << (2 * i);
		err_sum += best_d;
	}
	out_err = err_sum;
	return mask;
}

void compress_bc1_block(const uint8_t blk_r[16], const uint8_t blk_g[16], const uint8_t blk_b[16], uint8_t out[8]) {
	int min_r = 255, min_g = 255, min_b = 255;
	int max_r = 0, max_g = 0, max_b = 0;
	for (int i = 0; i < 16; i++) {
		const int r = blk_r[i];
		const int g = blk_g[i];
		const int b = blk_b[i];
		if (r < min_r) min_r = r;
		if (r > max_r) max_r = r;
		if (g < min_g) min_g = g;
		if (g > max_g) max_g = g;
		if (b < min_b) min_b = b;
		if (b > max_b) max_b = b;
	}

	if (min_r == max_r && min_g == max_g && min_b == max_b) {
		const uint16_t c0 = pack_rgb565(min_r, min_g, min_b);
		out[0] = static_cast<uint8_t>(c0 & 0xff);
		out[1] = static_cast<uint8_t>((c0 >> 8) & 0xff);
		out[2] = out[0];
		out[3] = out[1];
		out[4] = 0;
		out[5] = 0;
		out[6] = 0;
		out[7] = 0;
		return;
	}

	// Pick the bounding-box diagonal that follows channel correlations around the midpoint.
	const int span_r = max_r - min_r;
	const int span_g = max_g - min_g;
	const int span_b = max_b - min_b;
	const int sum_mid_r = min_r + max_r;
	const int sum_mid_g = min_g + max_g;
	const int sum_mid_b = min_b + max_b;

	int e0_r = min_r, e0_g = min_g, e0_b = min_b;
	int e1_r = max_r, e1_g = max_g, e1_b = max_b;

	if (span_g >= span_r && span_g >= span_b) {
		int64_t cov_gr = 0, cov_gb = 0;
		for (int i = 0; i < 16; i++) {
			const int64_t dr = 2 * blk_r[i] - sum_mid_r;
			const int64_t dg = 2 * blk_g[i] - sum_mid_g;
			const int64_t db = 2 * blk_b[i] - sum_mid_b;
			cov_gr += dg * dr;
			cov_gb += dg * db;
		}
		if (cov_gr < 0) std::swap(e0_r, e1_r);
		if (cov_gb < 0) std::swap(e0_b, e1_b);
	} else if (span_r >= span_g && span_r >= span_b) {
		int64_t cov_rg = 0, cov_rb = 0;
		for (int i = 0; i < 16; i++) {
			const int64_t dr = 2 * blk_r[i] - sum_mid_r;
			const int64_t dg = 2 * blk_g[i] - sum_mid_g;
			const int64_t db = 2 * blk_b[i] - sum_mid_b;
			cov_rg += dr * dg;
			cov_rb += dr * db;
		}
		if (cov_rg < 0) std::swap(e0_g, e1_g);
		if (cov_rb < 0) std::swap(e0_b, e1_b);
	} else {
		int64_t cov_br = 0, cov_bg = 0;
		for (int i = 0; i < 16; i++) {
			const int64_t dr = 2 * blk_r[i] - sum_mid_r;
			const int64_t dg = 2 * blk_g[i] - sum_mid_g;
			const int64_t db = 2 * blk_b[i] - sum_mid_b;
			cov_br += db * dr;
			cov_bg += db * dg;
		}
		if (cov_br < 0) std::swap(e0_r, e1_r);
		if (cov_bg < 0) std::swap(e0_g, e1_g);
	}

	// Inset bounding box by 1/16th of span to reduce endpoint outlier distortion.
	const int inset_r = span_r >> 4;
	const int inset_g = span_g >> 4;
	const int inset_b = span_b >> 4;
	if (e0_r < e1_r) { e0_r += inset_r; e1_r -= inset_r; } else { e0_r -= inset_r; e1_r += inset_r; }
	if (e0_g < e1_g) { e0_g += inset_g; e1_g -= inset_g; } else { e0_g -= inset_g; e1_g += inset_g; }
	if (e0_b < e1_b) { e0_b += inset_b; e1_b -= inset_b; } else { e0_b -= inset_b; e1_b += inset_b; }

	uint16_t c0 = pack_rgb565(e0_r, e0_g, e0_b);
	uint16_t c1 = pack_rgb565(e1_r, e1_g, e1_b);
	if (c0 < c1) {
		std::swap(c0, c1);
	}

	uint32_t best_mask = 0;
	if (c0 == c1) {
		int pr0, pg0, pb0;
		expand_rgb565(c0, pr0, pg0, pb0);
		int64_t err0 = 0;
		for (int i = 0; i < 16; i++) {
			const int dr = blk_r[i] - pr0;
			const int dg = blk_g[i] - pg0;
			const int db = blk_b[i] - pb0;
			err0 += dr * dr + dg * dg + db * db;
		}
		// Try un-inset endpoints in case span was small but distinct in RGB565.
		uint16_t uc0 = pack_rgb565(min_r, min_g, min_b);
		uint16_t uc1 = pack_rgb565(max_r, max_g, max_b);
		if (uc0 < uc1) std::swap(uc0, uc1);
		if (uc0 > uc1) {
			int pr[4], pg[4], pb[4];
			decode_bc1_palette(uc0, uc1, pr, pg, pb);
			int64_t err_u = 0;
			uint8_t idx_u[16];
			const uint32_t mask_u = match_bc1_indices(blk_r, blk_g, blk_b, pr, pg, pb, err_u, idx_u);
			if (err_u < err0) {
				c0 = uc0;
				c1 = uc1;
				best_mask = mask_u;
			}
		}
	} else {
		int pr[4], pg[4], pb[4];
		decode_bc1_palette(c0, c1, pr, pg, pb);
		int64_t best_err = 0;
		uint8_t idx[16];
		best_mask = match_bc1_indices(blk_r, blk_g, blk_b, pr, pg, pb, best_err, idx);

		// One pass of least-squares endpoint refinement using the assigned weights.
		int aa = 0, ab = 0, bb = 0;
		int sr0 = 0, sg0 = 0, sb0 = 0;
		int sr1 = 0, sg1 = 0, sb1 = 0;
		for (int i = 0; i < 16; i++) {
			// Palette index weights: 0->(3,0), 1->(0,3), 2->(2,1), 3->(1,2).
			static constexpr int W0_TABLE[4] = {3, 0, 2, 1};
			static constexpr int W1_TABLE[4] = {0, 3, 1, 2};
			const int w0 = W0_TABLE[idx[i]];
			const int w1 = W1_TABLE[idx[i]];
			aa += w0 * w0;
			ab += w0 * w1;
			bb += w1 * w1;
			sr0 += w0 * blk_r[i];
			sg0 += w0 * blk_g[i];
			sb0 += w0 * blk_b[i];
			sr1 += w1 * blk_r[i];
			sg1 += w1 * blk_g[i];
			sb1 += w1 * blk_b[i];
		}
		const int det = aa * bb - ab * ab;
		if (det > 0) {
			const float inv_det = 3.0f / static_cast<float>(det);
			const int nr0 = static_cast<int>((bb * sr0 - ab * sr1) * inv_det + 0.5f);
			const int ng0 = static_cast<int>((bb * sg0 - ab * sg1) * inv_det + 0.5f);
			const int nb0 = static_cast<int>((bb * sb0 - ab * sb1) * inv_det + 0.5f);
			const int nr1 = static_cast<int>((aa * sr1 - ab * sr0) * inv_det + 0.5f);
			const int ng1 = static_cast<int>((aa * sg1 - ab * sg0) * inv_det + 0.5f);
			const int nb1 = static_cast<int>((aa * sb1 - ab * sb0) * inv_det + 0.5f);
			uint16_t nc0 = pack_rgb565(nr0, ng0, nb0);
			uint16_t nc1 = pack_rgb565(nr1, ng1, nb1);
			if (nc0 < nc1) {
				std::swap(nc0, nc1);
			}
			if (nc0 > nc1) {
				int npr[4], npg[4], npb[4];
				decode_bc1_palette(nc0, nc1, npr, npg, npb);
				int64_t new_err = 0;
				uint8_t new_idx[16];
				const uint32_t new_mask = match_bc1_indices(blk_r, blk_g, blk_b, npr, npg, npb, new_err, new_idx);
				if (new_err < best_err) {
					c0 = nc0;
					c1 = nc1;
					best_mask = new_mask;
				}
			}
		}
	}

	out[0] = static_cast<uint8_t>(c0 & 0xff);
	out[1] = static_cast<uint8_t>((c0 >> 8) & 0xff);
	out[2] = static_cast<uint8_t>(c1 & 0xff);
	out[3] = static_cast<uint8_t>((c1 >> 8) & 0xff);
	out[4] = static_cast<uint8_t>(best_mask & 0xff);
	out[5] = static_cast<uint8_t>((best_mask >> 8) & 0xff);
	out[6] = static_cast<uint8_t>((best_mask >> 16) & 0xff);
	out[7] = static_cast<uint8_t>((best_mask >> 24) & 0xff);
}

inline uint64_t match_alpha_indices(const uint8_t blk_a[16], const int pal[8], int64_t &out_err) {
	uint64_t bits = 0;
	int64_t err_sum = 0;
	for (int i = 0; i < 16; i++) {
		const int a = blk_a[i];
		int best_k = 0;
		int best_d = 0x7fffffff;
		for (int k = 0; k < 8; k++) {
			const int d = a - pal[k];
			const int d2 = d * d;
			if (d2 < best_d) {
				best_d = d2;
				best_k = k;
			}
		}
		bits |= static_cast<uint64_t>(best_k) << (3 * i);
		err_sum += best_d;
	}
	out_err = err_sum;
	return bits;
}

void compress_bc3_alpha_block(const uint8_t blk_a[16], uint8_t out[8]) {
	int min_a = 255, max_a = 0;
	int min_int = 255, max_int = 0;
	bool has_zero = false, has_255 = false, has_int = false;
	for (int i = 0; i < 16; i++) {
		const int a = blk_a[i];
		if (a < min_a) min_a = a;
		if (a > max_a) max_a = a;
		if (a == 0) {
			has_zero = true;
		} else if (a == 255) {
			has_255 = true;
		} else {
			has_int = true;
			if (a < min_int) min_int = a;
			if (a > max_int) max_int = a;
		}
	}

	if (min_a == max_a) {
		out[0] = static_cast<uint8_t>(max_a);
		out[1] = static_cast<uint8_t>(max_a);
		out[2] = 0;
		out[3] = 0;
		out[4] = 0;
		out[5] = 0;
		out[6] = 0;
		out[7] = 0;
		return;
	}

	// 8-alpha interpolated mode (alpha0 > alpha1).
	uint8_t best_a0 = static_cast<uint8_t>(max_a);
	uint8_t best_a1 = static_cast<uint8_t>(min_a);
	int pal8[8];
	pal8[0] = max_a;
	pal8[1] = min_a;
	for (int k = 1; k <= 6; k++) {
		pal8[k + 1] = ((7 - k) * max_a + k * min_a) / 7;
	}
	int64_t best_err = 0;
	uint64_t best_bits = match_alpha_indices(blk_a, pal8, best_err);

	// 6-alpha + 0 + 255 mode (alpha0 <= alpha1) when block mixes hard 0/255 edges with soft fringe alphas.
	if (has_int && (has_zero || has_255)) {
		const int a0_6 = min_int;
		const int a1_6 = max_int;
		int pal6[8];
		pal6[0] = a0_6;
		pal6[1] = a1_6;
		for (int k = 1; k <= 4; k++) {
			pal6[k + 1] = ((5 - k) * a0_6 + k * a1_6) / 5;
		}
		pal6[6] = 0;
		pal6[7] = 255;
		int64_t err6 = 0;
		const uint64_t bits6 = match_alpha_indices(blk_a, pal6, err6);
		if (err6 < best_err) {
			best_a0 = static_cast<uint8_t>(a0_6);
			best_a1 = static_cast<uint8_t>(a1_6);
			best_bits = bits6;
		}
	}

	out[0] = best_a0;
	out[1] = best_a1;
	for (int k = 0; k < 6; k++) {
		out[2 + k] = static_cast<uint8_t>((best_bits >> (8 * k)) & 0xff);
	}
}

void compress_level(const uint8_t *rgba, int w, int h, bool alpha, uint8_t *dst) {
	const int bx_count = (w + 3) >> 2;
	const int by_count = (h + 3) >> 2;
	const int block_bytes = alpha ? 16 : 8;

	uint8_t blk_r[16];
	uint8_t blk_g[16];
	uint8_t blk_b[16];
	uint8_t blk_a[16];

	for (int by = 0; by < by_count; by++) {
		const int y0 = by << 2;
		for (int bx = 0; bx < bx_count; bx++) {
			const int x0 = bx << 2;
			int idx = 0;
			for (int py = 0; py < 4; py++) {
				const int sy = std::min(y0 + py, h - 1);
				const uint8_t *row = rgba + (static_cast<int64_t>(sy) * w) * 4;
				for (int px = 0; px < 4; px++) {
					const int sx = std::min(x0 + px, w - 1);
					const uint8_t *p = row + (sx << 2);
					blk_r[idx] = p[0];
					blk_g[idx] = p[1];
					blk_b[idx] = p[2];
					blk_a[idx] = p[3];
					idx++;
				}
			}
			uint8_t *out = dst + (static_cast<int64_t>(by) * bx_count + bx) * block_bytes;
			if (alpha) {
				compress_bc3_alpha_block(blk_a, out);
				compress_bc1_block(blk_r, blk_g, blk_b, out + 8);
			} else {
				compress_bc1_block(blk_r, blk_g, blk_b, out);
			}
		}
	}
}

void downsample_box_2x2(const uint8_t *src, int w, int h, uint8_t *dst, int nw, int nh) {
	for (int y = 0; y < nh; y++) {
		const int sy0 = y * 2;
		const int sy1 = std::min(sy0 + 1, h - 1);
		const uint8_t *row0 = src + static_cast<int64_t>(sy0) * w * 4;
		const uint8_t *row1 = src + static_cast<int64_t>(sy1) * w * 4;
		uint8_t *out_row = dst + static_cast<int64_t>(y) * nw * 4;
		for (int x = 0; x < nw; x++) {
			const int sx0 = x * 2;
			const int sx1 = std::min(sx0 + 1, w - 1);
			const uint8_t *p00 = row0 + (sx0 << 2);
			const uint8_t *p01 = row0 + (sx1 << 2);
			const uint8_t *p10 = row1 + (sx0 << 2);
			const uint8_t *p11 = row1 + (sx1 << 2);
			uint8_t *d = out_row + (x << 2);
			for (int c = 0; c < 4; c++) {
				d[c] = static_cast<uint8_t>((p00[c] + p01[c] + p10[c] + p11[c] + 2) >> 2);
			}
		}
	}
}

int64_t calc_expected_bc_bytes(int w, int h, bool alpha, bool mipmaps) {
	if (w <= 0 || h <= 0) {
		return 0;
	}
	const int64_t block_bytes = alpha ? 16 : 8;
	int64_t total = 0;
	int mw = w;
	int mh = h;
	while (true) {
		const int64_t bx = (mw + 3) >> 2;
		const int64_t by = (mh + 3) >> 2;
		total += bx * by * block_bytes;
		if (!mipmaps || (mw == 1 && mh == 1)) {
			break;
		}
		mw = std::max(1, mw >> 1);
		mh = std::max(1, mh >> 1);
	}
	return total;
}

int64_t calc_expected_rgba_bytes(int w, int h, bool mipmaps) {
	if (w <= 0 || h <= 0) {
		return 0;
	}
	int64_t total = 0;
	int mw = w;
	int mh = h;
	while (true) {
		total += static_cast<int64_t>(mw) * mh * 4;
		if (!mipmaps || (mw == 1 && mh == 1)) {
			break;
		}
		mw = std::max(1, mw >> 1);
		mh = std::max(1, mh >> 1);
	}
	return total;
}

PackedByteArray compress_rgba_impl(const uint8_t *rgba_data, int64_t data_size, int w, int h,
		bool alpha, bool input_has_mips, bool generate_mipmaps) {
	PackedByteArray out;
	if (w <= 0 || h <= 0 || rgba_data == nullptr) {
		return out;
	}
	const int64_t base_rgba = static_cast<int64_t>(w) * h * 4;
	if (data_size < base_rgba) {
		return out;
	}
	const bool out_mips = input_has_mips || generate_mipmaps;
	if (input_has_mips && data_size < calc_expected_rgba_bytes(w, h, true)) {
		return out;
	}

	const int64_t out_bytes = calc_expected_bc_bytes(w, h, alpha, out_mips);
	out.resize(out_bytes);
	uint8_t *dst = out.ptrw();

	const int block_bytes = alpha ? 16 : 8;
	int mw = w;
	int mh = h;
	int64_t dst_off = 0;

	if (input_has_mips) {
		int64_t src_off = 0;
		while (true) {
			compress_level(rgba_data + src_off, mw, mh, alpha, dst + dst_off);
			const int64_t bx = (mw + 3) >> 2;
			const int64_t by = (mh + 3) >> 2;
			dst_off += bx * by * block_bytes;
			src_off += static_cast<int64_t>(mw) * mh * 4;
			if (mw == 1 && mh == 1) {
				break;
			}
			mw = std::max(1, mw >> 1);
			mh = std::max(1, mh >> 1);
		}
		return out;
	}

	compress_level(rgba_data, mw, mh, alpha, dst);
	if (!generate_mipmaps || (mw == 1 && mh == 1)) {
		return out;
	}

	dst_off += ((static_cast<int64_t>(mw) + 3) >> 2) * ((static_cast<int64_t>(mh) + 3) >> 2) * block_bytes;
	std::vector<uint8_t> buf_a;
	std::vector<uint8_t> buf_b;
	const uint8_t *cur = rgba_data;

	while (mw > 1 || mh > 1) {
		const int nw = std::max(1, mw >> 1);
		const int nh = std::max(1, mh >> 1);
		std::vector<uint8_t> &next_buf = (cur == buf_a.data()) ? buf_b : buf_a;
		next_buf.resize(static_cast<size_t>(nw) * nh * 4);
		downsample_box_2x2(cur, mw, mh, next_buf.data(), nw, nh);
		compress_level(next_buf.data(), nw, nh, alpha, dst + dst_off);
		dst_off += ((static_cast<int64_t>(nw) + 3) >> 2) * ((static_cast<int64_t>(nh) + 3) >> 2) * block_bytes;
		cur = next_buf.data();
		mw = nw;
		mh = nh;
	}
	return out;
}

} // namespace

PackedByteArray TextureCompressNative::compress_bc1(const PackedByteArray &p_rgba_bytes, int p_width, int p_height,
		bool p_generate_mipmaps) const {
	return compress_rgba_impl(p_rgba_bytes.ptr(), p_rgba_bytes.size(), p_width, p_height, false, false, p_generate_mipmaps);
}

PackedByteArray TextureCompressNative::compress_bc3(const PackedByteArray &p_rgba_bytes, int p_width, int p_height,
		bool p_generate_mipmaps) const {
	return compress_rgba_impl(p_rgba_bytes.ptr(), p_rgba_bytes.size(), p_width, p_height, true, false, p_generate_mipmaps);
}

Ref<Image> TextureCompressNative::compress_image(const Ref<Image> &p_img, bool p_alpha, bool p_generate_mipmaps) const {
	if (p_img.is_null() || p_img->is_empty()) {
		return Ref<Image>();
	}
	Ref<Image> src = p_img;
	if (src->is_compressed() || src->get_format() != Image::FORMAT_RGBA8) {
		Ref<Image> copy = src->duplicate();
		if (copy.is_null() || copy->is_empty()) {
			return Ref<Image>();
		}
		if (copy->is_compressed()) {
			if (copy->decompress() != OK) {
				return Ref<Image>();
			}
		}
		if (copy->get_format() != Image::FORMAT_RGBA8) {
			copy->convert(Image::FORMAT_RGBA8);
		}
		src = copy;
	}

	const int w = src->get_width();
	const int h = src->get_height();
	const bool has_mips = src->has_mipmaps();
	const PackedByteArray rgba = src->get_data();
	const PackedByteArray compressed = compress_rgba_impl(
			rgba.ptr(), rgba.size(), w, h, p_alpha, has_mips, p_generate_mipmaps);
	if (compressed.is_empty()) {
		return Ref<Image>();
	}
	const Image::Format fmt = p_alpha ? Image::FORMAT_DXT5 : Image::FORMAT_DXT1;
	return Image::create_from_data(w, h, has_mips || p_generate_mipmaps, fmt, compressed);
}

int64_t TextureCompressNative::expected_size(int p_width, int p_height, bool p_alpha, bool p_mipmaps) const {
	return calc_expected_bc_bytes(p_width, p_height, p_alpha, p_mipmaps);
}

void TextureCompressNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("version"), &TextureCompressNative::version);
	ClassDB::bind_method(D_METHOD("compress_bc1", "rgba_bytes", "width", "height", "generate_mipmaps"),
			&TextureCompressNative::compress_bc1, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("compress_bc3", "rgba_bytes", "width", "height", "generate_mipmaps"),
			&TextureCompressNative::compress_bc3, DEFVAL(true));
	ClassDB::bind_method(D_METHOD("compress_image", "img", "alpha", "generate_mipmaps"),
			&TextureCompressNative::compress_image, DEFVAL(false), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("expected_size", "width", "height", "alpha", "mipmaps"),
			&TextureCompressNative::expected_size, DEFVAL(false), DEFVAL(true));
}
