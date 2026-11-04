# Uses the invoking migration's current $ITGlueExportBootstrapJob.
function Stop-ITGlueExportBootstrapJobIfRunning {
    if (-not $ITGlueExportBootstrapJob) {
        return
    }

    if ($ITGlueExportBootstrapJob.State -eq 'Running') {
        Write-Host "Stopping background IT Glue export job $($ITGlueExportBootstrapJob.Id)." -ForegroundColor Yellow
        Stop-Job -Job $ITGlueExportBootstrapJob -ErrorAction SilentlyContinue
    }

    Remove-Job -Job $ITGlueExportBootstrapJob -Force -ErrorAction SilentlyContinue
}
