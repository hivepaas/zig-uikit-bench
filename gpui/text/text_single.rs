//! Fixed-iteration runner so perf counters divide by call count.
//! Mirrors zig/src/single.zig on the Zig side.
use gpui::{FontFallbacks, FontRun, PlatformTextSystem, font, px};
use gpui_wgpu::CosmicTextSystem;
use std::borrow::Cow;

const PRIMARY_FAMILY: &str = "DejaVu Sans Mono";
const FALLBACK_FAMILY: &str = "DejaVu Sans";
const PRIMARY_PATH: &str = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
const FALLBACK_PATH: &str = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";

// ~4 000 chars of typical ASCII code text, as a single display line.
//
// `layout_line` is handed one line at a time, already split on `\n` by its
// callers, so the newlines are replaced rather than kept: leaving them in would
// make this measure the multi-paragraph path instead of the common one, since
// `\n` is itself a bidi paragraph separator.
fn code_text() -> String {
    concat!(
        "    fn compute_run_spans(\n",
        "        text: &str,\n",
        "        run_offset: usize,\n",
        "        run_len: usize,\n",
        "        primary: FontId,\n",
        "        fallback_chain: &[(FontId, SharedString)],\n",
        "        covers: &impl Fn(FontId, char) -> bool,\n",
        "    ) -> SmallVec<[RunSpan; 4]> {\n",
        "        let mut spans = SmallVec::new();\n",
        "        let run_end = run_offset + run_len;\n",
        "        if run_end <= run_offset { return spans; }\n",
        "        let run_text = &text[run_offset..run_end];\n",
        "        let mut span_start = run_offset;\n",
        "        let mut span_slot: Option<usize> = None;\n",
        "        for (ch_idx, ch) in run_text.char_indices() {\n",
        "            let abs = run_offset + ch_idx;\n",
        "            let next = pick_covering_slot(ch, span_slot, primary, fallback_chain, covers);\n",
        "            if next == span_slot { continue; }\n",
        "            if abs > span_start {\n",
        "                spans.push(RunSpan { start: span_start, end: abs, slot: span_slot });\n",
        "            }\n",
        "            span_start = abs;\n",
        "            span_slot = next;\n",
        "        }\n",
        "        spans\n",
        "    }\n",
    )
    .repeat(8) // ~3 800 chars
    .replace('\n', " ")
}


fn main() {
    let args: Vec<String> = std::env::args().collect();
    let which = args.get(1).map(|s| s.as_str()).unwrap_or("no_fallback");
    let iters: usize = args
        .get(2)
        .and_then(|s| s.parse().ok())
        .unwrap_or(2000);

    let primary = std::fs::read(PRIMARY_PATH).expect("primary font");
    let fallback = std::fs::read(FALLBACK_PATH).expect("fallback font");
    let system = CosmicTextSystem::new_without_system_fonts(PRIMARY_FAMILY);
    system
        .add_fonts(vec![Cow::Owned(primary), Cow::Owned(fallback)])
        .unwrap();

    let fid_plain = system.font_id(&font(PRIMARY_FAMILY)).unwrap();
    let fid_fallback = {
        let mut f = font(PRIMARY_FAMILY);
        f.fallbacks = Some(FontFallbacks::from_fonts(vec![FALLBACK_FAMILY.to_string()]));
        system.font_id(&f).unwrap()
    };

    let text = code_text();
    let text_mixed = text.clone() + "\u{001c}\u{05d0}\u{05d1}";

    let (corpus, runs) = match which {
        "with_fallback" => (
            text.clone(),
            vec![FontRun { len: text.len(), font_id: fid_fallback }],
        ),
        "mixed_direction" => (
            text_mixed.clone(),
            vec![FontRun { len: text_mixed.len(), font_id: fid_plain }],
        ),
        _ => (
            text.clone(),
            vec![FontRun { len: text.len(), font_id: fid_plain }],
        ),
    };

    eprintln!(
        "case={} bytes={} chars={} iters={}",
        which,
        corpus.len(),
        corpus.chars().count(),
        iters
    );

    {
        let probe = system.layout_line(&corpus, px(14.0), &runs);
        let glyphs: usize = probe.runs.iter().map(|r| r.glyphs.len()).sum();
        eprintln!("  runs={} glyphs={} width={:?}", probe.runs.len(), glyphs, probe.width);
    }

    let mut acc = 0usize;
    for _ in 0..iters {
        let l = system.layout_line(&corpus, px(14.0), &runs);
        acc = acc.wrapping_add(l.len);
    }
    std::hint::black_box(acc);
}
