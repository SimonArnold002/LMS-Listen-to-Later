# Let a plugin-registered custom action define an app's own category

6.4.6's `registerCustomAction` is a much better home for a plugin's context-menu entries than
writing to the shared `prefs/material-skin/actions.json` — no editing a file we don't own, no
stale categories left behind by an uninstall, and it isn't subject to the app-start cache of
`customactions.json`. Listen Later has moved its "Add to Listen Later" / "Add to Wish List"
entries over to it and it works well.

Two things can't move, and both are the same small gap: the per-app category override in
`browse-resp.js` only consults the FILE.

```js
let oca = (undefined!=appCat && undefined!=customActions && (appCat in customActions))
              ? getCustomActions(appCat, false, ocFilter, true)
              : getCustomActions("online-"+btype, false, ocFilter, true);
```

`getCustomActions` itself already merges both lists — it's only this existence test that
doesn't. So:

1. **A plugin can't customise the actions on its own view.** Registering `myplugin-album`
   has no effect: the test fails, `online-album` is used instead, and the registered
   category is never looked at.
2. **A plugin can't suppress the generic `online-*` actions on its own items** — an app's
   list showing items it has already saved doesn't want to offer "Add" again. From the file
   that's an empty `myplugin-album`; through the API it can't be expressed at all, because
   `registerCustomAction` takes an action and pushes it.

## The changes

* `browse-resp.js` — treat the category as defined if it is in either list.
* `MaterialSkin/Plugin.pm` — make `$action` optional in `registerCustomAction`, so
  `registerCustomAction('myplugin-album')` declares an empty category. The sub already
  creates the empty arrayref before pushing, so this is one condition on the push.

An empty registered category then makes `getCustomActions` return `undefined`, which is
exactly the existing "an empty category suppresses" behaviour — no new semantics.

## Compatibility

Nothing changes for actions defined in `customactions.json`: the file is still checked first
and, when a category is present there, behaves precisely as before. A plugin that registers no
`<command>-<type>` category is unaffected — `pluginCustomActions` simply doesn't contain the
key, so the test falls through to `online-*` as it does today.
