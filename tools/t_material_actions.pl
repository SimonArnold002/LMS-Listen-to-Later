#!/usr/bin/env perl
# Regression tests for how the Material context-menu entries are DELIVERED (0.1.95).
#
# Material 6.4.6 added a registration API — `registerCustomAction($section, $action)` — so a
# plugin hands Material its entries instead of editing the shared prefs/material-skin/actions.json.
# Material merges the two client-side (customactions.js `getSectionActions` walks the file list
# and then the plugin list), which makes exactly one failure mode catastrophic and silent on our
# side: if we register AND leave our old entries in the file, EVERY "Add" appears TWICE. That is
# what most of this suite is about.
#
# Four things cannot move to the API, and the suite pins them where they are:
#   * the EMPTY suppressor categories (listenlater-*, LLHome-*, the radio ones) — the API takes
#     an action and pushes it, so "this category exists and is empty" is inexpressible;
#   * the podcasts-* override — Material decides whether an app's own "<command>-<type>" category
#     wins over "online-*" with `appCat in customActions`, i.e. the FILE, never the registered
#     list (verified in the served 6.4.7 bundle);
#   * 'track' (Now Playing) and 'queue-track' — the only two categories Material resolves in the
#     BROWSER, and it snapshots them once, on a bus event only the customactions.json fetch
#     fires. The plugin list usually arrives after that, so a registered entry is invisible for
#     the whole page session (0.1.97; see _materialActionSet);
#   * everything, on a Material older than 6.4.6, which has no API at all.
#
# Nothing here is asserted from a copy of the action definitions: the categories and the entry
# shapes are read back out of _materialActionSet, and the two delivery paths are compared against
# EACH OTHER, so a change to a command is not silently blessed by a restated expectation.
use strict;
use warnings;
use FindBin;
use File::Temp ();
use File::Path ();
use JSON::XS ();
require "$FindBin::Bin/t_stubs.pl";

ll_require('DB', 'Sources', 'Podcast', 'Browse', 'Played', 'Settings', 'Plugin');

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-62s got=%-24s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)'), (defined $want ? "'$want'" : '(undef)');
}
sub section { printf "\n== %s\n", $_[0] }

# --- the fake Material -------------------------------------------------------------------
# The API is a plain sub, and _useActionApi is a ->can() test, so presence is controlled by
# installing / deleting the symbol rather than by a flag — which is precisely what the plugin
# checks. @REG records every ($section, $action) pushed.
our @REG;
sub install_api {
    no strict 'refs';
    no warnings 'redefine';
    *{'Plugins::MaterialSkin::Plugin::registerCustomAction'} = sub { push @REG, [ @_ ] };
}
sub remove_api {
    no strict 'refs';
    delete $Plugins::MaterialSkin::Plugin::{registerCustomAction};
}

my $JSON = JSON::XS->new->utf8->canonical;
my $tmp  = File::Temp::tempdir(CLEANUP => 1);
$Slim::Utils::Prefs::DIR = $tmp;

sub actions_file { return "$tmp/material-skin/actions.json" }
sub read_file {
    my $f = actions_file();
    return {} unless -e $f;
    open my $fh, '<:raw', $f or die $!;
    local $/; my $raw = <$fh>; close $fh;
    return $JSON->decode($raw);
}
sub reset_all {
    @REG = ();
    $Plugins::ListenLater::Plugin::REGISTERED   = 0;
    $Plugins::ListenLater::Plugin::REGISTERED_N = 0;
    %Plugins::ListenLater::Plugin::UNREGISTERED = ();
    File::Path::remove_tree("$tmp/material-skin");
}
# A Material whose registerCustomAction DIES — the case the file write has to catch. $REFUSE
# is a coderef deciding per section, so a total failure and a partial one are the same stub.
our $REFUSE;
sub install_failing_api {
    my ($refuse) = @_;
    $REFUSE = $refuse;
    no strict 'refs';
    no warnings 'redefine';
    *{'Plugins::MaterialSkin::Plugin::registerCustomAction'} = sub {
        die "registerCustomAction: nope\n" if $REFUSE->($_[0]);
        push @REG, [ @_ ];
    };
}
# Every entry in the file that is OURS, by the plugin's own test — the one that matters, since
# it is what a re-run strips and what a doubled menu is made of.
sub ours_in_file {
    my ($data) = @_;
    my $n = 0;
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        $n += grep { Plugins::ListenLater::Plugin::_isOurAction($_) } @{ $data->{$cat} };
    }
    return $n;
}
sub registered_count { my %c; $c{ $_->[0] }++ for @REG; return \%c }

my ($POSITIVE, $FILEONLY) = Plugins::ListenLater::Plugin::_materialActionSet();
my $TOTAL = 0; $TOTAL += scalar @{ $POSITIVE->{$_} } for keys %$POSITIVE;
# The file half that is written on BOTH paths, with no podcast feeds subscribed: the two
# client-resolved categories. "our entries in the file" is $TOTAL + this on the legacy path
# and exactly this on the API path — an API-path count of 0 would mean Now Playing lost Add.
my $FILEHALF = 0; $FILEHALF += scalar @{ $FILEONLY->{$_} } for keys %$FILEONLY;

# ---------------------------------------------------------------------------
section('the action set itself');

is('positive categories are the six SERVER-resolved menu surfaces',
    join(',', sort keys %$POSITIVE),
    'album,album-track,online-album,online-track,playlist,playlist-track');
is('no online-artist (0.1.32 — we save albums/tracks, not artists)',
    (exists $POSITIVE->{'online-artist'} ? 'present' : 'absent'), 'absent');
# 0.1.97: registering these two loses them to Material's once-only client-side snapshot.
is('the client-resolved surfaces are file-only, with no podcast feeds subscribed',
    join(',', sort keys %$FILEONLY), 'queue-track,track');
is('...and neither is also registered (that would double them)',
    join(',', grep { exists $POSITIVE->{$_} } sort keys %$FILEONLY), '');
is('every positive category carries Add + Wish List',
    join(',', map { scalar @{ $POSITIVE->{$_} } } sort keys %$POSITIVE),
    '2,2,2,2,2,2');
is('...and so does each file-only surface', $FILEHALF, 4);

# ---------------------------------------------------------------------------
section('Material 6.4.6+ — entries go to the API, not the file');

reset_all();
remove_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();   # a 0.1.94 install, as upgraded from
my $legacy = read_file();
is('legacy install has our entries in the file', ours_in_file($legacy), $TOTAL + $FILEHALF);

install_api();
$Plugins::ListenLater::Plugin::REGISTERED = 0;
my $n = Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $data = read_file();

is('every positive entry registered with Material', $n, $TOTAL);
is('...in the same six sections',
    join(',', sort keys %{ registered_count() }), join(',', sort keys %$POSITIVE));
is('no REGISTERED entry of ours left in the file (or every Add shows twice)',
    ours_in_file($data) - $FILEHALF, 0);
is('...while the client-resolved half stays in the file, where Material can see it',
    join(',', map { scalar @{ $data->{$_} // [] } } qw(queue-track track)), '2,2');
is('the emptied positive categories are removed, not left as husks',
    join(',', grep { exists $data->{$_} } sort keys %$POSITIVE), '');
is('own-view suppressors still written (empty)',
    join(',', map { scalar @{ $data->{$_} // [] } } qw(listenlater-album LLHome-album)), '0,0');
is('...and are still PRESENT — an absent category stops suppressing',
    (exists $data->{'listenlater-album'} && exists $data->{'LLHome-album'}) ? 'yes' : 'no', 'yes');
is('radio suppressors still written (TuneIn seed list)',
    (exists $data->{'music-album'} && exists $data->{'news-track'}) ? 'yes' : 'no', 'yes');

# The registered actions must BE the shipped ones, not a second spelling of them.
my ($alb) = grep { $_->[0] eq 'album' } @REG;
is('registered album action is the addctx command',
    join(' ', @{ $alb->[1]{lmscommand} }[0,1]), 'listenlater addctx');
is('...carrying the Add title',   $alb->[1]{title}, 'Add to Listen Later');
is('...and its icon',             $alb->[1]{icon},  'playlist_add');
is('what is registered equals what the legacy path wrote',
    $JSON->encode([ map { $_->[1] } grep { $_->[0] eq 'online-album' } @REG ]),
    $JSON->encode($legacy->{'online-album'}));

# ---------------------------------------------------------------------------
section('registering happens exactly ONCE (there is no unregister, and no de-dupe)');

my $before = scalar @REG;
is('a second postinit-equivalent call registers nothing',
    Plugins::ListenLater::Plugin::_registerMaterialActions(), 0);
is('...so the recorded set is unchanged', scalar @REG, $before);

# A Settings save re-runs the file write to refresh the diagnostics snapshot; the deferred
# radio pass re-runs it 60s after startup. Neither may add a second copy of anything.
Plugins::ListenLater::Plugin::_writeMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('...and repeated file writes register nothing either', scalar @REG, $before);
is('...and leave only the client-resolved half in the file',
    ours_in_file(read_file()), $FILEHALF);

# ---------------------------------------------------------------------------
section('older Material — the file path is unchanged');

reset_all();
remove_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $old = read_file();
is('nothing registered (no API to register with)', scalar @REG, 0);
is('all our entries are in the file', ours_in_file($old), $TOTAL + $FILEHALF);
is('...byte-identical to what 0.1.94 wrote', $JSON->encode($old), $JSON->encode($legacy));

# ---------------------------------------------------------------------------
section('podcasts — file-only on BOTH paths (Material reads the override from the file)');

reset_all();
Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds',
    [ { name => 'Darko.Audio', value => 'https://darko.audio/feed' } ]);
my (undef, $withFeeds) = Plugins::ListenLater::Plugin::_materialActionSet();
is('podcasts-* join the file half once a feed is subscribed',
    join(',', sort keys %$withFeeds), 'podcasts-album,podcasts-track,queue-track,track');

install_api();
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $pod = read_file();
is('podcasts-* NOT registered with Material',
    (grep { $_->[0] =~ /^podcasts-/ } @REG) ? 'registered' : 'no', 'no');
is('...written to the file instead', scalar @{ $pod->{'podcasts-album'} // [] }, 1);
is('...as the podcast add, with no Wish List entry',
    $pod->{'podcasts-album'}[0]{lmscommand}[2], 'kind:podcast');
Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds', []);

# ---------------------------------------------------------------------------
section('the pref turned off');

reset_all();
install_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();     # something to clean up
Plugins::ListenLater::Plugin::_clearMaterialActions();
my $cleared = read_file();
is('nothing was registered', scalar @REG, 0);
is('no entry of ours survives in the file', ours_in_file($cleared), 0);
is('and neither do our suppressor categories',
    join(',', grep { exists $cleared->{$_} } qw(listenlater-album LLHome-album music-album)), '');

# ---------------------------------------------------------------------------
section("someone else's entries are never touched");

reset_all();
install_api();
File::Path::make_path("$tmp/material-skin");
open my $fh, '>:raw', actions_file() or die $!;
print $fh $JSON->encode({
    'album'       => [ { title => 'Someone else', lmscommand => [ 'otherplugin', 'go' ] } ],
    'qobuz-album' => [ { title => 'Their scoping', lmscommand => [ 'otherplugin', 'go' ] } ],
});
close $fh;
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $shared = read_file();
is('a third party entry in a category we vacated survives',
    scalar @{ $shared->{'album'} // [] }, 1);
is('...and is theirs', $shared->{'album'}[0]{title}, 'Someone else');
is('a populated foreign per-command category survives',
    scalar @{ $shared->{'qobuz-album'} // [] }, 1);

# ---------------------------------------------------------------------------
section('a registration Material REFUSES falls back to the file, not to nothing');
# The API path is chosen by capability, but delivery is decided by what actually happened:
# registerCustomAction can die, and the file write is the only other way an entry reaches a
# menu. Gating the write on the capability test alone strips our entries from the file AND
# registers nothing — the one arrangement that leaves the user with no "Add" anywhere.

reset_all();
install_failing_api(sub { 1 });                       # every section refused
is('nothing registered', Plugins::ListenLater::Plugin::_registerMaterialActions(), 0);
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $refused = read_file();
is('...so every entry is written to the file instead',
    ours_in_file($refused), $TOTAL + $FILEHALF);
is('...in the same six sections',
    join(',', grep { @{ $refused->{$_} // [] } } sort keys %$POSITIVE),
    join(',', sort keys %$POSITIVE));
is('...and it is the shipped set, not a second spelling',
    $JSON->encode($refused->{'online-album'}), $JSON->encode($POSITIVE->{'online-album'}));
is('...with the suppressors still in place',
    (exists $refused->{'listenlater-album'} && exists $refused->{'LLHome-album'}) ? 'yes' : 'no', 'yes');

# A PARTIAL failure is the one that can double: the entries Material DID take must not also
# be written, or every "Add" in those sections shows twice.
reset_all();
install_failing_api(sub { $_[0] eq 'online-album' });
my $partial_n = Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $part = read_file();
is('the sections Material accepted are registered', $partial_n, $TOTAL - 2);
is('...and only the refused one joins the file half', ours_in_file($part), 2 + $FILEHALF);
# Categories holding entries of OURS in the file, and categories Material took — the whole
# point is that those two lists never overlap.
my @inFile = grep { grep { Plugins::ListenLater::Plugin::_isOurAction($_) }
                    @{ ref $part->{$_} eq 'ARRAY' ? $part->{$_} : [] } } sort keys %$part;
my %tookIt = map { $_->[0] => 1 } @REG;
is('...that one, alongside the always-file-only pair',
    join(',', @inFile), 'online-album,queue-track,track');
is('...so no section is delivered twice',
    join(',', grep { $tookIt{$_} } @inFile), '');

# The pref turned ON from Settings, mid-run: that re-runs the FILE write, but registering
# outside postinit is not safe (no de-dupe, no unregister). Nothing has registered, so the
# file must carry everything — otherwise the toggle does nothing until the next restart.
reset_all();
install_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('a write with no registration behind it writes the full set',
    ours_in_file(read_file()), $TOTAL + $FILEHALF);
is('...and registers nothing on the way', scalar @REG, 0);

# ---------------------------------------------------------------------------
section('the Settings save actually re-runs the write (0.1.97)');
# The toggle is only useful if saving it does something on THIS run. Before 0.1.97 the
# rewrite was gated on debug_log as well, so on the default config — debug logging off,
# which is every user who has not been asked to turn it on — saving the Material toggle
# did nothing at all until the next restart, in both directions.

{
    no strict 'refs';
    no warnings 'redefine';
    *{'Slim::Utils::PluginManager::isEnabled'} = sub { 1 };   # MaterialSkin present
}
sub save_settings {
    my (%pref) = @_;
    Slim::Utils::Log::clear();
    Plugins::ListenLater::Settings->handler(undef, {
        saveSettings => 1, map { ("pref_$_" => $pref{$_}) } keys %pref,
    });
}

reset_all();
install_api();
Plugins::ListenLater::Plugin::_registerMaterialActions();   # postinit, with the pref on
Plugins::ListenLater::Plugin::_writeMaterialActions();

# Turned OFF, debug logging off — the file half has to go NOW, not at the next restart.
save_settings(material_action => 0, debug_log => 0);
is('turning it OFF with debug_log off clears the file half',
    ours_in_file(read_file()), 0);
is('...and warns that the REGISTERED half waits for a restart',
    (grep { /go at the next .*restart/ } Slim::Utils::Log::lines()) ? 'warned' : 'silent',
    'warned');
# The registered "Add" entries CANNOT be withdrawn, so the empty suppressors are the only
# thing keeping them off our own list, the home shelf and radio browse rows. Deleting them
# here — as the pref-was-off-at-startup path rightly does — would ADD "Add" to every Listen
# Later/Played row until the restart, and using it on a Played row bounces it back.
is('...while the own-view suppressors STAY, because the registered pair is still live',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(listenlater-album LLHome-album)),
    'y,y');
is('...and are still EMPTY (a populated one would offer the entry, not suppress it)',
    join(',', map { scalar @{ read_file()->{$_} // [] } } qw(listenlater-album LLHome-album)),
    '0,0');
is('...and so do the radio empties, for the same reason',
    (exists read_file()->{'music-album'} && exists read_file()->{'news-track'}) ? 'yes' : 'no',
    'yes');

# The same OFF save, but with the file GONE — the one path the `-e $file` early return was
# widened for (a first-ever write that failed, or someone deleting actions.json to "reset"
# it). Everything the clear preserves elsewhere it has to RE-CREATE here, because there is
# nothing on disk to preserve: with the online-* pair still registered and unwithdrawable,
# a missing radio empty puts "Add" back on every TuneIn/BBC Sounds row until the restart.
unlink actions_file();
save_settings(material_action => 0, debug_log => 0);
is('a missing file is rebuilt rather than left absent', (-e actions_file()) ? 'yes' : 'no', 'yes');
is('...with the own-view suppressors re-created',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(listenlater-album LLHome-album)),
    'y,y');
is('...and the radio empties re-created too',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(music-album news-track)),
    'y,y');
is('...all still EMPTY, or they would OFFER the entry instead of suppressing it',
    join(',', map { scalar @{ read_file()->{$_} // [] } }
        qw(listenlater-album LLHome-album music-album news-track)), '0,0,0,0');
is('...and no "Add" entry of ours is written back',  ours_in_file(read_file()), 0);

# Restore the state the next section expects (the file half back, nothing re-registered).
save_settings(material_action => 1, debug_log => 0);

# Turned back ON in the same run. Registration already happened at postinit and there is no
# unregister, so those entries are still live with Material — the write must restore the file
# half ONLY, or every "Add" it re-writes shows twice.
save_settings(material_action => 1, debug_log => 0);
is('turning it ON again restores the client-resolved half',
    ours_in_file(read_file()), $FILEHALF);
is('...and Now Playing / the queue have their Add back',
    join(',', map { scalar @{ read_file()->{$_} // [] } } qw(queue-track track)), '2,2');

# The other direction: the pref was off at STARTUP, so postinit never registered. Now the
# file has to carry everything, or turning it on does nothing until a restart.
reset_all();
install_api();
save_settings(material_action => 1, debug_log => 0);
is('turning it ON when nothing registered writes the full set',
    ours_in_file(read_file()), $TOTAL + $FILEHALF);
is('...without registering behind postinit\'s back', scalar @REG, 0);
is('...and says nothing about a restart — nothing is waiting on one',
    (grep { /restart/ } Slim::Utils::Log::lines()) ? 'warned' : 'silent', 'silent');

# ---------------------------------------------------------------------------
section("a third party's EMPTY suppressor survives the pref going OFF (0.1.101)");
# An empty per-command category is not litter, it is a deliberate Add-suppressor — which is
# the whole reason WE write them. The clear pass deleted every empty "*-album/-track/-artist"
# by regex, so it silently disarmed another plugin's suppressors too; harmless while the pass
# only ran at install, but 0.1.97 made it run on every Settings save. It now deletes only the
# categories _radioSuppressorCats() names, i.e. the ones we actually wrote.

reset_all();
install_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();   # our own set, nothing registered
{
    # Injected AFTER the write, so this tests the clear pass and nothing else.
    my $data = read_file();
    $data->{'otherplugin-album'} = [];
    $data->{'otherplugin-track'} = [];
    open my $out, '>:raw', actions_file() or die $!;
    print $out $JSON->encode($data);
    close $out;
}
Plugins::ListenLater::Plugin::_clearMaterialActions();
my $afterClear = read_file();
is('their empty suppressors are still there',
    join(',', map { (exists $afterClear->{$_} ? 'y' : 'n') } qw(otherplugin-album otherplugin-track)),
    'y,y');
is('...while OUR radio empties are gone (nothing registered, so nothing to suppress)',
    join(',', map { (exists $afterClear->{$_} ? 'y' : 'n') } qw(music-album news-track)),
    'n,n');
is('...and so are our own-view suppressors', ours_in_file($afterClear), 0);

# ---------------------------------------------------------------------------
section("...and survives the WRITE pass too, which is the one that runs constantly");
# 0.1.101 hardened the clear pass and deliberately left its twin in _writeMaterialActions
# alone, on the reasoning that the write pass "has to delete empty per-command cruft it cannot
# name". It doesn't have to name it: the cruft is whatever the strip pass just emptied, because
# the 0.1.46–0.1.50 scoping experiments put OUR entries in those categories — that is what makes
# them ours. An empty that arrived empty was never ours and is somebody's deliberate suppressor.
# The exposure is the LARGER of the two: this pass runs at every startup, on every Settings save
# and on the deferred write, so their Add came back every time the user saved our settings.

reset_all();
install_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $ourBaseline = ours_in_file(read_file());
{
    # Injected AFTER a first write, so what is under test is the NEXT write pass — which is
    # how it happens in life: their suppressor is on disk, then we run again.
    my $data = read_file();
    $data->{'otherplugin-album'} = [];
    $data->{'otherplugin-track'} = [];
    # ...and next to it, the shape that MUST still be swept: a category holding nothing but our
    # own entry. Strictly a positive control — remove the provenance test and this one still
    # passes, but without it the fix could be "delete nothing" and the suite would not notice.
    $data->{'qobuz-album'} = [ { title => 'Add to Listen Later',
                                 lmscommand => [ 'listenlater', 'addctx' ] } ];
    open my $out, '>:raw', actions_file() or die $!;
    print $out $JSON->encode($data);
    close $out;
}
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $afterWrite = read_file();
is('their empty suppressors survive the write pass',
    join(',', map { (exists $afterWrite->{$_} ? 'y' : 'n') } qw(otherplugin-album otherplugin-track)),
    'y,y');
is('...while our own 0.1.51-era leftover is still swept (the reason the pass exists)',
    (exists $afterWrite->{'qobuz-album'} ? 'kept' : 'deleted'), 'deleted');
is('...and our own entry set comes out exactly as a clean write leaves it',
    ours_in_file($afterWrite), $ourBaseline);

# ---------------------------------------------------------------------------
section('the FILE-ONLY podcasts-* override leaves no husk when the pref goes OFF');
# podcasts-album/-track are ours and file-only, so the strip pass empties them — but they are
# per-app "<command>-<type>" categories, and an EMPTY one of those SUPPRESSES the online-*
# fallback (the 0.1.52 rule). The delete-empties pass names the categories it may remove, and
# the list it was checked against (%ourCats + _radioSuppressorCats, whose podcast entry is
# TuneIn's singular 'podcast') did not include them — so turning the pref off left
# {"podcasts-album":[],"podcasts-track":[]} behind, hiding Add on every Podcasts-app row for
# good. Nothing cleans it later: the pref-ON write pass that would is the one the pref being
# off stops from running.

reset_all();
install_api();
Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds',
    [ { name => 'Darko.Audio', value => 'https://darko.audio/feed' } ]);
Plugins::ListenLater::Plugin::_writeMaterialActions();     # nothing registered
is('the write pass wrote the override',
    scalar @{ read_file()->{'podcasts-album'} // [] }, 1);
Plugins::ListenLater::Plugin::_clearMaterialActions();
is('the clear pass deletes it outright, husk and all',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(podcasts-album podcasts-track)),
    'n,n');

# The same clear, but with every feed unsubscribed first — _materialActionSet stops emitting
# podcasts-* the moment hasFeeds() goes false, so a list read from IT would no longer name
# them and the husks would survive. This is why the clear pass hardcodes the pair.
reset_all();
install_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();
Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds', []);
Plugins::ListenLater::Plugin::_clearMaterialActions();
is('...even for a user who has unsubscribed from everything',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(podcasts-album podcasts-track)),
    'n,n');

# With registrations still live it is the OPPOSITE: the online-* pair cannot be withdrawn, so
# the emptied override is the only thing keeping "Add" off Podcasts rows until the restart —
# exactly the argument that keeps the radio empties. Kept when present, RE-CREATED when the
# file is gone.
reset_all();
install_api();
Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds',
    [ { name => 'Darko.Audio', value => 'https://darko.audio/feed' } ]);
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
Plugins::ListenLater::Plugin::_clearMaterialActions();
is('while entries are live the override STAYS',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(podcasts-album podcasts-track)),
    'y,y');
is('...and is EMPTY, so it suppresses rather than offers',
    join(',', map { scalar @{ read_file()->{$_} // [] } } qw(podcasts-album podcasts-track)),
    '0,0');
unlink actions_file();
Plugins::ListenLater::Plugin::_clearMaterialActions();
is('...and is re-created when the file has gone',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(podcasts-album podcasts-track)),
    'y,y');
Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds', []);

# ---------------------------------------------------------------------------
section('the diagnostic shadow scan reports FOREIGN categories only (0.1.101)');
# _dumpMaterialState flags a POPULATED "<svc>-album/-track" because such a category shadows
# online-* and hides Add on that one service. Three of our own populated categories —
# album-track, playlist-track, queue-track — are not "<service>-<type>" shaped at all, so the
# old prefix-based exemption listed them as foreign and pointed remote triage at the plugin's
# own entries. Exemption is now by FULL category name, taken from _materialActionSet.
sub shadow_line {
    my ($line) = grep { /shadow/i }
        split /\n/, ($Slim::Utils::Prefs::VALUES{material_debug_snapshot} // '');
    return $line // '(no shadow line in the snapshot)';
}
Slim::Utils::Prefs::set_test_pref('debug_log', 1);

reset_all();
install_api();
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('API path: a clean install reports NOTHING as shadowing',
    (shadow_line() =~ /^no non-empty per-service shadow/) ? 'clean' : shadow_line(), 'clean');

reset_all();
remove_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();   # legacy: every category in the file
is('legacy path: our own album-track/playlist-track/queue-track are not "foreign"',
    (shadow_line() =~ /^no non-empty per-service shadow/) ? 'clean' : shadow_line(), 'clean');

# The positive control — the scan still has to catch the thing it exists for.
{
    my $data = read_file();
    $data->{'tidal-album'} = [ { title => 'Theirs', lmscommand => [ 'otherplugin', 'go' ] } ];
    open my $out, '>:raw', actions_file() or die $!;
    print $out $JSON->encode($data);
    close $out;
}
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('...but a populated FOREIGN per-service category is still reported',
    (shadow_line() =~ /SHADOW online-\*.*\btidal-album\(1\)/) ? 'reported' : shadow_line(),
    'reported');
Slim::Utils::Prefs::set_test_pref('debug_log', 0);

# ---------------------------------------------------------------------------
section('a FAILED write must not record the ownership ledger (0.1.105)');
# _ownedCats hands back its generous one-time SEED only while material_owned_cats is unset:
#
#     my $l = $prefs->get('material_owned_cats');
#     return { map { $_ => 1 } @$l } if ref $l eq 'ARRAY';   # <- set: the seed is gone
#
# so setting the ledger at all retires the seed permanently. _writeMaterialActionsFile has four
# die paths (open/print/close/rename) and BOTH callers wrap it in `eval { ...; 1 }`, so a full
# disk or an unwritable prefs dir is swallowed and the plugin carries on. Recording the ledger
# BEFORE that write therefore had a permanent failure mode: the ledger claims categories the
# file never received, the seed is retired, and a pre-ledger husk — an empty '<svc>-album' left
# by 0.1.47-0.1.50 — is then in NEITHER %emptied (it arrives empty) NOR %owned. The
# delete-empties pass skips it forever and "Add" stays hidden on that service, unrecoverable
# without hand-editing the shared file. That is the 0.1.51 regression, so the ordering is
# load-bearing and pinned here: record only after the write returns.
reset_all();
remove_api();
delete $Slim::Utils::Prefs::VALUES{material_owned_cats};   # pre-ledger install: seed applies

# The husk 0.1.47-0.1.50 left behind. Deezer is in %SUPPORTED_CMD, so it is not a radio
# suppressor and not in %keep — the seed is the only thing that can ever sweep it.
File::Path::make_path("$tmp/material-skin");
{
    open my $out, '>:raw', actions_file() or die $!;
    print $out $JSON->encode({ 'deezer-album' => [] });
    close $out;
}

my $died = 0;
{
    no warnings 'redefine';
    local *Plugins::ListenLater::Plugin::_writeMaterialActionsFile = sub { die "disk full\n" };
    $died = 1 unless eval { Plugins::ListenLater::Plugin::_writeMaterialActions(); 1 };
}
is('the write really did fail', $died, 1);
is('...so the ledger was NOT recorded (the seed survives)',
    (ref $Slim::Utils::Prefs::VALUES{material_owned_cats} eq 'ARRAY') ? 'recorded' : 'unset',
    'unset');
is('...and the husk is still in the file, untouched',
    (ref read_file()->{'deezer-album'} eq 'ARRAY') ? 'present' : 'gone', 'present');

# The next write succeeds, and because the seed is intact it sweeps the husk it was there for.
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('the next successful write sweeps the pre-ledger husk',
    (exists read_file()->{'deezer-album'}) ? 'survived' : 'swept', 'swept');
is('...and NOW the ledger is recorded',
    (ref $Slim::Utils::Prefs::VALUES{material_owned_cats} eq 'ARRAY') ? 'recorded' : 'unset',
    'recorded');

# The same ordering on the CLEAR path (_clearMaterialActions): its ledger write is held behind
# the file write too, so a failed clear leaves the seed in place for the next attempt.
reset_all();
delete $Slim::Utils::Prefs::VALUES{material_owned_cats};
$Plugins::ListenLater::Plugin::REGISTERED_N = 1;          # $live: the re-assert branch runs
{
    no warnings 'redefine';
    local *Plugins::ListenLater::Plugin::_writeMaterialActionsFile = sub { die "disk full\n" };
    eval { Plugins::ListenLater::Plugin::_clearMaterialActions(); 1 };
}
is('clear path: a failed write leaves the seed intact too',
    (ref $Slim::Utils::Prefs::VALUES{material_owned_cats} eq 'ARRAY') ? 'recorded' : 'unset',
    'unset');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
