# Asset inventory

No assets were captured — this is the no-capture path. The "product" is a macOS notch
panel with no marketing website to crawl. Every visual is built directly in the
composition (HTML/CSS): the desktop gradient, the notch hardware pill, and a faithful
mock of the Notch glass panel (geometry, glass material, fonts, colors, and feedback
strings all taken verbatim from the shipping app's Swift source — see
`visible-text.txt` → "GROUND TRUTH FROM THE SHIPPING APP").

No logos, screenshots, or photos are needed or used. The brand mark "Notch" may appear
as a single closing wordmark in system font if the storyboard calls for it.

## Built-in (synthesized) visuals
- **Desktop** — calm dark-to-deep gradient, no real wallpaper. Optional faint top menu-bar tint (omitted by default for maximum restraint).
- **Notch hardware pill** — black, square top corners flush to screen edge, bottom corners radius ~9px, width ~192px. The physical MacBook camera cutout, drawn in CSS.
- **Notch glass panel** — the expand-in-place panel: dark smoked glass, white rim gradient, drop shadow. Holds the prompt input, the ask answer, and the remind/note feedback lines.
- **Caret + typed text** — simulated typing into the prompt field.
