function Invoke-FastHuduArticleContentCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$CommitRequests,

        [ValidateRange(1, 196)]
        [int]$ThrottleLimit = 4,

        [ValidateRange(0, 5)]
        [int]$MaxRetries = 2,

        [hashtable]$CustomHeaders = @{}
    )

    if (-not $CommitRequests -or $CommitRequests.Count -lt 1) {
        return @()
    }

    if (-not (Get-Command -Name Invoke-FastHuduRequestBatch -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'Invoke-FastHuduRequestBatch.ps1')
    }

    Write-Host "Committing $($CommitRequests.Count) article content update(s) to Hudu with $ThrottleLimit worker(s)." -ForegroundColor Cyan

    $fastRequests = foreach ($request in $CommitRequests) {
        $article = [ordered]@{
            content = [string]$request.Content
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$request.Name)) {
            $article.name = [string]$request.Name
        }
        if ($request.CompanyId) {
            $article.company_id = [int]$request.CompanyId
        }

        [pscustomobject]@{
            Method               = 'PUT'
            Resource             = "/api/v1/articles/$($request.ArticleId)"
            Body                 = (@{ article = $article } | ConvertTo-Json -Depth 10)
            ContentType          = 'application/json; charset=utf-8'
            SourceRequest        = $request
            CommitName           = 'article'
            GateDescription      = "article $($request.ArticleId)"
            TransientDescription = "fast article commit for article $($request.ArticleId)"
        }
    }

    $batchResults = Invoke-FastHuduRequestBatch -Requests $fastRequests -ThrottleLimit $ThrottleLimit -MaxRetries $MaxRetries -CustomHeaders $CustomHeaders

    foreach ($batchResult in @($batchResults)) {
        $request = $batchResult.SourceRequest
        if ($batchResult.Status -eq 'succeeded') {
            $articleObject = $batchResult.Response.article ?? $batchResult.Response
            [pscustomobject]@{
                Status         = 'committed'
                Index          = $request.Index
                ArticleId      = $request.ArticleId
                ArticleName    = $request.ArticleName
                UpdatedArticle = $articleObject
                Attempts       = $batchResult.Attempts
                SleptSeconds   = $batchResult.SleptSeconds
                ElapsedSeconds = $batchResult.ElapsedSeconds
                StatusCode     = 200
            }
        } else {
            [pscustomobject]@{
                Status         = 'failed'
                Index          = $request.Index
                ArticleId      = $request.ArticleId
                ArticleName    = $request.ArticleName
                UpdatedArticle = $null
                Attempts       = $batchResult.Attempts
                SleptSeconds   = $batchResult.SleptSeconds
                ElapsedSeconds = $batchResult.ElapsedSeconds
                StatusCode     = $batchResult.StatusCode
                Error          = $batchResult.Error
            }
        }
    }
}
