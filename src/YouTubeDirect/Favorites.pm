package Plugins::YouTubeDirect::Favorites;

# Videos favorited in YouTube Direct, kept on this Lyrion server only (pref
# `favorites` = { videoId => { title, channel, channel_id, duration, added } }),
# separate from Lyrion's own Favorites. Videos are added and removed from the
# video's "More" menu (trackInfoFeed), which every Lyrion client offers for a
# listed, queued or playing video.

use strict;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::YouTubeDirect::Source;
use Plugins::YouTubeDirect::Util qw(parseVideoUrl);

my $log   = logger('plugin.youtubedirect');
my $prefs = preferences('plugin.youtubedirect');

sub all { $prefs->get('favorites') || {} }

sub has { all()->{ $_[1] } ? 1 : 0 }

# Favorites as video items, newest first; only one channel's if given
sub list {
	my ($class, $channel) = @_;
	my $favs = all();
	my @ids = grep {
		!$channel || ($favs->{$_}{channel_id} || '') eq $channel->{id}
		|| (!$favs->{$_}{channel_id} && $channel->{title} && ($favs->{$_}{channel} || '') eq $channel->{title})
	} keys %$favs;

	return [
		map  { { type => 'video', id => $_, %{ $favs->{$_} } } }
		sort { ($favs->{$b}{added} || 0) <=> ($favs->{$a}{added} || 0) } @ids
	];
}

# -- track info menu ---------------------------------------------------------
#
# ProtocolHandler::trackInfoURL hands LMS this feed as the video's whole
# "More" menu. (A Slim::Menu::TrackInfo provider would only run for videos
# LMS already has a track object for, i.e. ones queued or played.)
#
# Positions never change meaning: the channel first, then the favorite
# entries. Menu-mode clients (Material) get one favorite toggle with no type
# or icon that flips in place; plain-list clients (LyrionJS) get entries that
# keep one meaning each, since they show an old copy of the page after
# going back (same reasoning as Plugin::channelMenu).
sub trackInfoFeed {
	my ($class, $client, $cb, $args, $url) = @_;

	my $id = parseVideoUrl($url) or return $cb->({ items => [] });
	my $menu = $args && ref $args->{params} eq 'HASH' && defined $args->{params}{menu} ? 1 : 0;
	my $known = Plugins::YouTubeDirect::Source->video($id) || {};
	my $fav = all()->{$id} || {};
	my %video = (
		id         => $id,
		title      => $known->{title} || $fav->{title},
		channel    => $known->{channel} || $fav->{channel},
		channel_id => $known->{channel_id} || $fav->{channel_id},
		duration   => $known->{duration} || $fav->{duration},
	);
	my $is = $class->has($id);
	my @items;

	if ($video{channel_id}) {
		push @items, {
			name  => $video{channel} || cstring($client, 'PLUGIN_YOUTUBEDIRECT_CHANNEL'),
			line2 => cstring($client, 'PLUGIN_YOUTUBEDIRECT_CHANNEL'),
			type  => 'link',
			image => Plugins::YouTubeDirect::Plugin::_icon('account_circle'),
			url   => \&Plugins::YouTubeDirect::Plugin::channelMenu,
			passthrough => [{ id => $video{channel_id}, title => $video{channel}, menu => $menu }],
		};
	}

	if ($menu) {
		push @items, {
			name  => cstring($client, $is ? 'PLUGIN_YOUTUBEDIRECT_UNFAVORITE' : 'PLUGIN_YOUTUBEDIRECT_FAVORITE'),
			url   => \&setFavorite,
			passthrough => [{ %video, favorite => $is ? 0 : 1 }],
			nextWindow => 'refresh',
		};
	}
	else {
		push @items, {
			name  => cstring($client, $is ? 'PLUGIN_YOUTUBEDIRECT_FAVORITED' : 'PLUGIN_YOUTUBEDIRECT_FAVORITE'),
			type  => 'link',
			image => Plugins::YouTubeDirect::Plugin::_icon('favorite'),
			url   => \&setFavorite,
			passthrough => [{ %video, favorite => 1 }],
		};
		push @items, {
			name  => cstring($client, 'PLUGIN_YOUTUBEDIRECT_UNFAVORITE'),
			type  => 'link',
			image => Plugins::YouTubeDirect::Plugin::_icon('heart_broken'),
			url   => \&setFavorite,
			passthrough => [{ %video, favorite => 0 }],
		} if $is;
	}

	$cb->({ items => \@items });
}

sub setFavorite {
	my ($client, $cb, $args, $pass) = @_;

	my %favs = %{ all() };
	my $id = $pass->{id};
	my $name = $pass->{title} || ($favs{$id} && $favs{$id}{title}) || $id;

	# see Plugin::isEcho: LyrionJS repeats every text reply in menu mode
	if (Plugins::YouTubeDirect::Plugin::isEcho("favorite:$id")) {
		main::INFOLOG && $log->info("ignoring repeated favorite request for $id");
	}
	elsif ($pass->{favorite} && !$favs{$id}) {
		$favs{$id} = {
			title      => $pass->{title},
			channel    => $pass->{channel},
			channel_id => $pass->{channel_id},
			duration   => $pass->{duration},
			added      => time(),
		};
		$prefs->set(favorites => \%favs);
		main::INFOLOG && $log->info("favorite: $id ($name)");
	}
	elsif (!$pass->{favorite} && $favs{$id}) {
		delete $favs{$id};
		$prefs->set(favorites => \%favs);
		main::INFOLOG && $log->info("unfavorite: $id ($name)");
	}

	my $token = $favs{$id} ? 'PLUGIN_YOUTUBEDIRECT_FAVORITE_ADDED' : 'PLUGIN_YOUTUBEDIRECT_FAVORITE_REMOVED';
	# the weblink keeps Material from wrapping the reply in HTML (see Plugin::setFollow)
	$cb->({ items => [{ name => sprintf(cstring($client, $token), $name), type => 'text', weblink => "https://www.youtube.com/watch?v=$id" }] });
}

1;
