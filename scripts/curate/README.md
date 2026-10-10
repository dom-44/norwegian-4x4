# Curated song lists

`high-intensity.txt` holds hand-picked interval songs (`genre|artist|title`).
`verify.ps1` resolves each line to a Spotify track ID via ReccoBeats search and
adds tempo / energy:

    pwsh scripts/curate/verify.ps1 -In scripts/curate/high-intensity.txt -Out result.csv

Keep rows with energy >= 0.75 and a driving tempo (>= 120 BPM, or half-time
that doubles to 150–215), drop wrong matches (check the `found` column), then
regenerate `Packages/FourByFourCore/Sources/FourByFourCore/CuratedCatalog+Data.swift`
from the kept rows.
