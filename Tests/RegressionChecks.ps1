$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$auth = Get-Content -Raw (Join-Path $root 'Beans/QQMusicAuth.swift')
$web = Get-Content -Raw (Join-Path $root 'Beans/QQWebLoginSheet.swift')
$lx = Get-Content -Raw (Join-Path $root 'Beans/LxScriptRuntime.swift')
$service = Get-Content -Raw (Join-Path $root 'Beans/UnblockService.swift')
$model = Get-Content -Raw (Join-Path $root 'Beans/UnblockSourceStore.swift')
$import = Get-Content -Raw (Join-Path $root 'Beans/ThirdPartySourceImportSheet.swift')
$soda = Get-Content -Raw (Join-Path $root 'Beans/SodaAuth.swift')
$sodaLogin = Get-Content -Raw (Join-Path $root 'Beans/SodaLoginSheet.swift')

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

Write-Output 'Beans regression checks passed.'
