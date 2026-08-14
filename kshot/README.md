# HTML renderer captures

Screenshots from `feat/html-terminal-renderer`, taken against the installed
`.app` with `KUROTTY_HTML_RENDERER=1`.

Only the terminal window is in frame. The full-screen captures these were cut
from also held unrelated windows, so they are deliberately not here.

| File | What it shows |
| --- | --- |
| `powerline-metal.png` | The prompt drawn by the Metal renderer, enlarged. Reference. |
| `powerline-html.png` | The same prompt drawn by the HTML renderer, after the fallback-font fix. Powerline separators resolve; before that fix they were empty boxes, because the system cascade answers `.LastResort` for those private-use codepoints and only the atlas's named Nerd Font list finds them. |
| `tui-html.png` | The HTML renderer under the TUI workload: alternate screen, cursor home, every line rewritten in place, so every frame is full damage. This is the shape `vim` and `htop` produce and what an ssh session spends its time on. |

Which renderer produced a capture is confirmed from the run's log
(`render latency [html|metal] probe installed`), not by eye — at this point the
two are hard to tell apart visually, which is most of the point.

Measured on the same machine, same shell, forty seconds per run:

| Workload | Renderer | p50 | p95 | Frames |
| --- | --- | --- | --- | --- |
| scroll | metal | 1.26–1.32ms | 2.53–2.99ms | ~2280 |
| scroll | html | 2.08–2.11ms | 3.24–3.63ms | ~1320 |
| tui | metal | 2.48–2.70ms | 3.50–3.61ms | ~1800 |
| tui | html | 4.25–4.32ms | 8.57–9.36ms | ~1200 |

One run per configuration. A repeat pass was underway when these were written
and its spread is not reflected here.
