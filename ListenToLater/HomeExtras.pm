package Plugins::ListenToLater::HomeExtras;

# Material Skin home-page scrollable row for the Listen to Later list. One
# HomeExtraBase subclass: own tag -> own CLI dispatch -> own feed (Browse::homeShelf).
# The feed returns a FLAT card list that does not vary by request quantity — the
# carousel and its "show all" click-in are the SAME feed, so a quantity- or
# structure-dependent result would shift item_ids and break deep playback (the
# sibling plugin's 0.6.11 rule).

use strict;
use base qw(Plugins::MaterialSkin::HomeExtraBase);

use Plugins::ListenToLater::Browse;

use constant ICON => 'plugins/ListenToLater/html/images/ListenToLaterIcon_svg.png';

sub initPlugin {
    my ($class) = @_;

    $class->SUPER::initPlugin(
        feed  => \&feed,
        tag   => 'LtLHome',
        extra => { title => 'PLUGIN_LTL_LISTEN_LATER', icon => ICON, needsPlayer => 0 },
    );
}

sub feed {
    my ($client, $cb, $args) = @_;
    Plugins::ListenToLater::Browse::homeShelf($client, $cb, $args);
}

1;
