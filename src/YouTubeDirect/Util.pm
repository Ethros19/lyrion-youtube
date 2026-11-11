package Plugins::YouTubeDirect::Util;

# Pure helpers (no LMS dependencies) so they can be unit tested: YouTube
# link parsing, the fragmented-MP4 audio YouTube serves (sidx index,
# AudioSpecificConfig, samples -> ADTS), the SponsorBlock skip timeline,
# chapters, yt-dlp / RSS / Data API result shapes, and formatting.

use strict;
use utf8;

use Exporter qw(import);

our @EXPORT_OK = qw(
	videoUrl parseVideoUrl parseLink isVideoId isChannelId uploadsPlaylist thumbnail
	iso8601Duration formatDuration
	topBoxes parseSidx mp4AudioConfig fmp4Samples adtsHeader adtsInfo fragmentAt
	mergeSkips skippedBefore realToVirtual virtualToReal skipAt skipSegments
	normalizeChapters splitArtistTitle trackAt
	flatEntries parseRss assetFor
);

# -- links -----------------------------------------------------------------

sub isVideoId   { defined $_[0] && $_[0] =~ /^[A-Za-z0-9_-]{11}$/ }
sub isChannelId { defined $_[0] && $_[0] =~ /^UC[A-Za-z0-9_-]{22}$/ }

sub videoUrl { 'ytdirect://' . $_[0] }

sub parseVideoUrl {
	my $url = shift || return;
	return $url =~ m{^ytdirect://([A-Za-z0-9_-]{11})} ? $1 : undef;
}

# A channel's uploads are a playlist: UC... -> UU...
sub uploadsPlaylist {
	my $channel = shift;
	return isChannelId($channel) ? 'UU' . substr($channel, 2) : undef;
}

sub thumbnail { "https://i.ytimg.com/vi/$_[0]/hqdefault.jpg" }

# Anything a person might paste -> { type => video|playlist|channel|handle|url, ... }
sub parseLink {
	my $in = shift // return;
	$in =~ s/^\s+|\s+$//g;
	return unless length $in;

	return { type => 'video', id => $in } if isVideoId($in);
	return { type => 'channel', id => $in } if isChannelId($in);
	return { type => 'handle', handle => $1 } if $in =~ /^@([\w.\-]+)$/;

	my ($host, $path, $query) = $in =~ m{^(?:https?://)?([^/?#]+)(/[^?#]*)?(?:\?([^#]*))?}i or return;
	$host = lc $host;
	$path //= '/';
	my %q = map { my ($k, $v) = split /=/, $_, 2; ($k => $v // '') } split /&/, $query // '';

	if ($host =~ /(?:^|\.)youtu\.be$/) {
		return { type => 'video', id => $1 } if $path =~ m{^/([A-Za-z0-9_-]{11})};
		return;
	}
	return unless $host =~ /(?:^|\.)youtube(?:-nocookie)?\.com$/;

	return { type => 'video', id => $q{v} } if isVideoId($q{v});
	return { type => 'video', id => $1 } if $path =~ m{^/(?:shorts|embed|live|v|e)/([A-Za-z0-9_-]{11})};
	return { type => 'playlist', id => $q{list} } if $q{list} && $q{list} =~ /^[A-Za-z0-9_-]{10,}$/;
	return { type => 'channel', id => $1 } if $path =~ m{^/channel/(UC[A-Za-z0-9_-]{22})};
	return { type => 'handle', handle => $1 } if $path =~ m{^/@([^/]+)};
	return { type => 'url', url => "https://www.youtube.com/$1/$2" } if $path =~ m{^/(c|user)/([^/]+)};
	return;
}

# -- durations ---------------------------------------------------------------

# Data API contentDetails.duration ("PT1H5M16S", "P1DT2H") -> seconds
sub iso8601Duration {
	my $d = shift || return;
	my ($days, $h, $m, $s) = $d =~ /^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/ or return;
	return ($days || 0) * 86400 + ($h || 0) * 3600 + ($m || 0) * 60 + ($s || 0);
}

sub formatDuration {
	my $secs = int(shift || 0);
	return '' unless $secs > 0;
	my $h = int($secs / 3600);
	my $m = int(($secs % 3600) / 60);
	return $h ? sprintf('%d:%02d:%02d', $h, $m, $secs % 60) : sprintf('%d:%02d', $m, $secs % 60);
}

# -- fragmented MP4 ------------------------------------------------------------
#
# YouTube's audio-only m4a (itag 140/139) is one fragmented MP4 file:
# ftyp, moov, a single sidx indexing every fragment, then moof+mdat pairs of
# up to ~10 s each. The sidx tells us each fragment's byte range and start
# time, so we fetch exactly one fragment per request and seek by fragment.

sub _boxes {
	my ($buf, $start, $end) = @_;
	use bytes;
	my @out;
	my $pos = $start;
	while ($pos + 8 <= $end) {
		my ($size, $type) = unpack('N a4', substr($buf, $pos, 8));
		my $header = 8;
		if ($size == 1) {
			last if $pos + 16 > $end;
			my ($hi, $lo) = unpack('N N', substr($buf, $pos + 8, 8));
			$size = $hi * 4294967296 + $lo;
			$header = 16;
		}
		elsif ($size == 0) {
			$size = $end - $pos;
		}
		last if $size < $header;
		push @out, { type => $type, start => $pos, body => $pos + $header, end => $pos + $size };
		$pos += $size;
	}
	return @out;
}

# Top-level boxes of a file prefix; the last may be truncated (end > length)
sub topBoxes {
	my $buf = shift;
	use bytes;
	return _boxes($buf, 0, length $buf);
}

sub _child {
	my ($buf, $box, @path) = @_;
	for my $type (@path) {
		($box) = grep { $_->{type} eq $type } _boxes($buf, $box->{body}, $box->{end});
		return unless $box;
	}
	return $box;
}

# File prefix -> { timescale, end, duration, fragments => [{ offset, size, start, duration }] }
# or { need => bytes } if the sidx runs past the buffer, or undef if there's none
sub parseSidx {
	my $buf = shift;
	use bytes;
	return unless defined $buf;

	my ($sidx) = grep { $_->{type} eq 'sidx' } topBoxes($buf) or return;
	return { need => $sidx->{end} } if $sidx->{end} > length $buf;

	my $p = $sidx->{body};
	my $version = ord(substr($buf, $p, 1));
	my $timescale = unpack('N', substr($buf, $p + 8, 4)) || return;
	$p += 12;

	my ($ept, $first);
	if ($version == 0) {
		($ept, $first) = unpack('N N', substr($buf, $p, 8));
		$p += 8;
	}
	else {
		my @v = unpack('N4', substr($buf, $p, 16));
		($ept, $first) = ($v[0] * 4294967296 + $v[1], $v[2] * 4294967296 + $v[3]);
		$p += 16;
	}
	my $count = unpack('n', substr($buf, $p + 2, 2));
	$p += 4;

	my $offset = $sidx->{end} + $first;
	my $time = $ept;
	my @fragments;

	for (1 .. $count) {
		my ($ref, $dur) = unpack('N N', substr($buf, $p, 8));
		$p += 12;
		return if $ref & 0x80000000;              # hierarchical sidx: not used by YouTube
		my $size = $ref & 0x7fffffff;
		push @fragments, { offset => $offset, size => $size, start => $time / $timescale, duration => $dur / $timescale };
		$offset += $size;
		$time += $dur;
	}

	return unless @fragments;
	return {
		timescale => $timescale,
		end       => $sidx->{end},
		duration  => ($time - $ept) / $timescale,
		fragments => \@fragments,
	};
}

# Fragment holding $secs (fragments sorted by start)
sub fragmentAt {
	my ($fragments, $secs) = @_;
	my $index = 0;
	for my $i (0 .. $#$fragments) {
		last if $fragments->[$i]{start} > $secs;
		$index = $i;
	}
	return $index;
}

my @SAMPLE_RATES = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350);

# MPEG-4 descriptor length: 1-4 bytes, 7 bits each
sub _descLen {
	my ($buf, $pos) = @_;
	my $len = 0;
	for (1 .. 4) {
		my $b = ord(substr($buf, $$pos++, 1));
		$len = ($len << 7) | ($b & 0x7f);
		last unless $b & 0x80;
	}
	return $len;
}

# moov -> { object, rateIndex, samplerate, channels, timescale, bitrate }
sub mp4AudioConfig {
	my $buf = shift;
	use bytes;
	return unless defined $buf;

	my ($moov) = grep { $_->{type} eq 'moov' } topBoxes($buf) or return;
	return if $moov->{end} > length $buf;
	my $trak = _child($buf, $moov, 'trak') or return;
	my $mdhd = _child($buf, $trak, 'mdia', 'mdhd');
	my $stsd = _child($buf, $trak, 'mdia', 'minf', 'stbl', 'stsd') or return;

	my $timescale;
	if ($mdhd) {
		my $version = ord(substr($buf, $mdhd->{body}, 1));
		$timescale = unpack('N', substr($buf, $mdhd->{body} + ($version ? 20 : 12), 4));
	}

	# stsd: version/flags(4) count(4), then the mp4a sample entry: 8 header +
	# 28 bytes of audio sample entry fields, then its child boxes (esds)
	my ($mp4a) = grep { $_->{type} eq 'mp4a' } _boxes($buf, $stsd->{body} + 8, $stsd->{end}) or return;
	my ($esds) = grep { $_->{type} eq 'esds' } _boxes($buf, $mp4a->{body} + 28, $mp4a->{end}) or return;

	my $pos = $esds->{body} + 4;                      # version/flags
	return unless ord(substr($buf, $pos++, 1)) == 0x03; # ES_Descriptor
	_descLen($buf, \$pos);
	$pos += 2;                                        # ES_ID
	my $flags = ord(substr($buf, $pos++, 1));
	$pos += 2 if $flags & 0x80;                       # dependsOn_ES_ID
	$pos += 1 + ord(substr($buf, $pos, 1)) if $flags & 0x40;   # URL
	$pos += 2 if $flags & 0x20;                       # OCR_ES_Id
	return unless ord(substr($buf, $pos++, 1)) == 0x04; # DecoderConfigDescriptor
	_descLen($buf, \$pos);
	my $bitrate = unpack('N', substr($buf, $pos + 9, 4));   # avgBitrate (0 = variable)
	$pos += 13;                                       # objectType ... avgBitrate
	return unless ord(substr($buf, $pos++, 1)) == 0x05; # DecoderSpecificInfo
	my $len = _descLen($buf, \$pos);
	return unless $len >= 2;

	# AudioSpecificConfig: 5 bits object type, 4 bits rate index, 4 bits channels
	my $asc = unpack('n', substr($buf, $pos, 2));
	my $object    = $asc >> 11;
	my $rateIndex = ($asc >> 7) & 0x0f;
	my $channels  = ($asc >> 3) & 0x0f;
	return if $object == 31 || $rateIndex == 15;      # escape values: not seen, not handled

	return {
		object     => $object,
		rateIndex  => $rateIndex,
		samplerate => $SAMPLE_RATES[$rateIndex],
		channels   => $channels,
		timescale  => $timescale,
		bitrate    => $bitrate || undef,
	};
}

# One fragment (moof + mdat, buffer starting at the moof) -> raw AAC frames
sub fmp4Samples {
	my $buf = shift;
	use bytes;
	my @samples;

	for my $moof (grep { $_->{type} eq 'moof' } topBoxes($buf)) {
		for my $traf (grep { $_->{type} eq 'traf' } _boxes($buf, $moof->{body}, $moof->{end})) {
			my ($tfhd) = grep { $_->{type} eq 'tfhd' } _boxes($buf, $traf->{body}, $traf->{end}) or next;

			my $tf = unpack('N', substr($buf, $tfhd->{body}, 4)) & 0xffffff;
			my $p = $tfhd->{body} + 8;                # version/flags + track_ID
			my $base = $moof->{start};                # default-base-is-moof
			if ($tf & 0x01) {
				my ($hi, $lo) = unpack('N N', substr($buf, $p, 8));
				$base = $hi * 4294967296 + $lo;
				$p += 8;
			}
			$p += 4 if $tf & 0x02;                    # sample_description_index
			$p += 4 if $tf & 0x08;                    # default_sample_duration
			my $defaultSize = $tf & 0x10 ? unpack('N', substr($buf, $p, 4)) : 0;

			my $offset = $base;
			for my $trun (grep { $_->{type} eq 'trun' } _boxes($buf, $traf->{body}, $traf->{end})) {
				my $f = unpack('N', substr($buf, $trun->{body}, 4)) & 0xffffff;
				my $count = unpack('N', substr($buf, $trun->{body} + 4, 4));
				my $q = $trun->{body} + 8;
				if ($f & 0x01) {
					$offset = $base + unpack('l>', substr($buf, $q, 4));
					$q += 4;
				}
				$q += 4 if $f & 0x04;                 # first_sample_flags

				for (1 .. $count) {
					$q += 4 if $f & 0x100;            # duration
					my $size = $defaultSize;
					if ($f & 0x200) { $size = unpack('N', substr($buf, $q, 4)); $q += 4 }
					$q += 4 if $f & 0x400;            # flags
					$q += 4 if $f & 0x800;            # composition offset
					last if $offset + $size > length $buf;
					push @samples, substr($buf, $offset, $size);
					$offset += $size;
				}
			}
		}
	}

	return @samples;
}

# 7-byte ADTS header for one raw AAC frame. HE-AAC (object 5/29) is sent as
# LC at the core rate; decoders find the SBR layer themselves.
sub adtsHeader {
	my ($config, $len) = @_;
	my $full = $len + 7;
	my $object = $config->{object} == 5 || $config->{object} == 29 ? 2 : $config->{object};
	my $profile = ($object - 1) & 0x03;
	return pack('C7',
		0xff,
		0xf1,                                         # MPEG-4, layer 0, no CRC
		($profile << 6) | ($config->{rateIndex} << 2) | (($config->{channels} >> 2) & 1),
		(($config->{channels} & 3) << 6) | (($full >> 11) & 3),
		($full >> 3) & 0xff,
		(($full & 7) << 5) | 0x1f,                    # buffer fullness 0x7FF (VBR)
		0xfc,                                         # ... and one raw data block
	);
}

# ADTS header at $pos -> { length, samplerate, channels, frames } or undef
sub adtsInfo {
	my ($buf, $pos) = @_;
	$pos ||= 0;

	use bytes;
	return if $pos + 7 > length $buf;

	my @h = unpack('C7', substr($buf, $pos, 7));
	return unless $h[0] == 0xff && ($h[1] & 0xf6) == 0xf0;

	my $rate = $SAMPLE_RATES[($h[2] >> 2) & 0x0f] || return;
	my $length = (($h[3] & 0x03) << 11) | ($h[4] << 3) | ($h[5] >> 5);
	return if $length < 7;

	return {
		length     => $length,
		samplerate => $rate,
		channels   => (($h[2] & 1) << 2) | ($h[3] >> 6),
		frames     => ($h[6] & 3) + 1,
	};
}

# -- SponsorBlock skip timeline ------------------------------------------------
#
# Skipped segments are cut out of the stream, so the player's clock runs on
# a "virtual" timeline: the video's time minus everything skipped before it.
# Durations, seeks and chapter lookups convert between the two.

# SponsorBlock JSON -> [[start, end], ...] for skip segments in the wanted categories
sub skipSegments {
	my ($data, $categories) = @_;
	return [] unless ref $data eq 'ARRAY';
	my %want = map { $_ => 1 } @{ $categories || [] };
	return [
		map  { [ $_->{segment}[0], $_->{segment}[1] ] }
		grep { ref $_->{segment} eq 'ARRAY' && ($_->{actionType} || 'skip') eq 'skip' && (!$categories || $want{ $_->{category} || '' }) }
		@$data
	];
}

# Sort, clamp to [0, duration], merge overlaps, drop slivers -> [[s, e], ...]
sub mergeSkips {
	my ($segments, $duration, $min) = @_;
	$min //= 1;

	my @in = sort { $a->[0] <=> $b->[0] }
	         grep { $_->[1] > $_->[0] }
	         map  { [ $_->[0] < 0 ? 0 : $_->[0], defined $duration && $_->[1] > $duration ? $duration : $_->[1] ] }
	         grep { ref $_ eq 'ARRAY' && defined $_->[0] && defined $_->[1] }
	         @{ $segments || [] };

	my @out;
	for my $s (@in) {
		if (@out && $s->[0] <= $out[-1][1]) {
			$out[-1][1] = $s->[1] if $s->[1] > $out[-1][1];
		}
		else {
			push @out, [ @$s ];
		}
	}
	return [ grep { $_->[1] - $_->[0] >= $min } @out ];
}

sub skippedBefore {
	my ($skips, $real) = @_;
	my $total = 0;
	for my $s (@{ $skips || [] }) {
		last if $s->[0] >= $real;
		$total += ($real < $s->[1] ? $real : $s->[1]) - $s->[0];
	}
	return $total;
}

sub realToVirtual {
	my ($skips, $real) = @_;
	return $real - skippedBefore($skips, $real);
}

sub virtualToReal {
	my ($skips, $virtual) = @_;
	my $real = $virtual;
	for my $s (@{ $skips || [] }) {
		last if $s->[0] > $real;
		$real += $s->[1] - $s->[0];
	}
	return $real;
}

# The skip segment containing $real, if any
sub skipAt {
	my ($skips, $real) = @_;
	for my $s (@{ $skips || [] }) {
		return $s if $real >= $s->[0] && $real < $s->[1];
		last if $s->[0] > $real;
	}
	return;
}

# -- chapters ------------------------------------------------------------------

# "Artist - Title", "03. Artist – Title", "Artist — Title" -> (artist, title)
sub splitArtistTitle {
	my $text = shift // '';
	$text =~ s/^\s*(?:\d{1,3}[.)]\s+)?//;
	$text =~ s/\s+$//;
	if ($text =~ /^(.+?)\s+[-–—]\s+(.+)$/) {
		return ($1, $2);
	}
	return (undef, $text);
}

# yt-dlp chapters -> [{ start, title, artist }], or [] when there's only
# YouTube's placeholder single chapter
sub normalizeChapters {
	my $chapters = shift;
	return [] unless ref $chapters eq 'ARRAY' && @$chapters > 1;

	my @out;
	for my $c (sort { ($a->{start_time} || 0) <=> ($b->{start_time} || 0) } @$chapters) {
		next unless defined $c->{start_time} && defined $c->{title} && length $c->{title};
		my ($artist, $title) = splitArtistTitle($c->{title});
		push @out, { start => $c->{start_time}, title => $title, ($artist ? (artist => $artist) : ()) };
	}
	return \@out;
}

# Chapter playing at $secs (sorted by start)
sub trackAt {
	my ($sections, $secs) = @_;
	my $current;
	for my $s (@{ $sections || [] }) {
		last if $s->{start} > $secs;
		$current = $s;
	}
	return $current;
}

# -- listings ------------------------------------------------------------------

sub _bestThumb {
	my $thumbs = shift;
	return unless ref $thumbs eq 'ARRAY' && @$thumbs;
	my ($best) = sort { ($b->{width} || 0) <=> ($a->{width} || 0) } grep { $_->{url} } @$thumbs;
	return unless $best;
	my $url = $best->{url};
	$url = "https:$url" if $url =~ m{^//};
	return $url;
}

# yt-dlp --flat-playlist -J output -> normalized videos, channels and playlists
sub flatEntries {
	my $data = shift;
	return [] unless ref $data eq 'HASH';

	my @out;
	for my $e (@{ $data->{entries} || [] }) {
		next unless ref $e eq 'HASH' && $e->{id};
		my $url = $e->{url} || '';

		if (isChannelId($e->{id}) || $url =~ m{/channel/UC}) {
			push @out, {
				type  => 'channel',
				id    => $e->{channel_id} || $e->{id},
				title => $e->{title} || $e->{channel},
				thumb => _bestThumb($e->{thumbnails}),
			};
		}
		elsif ($url =~ m{[?&]list=} || ($e->{ie_key} || '') eq 'YoutubeTab') {
			push @out, {
				type    => 'playlist',
				id      => $e->{id},
				title   => $e->{title},
				channel => $e->{channel} || $e->{uploader},
				count   => $e->{playlist_count},
				thumb   => _bestThumb($e->{thumbnails}),
			};
		}
		elsif (isVideoId($e->{id})) {
			next if ($e->{live_status} || '') =~ /^(?:is_upcoming|post_live)$/;
			push @out, {
				type       => 'video',
				id         => $e->{id},
				title      => $e->{title},
				duration   => $e->{duration},
				channel    => $e->{channel} || $e->{uploader} || $data->{channel},
				channel_id => $e->{channel_id} || $data->{channel_id},
				live       => ($e->{live_status} || '') eq 'is_live' ? 1 : 0,
			};
		}
	}
	return \@out;
}

sub _xmlText {
	my $s = shift // return;
	$s =~ s/&lt;/</g; $s =~ s/&gt;/>/g; $s =~ s/&quot;/"/g; $s =~ s/&#39;|&apos;/'/g; $s =~ s/&amp;/&/g;
	return $s;
}

# Channel RSS feed (youtube.com/feeds/videos.xml) -> videos, newest first
sub parseRss {
	my $xml = shift // return [];
	my ($channel) = $xml =~ m{<author>\s*<name>(.*?)</name>}s;
	my @out;
	while ($xml =~ m{<entry>(.*?)</entry>}sg) {
		my $e = $1;
		my ($id) = $e =~ m{<yt:videoId>([A-Za-z0-9_-]{11})</yt:videoId>} or next;
		my ($title) = $e =~ m{<title>(.*?)</title>}s;
		my ($published) = $e =~ m{<published>([^<]+)</published>};
		my ($cid) = $e =~ m{<yt:channelId>([^<]+)</yt:channelId>};
		my ($author) = $e =~ m{<author>\s*<name>(.*?)</name>}s;
		push @out, {
			type       => 'video',
			id         => $id,
			title      => _xmlText($title),
			published  => $published,
			channel    => _xmlText($author // $channel),
			channel_id => $cid,
		};
	}
	return \@out;
}

# Which yt-dlp release asset runs on this machine ($^O, $Config{archname}, musl?)
sub assetFor {
	my ($os, $arch, $musl) = @_;
	$arch //= '';
	return 'yt-dlp_macos' if $os eq 'darwin';
	return ($arch =~ /x64|x86_64|amd64/i ? 'yt-dlp.exe' : 'yt-dlp_x86.exe') if $os eq 'MSWin32';
	return unless $os eq 'linux';
	return $musl ? 'yt-dlp_musllinux' : 'yt-dlp_linux' if $arch =~ /^(?:x86_64|amd64)/;
	return $musl ? 'yt-dlp_musllinux_aarch64' : 'yt-dlp_linux_aarch64' if $arch =~ /^aarch64/;
	return 'yt-dlp_linux_armv7l' if $arch =~ /^arm/ && !$musl;
	return;
}

1;
