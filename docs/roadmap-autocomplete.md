# Autocomplete (tabled)

Inline, context-aware autocomplete that works in any text field on macOS. Tabled until the sidebar and memory are solid. Both features share the same core: AX context, memory, and the permission model.

## Decisions so far

- **Context source:** the AX tree is primary. Autocomplete needs text near the caret, the field type, and the surrounding window text. AX gives all three for free, exactly, with no inference cost.
- **Keystrokes:** read via `CGEventTap` (Input Monitoring permission). Use it to detect typing pauses and to cancel in-flight generations.
- **Accept key:** double-tap Shift for v1.
  - **Conflict:** the sidebar also uses double-tap Shift. Resolve before building. Options: (a) double-shift accepts only while a ghost suggestion is visible and opens the sidebar otherwise, (b) move accept to tap-Right-Option.
- **Memory:** markdown files on device, grepped. Same folder the sidebar uses (`~/Library/Application Support/DShift/memory`).
- **Inference:** fully local on an M4 Pro via MLX (mlx-swift). Use the smallest model that clears the quality bar and optimize the inference path, not the parameter count.

## When to use OCR vs the AX tree

Default to AX. Fall back to OCR (Apple Vision `VNRecognizeTextRequest` over a ScreenCaptureKit frame of the focused window) only when AX is insufficient:

1. **AX tree is thin.** The text extracted from the focused window falls below a threshold (for example under ~200 chars or under ~10 text-bearing nodes) while the window is visibly large. Typical cases: canvas apps (Figma), games, remote desktop / VNC, some Electron apps, PDFs rendered as images, video.
2. **Known-bad app list.** Per-bundle-ID override that forces OCR (or AX + OCR) for apps known to expose nothing useful.
3. **Content is an image.** The focused region is an `AXImage` or a web `img` and the question or completion depends on it.
4. **Never for the caret text.** The text being edited always comes from AX (`kAXValueAttribute`, `kAXSelectedTextRangeAttribute`). OCR is too slow and inexact for the prefix.

Cache OCR per window, keyed by a cheap frame hash, so it only re-runs when the pixels change. OCR stays off the per-keystroke path. It feeds the context buffer asynchronously.

For Chrome and Electron, set `AXManualAccessibility` / `AXEnhancedUserInterface` to `true` on the app element first. That alone turns many "thin" trees into full ones.

## Pipeline

1. Typing pause of about 150 ms (from the event tap).
2. Read the caret prefix and suffix plus the field role from AX.
3. Get window context: the cached AX text summary, or OCR text if the window is flagged thin.
4. Grep memory for terms in the prefix and the window title.
5. Build the prompt under a hard budget (about 1.5k tokens in, about 30 tokens out).
6. Stream from the local model. Cancel on the next keystroke.
7. Show the suggestion only if mean token logprob clears a threshold.
8. Render ghost text in a non-activating `NSPanel` at `kAXBoundsForRangeParameterizedAttribute`.
9. On accept, insert via the `kAXSelectedTextAttribute` set, with pasteboard + Cmd+V fallback (restore the pasteboard afterwards) and synthetic keystrokes for terminals.

## Local inference (M4 Pro)

- MLX via mlx-swift, with the model kept resident.
- Start with a 0.5B-1.5B instruct model at 4-bit. Move up to 3-4B only if acceptance rate demands it.
- Optimizations: reuse the KV cache for the stable system prompt prefix, use speculative decoding with a tiny draft model if needed, keep the output cap short, cancel aggressively.
- Targets: p50 first token under 80 ms, full suggestion under 250 ms.

## Open items

- Resolve the double-shift conflict with the sidebar.
- Detect and defer to native ghost text (Copilot, Gmail Smart Compose).
- Disable during IME composition (marked text) and secure input (`IsSecureEventInputEnabled()`).
- Local acceptance-rate logging as the quality signal.
