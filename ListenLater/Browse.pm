package Plugins::ListenLater::Browse;

# Single-page content view. On entry the user sees, in one list:
#   • Plugin Settings (top)
#   • a Material header "Listen Later (N)" + its albums
#   • a Material header "Wish List (N)" + its albums
#   • a Material header "Played (N)" + its albums
# Each album row is directly playable (type => 'playlist'); Remove/Move live in
# the row's "…" context menu via itemActions => info → the contextmenu query
# (see Plugin::_contextMenuQuery). Sort order comes from the `sort` pref.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::ListenLater::DB;
use Plugins::ListenLater::Sources;

use constant ICON => 'plugins/ListenLater/html/images/ListenLaterIcon_svg.png';

# Per-section icons. Wish List uses Material's own "shopping_cart" font icon via the
# "_MTL_icon_<name>" filename convention (same trolley as the context-menu action);
# Played uses Google's "music_history" SVG via the "_svg.png" recolour convention
# (that glyph isn't in Material's bundled icon font, so it can't be a font icon).
use constant ICON_WISHLIST  => 'plugins/ListenLater/html/images/WishListIcon_MTL_icon_shopping_cart.png';
use constant ICON_PLAYED => 'plugins/ListenLater/html/images/PlayedIcon_svg.png';

my $log   = logger('plugin.listenlater');
my $prefs = preferences('plugin.listenlater');

# Map a list status to its section icon (Listen Later uses the plugin icon).
sub _iconFor {
    my ($status) = @_;
    return ICON_WISHLIST  if $status eq 'wishlist';
    return ICON_PLAYED if $status eq 'played';
    return ICON;
}

# ---------------------------------------------------------------------------
# Top level — the whole list on one page
# ---------------------------------------------------------------------------
sub topLevel {
    my ($client, $callback, $args) = @_;

    my $wantHeaders = _wantHeaders(_featuresOf($args));

    my @items;

    push @items, {
        name    => cstring($client, 'PLUGIN_LL_SETTINGS'),
        type    => 'link',
        weblink => '/plugins/ListenLater/settings.html',
        image   => ICON,
    };

    push @items, _section($client, 'later',  'PLUGIN_LL_LISTEN_LATER', $wantHeaders);
    push @items, _section($client, 'wishlist',  'PLUGIN_LL_WISHLIST',        $wantHeaders);
    push @items, _section($client, 'played', 'PLUGIN_LL_PLAYED',       $wantHeaders);

    $callback->({ items => \@items });
}

sub _section {
    my ($client, $status, $titleStr, $wantHeaders) = @_;

    my $rows  = Plugins::ListenLater::DB::list($status, $prefs->get('sort') || 'added');
    my $count = scalar @$rows;

    my @items = ( _header($client, $status, $titleStr, $count, $wantHeaders) );

    # NB: deliberately NO "empty" text row here. Material disables the grid/list
    # view toggle for the whole page if any item is type => 'text' (browse-resp.js:
    # `types.has("text")`), whereas type => 'header' is fine. An empty section just
    # shows its "(0)" header. (The header count conveys emptiness.)
    push @items, map { _albumRow($client, $_) } @$rows;

    return @items;
}

# A section header. Material renders type => 'header' bold/accented, but forces a
# drill action onto it, so (per the sibling plugin's finding) give it a url that
# re-lists just this section — the header / its "More" then shows that section
# rather than an empty page. Non-header clients get plain text.
sub _header {
    my ($client, $status, $titleStr, $count, $wantHeaders) = @_;

    my $name = cstring($client, $titleStr) . " ($count)";
    # Give the header an image. Material 6.4.x has no header guard in its grid
    # check (browse-resp.js: `if (i.image) haveWithIcons; else haveWithoutIcons`
    # runs for headers too), so an image-less header sets haveWithoutIcons and
    # disables the whole page's grid/list toggle. With an icon, every item has an
    # image → grid stays available, and the header still renders as a divider.
    my $h = { name => $name, type => $wantHeaders ? 'header' : 'text', image => _iconFor($status) };

    if ($wantHeaders) {
        $h->{url}         = sub { _renderSection($_[0], $_[1], $status) };
        $h->{passthrough} = [ {} ];
    }

    return $h;
}

sub _renderSection {
    my ($client, $callback, $status) = @_;
    my $rows = Plugins::ListenLater::DB::list($status, $prefs->get('sort') || 'added');
    my @items = @$rows
        ? map { _albumRow($client, $_) } @$rows
        : ({ name => cstring($client, 'PLUGIN_LL_EMPTY'), type => 'text' });
    $callback->({ items => \@items });
}

# A directly-playable album row. type => 'playlist' + a url coderef that resolves
# the album's tracks gives Material the play button and Play/Play Next/Add in the
# "…". itemActions→info adds the "…" → More context entry → our Remove/Move menu
# (refreshes the list in place; see Plugin::_contextMenuQuery).
sub _albumRow {
    my ($client, $rec) = @_;

    my $name = '';
    $name .= $rec->{artist} . " \x{2013} " if $rec->{artist};
    $name .= $rec->{album_title} // cstring($client, 'PLUGIN_LL_UNKNOWN_ALBUM');
    $name .= " ($rec->{year})" if $rec->{year};

    return {
        name        => $name,
        line2       => ucfirst($rec->{source} || ''),
        image       => $rec->{artwork} || _iconFor($rec->{status}),
        type        => 'playlist',
        url         => \&_albumTracks,
        passthrough => [ { id => $rec->{id} } ],
        itemActions => {
            info => {
                command     => [ 'listenlater', 'contextmenu' ],
                fixedParams => { id => $rec->{id} },
            },
        },
    };
}

# Material home-page shelf: the "Listen Later" albums as a flat, quantity-stable
# card row. The Material carousel and its "show all" click-in are the SAME feed
# (Material exposes no way to give the click-in a different command), so the result
# must not vary by request quantity or structure — otherwise item_ids shift and
# deep playback resolves the wrong album. So: always the same flat list of rows.
sub homeShelf {
    my ($client, $callback, $args) = @_;
    my $rows = Plugins::ListenLater::DB::list('later', $prefs->get('sort') || 'added');
    $callback->({ items => [ map { _albumRow($client, $_) } @$rows ] });
}

# Resolve the tracks for an album row (drill-in and play both call this).
sub _albumTracks {
    my ($client, $callback, $args, $pt) = @_;

    my $rec = Plugins::ListenLater::DB::get($pt->{id});
    unless ($rec) {
        return $callback->({ items => [{ name => cstring($client, 'PLUGIN_LL_EMPTY'), type => 'text' }] });
    }

    Plugins::ListenLater::Sources::resolveTracks($client, $rec, sub {
        my $tracks = shift || [];
        $callback->({ items => $tracks });
    });
}

# ---------------------------------------------------------------------------
sub _featuresOf {
    my ($args) = @_;
    return (ref $args->{params} eq 'HASH') ? ($args->{params}{features} // '') : '';
}

sub _wantHeaders {
    my ($features) = @_;
    return (defined $features && $features =~ /h/) ? 1 : 0;
}

1;
