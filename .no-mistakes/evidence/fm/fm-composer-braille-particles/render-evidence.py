#!/usr/bin/env python3
"""Render the captured Codex panes + fm-send outcomes as one HTML artifact.

Input: the .ansi pane captures and probe/stdin transcripts this run produced.
"""
import html, re, sys, pathlib

EV = pathlib.Path(sys.argv[1])
SGR = re.compile(r"\x1b\[([0-9;]*)m")

def ansi_to_html(text):
    out, fg, bg, bold, dim = [], None, None, False, False
    def open_span():
        style = []
        if fg: style.append(f"color:{fg}")
        if bg: style.append(f"background:{bg}")
        if bold: style.append("font-weight:700")
        if dim: style.append("opacity:.55")
        return f'<span style="{";".join(style)}">' if style else "<span>"
    pos = 0
    out.append(open_span())
    for m in SGR.finditer(text):
        out.append(html.escape(text[pos:m.start()]))
        pos = m.end()
        codes = [c for c in m.group(1).split(";") if c != ""] or ["0"]
        i = 0
        while i < len(codes):
            c = int(codes[i])
            if c == 0: fg = bg = None; bold = dim = False
            elif c == 1: bold = True
            elif c == 2: dim = True
            elif c == 22: bold = dim = False
            elif c == 38 and codes[i+1] == "2":
                fg = "rgb(%s,%s,%s)" % tuple(codes[i+2:i+5]); i += 4
            elif c == 48 and codes[i+1] == "2":
                bg = "rgb(%s,%s,%s)" % tuple(codes[i+2:i+5]); i += 4
            elif c == 39: fg = None
            elif c == 49: bg = None
            i += 1
        out.append("</span>")
        out.append(open_span())
    out.append(html.escape(text[pos:]))
    out.append("</span>")
    return "".join(out)

def pane(rel):
    p = EV / rel
    return f'<pre class="pane">{ansi_to_html(p.read_text())}</pre>' if p.exists() else "<p>(missing)</p>"

def read(rel, limit=None):
    p = EV / rel
    if not p.exists(): return "(missing)"
    t = p.read_text().strip()
    return t if t else "(empty - nothing reached the worker)"

def probe(variant, mode, key, prefix="probe"):
    for line in (EV / variant / f"{prefix}-{mode}.txt").read_text().splitlines():
        if line.startswith(key):
            return line.split(":", 1)[1].strip()
    return "?"

def card(title, variant, mode, verdict_label, good, backend="tmux"):
    tag = "" if backend == "tmux" else "-herdr"
    probe_prefix = "probe" if backend == "tmux" else "probe-herdr"
    stderr = read(f"{variant}/fm-send-stderr{tag}-{mode}.txt")
    notice = [l for l in stderr.splitlines() if "doorbell skipped" in l]
    return f"""
    <div class="card {'good' if good else 'bad'}">
      <h4>{title}</h4>
      <dl>
        <dt>composer verdict</dt><dd><code>{probe(variant, mode, 'composer verdict', probe_prefix)}</code></dd>
        <dt>fm-send exit</dt><dd><code>{probe(variant, mode, 'fm-send exit', probe_prefix)}</code></dd>
        <dt>operator saw</dt><dd>{'<code class="notice">' + html.escape(notice[0].split('; ')[0]) + '</code>' if notice else '<code class="ok">no skip notice</code>'}</dd>
        <dt>bytes the worker received</dt><dd><code>{probe(variant, mode, 'bytes typed into pane', probe_prefix)}</code></dd>
      </dl>
      <p class="lbl">what the Codex pane actually received on stdin</p>
      <pre class="stdin">{html.escape(read(f'{variant}/pane-stdin{tag}-{mode}.txt'))}</pre>
    </div>"""

ladder_rows = ""
for variant, label in (("prefix", "before the fix"), ("fixed", "after the fix")):
    lines = [l for l in (EV / variant / "probe-ladder.txt").read_text().splitlines() if l.startswith("ladder")]
    ladder_rows += f'<tr><th rowspan="{len(lines)}">{label}</th>' + \
        "</tr><tr>".join(f'<td><code>{html.escape(l)}</code></td>' for l in lines) + "</tr>"

doc = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>Codex snow: composer pre-check vs the doorbell</title>
<style>
  :root {{ color-scheme: dark; }}
  body {{ background:#14161a; color:#e7e9ee; font:14px/1.5 -apple-system,Segoe UI,sans-serif; margin:0; padding:2rem; }}
  h1 {{ font-size:1.5rem; margin:0 0 .25rem; }}
  h2 {{ font-size:1.05rem; margin:2rem 0 .5rem; color:#9fb4ff; }}
  h4 {{ margin:0 0 .5rem; font-size:.95rem; }}
  p.sub {{ color:#98a0b0; margin:0 0 1rem; max-width:70rem; }}
  pre.pane {{ background:#1e1e1e; margin:0; padding:.6rem .8rem; border-radius:.4rem;
    font:12px/1.35 ui-monospace,SFMono-Regular,Menlo,monospace; overflow-x:auto; border:1px solid #2c3038; }}
  pre.stdin {{ background:#0f1114; border:1px solid #2c3038; border-radius:.4rem; padding:.5rem .6rem;
    font:11.5px/1.45 ui-monospace,Menlo,monospace; white-space:pre-wrap; word-break:break-all; margin:.25rem 0 0; color:#cfe3d0; }}
  .grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,26rem),1fr)); gap:1rem; }}
  .card {{ border:1px solid #2c3038; border-radius:.5rem; padding:.9rem 1rem; background:#181b20; min-width:0; }}
  .card.good {{ border-left:4px solid #3fb950; }}
  .card.bad {{ border-left:4px solid #f85149; }}
  dl {{ display:grid; grid-template-columns:auto minmax(0,1fr); gap:.15rem .75rem; margin:0 0 .5rem; }}
  dt {{ color:#98a0b0; }} dd {{ margin:0; min-width:0; overflow-wrap:anywhere; }}
  code {{ font:12px/1.4 ui-monospace,Menlo,monospace; }}
  code.notice {{ color:#f0883e; }} code.ok {{ color:#3fb950; }}
  p.lbl {{ color:#98a0b0; margin:.6rem 0 0; font-size:.8rem; text-transform:uppercase; letter-spacing:.04em; }}
  table {{ border-collapse:collapse; margin-top:.5rem; }}
  th, td {{ border:1px solid #2c3038; padding:.3rem .6rem; text-align:left; }}
  th {{ color:#98a0b0; font-weight:600; }}
</style></head><body>
<h1>Codex snow no longer blocks the doorbell</h1>
<p class="sub">Every panel below is a real <code>bin/fm-send.sh</code> run against a live pane (tmux below, real herdr in section 4) whose screen is the
captured Codex snow composer (<code>tests/fixtures/codex-snow-composer.ansi-escaped</code>), with the terminal cursor
parked in the composer and a pane process the tmux liveness probe reads as a live <code>codex</code> agent.
The only difference between the two columns is which <code>bin/fm-composer-lib.sh</code> is installed.</p>

<h2>1. The pane the operator's send is judging</h2>
{pane("fixed/pane-before-clean.ansi")}

<h2>2. Same send, before and after the fix</h2>
<div class="grid">
{card("Before the fix (base f3c650d)", "prefix", "clean", "pending", False)}
{card("After the fix (549cde2)", "fixed", "clean", "empty", True)}
</div>

<h2>3. Adversarial: operator words typed among the snow must still be protected</h2>
{pane("fixed/pane-before-typed.ansi")}
<div class="grid">
{card("Typed words among snow, after the fix", "fixed", "typed", "pending", True)}
{card("Wrapped words with the caret in them, after the fix", "fixed", "wrapped-cursor", "pending", True)}
</div>

<h2>4. The cursorless backend (herdr), which the reported incident ran on</h2>
<p class="sub">A real isolated herdr server (herdr 0.9.0) via <code>bin/fm-herdr-lab.sh</code>, a registered
<code>codex</code> agent on the pane, and herdr's own <code>capture --ansi</code> read - so the verdict comes from
the CURSORLESS selector, not the tmux cursor path.</p>
<div class="grid">
{card("Snow only, before the fix", "prefix", "clean", "pending", False, "herdr")}
{card("Snow only, after the fix", "fixed", "clean", "empty", True, "herdr")}
{card("Adversarial: typed words among snow, after the fix", "fixed", "typed", "pending", True, "herdr")}
</div>

<h2>5. A REAL Codex worker, end to end, with the fix installed</h2>
<p class="sub">codex-cli 0.154.0 launched idle in an isolated tmux server with an isolated CODEX_HOME. Today's Codex
draws no snow, so this is the regression half: the ordinary idle Codex composer must still read <code>empty</code> and
the doorbell must still reach a real worker.</p>
<pre class="stdin">{html.escape((EV / "real-codex-live-delivery.txt").read_text().strip())}</pre>

<h2>6. The watcher's re-ring ladder on the same pane</h2>
<p class="sub">Driven through <code>fm_task_inbox_due_action</code> / <code>fm_task_inbox_ring</code> - the owner
<code>bin/fm-watch.sh</code> calls - with no grace, so all three rungs run.</p>
<table><tbody>{ladder_rows}</tbody></table>
</body></html>"""

(EV / "codex-snow-doorbell.html").write_text(doc)
print(EV / "codex-snow-doorbell.html")
