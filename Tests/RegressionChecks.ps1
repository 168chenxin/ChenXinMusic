$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$auth = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Beans/QQMusicAuth.swift')
$web = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Beans/QQWebLoginSheet.swift')
$lx = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Beans/LxScriptRuntime.swift')
$service = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Beans/UnblockService.swift')
$model = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Beans/UnblockSourceStore.swift')
$import = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Beans/ThirdPartySourceImportSheet.swift')
$soda = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Beans/SodaAuth.swift')
$sodaLogin = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Beans/SodaLoginSheet.swift')
$project = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'project.yml')
$update = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Beans/UpdateChecker.swift')
$profile = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Beans/ProfileView.swift')
$discover = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Beans/DiscoverView.swift')
$readme = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'README.md')
$features = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'FEATURES.md')
$appIcon = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'Beans/Assets.xcassets/AppIcon.appiconset/Contents.json')

if ($auth -notmatch 'normalizeLoginCookies') { throw 'QQ cookie normalization regression' }
if ($auth -notmatch 'wxrefresh_token') { throw 'WeChat QQ credential regression' }
if ($auth -notmatch '(?s)for key in \["musicid", "pt2gguin", "pt4gguin", "qqmusic_uin", "p_uin"') { throw 'QQ p_uin identity fallback regression' }
if ($web -notmatch 'normalizeLoginCookies') { throw 'QQ web sync normalization regression' }
if ($lx -notmatch '__beansNativeSend.*name') { throw 'LX send bridge regression' }
if ($lx -notmatch 'setTimeout') { throw 'LX timer bridge regression' }
if ($lx -match '\[weak self, weak callback\]') { throw 'LX timer callback lifetime regression' }
if ($lx -match 'callback\?\.call') { throw 'LX timer callback optional-chain compile regression' }
if ($service -notmatch 'URLQueryItem\(name: "keyword"') { throw 'LX search keyword regression' }
if ($service -notmatch 'replacingOccurrences\(of: "\{songId\}"') { throw 'source placeholder regression' }
if ($service -notmatch 'guard !strict') { throw 'strict source matching regression' }
if ($model -notmatch 'case id, name, title, kind, type') { throw 'source alias decoding regression' }
if ($model -notmatch 'FlexibleString') { throw 'numeric header decoding regression' }
if ($import -notmatch 'sources.*data.*list') { throw 'source wrapper decoding regression' }

$sodaPlaylist = [regex]::Match($soda, '(?s)func fetchPlaylists\(\) async throws -> \[Playlist\] \{.*?\n    private func appendPlaylist').Value
if ($soda -notmatch '(?s)func verifyLogin\(\) async -> String\? \{.*try await fetchProfile\(\).*fetchPlaylists') { throw 'Soda login verification regression' }
if ($sodaPlaylist -match 'try\?\s+await getPc') { throw 'Soda playlist request error propagation regression' }
if ($sodaPlaylist -notmatch 'try await getPc\("/luna/pc/me/playlist"') { throw 'Soda created playlist sync regression' }
if ($soda -notmatch 'guard let importedSessionID = Self\.extractSessionID\(from: cleaned\) else \{ return false \}') { throw 'Soda cookie sessionid validation regression' }
if ($soda -notmatch 'vipBadge = isVIP \? "VIP" : nil') { throw 'Soda stale VIP state regression' }
if ($sodaLogin -notmatch 'guard SodaAuth\.shared\.importCookieHeader\(raw\) else') { throw 'Soda manual cookie login validation regression' }
if ($import -notmatch '(?s)let \(data, response\).*?LxScriptRuntime\.looksLikeLxScript\(text\).*?finishImport\(text\)') { throw 'Soda URL LX script import regression' }

$brand = -join ([char[]](0x79F0, 0x5FC3, 0x64AD, 0x653E, 0x5668))
$sodaName = -join ([char[]](0x6C7D, 0x6C34, 0x97F3, 0x4E50))
$neteaseName = -join ([char[]](0x7F51, 0x6613, 0x4E91))
$kugouName = -join ([char[]](0x9177, 0x72D7))
$groupName = -join ([char[]](0x4EA4, 0x6D41, 0x7FA4))

if ($project -notmatch 'MARKETING_VERSION:\s*"1\.0\.0"') { throw 'Release version regression' }
if (-not $project.Contains($brand)) { throw 'App display name regression' }
if ($update -notmatch 'static let repoPath = "168chenxin/ChenXinMusic"') { throw 'Update repository regression' }
if (-not $profile.Contains($brand)) { throw 'Profile brand regression' }
if (-not $profile.Contains($sodaName)) { throw 'Profile soda documentation regression' }
if ($profile -match 'CommunityQRSheet|Telegram' -or $profile.Contains($groupName)) { throw 'Community entry removal regression' }
if ($discover -notmatch 'case \.soda:') { throw 'Discover soda branch regression' }
if ($discover -notmatch 'SodaAuth\.shared\.searchSongs') { throw 'Discover soda content regression' }
if (-not ($readme.Contains($neteaseName) -and $readme.Contains('QQ') -and $readme.Contains($kugouName) -and $readme.Contains($sodaName))) { throw 'README platform documentation regression' }
if (-not ($features.Contains($neteaseName) -and $features.Contains('QQ') -and $features.Contains($kugouName) -and $features.Contains($sodaName))) { throw 'Feature platform documentation regression' }
if ($appIcon -notmatch '"idiom"\s*:\s*"ios-marketing"' -or $appIcon -notmatch '"size"\s*:\s*"1024x1024"') { throw 'AppIcon metadata regression' }

foreach ($asset in @(
    'Beans/Assets.xcassets/AppIcon.appiconset/AppIcon.png',
    'Beans/Assets.xcassets/OnboardingLogo.imageset/icon.png',
    'Beans/Assets.xcassets/BrandNetease.imageset/icon.png',
    'Beans/Assets.xcassets/BrandQQ.imageset/icon.png',
    'Beans/Assets.xcassets/BrandKugou.imageset/icon.png',
    'Beans/Assets.xcassets/BrandSoda.imageset/icon.png'
)) {
    $path = Join-Path $root $asset
    if (-not (Test-Path $path) -or (Get-Item $path).Length -eq 0) { throw "Asset regression: $asset" }
}

Write-Output 'Beans regression checks passed.'
