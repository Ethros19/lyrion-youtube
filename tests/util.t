use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP qw(decode_json);

use Plugins::YouTubeDirect::Util qw(
	videoUrl parseVideoUrl parseLink isVideoId isChannelId uploadsPlaylist thumbnail
	iso8601Duration formatDuration
	topBoxes parseSidx mp4AudioConfig fmp4Samples adtsHeader adtsInfo fragmentAt
	mergeSkips skippedBefore realToVirtual virtualToReal skipAt skipSegments
	normalizeChapters splitArtistTitle trackAt
	flatEntries parseRss assetFor
);

binmode Test::More->builder->$_, ':utf8' for qw(output failure_output todo_output);

sub fixture {
	my $file = "$FindBin::Bin/fixtures/" . shift;
	open my $fh, '<:raw', $file or die "$file: $!";
	local $/;
	return scalar <$fh>;
}

# -- links -------------------------------------------------------------------
{
	is(videoUrl('UhEt8o77fXI'), 'ytdirect://UhEt8o77fXI', 'videoUrl');
	is(parseVideoUrl('ytdirect://UhEt8o77fXI'), 'UhEt8o77fXI', 'parseVideoUrl');
	is(parseVideoUrl('mcdirect://x/y'), undef, 'foreign url');
	ok(isVideoId('aqz-KE-bpKQ'), 'video id');
	ok(!isVideoId('aqz-KE-bpK'), 'short id');
	ok(isChannelId('UCMFz_xS7TI7tBJrgmlmyjLA'), 'channel id');
	is(uploadsPlaylist('UCMFz_xS7TI7tBJrgmlmyjLA'), 'UUMFz_xS7TI7tBJrgmlmyjLA', 'uploads playlist');
	like(thumbnail('aqz-KE-bpKQ'), qr{^https://i\.ytimg\.com/vi/aqz-KE-bpKQ/}, 'thumbnail');

	my %cases = (
		'https://www.youtube.com/watch?v=UhEt8o77fXI'                       => [video => 'UhEt8o77fXI'],
		'https://www.youtube.com/watch?v=UhEt8o77fXI&list=PLabcdefghij&t=30' => [video => 'UhEt8o77fXI'],
		'youtube.com/watch?feature=share&v=UhEt8o77fXI'                     => [video => 'UhEt8o77fXI'],
		'https://youtu.be/UhEt8o77fXI?si=abc'                               => [video => 'UhEt8o77fXI'],
		'https://m.youtube.com/shorts/UhEt8o77fXI'                          => [video => 'UhEt8o77fXI'],
		'https://music.youtube.com/watch?v=UhEt8o77fXI'                     => [video => 'UhEt8o77fXI'],
		'https://www.youtube.com/live/UhEt8o77fXI'                          => [video => 'UhEt8o77fXI'],
		'  UhEt8o77fXI  '                                                   => [video => 'UhEt8o77fXI'],
		'https://www.youtube.com/playlist?list=PLs2_8NKh_-t9YLMSyZBew3b7pVbmJbyzh' => [playlist => 'PLs2_8NKh_-t9YLMSyZBew3b7pVbmJbyzh'],
		'https://www.youtube.com/channel/UCMFz_xS7TI7tBJrgmlmyjLA/videos'   => [channel => 'UCMFz_xS7TI7tBJrgmlmyjLA'],
		'UCMFz_xS7TI7tBJrgmlmyjLA'                                          => [channel => 'UCMFz_xS7TI7tBJrgmlmyjLA'],
	);
	for my $in (sort keys %cases) {
		my $got = parseLink($in) || {};
		is_deeply([ $got->{type}, $got->{id} ], $cases{$in}, "parseLink $in");
	}
	is_deeply(parseLink('https://www.youtube.com/@BlenderOfficial/videos'), { type => 'handle', handle => 'BlenderOfficial' }, 'handle url');
	is_deeply(parseLink('@BlenderOfficial'), { type => 'handle', handle => 'BlenderOfficial' }, 'bare handle');
	is_deeply(parseLink('https://www.youtube.com/c/Blender'), { type => 'url', url => 'https://www.youtube.com/c/Blender' }, '/c/ url');
	is(parseLink('https://www.mixcloud.com/NTSRadio/'), undef, 'not youtube');
	is(parseLink(''), undef, 'empty');
}

# -- durations ---------------------------------------------------------------
{
	is(iso8601Duration('PT1H5M16S'), 3916, 'PT1H5M16S');
	is(iso8601Duration('PT45S'), 45, 'PT45S');
	is(iso8601Duration('P1DT2H'), 93600, 'P1DT2H');
	is(iso8601Duration('P0D'), 0, 'P0D (live)');
	is(iso8601Duration('junk'), undef, 'junk');
	is(formatDuration(3916), '1:05:16', 'h:mm:ss');
	is(formatDuration(65), '1:05', 'm:ss');
	is(formatDuration(0), '', 'zero');
}

# -- fragmented MP4 (Big Buck Bunny, CC-BY Blender Foundation) ---------------
{
	my $init = fixture('bbb-init.mp4');
	my @boxes = map { $_->{type} } topBoxes($init);
	is_deeply(\@boxes, [qw(ftyp moov sidx)], 'init boxes');

	my $config = mp4AudioConfig($init);
	is($config->{object}, 2, 'AAC LC');
	is($config->{samplerate}, 44100, '44.1 kHz');
	is($config->{channels}, 2, 'stereo');

	my $index = parseSidx($init);
	ok($index && $index->{fragments}, 'sidx parsed');
	is($index->{end}, 1523, 'media starts after sidx');
	my $f = $index->{fragments};
	is($f->[0]{offset}, 1523, 'first fragment offset');
	is($f->[0]{size}, 161972, 'first fragment size');
	is($f->[0]{start}, 0, 'first fragment start');
	is($f->[1]{offset}, 1523 + 161972, 'second fragment follows');
	cmp_ok(abs($index->{duration} - 635), '<', 1, 'total ~ 635 s');
	ok(!(grep { $_->{size} > 524288 } @$f), 'every fragment fits one range request');
	is(fragmentAt($f, 0), 0, 'fragmentAt 0');
	is(fragmentAt($f, $f->[3]{start} + 0.5), 3, 'fragmentAt mid');
	is(fragmentAt($f, 99999), $#$f, 'fragmentAt past end');

	is_deeply(parseSidx(substr($init, 0, 1000)), { need => 1523 }, 'truncated sidx asks for more');
	is(parseSidx(substr($init, 0, 723)), undef, 'no sidx');

	my @samples = fmp4Samples(fixture('bbb-fragment.m4s'));
	cmp_ok(scalar @samples, '>', 400, 'samples from fragment');
	my $frame = adtsHeader($config, length $samples[0]) . $samples[0];
	my $info = adtsInfo($frame);
	is($info->{length}, length $frame, 'ADTS length');
	is($info->{samplerate}, 44100, 'ADTS rate');
	is($info->{channels}, 2, 'ADTS channels');
	my $secs = @samples * 1024 / 44100;
	cmp_ok(abs($secs - $f->[0]{duration}), '<', 0.05, 'samples cover the fragment duration');

	my $he = { %$config, object => 5 };
	is((unpack('C3', adtsHeader($he, 100)))[2] >> 6, 1, 'HE-AAC signalled as LC');
}

# -- skip timeline -------------------------------------------------------------
{
	my $sb = decode_json(fixture('sponsorblock.json'));
	my $all = skipSegments($sb);
	is(scalar @$all, scalar @$sb, 'all segments');
	my $sponsor = skipSegments($sb, ['sponsor']);
	ok(@$sponsor && @$sponsor < @$all, 'category filter');
	is_deeply(skipSegments([{ category => 'sponsor', actionType => 'mute', segment => [1, 2] }], ['sponsor']), [], 'mute segments ignored');
	is_deeply(skipSegments(undef), [], 'no data');

	my $skips = mergeSkips([[50, 60], [10, 20], [15, 25], [100, 100.5], [-5, 2], [590, 700]], 600);
	is_deeply($skips, [[0, 2], [10, 25], [50, 60], [590, 600]], 'merge, clamp, drop slivers');

	is(skippedBefore($skips, 30), 17, 'skipped before 30');
	is(skippedBefore($skips, 12), 4, 'skipped before 12 (inside)');
	is(realToVirtual($skips, 30), 13, 'real 30 -> virtual 13');
	is(realToVirtual($skips, 600), 600 - 37, 'virtual duration');
	is(virtualToReal($skips, 0), 2, 'virtual 0 -> after the intro skip');
	is(virtualToReal($skips, 13), 30, 'virtual 13 -> real 30');
	is(virtualToReal($skips, 8), 25, 'virtual boundary -> end of skip');
	for my $v (0, 5, 13, 40, 200, 563) {
		my $r = virtualToReal($skips, $v);
		is(realToVirtual($skips, $r), $v, "round trip $v");
		ok(!skipAt($skips, $r), "virtual $v never lands in a skip");
	}
	is_deeply(skipAt($skips, 55), [50, 60], 'skipAt inside');
	is(skipAt($skips, 60), undef, 'skipAt end is exclusive');
	is(virtualToReal([], 42), 42, 'no skips');
}

# -- chapters ------------------------------------------------------------------
{
	is_deeply([ splitArtistTitle('Bicep - Glue') ], ['Bicep', 'Glue'], 'artist - title');
	is_deeply([ splitArtistTitle('03. Bicep – Glue (Extended)') ], ['Bicep', 'Glue (Extended)'], 'numbered, en dash');
	is_deeply([ splitArtistTitle('Intro') ], [undef, 'Intro'], 'no artist');

	my $chapters = normalizeChapters([
		{ start_time => 300, end_time => 600, title => 'Bicep - Glue' },
		{ start_time => 0, end_time => 300, title => 'Intro' },
	]);
	is_deeply($chapters, [{ start => 0, title => 'Intro' }, { start => 300, title => 'Glue', artist => 'Bicep' }], 'sorted, split');
	is_deeply(normalizeChapters([{ start_time => 0, end_time => 600, title => '<Untitled Chapter 1>' }]), [], 'placeholder chapter dropped');
	is(trackAt($chapters, 450)->{title}, 'Glue', 'trackAt');
}

# -- listings ------------------------------------------------------------------
{
	my $videos = flatEntries(decode_json(fixture('flat-search.json')));
	is(scalar @$videos, 3, 'search entries');
	is($videos->[0]{type}, 'video', 'video type');
	ok(isVideoId($videos->[0]{id}), 'video id');
	ok($videos->[0]{duration} > 0, 'video duration');
	ok($videos->[0]{channel} && isChannelId($videos->[0]{channel_id}), 'video channel');

	my $channels = flatEntries(decode_json(fixture('flat-channels.json')));
	is($channels->[0]{type}, 'channel', 'channel type');
	ok(isChannelId($channels->[0]{id}), 'channel id');
	like($channels->[0]{thumb} || '', qr{^https://}, 'channel thumb');

	my $playlists = flatEntries(decode_json(fixture('flat-playlists.json')));
	is($playlists->[0]{type}, 'playlist', 'playlist type');
	like($playlists->[0]{id}, qr/^PL/, 'playlist id');

	my $uploads = flatEntries(decode_json(fixture('flat-uploads.json')));
	is($uploads->[0]{type}, 'video', 'upload type');
	ok($uploads->[0]{channel}, 'uploads inherit the channel name');

	my $rss = parseRss(fixture('rss.xml'));
	is(scalar @$rss, 15, 'rss entries');
	ok(isVideoId($rss->[0]{id}), 'rss video id');
	is($rss->[0]{channel}, 'Blender', 'rss channel');
	like($rss->[0]{published}, qr/^\d{4}-\d\d-\d\dT/, 'rss published');
	ok(isChannelId($rss->[0]{channel_id}), 'rss channel id');
	is_deeply(parseRss('<feed></feed>'), [], 'empty feed');
	my $accented = parseRss("<feed><entry><yt:videoId>aqz-KE-bpKQ</yt:videoId><title>Beyonc\x{e9} &amp; Jay \x{2013} Live</title></entry></feed>");
	is($accented->[0]{title}, "Beyonc\x{e9} & Jay \x{2013} Live", 'decoded titles keep accents and entities');
}

# -- yt-dlp assets ---------------------------------------------------------------
{
	is(assetFor('linux', 'x86_64-linux-thread-multi'), 'yt-dlp_linux', 'linux x86_64');
	is(assetFor('linux', 'x86_64-linux-thread-multi', 1), 'yt-dlp_musllinux', 'musl x86_64');
	is(assetFor('linux', 'aarch64-linux-gnu-thread-multi'), 'yt-dlp_linux_aarch64', 'linux arm64');
	is(assetFor('linux', 'arm-linux-gnueabihf-thread-multi-64int'), 'yt-dlp_linux_armv7l', 'linux armhf');
	is(assetFor('darwin', 'darwin-thread-multi-2level'), 'yt-dlp_macos', 'macOS');
	is(assetFor('MSWin32', 'MSWin32-x64-multi-thread'), 'yt-dlp.exe', 'Windows x64');
	is(assetFor('freebsd', 'amd64-freebsd'), undef, 'FreeBSD: no binary');
}

done_testing;
