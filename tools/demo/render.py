#!/usr/bin/env python3
"""Render tools/demo/transcript.txt (a REAL okf-check session, see record.py) as docs/demo.gif.

Every character of tool output in the GIF comes from the transcript. The only text that is not from the transcript
is the one-line caption under each scene (CAPTIONS below). The render is deterministic: the same transcript and the
same Pillow give the same bytes.

Needs Pillow and a monospace font (macOS: Menlo). Usage: python3 tools/demo/render.py [out.gif]
"""
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "docs" / "demo.gif"

FONT_PATHS = ["/System/Library/Fonts/Menlo.ttc", "/System/Library/Fonts/Monaco.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"]
FONT_SIZE = 15
COLS, ROWS = 100, 18           # terminal size in cells; long lines wrap with a hanging indent
PAD = 14
CAPTION_H = 34

BG, FG, DIM = (30, 30, 30), (212, 212, 212), (128, 128, 128)
PROMPT, PASS, WARN, FAIL, CAPTION = (86, 182, 194), (152, 195, 121), (229, 192, 123), (224, 108, 117), (97, 175, 239)

CAPTIONS = [
    "1/4  A note with no `type` is not valid OKF: exit 1",
    "2/4  Fixed. A draft that claims a human verified it passes, with a Trust warning",
    "3/4  --strict-trust turns that warning into a failure",
    "4/4  A note a person wrote, and a person reviewed after the last change, passes",
]
TYPE_STEP = 2                  # characters typed per frame
TYPE_MS, LINE_MS, LINES_PER_FRAME = 45, 90, 2
AFTER_CMD_MS, SCENE_END_MS, FINAL_MS = 450, 2600, 4200


def load_font():
    for p in FONT_PATHS:
        try:
            return ImageFont.truetype(p, FONT_SIZE)
        except OSError:
            continue
    sys.exit("render.py: no monospace font found; tried " + ", ".join(FONT_PATHS))


def parse(path):
    """-> list of scenes; a scene is a list of (command, output_lines, exit_code)."""
    scenes = []
    for line in path.read_text().split("\n"):
        if line == "#scene":
            scenes.append([])
        elif line.startswith("$ "):
            scenes[-1].append([line[2:], [], None])
        elif line.startswith("[exit ") and line.endswith("]"):
            scenes[-1][-1][2] = int(line[6:-1])
        elif line != "" or (scenes and scenes[-1] and scenes[-1][-1][2] is None):
            scenes[-1][-1][1].append(line)
    return scenes


def color_for(text):
    if "FAIL" in text:
        return FAIL
    if "WARN" in text:
        return WARN
    if "PASS" in text:
        return PASS
    if "SKIPPED" in text:
        return DIM
    return FG


def wrap(text):
    """Wrap one output line at COLS; continuation lines keep the line's own indent so the table stays readable."""
    if len(text) <= COLS:
        return [text]
    indent = len(text) - len(text.lstrip(" "))
    hang = 19 if indent >= 19 else 19 if text.startswith("  ") else 0
    out, cur = [], text
    first = True
    while len(cur) > COLS:
        cut = cur.rfind(" ", hang + 1, COLS)
        cut = cut if cut > 0 else COLS
        out.append(cur[:cut].rstrip())
        cur = " " * hang + cur[cut:].lstrip()
        first = False
    out.append(cur)
    return out


def main():
    font = load_font()
    cw = int(round(font.getlength("M")))
    lh = FONT_SIZE + 6
    W, H = COLS * cw + 2 * PAD, ROWS * lh + 2 * PAD + CAPTION_H
    scenes = parse(HERE / "transcript.txt")
    assert len(scenes) == len(CAPTIONS), (len(scenes), len(CAPTIONS))

    def frame(rows, caption, cursor=None):
        im = Image.new("RGB", (W, H), BG)
        d = ImageDraw.Draw(im)
        for r, (text, col) in enumerate(rows[-ROWS:]):
            if text.startswith("$ "):
                d.text((PAD, PAD + r * lh), "$", font=font, fill=PROMPT)
                d.text((PAD + 2 * cw, PAD + r * lh), text[2:], font=font, fill=FG)
            else:
                d.text((PAD, PAD + r * lh), text, font=font, fill=col)
        if cursor is not None:
            r, c = cursor
            d.rectangle([PAD + c * cw, PAD + r * lh + 2, PAD + (c + 1) * cw - 2, PAD + r * lh + lh - 3], fill=FG)
        d.line([(0, H - CAPTION_H), (W, H - CAPTION_H)], fill=(60, 60, 60))
        d.text((PAD, H - CAPTION_H + 8), caption, font=font, fill=CAPTION)
        return im

    frames, durations = [], []

    def add(im, ms):
        frames.append(im)
        durations.append(ms)

    for si, scene in enumerate(scenes):
        rows = []
        cap = CAPTIONS[si]
        add(frame(rows, cap, (0, 0)), 350)
        for cmd, output, code in scene:
            typed = ""
            line = "$ " + cmd
            for i in range(TYPE_STEP, len(cmd) + TYPE_STEP, TYPE_STEP):
                typed = cmd[:i]
                add(frame(rows + [("$ " + typed, FG)], cap, (len(rows), 2 + len(typed))), TYPE_MS)
            rows.append((line, FG))
            add(frame(rows, cap), AFTER_CMD_MS)
            shown = [(w, color_for(l)) for l in output for w in wrap(l)]
            for i in range(0, len(shown), LINES_PER_FRAME):
                rows.extend(shown[i:i + LINES_PER_FRAME])
                add(frame(rows, cap), LINE_MS)
            rows.append((f"[exit {code}]", DIM))
            add(frame(rows, cap), AFTER_CMD_MS)
        durations[-1] = FINAL_MS if si == len(scenes) - 1 else SCENE_END_MS

    # One palette for every frame: a quantised composite of all frames' colours (text is anti-aliased, so a handful
    # of shades per colour). A per-frame palette flickers and doubles the file size.
    ref = Image.new("RGB", (W, H * 1))
    sheet = Image.new("RGB", (W, H * min(len(frames), 12)))
    for i, f in enumerate(frames[:: max(1, len(frames) // 12)][:12]):
        sheet.paste(f, (0, i * H))
    pal = sheet.quantize(colors=48, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    out = [f.quantize(palette=pal, dither=Image.Dither.NONE) for f in frames]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    out[0].save(OUT, save_all=True, append_images=out[1:], duration=durations, loop=0, optimize=True)
    print(f"wrote {OUT}: {len(out)} frames, {W}x{H}, {OUT.stat().st_size} bytes, {sum(durations) / 1000:.1f} s")


if __name__ == "__main__":
    main()
