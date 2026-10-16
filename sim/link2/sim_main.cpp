// Driver for tb_link2: two NGPCs on a simulated link cable.
//
//   Vtb_link2 +bios=<hex> +cart0=<hex> +cart0_bytes=<n> +cart1=<hex> +cart1_bytes=<n>
//             +script=<file> [+out=<dir>] [+restore=<checkpoint>] [+frames=<n>]
//             [+shot_every=<n>] [+sameclock] [+linklog=<file>]
//
// +sameclock drives both machines from machine A's clock: half the evaluation
// steps. The link transport's tolerance of two different clocks is covered by
// sim/eq/tb_link.sv; here the point is the games.
//
// Time is counted in machine A's frames (vblank edges). The script holds one
// command per line, run at the start of the given frame:
//
//   <frame> A|B|AB press <buttons> <frames>   hold buttons (U D L R A B O)
//   <frame> A|B|AB link on|off                the Link Cable menu option
//   <frame> -  cable in|out                   plug or unplug the cable
//   <frame> -  shot [label]                   PNG of both screens
//   <frame> -  save <name>                    checkpoint (resume with +restore)
//   <frame> -  end
//
// Lines starting with # are comments.

#include "Vtb_link2.h"
#include "verilated.h"
#include "verilated_save.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

// clk_sys is 49.152 MHz. Machine B runs about 300 ppm slow, more than two
// Pockets' oscillators differ.
static const uint64_t HALF_A_PS = 10173;
static const uint64_t HALF_B_PS = 10176;

// ---- a minimal PNG writer (stored deflate, no compression) ----------------
static uint32_t crc_table[256];
static void crc_init() {
	for (uint32_t n = 0; n < 256; n++) {
		uint32_t c = n;
		for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
		crc_table[n] = c;
	}
}
static uint32_t crc(const uint8_t* p, size_t n, uint32_t c = 0xFFFFFFFFu) {
	for (size_t i = 0; i < n; i++) c = crc_table[(c ^ p[i]) & 0xFF] ^ (c >> 8);
	return c;
}
static void be32(std::vector<uint8_t>& v, uint32_t x) {
	v.push_back(x >> 24); v.push_back(x >> 16); v.push_back(x >> 8); v.push_back(x);
}
static void chunk(FILE* f, const char* type, const std::vector<uint8_t>& data) {
	std::vector<uint8_t> b;
	be32(b, (uint32_t)data.size());
	b.insert(b.end(), type, type + 4);
	b.insert(b.end(), data.begin(), data.end());
	uint32_t c = crc(b.data() + 4, b.size() - 4) ^ 0xFFFFFFFFu;
	be32(b, c);
	fwrite(b.data(), 1, b.size(), f);
}
static void write_png(const std::string& path, int w, int h, const std::vector<uint32_t>& px) {
	FILE* f = fopen(path.c_str(), "wb");
	if (!f) { fprintf(stderr, "cannot write %s\n", path.c_str()); return; }
	static const uint8_t sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
	fwrite(sig, 1, 8, f);
	std::vector<uint8_t> ihdr;
	be32(ihdr, w); be32(ihdr, h);
	ihdr.push_back(8); ihdr.push_back(2); ihdr.push_back(0); ihdr.push_back(0); ihdr.push_back(0);
	chunk(f, "IHDR", ihdr);
	std::vector<uint8_t> raw;
	for (int y = 0; y < h; y++) {
		raw.push_back(0);
		for (int x = 0; x < w; x++) {
			uint32_t p = px[(size_t)y * w + x];
			raw.push_back(p >> 16); raw.push_back(p >> 8); raw.push_back(p);
		}
	}
	std::vector<uint8_t> z = {0x78, 0x01};
	uint32_t a = 1, b = 0;
	for (uint8_t c : raw) { a = (a + c) % 65521; b = (b + a) % 65521; }
	for (size_t off = 0; off < raw.size(); off += 65535) {
		size_t n = std::min<size_t>(65535, raw.size() - off);
		z.push_back(off + n == raw.size() ? 1 : 0);
		z.push_back(n & 0xFF); z.push_back(n >> 8);
		z.push_back(~n & 0xFF); z.push_back((~n >> 8) & 0xFF);
		z.insert(z.end(), raw.begin() + off, raw.begin() + off + n);
	}
	be32(z, (b << 16) | a);
	chunk(f, "IDAT", z);
	chunk(f, "IEND", {});
	fclose(f);
}

// ---- one screen's capture ---------------------------------------------------
struct Screen {
	std::vector<uint32_t> cur, last;
	int x = 0, y = 0, w = 0, h = 0, lw = 0, lh = 0;
	bool hbl_q = true, vbl_q = true;
	uint64_t frames = 0;
	void sample(bool ce, bool hbl, bool vbl, uint8_t r, uint8_t g, uint8_t b) {
		if (cur.empty()) cur.assign(256 * 256, 0);
		if (ce && !hbl && !vbl && x < 256 && y < 256) {
			cur[(size_t)y * 256 + x] = (r << 16) | (g << 8) | b;
			x++;
			if (x > w) w = x;
		}
		if (hbl && !hbl_q && x > 0) { y++; x = 0; }
		if (vbl && !vbl_q) {
			if (y > 0) { last = cur; lw = w; lh = y; frames++; }
			x = 0; y = 0; w = 0;
		}
		hbl_q = hbl; vbl_q = vbl;
	}
	void save(const std::string& path) const {
		if (lw == 0 || lh == 0) return;
		std::vector<uint32_t> px((size_t)lw * lh);
		for (int yy = 0; yy < lh; yy++)
			for (int xx = 0; xx < lw; xx++) px[(size_t)yy * lw + xx] = last[(size_t)yy * 256 + xx];
		write_png(path, lw, lh, px);
	}
};

// ---- what crosses the cable ----------------------------------------------
// Decodes one side's link frames off its SO wire (the same 6-bit frames
// ngpc_link.sv sends: start, TxD, RTS_n, tag, parity, stop at 48 clk_sys per
// bit), which gives that machine's serial TxD0 and RTS_n as the other side
// rebuilds them; then decodes TxD0 as 19200 bps 8N1 (2560 clk_sys per bit).
// It only watches the wire, so it changes nothing in the simulated design.
struct LinkTap {
	// frame decoder
	bool busy = false, prev = true;
	int cnt = 0, bit = 0;
	bool smp[6] = {};
	bool txd = true, rts_n = true;
	uint64_t frames_ok = 0, frames_bad = 0;
	// UART decoder on the rebuilt TxD
	int ust = 0, ucnt = 0, ubit = 0;
	uint8_t ub = 0;
	bool txd_prev = true;
	uint64_t bytes = 0, uart_errors = 0, rts_changes = 0;
	bool rts_prev = true;
	std::vector<uint8_t> recent;
	FILE* log = nullptr;
	const char* name = "";

	void clk(bool s, uint64_t frame) {
		if (!busy) {
			if (prev && !s) { busy = true; cnt = 23; bit = 0; }
		} else if (cnt) {
			cnt--;
		} else {
			smp[bit] = s;
			if (bit == 0 && s) busy = false;
			else if (bit == 5) {
				busy = false;
				bool ok = s && (smp[1] ^ smp[2] ^ smp[3] ^ smp[4]);
				if (ok) { txd = smp[1]; rts_n = smp[2]; frames_ok++; } else frames_bad++;
			} else { bit++; cnt = 47; }
		}
		prev = s;

		if (rts_n != rts_prev) {
			rts_changes++;
			if (log) fprintf(log, "%llu %s RTS_n=%d\n", (unsigned long long)frame, name, rts_n);
			rts_prev = rts_n;
		}
		// 19200 8N1: start edge, sample mid-bit
		if (ust == 0) {
			if (txd_prev && !txd) { ust = 1; ucnt = 1280; }
		} else if (--ucnt == 0) {
			if (ust == 1) {
				if (txd) ust = 0; else { ust = 2; ubit = 0; ub = 0; ucnt = 2560; }
			} else if (ust == 2) {
				ub |= (txd ? 1 : 0) << ubit;
				if (++ubit == 8) ust = 3;
				ucnt = 2560;
			} else {
				if (txd) {
					bytes++;
					recent.push_back(ub);
					if (recent.size() > 8) recent.erase(recent.begin());
					if (log) fprintf(log, "%llu %s %02X\n", (unsigned long long)frame, name, ub);
				} else uart_errors++;
				ust = 0;
			}
		}
		txd_prev = txd;
	}
	std::string summary() const {
		char b[160];
		std::string r;
		for (uint8_t x : recent) { snprintf(b, sizeof b, "%02X ", x); r += b; }
		snprintf(b, sizeof b, "%s: %llu bytes [%s] RTS_n %d (%llu changes)", name,
			(unsigned long long)bytes, r.c_str(), rts_n, (unsigned long long)rts_changes);
		return b;
	}
};

struct Cmd { uint64_t frame; std::string who, op, a1, a2; };

static uint8_t buttons(const std::string& s) {
	uint8_t m = 0;
	for (char c : s) switch (c) {
		case 'U': m |= 1; break;  case 'D': m |= 2; break;  case 'L': m |= 4; break;
		case 'R': m |= 8; break;  case 'A': m |= 16; break; case 'B': m |= 32; break;
		case 'O': m |= 64; break;
	}
	return m;
}

int main(int argc, char** argv) {
	crc_init();
	auto ctx = std::make_unique<VerilatedContext>();
	ctx->commandArgs(argc, argv);
	auto top = std::make_unique<Vtb_link2>(ctx.get());

	// commandArgsPlusMatch returns "" (not null) when the option is absent.
	auto arg = [&](const char* name) -> const char* {
		const char* s = ctx->commandArgsPlusMatch(name);
		return (s && *s) ? s : nullptr;
	};
	std::string out = ".", script, restore;
	if (const char* s = arg("out=")) out = std::string(s).substr(5);
	if (const char* s = arg("script=")) script = std::string(s).substr(8);
	if (const char* s = arg("restore=")) restore = std::string(s).substr(9);
	uint64_t max_frames = 1000000, shot_every = 0;
	const bool same_clock = arg("sameclock") != nullptr;
	if (const char* s = arg("frames=")) max_frames = strtoull(s + 8, 0, 10);
	if (const char* s = arg("shot_every=")) shot_every = strtoull(s + 12, 0, 10);

	std::vector<Cmd> cmds;
	if (!script.empty()) {
		std::ifstream in(script);
		std::string line;
		while (std::getline(in, line)) {
			if (line.empty() || line[0] == '#') continue;
			std::istringstream ss(line);
			Cmd c;
			if (!(ss >> c.frame >> c.who >> c.op)) continue;
			ss >> c.a1 >> c.a2;
			cmds.push_back(c);
		}
	}

	Screen sa, sb;
	LinkTap ta, tb;
	ta.name = "A>B"; tb.name = "B>A";
	if (const char* s = arg("linklog=")) {
		FILE* lf = fopen(std::string(s).substr(9).c_str(), "a");
		ta.log = tb.log = lf;
	}
	uint64_t t_a = 0, t_b = HALF_B_PS / 2, edges_a = 0;
	uint64_t hold_a = 0, hold_b = 0;   // frame at which the held buttons release
	uint64_t frame = 0;
	size_t next_cmd = 0;

	top->clk_a = 0; top->clk_b = 0; top->reset = 1;
	top->btn_a = 0; top->btn_b = 0;
	top->link_en_a = 0; top->link_en_b = 0; top->cable = 1;

	if (!restore.empty()) {
		VerilatedRestore is;
		is.open(restore.c_str());
		is >> t_a >> t_b >> edges_a >> hold_a >> hold_b >> frame >> sa.frames >> sb.frames;
		is >> *top;
		is.close();
		while (next_cmd < cmds.size() && cmds[next_cmd].frame < frame) next_cmd++;
		// A checkpoint taken with +sameclock never advanced machine B's own
		// schedule; continuing it on two clocks starts B's from here.
		if (!same_clock && t_b + 1000000 < t_a) t_b = t_a + HALF_B_PS / 2;
		printf("restored %s at frame %llu\n", restore.c_str(), (unsigned long long)frame);
	}

	auto wall0 = std::chrono::steady_clock::now();
	uint64_t edges0 = edges_a;
	bool done = false;
	uint64_t last_report = frame;

	while (!done && frame < max_frames) {
		bool rise_a = false, rise_b = false;
		if (same_clock) {
			top->clk_a = !top->clk_a; top->clk_b = top->clk_a; t_a += HALF_A_PS;
			rise_a = rise_b = top->clk_a;
			if (rise_a) edges_a++;
		} else if (t_a <= t_b) {
			top->clk_a = !top->clk_a; t_a += HALF_A_PS; rise_a = top->clk_a;
			if (rise_a) edges_a++;
		} else {
			top->clk_b = !top->clk_b; t_b += HALF_B_PS; rise_b = top->clk_b;
		}
		if (edges_a == 64) top->reset = 0;
		top->eval();

		if (rise_a) ta.clk(top->so_a_o, frame);
		if (rise_b) tb.clk(top->so_b_o, frame);
		if (rise_a) {
			uint64_t before = sa.frames;
			sa.sample(top->ce_pix_a, top->hbl_a, top->vbl_a, top->r_a, top->g_a, top->b_a);
			if (sa.frames != before) {
				frame = sa.frames;
				if (frame >= hold_a) top->btn_a = 0;
				if (frame >= hold_b) top->btn_b = 0;
				if (shot_every && frame % shot_every == 0) {
					char n[64]; snprintf(n, sizeof n, "/f%06llu", (unsigned long long)frame);
					sa.save(out + n + "_A.png"); sb.save(out + n + "_B.png");
				}
				while (next_cmd < cmds.size() && cmds[next_cmd].frame <= frame) {
					const Cmd& c = cmds[next_cmd++];
					bool on_a = c.who.find('A') != std::string::npos;
					bool on_b = c.who.find('B') != std::string::npos;
					if (c.op == "press") {
						uint8_t m = buttons(c.a1);
						uint64_t n = c.a2.empty() ? 3 : strtoull(c.a2.c_str(), 0, 10);
						if (on_a) { top->btn_a = m; hold_a = frame + n; }
						if (on_b) { top->btn_b = m; hold_b = frame + n; }
					} else if (c.op == "link") {
						if (on_a) top->link_en_a = (c.a1 == "on");
						if (on_b) top->link_en_b = (c.a1 == "on");
					} else if (c.op == "cable") {
						top->cable = (c.a1 == "in");
					} else if (c.op == "shot") {
						char n[96]; snprintf(n, sizeof n, "/s%06llu%s%s", (unsigned long long)frame,
							c.a1.empty() ? "" : "_", c.a1.c_str());
						sa.save(out + n + "_A.png"); sb.save(out + n + "_B.png");
						printf("frame %llu: shot %s\n", (unsigned long long)frame, n + 1);
					} else if (c.op == "save") {
						std::string p = out + "/" + c.a1 + ".ckpt";
						VerilatedSave os;
						os.open(p.c_str());
						os << t_a << t_b << edges_a << hold_a << hold_b << frame << sa.frames << sb.frames;
						os << *top;
						os.close();
						printf("frame %llu: saved %s\n", (unsigned long long)frame, p.c_str());
					} else if (c.op == "end") {
						done = true;
					}
				}
				if (frame - last_report >= 60) {
					last_report = frame;
					double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - wall0).count();
					printf("frame %llu  B %llu  present %d/%d  powered %d/%d  link %d/%d  %.0f s wall, %.2f MHz\n",
						(unsigned long long)frame, (unsigned long long)sb.frames,
						top->present_a, top->present_b, top->powered_a, top->powered_b,
						top->link_en_a, top->link_en_b, s, (edges_a - edges0) / s / 1e6);
					printf("    %s | %s\n", ta.summary().c_str(), tb.summary().c_str());
					if (ta.log) fflush(ta.log);
					fflush(stdout);
				}
			}
		}
		if (rise_b)
			sb.sample(top->ce_pix_b, top->hbl_b, top->vbl_b, top->r_b, top->g_b, top->b_b);
	}

	sa.save(out + "/last_A.png");
	sb.save(out + "/last_B.png");
	printf("stopped at frame %llu\n", (unsigned long long)frame);
	top->final();
	return 0;
}
