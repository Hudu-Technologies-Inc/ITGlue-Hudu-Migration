#requires -Version 7.2
# Run the main script's wrap-up orchestration with offline phase/API doubles.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$checks = 0
function Assert-LinkOrchestration {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}

$helperNames = @('Invoke-InitialLinkReplacements.ps1', 'Invoke-LinkReplacement.ps1', 'Invoke-ArticleContentCommit.ps1', 'Invoke-AssetRichTextLinkReplacement.ps1')
foreach ($name in $helperNames) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot "Public/Jobs/$name"), [ref]$tokens, [ref]$errors)
    Assert-LinkOrchestration ($errors.Count -eq 0) "$name did not parse."
    $trackers = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Start-MigrationJob', 'Complete-MigrationJob')
    }, $true))
    Assert-LinkOrchestration ($trackers.Count -eq 0) "$name still owns migration job tracking."
}
$mainSource = Get-Content -LiteralPath "$repoRoot/ITGlue-Hudu-Migration.ps1" -Raw
$start = $mainSource.IndexOf('############################### Wrap-Up ###############################')
$end = $mainSource.IndexOf('write-host "wrapup 3/10...', $start)
Assert-LinkOrchestration ($start -ge 0 -and $end -gt $start) 'Could not locate the main wrap-up orchestration.'
$wrapUp = [scriptblock]::Create($mainSource.Substring($start, $end - $start).Replace('$PSScriptRoot', '$fixtureRoot'))
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "itglue-link-orchestration-$([guid]::NewGuid().ToString('N'))"
try {
    $null = [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'Public/Jobs'))
    $MigrationLogs = Join-Path $fixtureRoot 'logs'
    $null = [IO.Directory]::CreateDirectory($MigrationLogs)
    $phaseScripts = @{
        'Public/Jobs/Invoke-InitialLinkReplacements.ps1' = 'Add-PhaseEvent Initial'
        'Add-HuduAttachmentsViaAPI.ps1' = 'Add-PhaseEvent Attachments'
        'Public/Jobs/Invoke-LinkReplacement.ps1' = @'
Add-PhaseEvent ArticleStage
$AttachmentUrlMapForReplacement = @{ source = 'target' }
$AttachmentUrlLookupForReplacement = @{ source = @{ ReplacementUrl = 'target' } }
'@
        'Public/Jobs/Invoke-ArticleContentCommit.ps1' = @'
Add-PhaseEvent ArticleCommit
if ($failCommit) { throw 'simulated commit failure' }
'@
        'Public/Jobs/Invoke-AssetRichTextLinkReplacement.ps1' = @'
param($AttachmentUrlMapForReplacement, $AttachmentUrlLookupForReplacement)
Add-PhaseEvent AssetLinks
Assert-LinkOrchestration ($AttachmentUrlMapForReplacement.source -eq 'target' -and $AttachmentUrlLookupForReplacement.source.ReplacementUrl -eq 'target') 'Asset replacement did not receive the prepared attachment maps.'
'@
        'Public/Set-HuduImageAnchorsReplaced.ps1' = 'function Set-HuduImageAnchorsReplaced {}'
    }
    foreach ($path in $phaseScripts.Keys) { [IO.File]::WriteAllText((Join-Path $fixtureRoot $path), $phaseScripts[$path]) }

    foreach ($failCommit in @($false, $true)) {
        & {
            $script:JobStartTime = @{}
            $script:MigrationJobTimeline = [Collections.ArrayList]::new()
            . "$repoRoot/Public/Timed-Job.ps1"
            $events = [Collections.Generic.List[object]]::new()
            function Add-PhaseEvent {
                param($Phase)
                $events.Add(@{ Phase = $Phase; Job = $script:MigrationJobTimeline[-1].Job })
            }
            function Get-HuduAssetLayouts { @{ id = 1 } }
            function Set-HuduAssetLayout {
                param($Id, $Active)
                Assert-LinkOrchestration ($Id -eq 1 -and $Active) 'Layout activation arguments changed.'
                Add-PhaseEvent Layouts
                @{ asset_layout = @{ name = 'layout' } }
            }
            function Set-HuduWebsite {
                param($Id, $EnableDMARC, $EnableDKIM, $EnableSPF, $DisableDNS, $DisableSSL, $DisableWhois, $Paused)
                Assert-LinkOrchestration ($Id -eq 2 -and $EnableDMARC -eq 'true' -and $EnableDKIM -eq 'true' -and $EnableSPF -eq 'true' -and $DisableDNS -eq 'false' -and $DisableSSL -eq 'false' -and $DisableWhois -eq 'false' -and $Paused -eq 'false') 'Website monitoring arguments changed.'
                Add-PhaseEvent Websites
                @{ name = 'website' }
            }
            function Write-TimedMessage { param($Timeout, $Message, $DefaultResponse) }
            $DisableWebsiteMonitoring = $failCommit
            $MatchedWebsites = @(@{ HuduObject = @{ id = 2 } })
            $ManualActions = @(@{ Type = 'offline test' })
            # Deliberately leave LinkReplacementJobPublicRoot/ProjectRoot unset:
            # orchestration must resolve paths without the initial helper.
            try {
                . $wrapUp 6>$null
                Assert-LinkOrchestration (-not $failCommit) 'The injected commit failure was swallowed.'
            } catch {
                Assert-LinkOrchestration ($failCommit -and $_.Exception.Message -eq 'simulated commit failure') "Unexpected orchestration failure: $($_.Exception.Message)"
            }
            $expectedJobs = @('Wrap-Up - Layouts', 'LinkReplacement', 'Wrap-Up - Attachments', 'Wrap-Up - Article Link Replacement', 'Wrap-Up - Article Content Commit')
            if (-not $failCommit) { $expectedJobs += 'Wrap-Up - Asset Link Replacement' }
            Assert-LinkOrchestration (($script:MigrationJobTimeline.Job -join '|') -ceq ($expectedJobs -join '|')) 'Main job tracking has missing, duplicated, or reordered phases.'
            Assert-LinkOrchestration (@($script:MigrationJobTimeline | Where-Object { $null -eq $_.FinishedAt }).Count -eq 0) 'A job was left running after completion or the commit failure.'
            $expectedPhases = if ($failCommit) { 'Layouts,Initial,Attachments,ArticleStage,ArticleCommit' } else { 'Layouts,Websites,Initial,Attachments,ArticleStage,ArticleCommit,AssetLinks' }
            Assert-LinkOrchestration (($events.Phase -join ',') -ceq $expectedPhases) 'Phase order or the website monitoring setting changed.'
            $expectedJobByPhase = @{
                Layouts = 'Wrap-Up - Layouts'; Websites = 'Wrap-Up - Layouts'; Initial = 'LinkReplacement'
                Attachments = 'Wrap-Up - Attachments'; ArticleStage = 'Wrap-Up - Article Link Replacement'
                ArticleCommit = 'Wrap-Up - Article Content Commit'; AssetLinks = 'Wrap-Up - Asset Link Replacement'
            }
            foreach ($event in $events) {
                Assert-LinkOrchestration ($event.Job -ceq $expectedJobByPhase[$event.Phase]) "$($event.Phase) ran under the wrong job timer."
            }
            Assert-LinkOrchestration (Test-Path -LiteralPath (Join-Path $MigrationLogs 'ManualActions.json')) 'The manual-actions snapshot was lost.'
        }
    }
    Write-Output "Passed $checks link replacement orchestration checks (offline)."
} finally {
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixtureRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolvedFixtureRoot) -notmatch '^itglue-link-orchestration-[a-f0-9]{32}$') {
        throw "Refusing fixture cleanup outside the expected temp directory: $resolvedFixtureRoot"
    }
    if ([IO.Directory]::Exists($resolvedFixtureRoot)) { [IO.Directory]::Delete($resolvedFixtureRoot, $true) }
}
