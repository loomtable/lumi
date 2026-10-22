# ``BuddyOverlay``


The floating overlay: one never-key panel per display with the listening and thinking pill,
chips and cards, placement and motion. The shell drives it through `OverlayPresenting`
(`BuddyOverlayController`, or `FakeOverlay` in tests). Anchors are global points with a
top-left origin, the same space as `ContextPacket`.

## Glass gotchas

Found while building M1 on macOS 26. Each one caused a visible bug.

1. **Render transforms inside a `GlassEffectContainer` don't reach the glass.**
   `scaleEffect`, `blur` and `opacity` placed after `.glassEffect` on a view inside the
   container are ignored for the glass (the fold neither shrank nor faded). Animate the
   container itself, or change layout (frame, padding), which the glass does follow.
2. **Inside glass, `\.colorScheme` is the glass's adaptive look, not the Mac's appearance.**
   Over a white page in dark mode, views inside a glass surface read `.light`. Resolve
   tokens outside the container and pass them in. Don't use semantic colours (`.primary`,
   `.secondary`) or anything colour-scheme dependent inside glass surfaces; the card's
   `WKWebView` gets its appearance explicitly for the same reason.
3. **Use `MoveKeyframe` for an instant jump in a keyframe track.** A zero-duration
   `LinearKeyframe` produced a NaN transform and an AppKit assertion abort.

Also measured: a never-key panel always renders the inactive glass look (accepted), and
small Regular glass follows the backdrop's brightness whatever the tint or appearance. That's
why all text sits on 94% reading wells, including the pill's.
