<#
.SYNOPSIS
  QA checker for the Raqeeb Garments Workshop V2 static site.
  Native Windows PowerShell only — no external modules or dependencies.
  Mirrors tools/qa_check.py for machines without Python installed.

.USAGE
  powershell -ExecutionPolicy Bypass -File tools\qa_check.ps1

  Exit code is non-zero only if at least one ERROR was found.
  Warnings never fail the run.
#>

param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path $Root).Path
$SiteOrigin = 'https://www.raqeebgmt.com'
$ExpectedSiteName = 'Raqeeb Garments Workshop'

$script:Errors = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]

$externalSchemes = @('http://', 'https://', 'mailto:', 'tel:', 'javascript:', '//')

# Fabric terms are WARNINGS, not ERRORS, since some may become verified
# later. The T-shirt page's confirmed "Cotton" / "Polyester mesh" must never
# trip these — none of the patterns below match bare "cotton" or "polyester".
$suspiciousPatterns = @(
  @{ Pattern = '5\s*[–\-]\s*14\s*days'; Label = '"5-14 days" turnaround claim' },
  @{ Pattern = 'high[\s-]?volume'; Label = '"high-volume" claim' },
  @{ Pattern = 'nothing\s+subcontracted\s+out'; Label = '"nothing subcontracted out" claim' },
  @{ Pattern = '\b\d[\d,]*\+?\s*(specializ\w*\s+)?workers?\b'; Label = 'worker-count language' },
  @{ Pattern = '\b\d[\d,]*\+?\s*(stitching\s+)?machines?\b'; Label = 'machine-count language' },
  @{ Pattern = '\bfounder\b'; Label = 'founder-experience language' },
  @{ Pattern = 'repeatable\s+tailoring'; Label = '"repeatable tailoring" claim' },
  @{ Pattern = 'consistent\s+sizing'; Label = '"consistent sizing" outcome claim' },
  @{ Pattern = '\bunisex\b'; Label = '"unisex" claim' },
  @{ Pattern = 'poly-cotton'; Label = '"poly-cotton" fabric claim' },
  @{ Pattern = 'stretch[\s-]blend'; Label = '"stretch blend" fabric claim' }
)

function Get-RelPath {
  param([string]$FullPath)
  $p = $FullPath.Substring($Root.Length).TrimStart('\', '/')
  return $p.Replace('\', '/')
}

function Get-ExpectedCanonical {
  # Derives the production canonical URL for a file from its path relative
  # to the site root. All indexable pages are either the root index.html,
  # thanks.html, or a <dir>/index.html — directories become trailing-slash
  # URLs with no "index.html" segment.
  param([string]$RelPath)
  if ($RelPath -eq 'index.html') { return "$SiteOrigin/" }
  if ($RelPath -eq 'thanks.html') { return "$SiteOrigin/thanks.html" }
  if ($RelPath.EndsWith('/index.html')) {
    $dir = $RelPath.Substring(0, $RelPath.Length - 'index.html'.Length)
    return "$SiteOrigin/$dir"
  }
  return "$SiteOrigin/$RelPath"
}

function Get-LineNumber {
  param([string]$Text, [int]$Index)
  if ($Index -lt 0) { return 0 }
  $slice = $Text.Substring(0, [Math]::Min($Index, $Text.Length))
  return ([regex]::Matches($slice, "`n").Count + 1)
}

function Test-IsInternal {
  param([string]$Href)
  if ([string]::IsNullOrWhiteSpace($Href)) { return $false }
  $h = $Href.Trim()
  if ($h.StartsWith('#')) { return $false }
  $low = $h.ToLowerInvariant()
  foreach ($scheme in $externalSchemes) {
    if ($low.StartsWith($scheme)) { return $false }
  }
  return $true
}

function Resolve-Href {
  # Resolves an internal href relative to the directory of the file that
  # contains it. Returns @{ Resolved = <abs path or $null>; PathOnly = <string> }
  param([string]$FileFullPath, [string]$Href)
  $pathOnly = $Href
  $hashIdx = $pathOnly.IndexOf('#')
  if ($hashIdx -ge 0) { $pathOnly = $pathOnly.Substring(0, $hashIdx) }
  $qIdx = $pathOnly.IndexOf('?')
  if ($qIdx -ge 0) { $pathOnly = $pathOnly.Substring(0, $qIdx) }
  $pathOnly = [System.Uri]::UnescapeDataString($pathOnly)
  if ([string]::IsNullOrEmpty($pathOnly)) {
    return @{ Resolved = $null; PathOnly = $pathOnly }
  }
  $baseDir = Split-Path -Parent $FileFullPath
  $joined = Join-Path $baseDir $pathOnly
  # Manual normalization (Resolve-Path requires the target to exist)
  $full = [System.IO.Path]::GetFullPath($joined)
  return @{ Resolved = $full; PathOnly = $pathOnly }
}

# ---------------------------------------------------------------------------
# Discover files
# ---------------------------------------------------------------------------
$htmlFiles = Get-ChildItem -Path $Root -Recurse -Filter '*.html' -File |
  Where-Object { $_.FullName -notmatch '\\tools(\\|$)' -and $_.FullName -notmatch '\\\.claude(\\|$)' -and $_.FullName -notmatch '\\\.git(\\|$)' } |
  Sort-Object FullName

$pageData = @{}   # fullpath -> hashtable of parsed fields
$rawText  = @{}   # fullpath -> raw content

foreach ($file in $htmlFiles) {
  $text = Get-Content -Path $file.FullName -Raw -Encoding UTF8
  $rawText[$file.FullName] = $text

  $titleMatch = [regex]::Match($text, '<title>([\s\S]*?)</title>', 'IgnoreCase')
  $descMatch  = [regex]::Match($text, '<meta\s+name="description"\s+content="([^"]*)"', 'IgnoreCase')
  $canonMatch = [regex]::Match($text, '<link\s+rel="canonical"\s+href="([^"]*)"', 'IgnoreCase')
  $ogImgMatch = [regex]::Match($text, '<meta\s+property="og:image"\s+content="([^"]*)"', 'IgnoreCase')
  $ogSiteMatch = [regex]::Match($text, '<meta\s+property="og:site_name"\s+content="([^"]*)"', 'IgnoreCase')
  $robotsMatch = [regex]::Match($text, '<meta\s+name="robots"\s+content="([^"]*)"', 'IgnoreCase')
  $h1Matches  = [regex]::Matches($text, '<h1[^>]*>([\s\S]*?)</h1>', 'IgnoreCase')

  $ids = [regex]::Matches($text, '\bid="([^"]+)"') | ForEach-Object {
    [PSCustomObject]@{ Id = $_.Groups[1].Value; Line = Get-LineNumber $text $_.Index }
  }

  $linkMatches = [regex]::Matches($text, '<(?:a|link)\s[^>]*?\bhref="([^"]*)"', 'IgnoreCase') | ForEach-Object {
    [PSCustomObject]@{ Href = $_.Groups[1].Value; Line = Get-LineNumber $text $_.Index }
  }

  $imgMatches = [regex]::Matches($text, '<img\s[^>]*?>', 'IgnoreCase') | ForEach-Object {
    $tag = $_.Value
    $srcM = [regex]::Match($tag, '\bsrc="([^"]*)"')
    $altM = [regex]::Match($tag, '\balt="([^"]*)"')
    [PSCustomObject]@{
      Src  = if ($srcM.Success) { $srcM.Groups[1].Value } else { $null }
      Alt  = if ($altM.Success) { $altM.Groups[1].Value } else { $null }
      HasAlt = $altM.Success
      Line = Get-LineNumber $text $_.Index
    }
  }

  $pageData[$file.FullName] = @{
    Title       = if ($titleMatch.Success) { $titleMatch.Groups[1].Value.Trim() } else { $null }
    Description = if ($descMatch.Success) { $descMatch.Groups[1].Value.Trim() } else { $null }
    Canonical   = if ($canonMatch.Success) { $canonMatch.Groups[1].Value.Trim() } else { $null }
    OgImage     = if ($ogImgMatch.Success) { $ogImgMatch.Groups[1].Value.Trim() } else { $null }
    OgSiteName  = if ($ogSiteMatch.Success) { $ogSiteMatch.Groups[1].Value.Trim() } else { $null }
    Robots      = if ($robotsMatch.Success) { $robotsMatch.Groups[1].Value.Trim() } else { $null }
    H1Count     = $h1Matches.Count
    H1          = if ($h1Matches.Count -gt 0) { ($h1Matches[0].Groups[1].Value -replace '<[^>]+>', '').Trim() } else { $null }
    Ids         = $ids
    Links       = $linkMatches
    Imgs        = $imgMatches
  }
}

# ---------------------------------------------------------------------------
# Per-page checks
# ---------------------------------------------------------------------------
foreach ($file in $htmlFiles) {
  $full = $file.FullName
  $r = Get-RelPath $full
  $data = $pageData[$full]
  $isThanksPage = ($r -eq 'thanks.html')

  if ([string]::IsNullOrWhiteSpace($data.Title)) {
    $script:Errors.Add("$r -- missing <title>")
  }
  if ($null -eq $data.Description -or $data.Description -eq '') {
    $script:Errors.Add("$r -- missing meta description")
  }
  if ($data.H1Count -eq 0) {
    $script:Errors.Add("$r -- missing H1")
  } elseif ($data.H1Count -gt 1) {
    $script:Errors.Add("$r -- $($data.H1Count) H1 elements found (expected exactly one)")
  }
  if ([string]::IsNullOrWhiteSpace($data.Canonical)) {
    $script:Errors.Add("$r -- missing canonical link")
  } else {
    $expectedCanonical = Get-ExpectedCanonical $r
    if ($data.Canonical -ne $expectedCanonical) {
      $script:Errors.Add("$r -- canonical does not match expected production URL: got `"$($data.Canonical)`", expected `"$expectedCanonical`"")
    }
  }

  # Indexing regressions
  $hasNoindex = ($null -ne $data.Robots -and $data.Robots -match 'noindex')
  if ($isThanksPage) {
    if (-not $hasNoindex) {
      $script:Errors.Add("$r -- thanks.html must stay noindex")
    }
  } else {
    if ($hasNoindex) {
      $script:Errors.Add("$r -- accidental noindex on an indexable page")
    }
    # OG / social metadata required on every indexable page
    if ([string]::IsNullOrWhiteSpace($data.OgSiteName)) {
      $script:Errors.Add("$r -- missing og:site_name")
    } elseif ($data.OgSiteName -ne $ExpectedSiteName) {
      $script:Warnings.Add("$r -- og:site_name is `"$($data.OgSiteName)`", expected `"$ExpectedSiteName`"")
    }
  }

  # Duplicate IDs within the page
  $grouped = $data.Ids | Group-Object -Property Id
  foreach ($g in $grouped) {
    if ($g.Count -gt 1) {
      $lines = $g.Group | ForEach-Object { $_.Line }
      $script:Errors.Add("$r`:$($lines[1]) -- duplicate id `"$($g.Name)`" (also at line $($lines[0]))")
    }
  }

  # og:image relative
  if ($data.OgImage -and -not ($data.OgImage -match '^https?://')) {
    $script:Warnings.Add("$r -- og:image is relative, not absolute: $($data.OgImage)")
  }

  # alt text
  foreach ($img in $data.Imgs) {
    if (-not $img.HasAlt -or [string]::IsNullOrWhiteSpace($img.Alt)) {
      $srcLabel = if ($img.Src) { $img.Src } else { '(no src)' }
      $script:Warnings.Add("$r -- image missing/empty alt text: $srcLabel")
    }
  }

  # links: broken internal refs + explicit index.html requirement
  foreach ($lnk in $data.Links) {
    if (-not (Test-IsInternal $lnk.Href)) { continue }
    $res = Resolve-Href -FileFullPath $full -Href $lnk.Href
    if ($null -eq $res.Resolved) { continue }  # pure same-page anchor
    $pathOnly = $res.PathOnly
    $lastSeg = $pathOnly.Substring($pathOnly.TrimEnd('/').LastIndexOf('/') + 1)
    if ($pathOnly.EndsWith('/')) { $lastSeg = '' }
    $looksLikeDirectory = $pathOnly.EndsWith('/') -or (-not $lastSeg.Contains('.'))
    if ($looksLikeDirectory) {
      $script:Errors.Add("$r`:$($lnk.Line) -- internal link omits explicit index.html (directory-listing risk): $($lnk.Href)")
      $candidate = Join-Path $res.Resolved 'index.html'
      if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $script:Errors.Add("$r`:$($lnk.Line) -- broken internal link (no index.html at target): $($lnk.Href)")
      }
      continue
    }
    if (-not (Test-Path -LiteralPath $res.Resolved -PathType Leaf)) {
      $script:Errors.Add("$r`:$($lnk.Line) -- broken internal link (target not found): $($lnk.Href)")
    }
  }

  # local image files exist
  foreach ($img in $data.Imgs) {
    if (-not $img.Src) { continue }
    if (-not (Test-IsInternal $img.Src)) { continue }
    $res = Resolve-Href -FileFullPath $full -Href $img.Src
    if ($res.Resolved -and -not (Test-Path -LiteralPath $res.Resolved -PathType Leaf)) {
      $script:Errors.Add("$r`:$($img.Line) -- broken image reference: $($img.Src)")
    }
  }

  # suspicious wording (raw text scan)
  $text = $rawText[$full]
  foreach ($sp in $suspiciousPatterns) {
    $m = [regex]::Match($text, $sp.Pattern, 'IgnoreCase')
    if ($m.Success) {
      $line = Get-LineNumber $text $m.Index
      $script:Warnings.Add("$r`:$line -- suspicious wording -- $($sp.Label)")
    }
  }

  # banned OLD phone number regression (all variants of 056 242 4693)
  $oldNumberMatch = [regex]::Match($text, '(\+?971[\s-]?|0)?56[\s-]?242[\s-]?4693')
  if ($oldNumberMatch.Success) {
    $line = Get-LineNumber $text $oldNumberMatch.Index
    $script:Errors.Add("$r`:$line -- banned OLD phone number regression detected: $($oldNumberMatch.Value)")
  }

  # accidental /v2/ runtime dependency
  $v2Match = [regex]::Match($text, 'href="[^"]*/v2/|src="[^"]*/v2/|https://www\.raqeebgmt\.com/v2/')
  if ($v2Match.Success) {
    $line = Get-LineNumber $text $v2Match.Index
    $script:Errors.Add("$r`:$line -- accidental /v2/ runtime dependency found: $($v2Match.Value)")
  }
}

# ---------------------------------------------------------------------------
# Duplicate titles / descriptions across pages
# ---------------------------------------------------------------------------
$titleGroups = $htmlFiles | Where-Object { $pageData[$_.FullName].Title } |
  Group-Object { $pageData[$_.FullName].Title }
foreach ($g in $titleGroups) {
  if ($g.Count -gt 1) {
    $files = ($g.Group | ForEach-Object { Get-RelPath $_.FullName }) -join ', '
    $script:Warnings.Add("$files -- duplicate <title>: `"$($g.Name)`"")
  }
}

$descGroups = $htmlFiles | Where-Object { $pageData[$_.FullName].Description } |
  Group-Object { $pageData[$_.FullName].Description }
foreach ($g in $descGroups) {
  if ($g.Count -gt 1) {
    $files = ($g.Group | ForEach-Object { Get-RelPath $_.FullName }) -join ', '
    $shortDesc = $g.Name.Substring(0, [Math]::Min(70, $g.Name.Length))
    $script:Warnings.Add("$files -- duplicate meta description: `"$shortDesc`"")
  }
}

# ---------------------------------------------------------------------------
# Orphan product pages: BFS from products/index.html
# ---------------------------------------------------------------------------
$hubPath = Join-Path $Root 'products\index.html'
$productDir = Join-Path $Root 'products'

$allProductPages = @()
if (Test-Path -LiteralPath $productDir -PathType Container) {
  Get-ChildItem -Path $productDir -Directory | ForEach-Object {
    $candidate = Join-Path $_.FullName 'index.html'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $allProductPages += (Resolve-Path $candidate).Path
    }
  }
}

$reachableFromHub = New-Object System.Collections.Generic.HashSet[string]
if ((Test-Path -LiteralPath $hubPath -PathType Leaf) -and $pageData.ContainsKey((Resolve-Path $hubPath).Path)) {
  $hubFull = (Resolve-Path $hubPath).Path
  $queue = New-Object System.Collections.Generic.Queue[string]
  $queue.Enqueue($hubFull)
  $visited = New-Object System.Collections.Generic.HashSet[string]
  [void]$visited.Add($hubFull)
  $productDirFull = (Resolve-Path $productDir).Path

  while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    if (-not $pageData.ContainsKey($current)) { continue }
    foreach ($lnk in $pageData[$current].Links) {
      if (-not (Test-IsInternal $lnk.Href)) { continue }
      $res = Resolve-Href -FileFullPath $current -Href $lnk.Href
      if ($null -eq $res.Resolved) { continue }
      $resolved = $res.Resolved
      if ($res.PathOnly.EndsWith('/')) { $resolved = Join-Path $resolved 'index.html' }
      if (-not $resolved.StartsWith($productDirFull, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
      if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { continue }
      $resolved = [System.IO.Path]::GetFullPath($resolved)
      if ($reachableFromHub.Add($resolved)) {
        if ($visited.Add($resolved)) { $queue.Enqueue($resolved) }
      }
    }
  }
}

foreach ($page in ($allProductPages | Sort-Object)) {
  if ($page -eq (Resolve-Path $hubPath).Path) { continue }
  if (-not $reachableFromHub.Contains($page)) {
    $script:Errors.Add("$(Get-RelPath $page) -- orphan product page not reachable from Products Hub")
  }
}

# ---------------------------------------------------------------------------
# Site-wide orphan check: BFS from the homepage across every indexable page
# (catches pages outside products/, e.g. private-label/, that the
# products-hub-scoped check above can't see).
# ---------------------------------------------------------------------------
$homePath = Join-Path $Root 'index.html'
$indexablePages = $htmlFiles | Where-Object { (Get-RelPath $_.FullName) -ne 'thanks.html' }

if ((Test-Path -LiteralPath $homePath -PathType Leaf) -and $pageData.ContainsKey((Resolve-Path $homePath).Path)) {
  $homeFull = (Resolve-Path $homePath).Path
  $siteReachable = New-Object System.Collections.Generic.HashSet[string]
  [void]$siteReachable.Add($homeFull)
  $queue2 = New-Object System.Collections.Generic.Queue[string]
  $queue2.Enqueue($homeFull)

  while ($queue2.Count -gt 0) {
    $current = $queue2.Dequeue()
    if (-not $pageData.ContainsKey($current)) { continue }
    foreach ($lnk in $pageData[$current].Links) {
      if (-not (Test-IsInternal $lnk.Href)) { continue }
      $res = Resolve-Href -FileFullPath $current -Href $lnk.Href
      if ($null -eq $res.Resolved) { continue }
      $resolved = $res.Resolved
      if ($res.PathOnly.EndsWith('/')) { $resolved = Join-Path $resolved 'index.html' }
      if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { continue }
      $resolved = [System.IO.Path]::GetFullPath($resolved)
      if ($siteReachable.Add($resolved)) { $queue2.Enqueue($resolved) }
    }
  }

  foreach ($page in $indexablePages) {
    if (-not $siteReachable.Contains($page.FullName)) {
      $script:Errors.Add("$(Get-RelPath $page.FullName) -- orphan page not reachable from the homepage")
    }
  }
}

# ---------------------------------------------------------------------------
# sitemap.xml checks
# ---------------------------------------------------------------------------
$sitemapPath = Join-Path $Root 'sitemap.xml'
if (-not (Test-Path -LiteralPath $sitemapPath -PathType Leaf)) {
  $script:Errors.Add("sitemap.xml -- file not found at site root")
} else {
  $sitemapText = Get-Content -Path $sitemapPath -Raw -Encoding UTF8
  $locMatches = [regex]::Matches($sitemapText, '<loc>\s*([^<\s]+)\s*</loc>')
  $sitemapUrls = $locMatches | ForEach-Object { $_.Groups[1].Value.Trim() }

  $urlCounts = @{}
  foreach ($u in $sitemapUrls) { $urlCounts[$u] = ($urlCounts[$u] + 1) }
  foreach ($u in $urlCounts.Keys) {
    if ($urlCounts[$u] -gt 1) {
      $script:Errors.Add("sitemap.xml -- URL listed $($urlCounts[$u]) times, expected exactly once: $u")
    }
  }

  $thanksUrl = Get-ExpectedCanonical 'thanks.html'
  if ($sitemapUrls -contains $thanksUrl) {
    $script:Errors.Add("sitemap.xml -- thanks.html must be excluded from the sitemap")
  }

  $expectedUrls = $indexablePages | ForEach-Object { Get-ExpectedCanonical (Get-RelPath $_.FullName) }
  $expectedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$expectedUrls)
  $sitemapSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$sitemapUrls)

  foreach ($u in $expectedSet) {
    if (-not $sitemapSet.Contains($u)) {
      $script:Errors.Add("sitemap.xml -- missing expected canonical URL: $u")
    }
  }
  foreach ($u in $sitemapSet) {
    if (-not $expectedSet.Contains($u) -and $u -ne $thanksUrl) {
      $script:Errors.Add("sitemap.xml -- lists a URL with no matching indexable page: $u")
    }
  }
}

# ---------------------------------------------------------------------------
# robots.txt checks
# ---------------------------------------------------------------------------
$robotsPath = Join-Path $Root 'robots.txt'
if (-not (Test-Path -LiteralPath $robotsPath -PathType Leaf)) {
  $script:Errors.Add("robots.txt -- file not found at site root")
} else {
  $robotsText = Get-Content -Path $robotsPath -Raw -Encoding UTF8
  $expectedSitemapLine = "$SiteOrigin/sitemap.xml"
  if ($robotsText -notmatch [regex]::Escape($expectedSitemapLine)) {
    $script:Errors.Add("robots.txt -- does not declare the sitemap URL ($expectedSitemapLine)")
  }
  if ($robotsText -match '(?m)^\s*Disallow:\s*/\s*$') {
    $script:Errors.Add("robots.txt -- blanket 'Disallow: /' would block all public pages")
  }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
if ($script:Errors.Count -gt 0) {
  Write-Output "ERRORS ($($script:Errors.Count)):"
  $script:Errors | Sort-Object | ForEach-Object { Write-Output "  [ERROR] $_" }
  Write-Output ""
}

if ($script:Warnings.Count -gt 0) {
  Write-Output "WARNINGS ($($script:Warnings.Count)):"
  $script:Warnings | Sort-Object | ForEach-Object { Write-Output "  [WARN]  $_" }
  Write-Output ""
}

Write-Output ("PASS SUMMARY: {0} file(s) scanned, {1} error(s), {2} warning(s)." -f $htmlFiles.Count, $script:Errors.Count, $script:Warnings.Count)

if ($script:Errors.Count -gt 0) { exit 1 } else { exit 0 }
