# Proposal: custom actions on streaming / app browse items (Material)

**Target:** CDrummond/lms-material (Material Skin)
**Tested against:** `master` @ `Release 6.4.3`, on LMS 9.1.0 with the Qobuz plugin.

---

## GitHub issue draft

**Title:**
> Custom actions: support streaming / app browse items (Qobuz/Tidal/Deezer/Bandcamp), not just library content

**Opening:**
> Custom actions currently only appear on **library** items — there's no way to add one to a **streaming** album/track while browsing a service (new releases, an artist's discography, search). Those "…" menus are owned by the service plugins, and Material's custom-action machinery is gated to library items. Below is the cause and a working change (verified locally against 6.4.3) that surfaces custom actions on playable streaming/app rows.

**Use case:** a "Listen to Later"-style plugin wants an "Add to Listen to Later" entry on a streaming **album row while browsing** — without playing it first or relying on search.

---

## How custom actions render today

1. `customactions.js` — `getCustomActions(id, locked, filter)` returns actions for category `id` (optionally filtered by a `favorites_url` prefix); `doReplacements(str, player, item)` substitutes `$VARS` from the **item**; `doCustomAction` executes (`lmscommand` / `weblink` / …).
2. `browse-page.js` — the item context menu iterates `menu.itemMenu`; on a `CUSTOM_ACTIONS` (`-2`) entry it renders the **view-level** `itemCustomActions` array.
3. `browse-functions.js` — `menu.itemMenu` is `item.menu` when the item already has one (app/online items), or is built from `STD_ITEMS[item.stdItem]` otherwise (library items). Per-item custom actions are attached here, but **only** inside:
   ```js
   if (undefined!=item && undefined!=item.stdItem && item.stdItem < STD_ITEMS.length &&
       undefined!=STD_ITEMS[item.stdItem].actionMenu) {
       …  if (CUSTOM_ACTIONS==loop[i]) { …push view.itemCustomActions… }
   }
   ```
4. `browse-resp.js` sets `resp.itemCustomActions` per response — but only in the **library** branches (`albums_loop`, `titles_loop`, `artists_loop`, `playlists_loop`, `genres_loop`, `years_loop`).

## Why streaming items get nothing

Streaming / app content is delivered as a SlimBrowse **`item_loop`** response, whose per-item loop builds each item's own `i.menu` array directly. Custom actions never appear there for two reasons:

1. **They bypass the `STD_ITEMS` path.** Online items are tagged `STD_ITEM_ONLINE_ARTIST=300` / `STD_ITEM_ONLINE_ALBUM=301` (or left untyped). The gate in step 3 requires `item.stdItem < STD_ITEMS.length` (~16), so online items never reach the `CUSTOM_ACTIONS` handling.
2. **The `item_loop` branch never sets `resp.itemCustomActions`.**

Both are required to render a custom action on an item: the `CUSTOM_ACTIONS` marker must be present in that item's `i.menu`, **and** the view-level `resp.itemCustomActions` must be populated.

## The data reality (why this keys off playability)

On LMS 9.1.0 the Qobuz plugin's **album rows** in a browse list carry no album identity:
```json
{ "type":"playlist", "text":"Album Name (Hi-Res)\nArtist (2026)",
  "params":{ "item_id":"6.0" }, "icon":"…/cover.jpg" }
```
No `presetParams.favorites_url`, no `metadata` (even with `wantMetadata:1`). Title/artist/year exist only in the two-line `text`; the item is playable via `base.actions.play` + the **positional** `item_id`. Only **track** rows (inside an album) carry `presetParams.favorites_url` (`qobuz://<trackid>.flac`).

So the `STD_ITEM_ONLINE_*` classification (which needs `favorites_url`/`metadata`) doesn't match album rows — the change keys off **playability** instead, and exposes the row's title/subtitle for substitution.

## Proposed change

In `browse-resp.js`, in the `item_loop` per-item section (after the play-action block that sets `addedPlayAction`), attach custom actions to playable app/online rows:

```js
// Surface custom actions on app/online (streaming) browse items. These arrive via
// item_loop (library content uses the *_loop branches) and bypass the STD_ITEMS
// action-menu path, so add the CUSTOM_ACTIONS marker to the item's own menu and
// populate the view-level itemCustomActions for browse-page to render.
let isOnlineAlbum  = STD_ITEM_ONLINE_ALBUM==i.stdItem;
let isOnlineArtist = STD_ITEM_ONLINE_ARTIST==i.stdItem;
let isAppItem = !isOnlineAlbum && !isOnlineArtist && !isOnlineTrack &&
                addedPlayAction && undefined==i.stdItem && !isFavorites && !isAppsTop;
if (isOnlineAlbum || isOnlineArtist || isOnlineTrack || isAppItem) {
    let btype    = isOnlineArtist ? "artist" : isOnlineTrack ? "track" : "album";
    let ocFilter = i.presetParams ? i.presetParams.favorites_url : undefined;
    // A plugin/app can define a custom-action category for its OWN view, named
    // "<command>-<type>" (e.g. "listentolater-album"). If that category is defined -
    // even as an empty list - it takes precedence over the generic "online-*" one,
    // so a plugin's own list can show different actions, or none (an empty category
    // suppresses the generic streaming actions on that app's items).
    let appCat = (undefined!=command) ? command+"-"+btype : undefined;
    let oca = (undefined!=appCat && undefined!=customActions && (appCat in customActions))
              ? getCustomActions(appCat, false, ocFilter)
              : getCustomActions("online-"+btype, false, ocFilter);
    if (undefined!=oca && oca.length>0) {
        if (isAppItem) {                        // expose the only identity these rows have
            if (undefined==i.album)  { i.album  = i.title; }
            if (undefined==i.artist) { i.artist = i.subtitle; }
            i.service = command;                // the service this view belongs to
        }
        addedDivider = addDivider(i, addedDivider);
        i.menu.push(CUSTOM_ACTIONS);
        if (undefined==resp.itemCustomActions) { resp.itemCustomActions = oca; }
    }
}
```

This gives the plugin `$TITLE`/`$ALBUMNAME` (album name) and `$ARTISTNAME` (the "Artist (year)" subtitle). `$FAVURL` is also passed when present (online tracks).

### Service id — `$SERVICE`

Album rows carry no `favorites_url`, so the action can't tell *which* service the item came from. But the **view** does: `browse-resp.js` already computes `command = data.params[1][0]` (e.g. `"qobuz"`, `"bandcamp"`), constant for the whole list. The block above stores it as `i.service`; expose it for substitution in `customactions.js` `doReplacements`:

```js
if (undefined!=item.service) { val = val.replaceAll("$SERVICE", item.service); }
```
A plugin then writes `…,"svc:$SERVICE",…` in its `lmscommand`.

### Optional — `$SUBTITLE`

To let a plugin parse the raw second line itself: `if (undefined!=item.subtitle) val=val.replaceAll("$SUBTITLE", item.subtitle);`.

## Category naming

New `online-album` / `online-track` / `online-artist` categories (recommended) — explicit, no behaviour change for existing library actions. A single generic `online-item` / `app-item` category would also work; `online-album` is used here because the album case is the motivating one and homogeneous lists (New Releases) are all albums.

## Per-app override (`<command>-<type>`)

For app items the lookup tries a per-app category `<command>-<type>` (e.g. `qobuz-album`, `listentolater-album`) before the generic `online-<type>`. A category that is **defined at all** — even an empty array — wins, which gives plugins two useful controls:

- **Customise** their own app view: a plugin browsing its own app can offer view-specific actions (different from the generic streaming ones).
- **Suppress**: define an empty `<command>-<type>` to stop the generic `online-*` actions appearing on that app's items.

Motivating case: the "Listen to Later" plugin browses streaming services (where its `online-album` "Add to Listen to Later" should appear), but its **own** list view must *not* offer "Add" again (re-adding an album already saved is pointless and would move a *Played* album back to the list). It writes an empty `listentolater-album` category, so its own rows show no "Add" while every streaming service still does. (Detecting an empty-but-defined category needs a direct `command+"-"+btype in customActions` check, since `getCustomActions` returns `undefined` for an empty category.)

## Why this is safe

- Only adds to a code path (`item_loop`) that currently leaves `itemCustomActions` undefined and never marks `CUSTOM_ACTIONS`.
- Scoped to playable app/online rows (`addedPlayAction && undefined==i.stdItem && !isFavorites && !isAppsTop`); library albums never reach `item_loop`.
- With new `online-*` categories, zero behaviour change unless a user adds them to `actions.json`.
- Keys off generic SlimBrowse signals (playability, `metadata.type`, `favorites_url`), not any one service.

## Worked example

`actions.json`:
```json
{
  "online-album": [
    { "title": "Add to Listen to Later", "icon": "playlist_add",
      "lmscommand": ["listentolater","addctx","name:$ALBUMNAME","artist:$ARTISTNAME","svc:$SERVICE","image:$IMAGE"] }
  ],
  "listentolater-album": []
}
```
Browsing **Qobuz → New Releases**, an album's "…" shows **Add to Listen to Later**, passing `name="Album Name (Hi-Res)"`, `artist="Artist (2026)"`, `svc="qobuz"`, plus the cover — enough for the plugin to store and later replay the album. No play-first, no separate search. Inside the plugin's **own** list view (`command=="listentolater"`), the empty `listentolater-album` overrides `online-album`, so "Add" is not shown there.

## File / line pointers (`Release 6.4.3`)

- `…/html/js/browse-resp.js`
  - online classification in the `item_loop` per-item loop (`STD_ITEM_ONLINE_*`, `isOnlineTrack`, `metadataTypes`) and the play-action block that sets `addedPlayAction` ← **add the block above just after it**
  - `command = data.params[1][0]` (the service id)
  - existing library assignments for comparison: `getCustomActions("album")` etc.
- `…/html/js/customactions.js` — `doReplacements` (add `$SERVICE`, optional `$SUBTITLE`); `getCustomActions` / `getSectionActions` (category + `filter`).
- `…/html/js/browse-functions.js` — the `STD_ITEMS`-gated `CUSTOM_ACTIONS` attach (`item.stdItem < STD_ITEMS.length`) that online items skip; `showMenu(…, itemMenu:item.menu, …)`.
- `…/html/js/browse-page.js` — `CUSTOM_ACTIONS` render template over `itemCustomActions` (no change needed).
- `…/html/js/constants.js` — `STD_ITEM_ONLINE_ARTIST=300`, `STD_ITEM_ONLINE_ALBUM=301`.
