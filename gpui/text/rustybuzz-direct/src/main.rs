//! Isolates the shaping engine: rustybuzz alone, with the same hardcoded
//! direction/script/language and a pre-allocated glyph array as the Zig
//! C-HarfBuzz path. No bidi analysis, no fallback resolution, no run
//! segmentation, no per-call allocation of the result.
use rustybuzz::{Direction, Face, UnicodeBuffer, script, Language};
use std::str::FromStr;

const FONT: &str = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
const FONT_SIZE: f32 = 14.0;

#[derive(Clone, Copy, Default)]
struct Glyph { index: u32, id: u32, x: f32 }

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(|s| s.as_str()).unwrap_or("report");
    let corpus_path = args.get(2).map(|s| s.as_str())
        .unwrap_or("/Dev/dev/uiwing-bench/gpui/text/ref/corpus_no_fallback.txt");
    let iters: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(2000);

    let font_data = std::fs::read(FONT).expect("font");
    let face = Face::from_slice(&font_data, 0).expect("face");
    let upem = face.units_per_em() as f32;
    let px_per_unit = FONT_SIZE / upem;

    let text = std::fs::read_to_string(corpus_path).expect("corpus");
    let chars = text.chars().count();

    let mut out: Vec<Glyph> = vec![Glyph::default(); text.len() + 16];
    let lang = Language::from_str("en").unwrap();

    // rustybuzz consumes and returns the buffer, so it is moved in and out
    // rather than reset in place; that is the library's intended pattern.
    let mut buffer = Some(UnicodeBuffer::new());

    let shape_once = |buffer: &mut Option<UnicodeBuffer>, out: &mut Vec<Glyph>| -> usize {
        let mut b = buffer.take().unwrap();
        b.clear();
        b.push_str(&text);
        b.set_direction(Direction::LeftToRight);
        b.set_script(script::LATIN);
        b.set_language(lang.clone());
        let g = rustybuzz::shape(&face, &[], b);
        let infos = g.glyph_infos();
        let posns = g.glyph_positions();
        let n = infos.len().min(out.len());
        let mut x = 0.0f32;
        for i in 0..n {
            out[i] = Glyph {
                index: infos[i].cluster,
                id: infos[i].glyph_id,
                x: x + posns[i].x_offset as f32 * px_per_unit,
            };
            x += posns[i].x_advance as f32 * px_per_unit;
        }
        *buffer = Some(g.clear());
        n
    };

    match mode {
        "verify" => {
            let n = shape_once(&mut buffer, &mut out);
            let mut s = format!("# shaper=rustybuzz-direct font_size={} glyphs={}\n", FONT_SIZE, n);
            for g in &out[..n] {
                s.push_str(&format!("{} {} {:.4}\n", g.index, g.id, g.x));
            }
            std::fs::write("rustybuzz_direct.dump", s).unwrap();
            eprintln!("chars={} glyphs={} wrote rustybuzz_direct.dump", chars, n);
        }
        "perf" => {
            let mut acc = 0usize;
            for _ in 0..iters { acc += shape_once(&mut buffer, &mut out); }
            std::hint::black_box(acc);
        }
        _ => {
            for _ in 0..50 { shape_once(&mut buffer, &mut out); }
            let mut best = u128::MAX;
            let mut sum = 0u128;
            let mut n = 0;
            for _ in 0..iters {
                let t0 = std::time::Instant::now();
                n = shape_once(&mut buffer, &mut out);
                let dt = t0.elapsed().as_nanos();
                sum += dt;
                if dt < best { best = dt; }
            }
            let mean = sum / iters as u128;
            println!("chars={} glyphs={}", chars, n);
            println!("  mean {} ns/call, best {} ns/call", mean, best);
            println!("  mean {:.1} ns/char, best {:.1} ns/char",
                mean as f64 / chars as f64, best as f64 / chars as f64);
        }
    }
}
