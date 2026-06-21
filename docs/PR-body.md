# Custom actions on streaming / app browse items

## What & why
Custom actions currently only appear on **library** items. There is no way to add one to a **streaming/app** album or track while browsing a service (Qobuz/Tidal/Deezer/Bandcamp — new releases, an artist's discography, search), because that content is delivered as SlimBrowse `item_loop` items which bypass Material's custom-action wiring.

Two reasons online/app items get nothing today:
1. They bypass the `STD_ITEMS` action-menu path — their `stdItem` is `>= STD_ITEM_ONLINE_ARTIST` (300/301), so the `item.stdItem < STD_ITEMS.length` gate in `browse-functions.js` is false and they never reach the `CUSTOM_ACTIONS` handling.
2. The `item_loop` branch never sets `resp.itemCustomActions`.

Both are needed to render a custom action: the `CUSTOM_ACTIONS` marker in the item's own `i.menu`, **and** the view-level `resp.itemCustomActions`.

## Change
**`browse-resp.js`** (in the `item_loop` per-item handling): for online items and playable app rows, add the `CUSTOM_ACTIONS` marker to the item's `i.menu` and populate `resp.itemCustomActions`.

- Service **album rows** (e.g. Qobuz New Releases) carry no `favorites_url`/`metadata` — only a playable `item_id` and a two-line `title`/`subtitle` — so the rule keys off **playability** (`addedPlayAction && undefined==i.stdItem && !isFavorites && !isAppsTop`), and exposes `i.title`/`i.subtitle` as `i.album`/`i.artist` so `$ALBUMNAME`/`$ARTISTNAME` resolve.
- Category lookup tries `"<command>-<type>"` (the app's own view, e.g. `qobuz-album`) before the generic `"online-<type>"`. A category that is **defined at all** — even an empty array — wins, so an app/plugin can customise actions on its own view or suppress the generic ones (an empty category).

**`customactions.js`** (`doReplacements`): add `$SERVICE` (the browsing service, i.e. the `command`) and `$SUBTITLE` (the raw second line), and register them in `ACTION_KEYS`.

## Example `actions.json`
```json
{
  "online-album": [
    { "title": "Add to Listen to Later", "icon": "playlist_add",
      "lmscommand": ["listentolater","addctx","name:$ALBUMNAME","artist:$ARTISTNAME","svc:$SERVICE","image:$IMAGE"] }
  ],
  "listentolater-album": []
}
```
Browsing Qobuz → New Releases, an album's "…" now shows the action, passing the album name, the "Artist (Year)" subtitle, the service, and the cover. Inside the `listentolater` app's own list, the empty `listentolater-album` category overrides `online-album`, so the action isn't offered there.

## Notes
- Scoped to playable app/online rows; library items use the `*_loop` branches and are unaffected.
- With new `online-*` categories, zero behaviour change unless a user adds them to `actions.json`.
- Verified locally against `Release 6.4.3` on LMS 9.1 with the Qobuz plugin (album rows in browse lists, and a plugin's own app view).
