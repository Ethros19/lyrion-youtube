#!/usr/bin/env bash
# Package the plugin as dist/YouTubeDirect-<version>.zip (files at zip root,
# the layout LMS repo installs expect) and regenerate repo.xml to point at it.
# BASE_URL overrides where the zip is downloaded from (default: the GitHub
# release), e.g. BASE_URL=http://192.168.1.50:8765 to serve it over the LAN.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=Ethros19/lyrion-youtube
version=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' src/YouTubeDirect/install.xml)
zip="dist/YouTubeDirect-$version.zip"
base=${BASE_URL:-https://github.com/$REPO/releases/download/v$version}

mkdir -p dist
rm -f "$zip"
(cd src/YouTubeDirect && zip -qr "../../$zip" . -x '*.DS_Store')
sha=$(shasum "$zip" | cut -d' ' -f1)

cat > "${REPO_XML:-repo.xml}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<extensions>
	<details>
		<title lang="EN">YouTube Direct</title>
	</details>
	<plugins>
		<plugin name="YouTubeDirect" version="$version" minTarget="8.0" maxTarget="*">
			<title lang="EN">YouTube Direct</title>
			<desc lang="EN">YouTube audio for Lyrion with SponsorBlock: sponsor reads and the non-music parts of mixes are cut out as you listen. Search, follow channels, playlists, links and chapters. Installs and updates its own yt-dlp (no shell access needed); API key optional. Built for Lyrion 9.0 servers that can't upgrade; works on 8.x and 9.x.</desc>
			<creator>Ethan Rosch</creator>
			<category>musicservices</category>
			<link>https://github.com/$REPO</link>
			<url>$base/YouTubeDirect-$version.zip</url>
			<sha>$sha</sha>
		</plugin>
	</plugins>
</extensions>
XML

echo "$zip ($sha)"
