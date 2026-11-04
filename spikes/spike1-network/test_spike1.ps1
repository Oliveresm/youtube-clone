# Ejecutar en PowerShell, dentro de spikes\spike1-network, DESPUES de `tofu apply`
# y de esperar ~1-2 min a que la tarea este en RUNNING.
# Requiere: tofu, aws CLI y curl.exe disponibles en PowerShell.

$env:AWS_DEFAULT_REGION = "us-east-1"
$cluster = "spike1-cluster"

# --- Verificar herramientas ---
foreach ($tool in @("tofu", "aws", "curl.exe")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "NO SE PUEDE PROBAR: falta '$tool' en el PATH de PowerShell" -ForegroundColor Red
        return
    }
}

$base = (tofu output -raw api_base_url).Trim()
if (-not $base) {
    Write-Host "NO SE PUEDE PROBAR: tofu output api_base_url vacio" -ForegroundColor Red
    return
}
Write-Host "API base: $base`n"

Write-Host "== 0. Estado de la tarea =="
aws ecs describe-services --cluster $cluster --services spike1-service `
    --query "services[0].{running:runningCount,desired:desiredCount}" --output text

Write-Host "`n== 1. Via API Gateway (la URI debe llegar con el prefijo /api intacto) =="
foreach ($path in @("/api", "/api/foo", "/api/foo/bar")) {
    Write-Host "-- GET $base$path"
    $body = curl.exe -s -m 10 "$base$path"
    if ($LASTEXITCODE -ne 0 -or -not $body) {
        Write-Host "FALLO: sin respuesta (curl exit $LASTEXITCODE)" -ForegroundColor Red
        continue
    }
    $line = $body | Select-String -CaseSensitive -Pattern "URI:" | Select-Object -First 1
    if ($line) { Write-Host (($line.Line -replace "<[^>]+>", " ").Trim()) -ForegroundColor Green }
    else       { Write-Host "FALLO: respondio pero sin linea URI" -ForegroundColor Red }
}

Write-Host "`n== 2. Acceso directo a la IP publica (debe estar BLOQUEADO) =="
$task = aws ecs list-tasks --cluster $cluster --query "taskArns[0]" --output text
if (-not $task -or $task -eq "None") {
    Write-Host "NO SE PUEDE PROBAR: no hay tarea corriendo" -ForegroundColor Red
    return
}
$eni = aws ecs describe-tasks --cluster $cluster --tasks $task `
    --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value | [0]" --output text
$ip = aws ec2 describe-network-interfaces --network-interface-ids $eni `
    --query "NetworkInterfaces[0].Association.PublicIp" --output text

if (-not $ip -or $ip -eq "None") {
    Write-Host "NO SE PUEDE PROBAR: la tarea no tiene IP publica asignada" -ForegroundColor Red
    return
}
Write-Host "IP publica de la tarea: $ip"

curl.exe -s -m 5 -o NUL "http://$ip"
switch ($LASTEXITCODE) {
    0       { Write-Host "FALLO: la tarea responde directo por su IP publica" -ForegroundColor Red }
    28      { Write-Host "OK: acceso directo bloqueado (timeout)" -ForegroundColor Green }
    7       { Write-Host "OK: acceso directo rechazado (conexion rehusada)" -ForegroundColor Green }
    default { Write-Host "INCIERTO: curl termino con codigo $LASTEXITCODE" -ForegroundColor Yellow }
}