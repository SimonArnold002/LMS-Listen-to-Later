Thanks — that's fair, and I agree `actions.json` is really the user's space; a plugin writing into it is intrusive. I'm happy to move plugin-owned actions to a `uiactions` field gated on `features:a`, and to use `$APP` rather than `$SERVICE`.

One thing worth flagging before I rework, because it affects whether `uiactions` can fully *replace* this PR or only complement it: `uiactions` in the response only lets a plugin decorate **its own** views. The motivating case here is "Add to Listen to Later" on a **Qobuz** album while browsing Qobuz — and that view is the Qobuz plugin's response. My plugin can't attach a `uiaction` to it: it doesn't own that response, and Qobuz has no knowledge of my plugin. The reason this PR reaches those rows at all is the global `online-*` categories — which is exactly the part you're (rightly) wary of.

So I think the two are complementary rather than either/or:

- **A plugin decorating its _own_ views** (e.g. my list's Remove/Move, or *not* offering "Add" inside it) → `uiactions` in the response. The plugin owns it and never touches `actions.json`.
- **Adding an action onto _another_ plugin's streaming view** (Add on Qobuz/Tidal while browsing) → the per-item online rendering in this PR, driven by a **user-defined** `actions.json` entry. That keeps it user-specific, which is your point.

If that split works for you, I'd rework as:

- **Material**: add the `uiactions` field + `features:a` + `$APP`, and **keep** the `browse-resp.js` per-item online rendering so a *user's* `actions.json` entry can target streaming rows.
- **My plugin**: stop writing `actions.json` entirely — use `uiactions` for its own view, and ship "Add on Qobuz" as a documented, opt-in `actions.json` snippet.

The one decision I'd defer to you on: whether to keep the per-item online rendering for user `actions.json` entries. Without it there's no way for a user to add an action to a streaming browse row at all (the original use case); but if you'd rather Material not support that, I'll scope this PR down to just `uiactions` and drop the `online-*` category rendering.

Happy to implement whichever direction you prefer.
