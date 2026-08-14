# HTML renderer notes

Evidence from `feat/html-terminal-renderer`, gathered against the installed
`.app` with `KUROTTY_HTML_RENDERER=1`.

Screenshots were here and have been removed: they were only ever a way to show
the work to someone who could not run it, and they carried whatever else was on
the desktop at the time.

`sample-frame.html` is the markup the renderer actually emits, written by
`TerminalHTMLSampleTests`. It is here because the screenshots cannot answer
"is this really HTML?" — looking identical to Metal is the goal, so a picture
proves nothing either way. The markup does:

```html
<div class="trow" id="r0"><span class="trun"
  style="color:rgba(102,179,255,1.000);background:rgba(38,38,51,1.000);width:calc(var(--cw) * 10)"
  >skyepodium</span>...
```

One `div` per row, one `span` per run of cells that share a colour, each sized
in cell units. There is nothing in DOM text that forces it to look unstyled —
a terminal is a grid of coloured character cells, and that is a shape CSS can
state exactly.

Which renderer produced a capture is confirmed from the run's log
(`render latency [html|metal] probe installed`), not by eye — at this point the
two are hard to tell apart visually, which is most of the point.

Measured on the same machine, same shell, forty seconds per run, three runs
per configuration.

| Workload | Renderer | p50 | p95 | Frames per run |
| --- | --- | --- | --- | --- |
| scroll | metal | 1.26–1.28ms | 2.71–2.73ms | ~1970 |
| scroll | html | 2.06–2.07ms | 2.32–3.00ms | ~1200 |
| tui | metal | 2.46–2.56ms | 3.46–3.56ms | ~1640 |
| tui | html | 3.97–4.09ms | 8.70–8.85ms | ~960 |

The spread inside a configuration is at most 0.12ms on the median, against a
0.8–1.5ms gap between the backends, so the difference is the renderers and not
the machine.

Three readings survive the repeat:

- **The median cost is 1.6x, in both workload shapes.** Scroll 2.06/1.27,
  full-damage 4.03/2.51. Both backends also degrade by the same factor going
  from scrolling to full damage, so a TUI is not specifically hostile to the
  web view — it is just more work for either.
- **Throughput is about 59% of Metal's**, consistently. Under identical load
  the web view presents roughly three frames for every five.
- **The tail is where they part, and only under full damage.** On scrolling,
  html's p95 is level with Metal's or slightly better. On a TUI repaint it is
  2.5x. A 27ms outlier seen in the first single run did not reproduce in any of
  the three repeats and should be treated as a one-off.

Everything measured fits inside a 60Hz budget, so this is a cost rather than a
wall. Whether it is worth paying is a product question these numbers do not
answer: the web view buys continuous selection, find, accessibility from real
text, and CSS styling, all of which the glyph atlas has to implement itself.
