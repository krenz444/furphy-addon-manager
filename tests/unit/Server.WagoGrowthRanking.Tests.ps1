<#
  Unit tests (Pester 3 syntax): addon-server.ps1's Get-WagoGrowthRanking -
  the entire "Gaining this week" ranking algorithm (WAGO-BROWSE-SPEC.md
  section 4.6). Pure function: every test constructs a snapshot-file object
  in memory and passes it directly - no disk, no network, no dependency on
  wall-clock "now" (every fixture below uses a fixed reference date so
  results are fully deterministic).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

$Script:FixedNowUtc = [DateTime]::Parse('2026-09-06T00:00:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)

function New-WagoSnapshotItem {
    param([string]$Slug, [int64]$Downloads, [string]$Name, $Rank = $null)
    return [PSCustomObject]@{ slug = $Slug; name = $(if ($Name) { $Name } else { $Slug }); thumbnail = $null; downloads = $Downloads; rank = $Rank }
}

function New-WagoSnapshotEntry {
    param([DateTime]$CapturedAt, [object[]]$Items)
    return [PSCustomObject]@{
        capturedAt = $CapturedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
        items      = @($Items)
    }
}

function New-WagoSnapshotFile {
    param([DateTime]$FirstCapturedAt, [object[]]$Snapshots)
    return [PSCustomObject]@{
        gameVersion     = 'retail'
        firstCapturedAt = $FirstCapturedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
        snapshots       = @($Snapshots)
    }
}

Describe 'Get-WagoGrowthRanking' {

    It 'case 1: exact ordering - qualifying (strictly positive-delta) addons ranked delta-descending; flat/declining/new-entrant addons excluded' {
        $baselineAt = $Script:FixedNowUtc.AddDays(-7)
        $baseline = New-WagoSnapshotEntry -CapturedAt $baselineAt -Items @(
            (New-WagoSnapshotItem -Slug 'addonA' -Downloads 1000)
            (New-WagoSnapshotItem -Slug 'addonB' -Downloads 500)
            (New-WagoSnapshotItem -Slug 'addonC' -Downloads 2000)
            (New-WagoSnapshotItem -Slug 'addonD' -Downloads 300)   # will be FLAT
            (New-WagoSnapshotItem -Slug 'addonE' -Downloads 900)   # will DECLINE
        )
        $latest = New-WagoSnapshotEntry -CapturedAt $Script:FixedNowUtc -Items @(
            (New-WagoSnapshotItem -Slug 'addonA' -Downloads 1500)   # +500
            (New-WagoSnapshotItem -Slug 'addonB' -Downloads 800)    # +300
            (New-WagoSnapshotItem -Slug 'addonC' -Downloads 2100)   # +100
            (New-WagoSnapshotItem -Slug 'addonD' -Downloads 300)    # +0, excluded
            (New-WagoSnapshotItem -Slug 'addonE' -Downloads 850)    # -50, excluded
            (New-WagoSnapshotItem -Slug 'addonF' -Downloads 5000)   # not in baseline, excluded
        )
        $file = New-WagoSnapshotFile -FirstCapturedAt $baselineAt -Snapshots @($baseline, $latest)

        $r = Get-WagoGrowthRanking -SnapshotData $file -NowUtc $Script:FixedNowUtc
        $r.ready | Should Be $true
        $r.items.Count | Should Be 3
        (($r.items | ForEach-Object { $_.slug }) -join ',') | Should Be 'addonA,addonB,addonC'
        $r.items[0].deltaDownloads | Should Be 500
        $r.items[1].deltaDownloads | Should Be 300
        $r.items[2].deltaDownloads | Should Be 100
        $r.snapshotCount | Should Be 2
    }

    It 'case 2: the baseline window is inclusive at BOTH the 5-day and 9-day edges, and an exact tie is broken toward the OLDER candidate' {
        $exactly5d = $Script:FixedNowUtc.AddDays(-5)   # in-window, distance-from-target(7d) = 2
        $exactly9d = $Script:FixedNowUtc.AddDays(-9)   # in-window, distance-from-target(7d) = 2 (TIE with exactly5d)
        $tooRecent = $Script:FixedNowUtc.AddDays(-4.5) # just outside the window (< 5d back)
        $tooOld    = $Script:FixedNowUtc.AddDays(-10)  # just outside the window (> 9d back)

        $latest = New-WagoSnapshotEntry -CapturedAt $Script:FixedNowUtc -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 200))
        $snapshots = @(
            (New-WagoSnapshotEntry -CapturedAt $exactly5d -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 150)))
            (New-WagoSnapshotEntry -CapturedAt $exactly9d -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 100)))
            (New-WagoSnapshotEntry -CapturedAt $tooRecent -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 190)))
            (New-WagoSnapshotEntry -CapturedAt $tooOld -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 10)))
            $latest
        )
        $file = New-WagoSnapshotFile -FirstCapturedAt $tooOld -Snapshots $snapshots

        $r = Get-WagoGrowthRanking -SnapshotData $file -NowUtc $Script:FixedNowUtc
        $r.ready | Should Be $true
        # The tie is broken toward the OLDER candidate (exactly9d, downloads
        # 100) - NOT exactly5d (150) and NOT the out-of-window tooRecent/
        # tooOld entries, even though tooRecent (190) is numerically closer
        # to latest's own value.
        $r.baselineAsOf | Should Be $exactly9d.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $r.items[0].deltaDownloads | Should Be 100   # 200 - 100 (against exactly9d), not 50 (against exactly5d)
    }

    It 'case 3: a non-tied window pick chooses whichever candidate is numerically closest to 7 days back' {
        $closer = $Script:FixedNowUtc.AddDays(-6.5)   # distance 0.5 from the 7-day target
        $farther = $Script:FixedNowUtc.AddDays(-7.8)  # distance 0.8 from the 7-day target

        $latest = New-WagoSnapshotEntry -CapturedAt $Script:FixedNowUtc -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 500))
        $snapshots = @(
            (New-WagoSnapshotEntry -CapturedAt $closer -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 300)))
            (New-WagoSnapshotEntry -CapturedAt $farther -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 100)))
            $latest
        )
        $file = New-WagoSnapshotFile -FirstCapturedAt $farther -Snapshots $snapshots

        $r = Get-WagoGrowthRanking -SnapshotData $file -NowUtc $Script:FixedNowUtc
        $r.baselineAsOf | Should Be $closer.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $r.items[0].deltaDownloads | Should Be 200   # 500 - 300 (against the closer candidate)
    }

    It 'case 4: item-sort tie-break is delta descending, then downloads descending, then slug ascending' {
        $baselineAt = $Script:FixedNowUtc.AddDays(-7)
        $baseline = New-WagoSnapshotEntry -CapturedAt $baselineAt -Items @(
            (New-WagoSnapshotItem -Slug 'a' -Downloads 100)
            (New-WagoSnapshotItem -Slug 'b' -Downloads 200)
            (New-WagoSnapshotItem -Slug 'c' -Downloads 100)
            (New-WagoSnapshotItem -Slug 'd' -Downloads 100)
        )
        $latest = New-WagoSnapshotEntry -CapturedAt $Script:FixedNowUtc -Items @(
            (New-WagoSnapshotItem -Slug 'a' -Downloads 300)   # delta 200, downloads 300
            (New-WagoSnapshotItem -Slug 'b' -Downloads 400)   # delta 200, downloads 400 - SAME delta as a, higher downloads
            (New-WagoSnapshotItem -Slug 'c' -Downloads 250)   # delta 150, downloads 250
            (New-WagoSnapshotItem -Slug 'd' -Downloads 250)   # delta 150, downloads 250 - SAME delta+downloads as c, slug tie-break
        )
        $file = New-WagoSnapshotFile -FirstCapturedAt $baselineAt -Snapshots @($baseline, $latest)

        $r = Get-WagoGrowthRanking -SnapshotData $file -NowUtc $Script:FixedNowUtc
        (($r.items | ForEach-Object { $_.slug }) -join ',') | Should Be 'b,a,c,d'
    }

    It 'case 5: an intra-snapshot duplicate slug is de-duplicated (first occurrence wins) on BOTH baseline and latest sides' {
        $baselineAt = $Script:FixedNowUtc.AddDays(-7)
        $baseline = New-WagoSnapshotEntry -CapturedAt $baselineAt -Items @(
            (New-WagoSnapshotItem -Slug 'x' -Downloads 100)
            (New-WagoSnapshotItem -Slug 'x' -Downloads 999)   # duplicate slug, later occurrence - ignored
            (New-WagoSnapshotItem -Slug 'y' -Downloads 50)
        )
        $latest = New-WagoSnapshotEntry -CapturedAt $Script:FixedNowUtc -Items @(
            (New-WagoSnapshotItem -Slug 'x' -Downloads 500)   # first occurrence - used
            (New-WagoSnapshotItem -Slug 'x' -Downloads 111)   # duplicate slug, later occurrence - ignored
            (New-WagoSnapshotItem -Slug 'y' -Downloads 80)
        )
        $file = New-WagoSnapshotFile -FirstCapturedAt $baselineAt -Snapshots @($baseline, $latest)

        $r = Get-WagoGrowthRanking -SnapshotData $file -NowUtc $Script:FixedNowUtc
        $r.items.Count | Should Be 2
        $x = $r.items | Where-Object { $_.slug -eq 'x' }
        $x.deltaDownloads | Should Be 400   # 500 - 100 (first occurrence on both sides), NOT 111-999 or any other combination
        $y = $r.items | Where-Object { $_.slug -eq 'y' }
        $y.deltaDownloads | Should Be 30
    }

    It 'case 6: a single existing snapshot is not ready (no baseline candidate can exist), but since/snapshotCount reflect the real data' {
        $onlyAt = $Script:FixedNowUtc
        $file = New-WagoSnapshotFile -FirstCapturedAt $onlyAt -Snapshots @(
            (New-WagoSnapshotEntry -CapturedAt $onlyAt -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 100)))
        )

        $r = Get-WagoGrowthRanking -SnapshotData $file -NowUtc $Script:FixedNowUtc
        $r.ready | Should Be $false
        $r.since | Should Be $onlyAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $r.asOf | Should Be $null
        $r.baselineAsOf | Should Be $null
        $r.snapshotCount | Should Be 1
        $r.items.Count | Should Be 0
    }

    It 'case 7: a $null SnapshotData (missing/corrupt/unreadable file) is not ready, snapshotCount 0, since $null' {
        $r = Get-WagoGrowthRanking -SnapshotData $null -NowUtc $Script:FixedNowUtc
        $r.ready | Should Be $false
        $r.since | Should Be $null
        $r.asOf | Should Be $null
        $r.baselineAsOf | Should Be $null
        $r.snapshotCount | Should Be 0
        $r.items.Count | Should Be 0
    }

    It 'case 7b: an empty snapshots array is treated identically to a missing file' {
        $file = New-WagoSnapshotFile -FirstCapturedAt $Script:FixedNowUtc -Snapshots @()
        $r = Get-WagoGrowthRanking -SnapshotData $file -NowUtc $Script:FixedNowUtc
        $r.ready | Should Be $false
        $r.snapshotCount | Should Be 0
    }

    It 'case 8: real data exists but no snapshot falls in the [5d,9d] window - NOT ready, but since/snapshotCount are populated from the real data, not zeroed' {
        $tooRecent = $Script:FixedNowUtc.AddDays(-2)
        $file = New-WagoSnapshotFile -FirstCapturedAt $tooRecent -Snapshots @(
            (New-WagoSnapshotEntry -CapturedAt $tooRecent -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 100)))
            (New-WagoSnapshotEntry -CapturedAt $Script:FixedNowUtc -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 150)))
        )

        $r = Get-WagoGrowthRanking -SnapshotData $file -NowUtc $Script:FixedNowUtc
        $r.ready | Should Be $false
        $r.since | Should Be $tooRecent.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $r.asOf | Should Be $null
        $r.baselineAsOf | Should Be $null
        # snapshotCount reflects the REAL entry count (2), proving this is
        # not conflated with the "zero snapshots" not-ready path.
        $r.snapshotCount | Should Be 2
    }

    It 'an entry with an unparseable capturedAt is dropped from ranking consideration but still counted in snapshotCount (never aborts the whole computation)' {
        $baselineAt = $Script:FixedNowUtc.AddDays(-7)
        $baseline = New-WagoSnapshotEntry -CapturedAt $baselineAt -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 100))
        $latest = New-WagoSnapshotEntry -CapturedAt $Script:FixedNowUtc -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 300))
        $corrupt = [PSCustomObject]@{ capturedAt = 'not-a-real-timestamp'; items = @((New-WagoSnapshotItem -Slug 'x' -Downloads 9999)) }
        $file = New-WagoSnapshotFile -FirstCapturedAt $baselineAt -Snapshots @($baseline, $corrupt, $latest)

        { Get-WagoGrowthRanking -SnapshotData $file -NowUtc $Script:FixedNowUtc } | Should Not Throw
        $r = Get-WagoGrowthRanking -SnapshotData $file -NowUtc $Script:FixedNowUtc
        $r.ready | Should Be $true
        $r.snapshotCount | Should Be 3   # raw file entry count, including the corrupt one
        $r.items[0].deltaDownloads | Should Be 200   # 300 - 100, the corrupt entry never enters the math
    }

    It 'zero addons flagged as gaining is a valid ready:true result with an empty items array, not a not-ready state' {
        $baselineAt = $Script:FixedNowUtc.AddDays(-7)
        $baseline = New-WagoSnapshotEntry -CapturedAt $baselineAt -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 500))
        $latest = New-WagoSnapshotEntry -CapturedAt $Script:FixedNowUtc -Items @((New-WagoSnapshotItem -Slug 'x' -Downloads 500))   # flat
        $file = New-WagoSnapshotFile -FirstCapturedAt $baselineAt -Snapshots @($baseline, $latest)

        $r = Get-WagoGrowthRanking -SnapshotData $file -NowUtc $Script:FixedNowUtc
        $r.ready | Should Be $true
        $r.items.Count | Should Be 0
    }
}
