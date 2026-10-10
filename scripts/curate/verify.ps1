param([string]$In, [string]$Out)
# Resolves "genre|artist|title" lines to Spotify track IDs via ReccoBeats
# search, then fetches tempo/energy. Writes a CSV.

function Norm([string]$s) {
    $s = $s.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $s = -join ($s.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
    return ($s -replace '[^a-z0-9]', '')
}
$bad = 'remix|live|instrumental|karaoke|acoustic|cover|tribute|re-?recorded|version|edit\)|demo|mixed|cut\)|sped|slowed|8d'

$rows = @()
foreach ($line in Get-Content $In -Encoding utf8) {
    if ($line -match '^\s*#' -or -not $line.Trim()) { continue }
    $genre, $artist, $title = $line.Split('|')
    $query = ($title -replace '\s*\(.*\)', '').Trim()
    $best = $null; $bestScore = -1
    foreach ($page in 0..1) {
        try {
            $r = Invoke-RestMethod "https://api.reccobeats.com/v1/track/search?searchText=$([uri]::EscapeDataString($query))&size=50&page=$page" -Headers @{Accept='application/json'}
        } catch { Start-Sleep -Milliseconds 800; continue }
        foreach ($t in $r.content) {
            if (-not ($t.artists | Where-Object { (Norm $_.name) -eq (Norm $artist) -or (Norm $_.name).Contains((Norm $artist)) -or (Norm $artist).Contains((Norm $_.name)) })) { continue }
            $nt = Norm $t.trackTitle; $nq = Norm $query
            if (-not $nt.StartsWith($nq)) { continue }
            $score = [int]($t.popularity) + ($(if ($nt -eq $nq) { 30 } else { 0 })) - ($(if ($t.trackTitle -match $bad) { 50 } else { 0 }))
            if ($score -gt $bestScore) { $bestScore = $score; $best = $t }
        }
        if ($best -and $bestScore -ge 30) { break }
        Start-Sleep -Milliseconds 150
    }
    $id = if ($best) { ($best.href -split '/')[-1] } else { '' }
    $rows += [pscustomobject]@{ genre = $genre; artist = $artist; title = $title; found = $(if ($best) { $best.trackTitle } else { '' }); id = $id; tempo = ''; energy = '' }
    Start-Sleep -Milliseconds 150
}

$ids = $rows | Where-Object id | ForEach-Object id | Select-Object -Unique
for ($i = 0; $i -lt $ids.Count; $i += 40) {
    $chunk = $ids[$i..([Math]::Min($i + 39, $ids.Count - 1))] -join ','
    try { $f = Invoke-RestMethod "https://api.reccobeats.com/v1/audio-features?ids=$chunk" -Headers @{Accept='application/json'} } catch { continue }
    foreach ($c in $f.content) {
        $sid = ($c.href -split '/')[-1]
        foreach ($row in $rows | Where-Object { $_.id -eq $sid }) { $row.tempo = [math]::Round($c.tempo, 1); $row.energy = [math]::Round($c.energy, 2) }
    }
}
$rows | Export-Csv $Out -NoTypeInformation -Encoding utf8
