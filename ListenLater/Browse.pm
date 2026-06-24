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

# A section header. Emitted only when the client advertises header support
# (features contains 'h', i.e. features:hi — what Material sends); other clients
# get plain text. On Material >= 6.4.3 the type is 'header-basic' (clears the
# item's actions so it renders as a plain full-width divider rather than an
# actionable grid card); older Material gets the long-standing 'header'. See
# _headerType. We keep the re-list url so 'header' still drills on older skins;
# 'header-basic' strips the action, so the url is harmlessly ignored there.
sub _header {
    my ($client, $status, $titleStr, $count, $wantHeaders) = @_;

    my $name = cstring($client, $titleStr) . " ($count)";
    # Give the header an image so the page's grid view stays available (an
    # image-less item sets haveWithoutIcons and disables the grid/list toggle).
    my $h = { name => $name, type => $wantHeaders ? _headerType() : 'text', image => _iconFor($status) };

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
        # Some services prepend non-playable helper items (e.g. Bandcamp's
        # "Download album from …" text + the page weblink). Keep them out of the
        # drill view / play queue. Fall back to the raw list if filtering empties
        # it (e.g. the single "no match" text row) so the view is never blank.
        my @playable = grep {
            ref $_ eq 'HASH' && !$_->{weblink} && (($_->{type} // '') ne 'text')
        } @$tracks;
        @playable = @$tracks unless @playable;
        $callback->({ items => \@playable });
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

# Which header item-type to emit for a header-capable (Material) client.
# Material's 'header-basic' (a non-actionable, full-width divider) only exists
# from Material 6.4.3 onwards; older Material understands only 'header'. To avoid
# changing behaviour for users on older skins, use 'header-basic' iff the running
# Material is >= 6.4.3 (or a non-release dev/test build), else fall back to the
# long-standing 'header'. Cached — the Material version can't change at runtime.
my $_headerTypeCache;
sub _headerType {
    return $_headerTypeCache if defined $_headerTypeCache;
    my $ver = eval { Plugins::MaterialSkin::Plugin->getPluginVersion() };
    my $useBasic;
    if (!defined $ver) {
        $useBasic = 0;                                  # can't tell -> stay safe
    } elsif ($ver =~ /^(\d+)\.(\d+)\.(\d+)/) {
        $useBasic = ( $1 <=> 6 || $2 <=> 4 || $3 <=> 3 ) >= 0 ? 1 : 0;
    } else {
        $useBasic = 1;                                  # dev/test build -> new
    }
    return $_headerTypeCache = $useBasic ? 'header-basic' : 'header';
}

1;
