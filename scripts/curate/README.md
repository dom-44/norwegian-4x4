# Researched song lists

Hand-picked songs per phase (`genre|artist|title`):

- `high-intensity.txt`: intervals
- `moderate.txt`: warm-up and recovery
- `calm.txt`: cool-down

1. Check a list. `verify.ps1` resolves each line to a Spotify track ID via
   ReccoBeats search (exact artist only) and adds tempo / energy:

       pwsh scripts/curate/verify.ps1 -In scripts/curate/moderate.txt -Out scripts/curate/checked-moderate.csv

   Run the lists one after another; in parallel ReccoBeats rate-limits.
2. Look at the `found` column for wrong versions (remixes, re-recordings) and
   pass them to the generator as `-Exclude "genre|title"`.
3. Generate `Packages/FourByFourCore/Sources/FourByFourCore/CuratedCatalog+Data.swift`:

       pwsh scripts/curate/generate.ps1 -HighCsv scripts/curate/checked-high-intensity.csv `
           -ModerateCsv scripts/curate/checked-moderate.csv -CalmCsv scripts/curate/checked-calm.csv `
           -Exclude "hardrock|Seven Nation Army","hardrock|The Final Countdown"

   The energy rules per phase are at the top of `generate.ps1`. A genre with
   fewer than 5 songs in a phase is left out for that phase.
