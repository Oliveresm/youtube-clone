# Ejecutar en PowerShell dentro de spike4-cloudfront, DESPUES de `tofu apply`.
# Requiere: tofu y curl.exe en el PATH.

foreach ($tool in @("tofu", "curl.exe")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "NO SE PUEDE PROBAR: falta '$tool' en el PATH" -ForegroundColor Red
        return
    }
}

$cdn = (tofu output -raw cdn_url).Trim()
$direct = (tofu output -raw frontend_direct_url).Trim()
if (-not $cdn) { Write-Host "NO SE PUEDE PROBAR: sin cdn_url" -ForegroundColor Red; return }
Write-Host "CDN: $cdn`n"

$script:pass = 0
$script:fail = 0

function Test-Url {
    param(
        [string]$Name,
        [string]$Url,
        [int]$Status,
        [string[]]$Contains = @(),
        [string[]]$NotContains = @(),
        [string]$CType = "",
        [string[]]$Header = @()
    )
    $tmp = [System.IO.Path]::GetTempFileName()
    $curlArgs = @("-s", "-m", "30", "-o", $tmp, "-w", "%{http_code}|%{content_type}")
    foreach ($h in $Header) { $curlArgs += @("-H", $h) }
    $curlArgs += $Url
    $out = & curl.exe @curlArgs
    $body = Get-Content $tmp -Raw -ErrorAction SilentlyContinue
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    if (-not $body) { $body = "" }

    $problems = @()
    if (-not $out) {
        $problems += "curl sin respuesta"
    } else {
        $code, $ct = $out -split "\|", 2
        if ([int]$code -ne $Status) { $problems += "HTTP $code (esperado $Status)" }
        if ($CType -and ($ct -notlike "*$CType*")) { $problems += "content-type '$ct' (esperado '$CType')" }
    }
    foreach ($c in $Contains)    { if ($body -notlike "*$c*") { $problems += "falta '$c' en el cuerpo" } }
    foreach ($c in $NotContains) { if ($body -like "*$c*")    { $problems += "no debia contener '$c'" } }

    if ($problems.Count -eq 0) {
        Write-Host "PASS  $Name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "FAIL  $Name -> $($problems -join '; ')" -ForegroundColor Red
        $script:fail++
    }
}

function Test-Header {
    param([string]$Name, [string]$Url, [string]$Origin, [bool]$ExpectPresent, [string]$ExpectValue = "")
    $lines = & curl.exe -s -m 30 -o NUL -D - -H "Origin: $Origin" $Url
    $hit = $lines | Select-String -Pattern "(?i)^access-control-allow-origin:\s*(.+?)\s*$"
    $present = [bool]$hit
    $ok = ($present -eq $ExpectPresent)
    if ($ok -and $present -and $ExpectValue) { $ok = ($hit.Matches[0].Groups[1].Value -eq $ExpectValue) }
    if ($ok) { Write-Host "PASS  $Name" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "FAIL  $Name (presente=$present)" -ForegroundColor Red; $script:fail++ }
}

Write-Host "== Frontend estatico (CloudFront Function + OAC) =="
Test-Url "/ sirve index.html"                  "$cdn/"                 200 -Contains "HOME PAGE"
Test-Url "/watch/?v=abc sirve watch/index.html" "$cdn/watch/?v=abc"    200 -Contains "WATCH PAGE"
Test-Url "/watch (sin slash) tambien resuelve"  "$cdn/watch"           200 -Contains "WATCH PAGE"
Test-Url "/assets/app.js no se reescribe"       "$cdn/assets/app.js"   200 -CType "javascript" -NotContains "<html"
Test-Url "/missing.js da 404 real (no HTML 200)" "$cdn/missing.js"     404 -NotContains "HOME PAGE","WATCH PAGE"
Test-Url "/ruta-inexistente da 404 real"        "$cdn/ruta-inexistente" 404 -NotContains "HOME PAGE","WATCH PAGE"

Write-Host "`n== /api/* (CloudFront -> API Gateway) =="
Test-Url "/api/hello llega con prefijo y Authorization" "$cdn/api/hello" 200 `
    -Contains '"/api/hello"', 'Bearer test123', 'execute-api' -Header "Authorization: Bearer test123"
Test-Url "/api/notfound devuelve 404 JSON (no HTML 200)" "$cdn/api/notfound" 404 `
    -Contains '"rawPath"' -NotContains "HOME PAGE"

Write-Host "`n== /videos/* =="
Test-Url "manifest .m3u8 con content-type HLS" "$cdn/videos/test/index.m3u8" 200 -CType "mpegurl" -Contains "#EXTM3U"
Test-Url "segmento .ts"                         "$cdn/videos/test/seg0.ts"    200 -Contains "FAKE-TS"
Test-Url "segmento inexistente da 404 real"     "$cdn/videos/test/nope.ts"    404 -NotContains "HOME PAGE","WATCH PAGE"
Test-Header "CORS: origen permitido recibe el header"  "$cdn/videos/test/index.m3u8" "http://localhost:3000" $true "http://localhost:3000"
Test-Header "CORS: origen ajeno NO recibe el header"   "$cdn/videos/test/index.m3u8" "http://evil.example"   $false

Write-Host "`n== Seguridad: acceso directo al bucket =="
Test-Url "S3 directo (sin CloudFront) esta bloqueado" "$direct/index.html" 403

Write-Host ""
if ($script:fail -eq 0) { Write-Host "SPIKE 4 APROBADO ($($script:pass) pruebas)" -ForegroundColor Green }
else { Write-Host "SPIKE 4 CON FALLOS: $($script:fail) de $($script:pass + $script:fail)" -ForegroundColor Red }
