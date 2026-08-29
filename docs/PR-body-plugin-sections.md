# Let plugins fully define their custom actions without actions.json

Hi Craig, Thanks for adding `registerCustomAction` in 6.4.6 — it's a much better fit for a plugin than
writing into the shared `prefs/material-skin/actions.json`, and I have moved most of the actions used in my plugins across to it.

I would like to stop touching that file altogether, but three things I use it for at the moment can only be done from it and are not available in current version, so I still have to write it (and then keep it tidy, and clean it up on uninstall).  My Plugin ListenLater is the one that uses custom actions all the time to operate. It uses them to add releases from Streaming services or lcoal library to lists for a user to then listen at a later time without having to add it to thier streaming Library. Its a useful tool for discovering new music. It has a number of custom actions, add to Listen Later, add to wish List. Remove from List, Move to Played, Move to Wish List, Buy on Bandcamp. In materials current state if I switched to using registerCustomAction only, some of these would not function as they do now. Their is logic to stop items in these views from invoking the Add to options as they are added all ready and only the move or remove options are available. 

This PR closes those gaps. They're small and independent — happy to split them into separate PRs if you prefer?


## What the API can't currently express

### 1. A plugin can't give its own view a different set of actions

Material lets an app's own rows use a `<command>-<type>` category in preference to the generic
`online-*` one, so an app can offer something different on its own items. `browse-resp.js` only
tests the file for that category, though:

```js
let appCat = (undefined!=command) ? command+"-"+btype : undefined;
let oca = (undefined!=appCat && undefined!=customActions && (appCat in customActions))
              ? getCustomActions(appCat, false, ocFilter, true)
              : getCustomActions("online-"+btype, false, ocFilter, true);
```

`getCustomActions` itself reads both `customActions` and `pluginCustomActions`, so the actions
would resolve fine — it's only this existence test that looks at one list. A registered
`<command>-<type>` category is therefore never reached.

*Reproduce:* register an action for `podcasts-album` and browse into Podcasts. The generic
`online-album` actions appear instead. Put the same category in `actions.json` and it works.

### 2. A plugin can't turn the generic actions off on its own items

A category that exists but is empty suppresses the generic `online-*` actions for that app.
That matters for a plugin whose own browse view lists items the generic actions make no sense
for — the actions still appear, and do nothing useful when tapped.

From the file that's `"myplugin-album": []`. `registerCustomAction` always pushes an action, so
there's no way to say "this category exists and is empty".

### 3. A registered action can't reach Now Playing or the queue

Both resolve their actions once, on the `customActions` bus event:

```js
bus.$on('customActions', function(val) { this.customActions = getCustomActions("track", false); });
```

The only `$emit('customActions')` is inside the `customactions.json` `.then`. The
`["material-skin","plugin-actions"]` request that fills `pluginCustomActions` runs alongside it
and doesn't emit — so when it finishes second, the snapshot is taken without it and nothing
re-resolves. The action is then absent from both panels for the rest of the page session.

The two requests take about the same time (~20ms each on our server), and a browser-cached
`customactions.json` settles it outright, so the order isn't reliable in either direction: the
action can be there on one page load and gone on the next.

*Reproduce:* register an action for `track`, with nothing in `actions.json`, and open Now
Playing.

## The changes

* `browse-resp.js` — check `pluginCustomActions` as well as `customActions`.
* `Plugin.pm` — `push` only when `$action` is defined, so `registerCustomAction('myplugin-album')`
  declares an empty category. The sub already creates the empty arrayref before pushing, and
  `getCustomActions` already returns `undefined` for an empty section, so the existing "an empty
  category suppresses" behaviour is unchanged — it just becomes reachable from the API.
* `customactions.js` — `bus.$emit('customActions')` when the plugin list arrives too.

```perl
my $register = Plugins::MaterialSkin::Plugin->can('registerCustomAction');

$register->('online-album', { title => 'Add to My Plugin', icon => 'playlist_add',
                              lmscommand => ['myplugin','add','name:$ALBUMNAME'] });
$register->('myplugin-album');   # empty — suppress the generic actions in my own view
```

## Compatibility

Nothing changes for `actions.json`: it's still checked first, and a category present there
behaves exactly as before. An existing two-argument `registerCustomAction` call is unaffected,
and the extra emit is idempotent — the listeners only re-resolve a snapshot.
