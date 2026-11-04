# Ejecutar en PowerShell dentro de spike5-eventbridge, DESPUES de `tofu apply`.
# Requiere: tofu y aws CLI en el PATH.

$env:AWS_DEFAULT_REGION = "us-east-1"
foreach ($tool in @("tofu", "aws")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "NO SE PUEDE PROBAR: falta '$tool' en el PATH" -ForegroundColor Red
        return
    }
}

$queue = (tofu output -raw queue_url).Trim()
$dlq   = (tofu output -raw dlq_url).Trim()
if (-not $queue -or -not $dlq) { Write-Host "NO SE PUEDE PROBAR: faltan outputs" -ForegroundColor Red; return }

$script:pass = 0
$script:fail = 0
function Report($ok, $name, $detail = "") {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "FAIL  $name $detail" -ForegroundColor Red; $script:fail++ }
}

function Send-Event($status, $withVideoId, $label) {
    $meta = if ($withVideoId) { '{\"videoId\":\"11111111-1111-1111-1111-111111111111\"}' } else { '{}' }
    $json = '[{"Source":"spike.mediaconvert","DetailType":"MediaConvert Job State Change","Detail":"{\"status\":\"' + $status + '\",\"jobId\":\"job-' + $label + '\",\"userMetadata\":' + $meta + '}"}]'
    Set-Content -Path "event-$label.json" -Value $json -Encoding ascii
    $r = aws events put-events --entries "file://event-$label.json" --output json | ConvertFrom-Json
    Remove-Item "event-$label.json" -Force
    return ($r.FailedEntryCount -eq 0)
}

function Receive-One($url, $wait, $visibility = 30) {
    $r = aws sqs receive-message --queue-url $url --max-number-of-messages 1 `
        --wait-time-seconds $wait --visibility-timeout $visibility --output json | ConvertFrom-Json
    if ($r -and $r.Messages) { return $r.Messages[0] }
    return $null
}

Write-Host "== 1. Evento COMPLETE -> SQS con el contrato de mensaje =="
$sent = Send-Event "COMPLETE" $true "complete"
Report $sent "put-events COMPLETE aceptado"
$m = Receive-One $queue 15
if ($m) {
    $b = $m.Body | ConvertFrom-Json
    Report ($b.type -eq "TRANSCODE_COMPLETE") "type = TRANSCODE_COMPLETE" "(body: $($m.Body))"
    Report ($b.videoId -eq "11111111-1111-1111-1111-111111111111") "videoId extraido de userMetadata"
    Report ([bool]$b.occurredAt) "occurredAt presente"
    aws sqs delete-message --queue-url $queue --receipt-handle $m.ReceiptHandle | Out-Null
} else { Report $false "mensaje COMPLETE llego a la cola" "(timeout: revisar resource policy / regla)" }

Write-Host "`n== 2. Evento ERROR =="
Send-Event "ERROR" $true "error" | Out-Null
$m = Receive-One $queue 15
if ($m) {
    $b = $m.Body | ConvertFrom-Json
    Report ($b.type -eq "TRANSCODE_ERROR") "type = TRANSCODE_ERROR" "(body: $($m.Body))"
    aws sqs delete-message --queue-url $queue --receipt-handle $m.ReceiptHandle | Out-Null
} else { Report $false "mensaje ERROR llego a la cola" }

Write-Host "`n== 3. Filtros: NO deben llegar mensajes =="
Send-Event "COMPLETE" $false "novideoid" | Out-Null
Send-Event "PROGRESSING" $true "progressing" | Out-Null
$m = Receive-One $queue 15
Report (-not $m) "sin userMetadata.videoId o con status distinto: nada llega" $(if ($m) { "(llego: $($m.Body))" } else { "" })
if ($m) { aws sqs delete-message --queue-url $queue --receipt-handle $m.ReceiptHandle | Out-Null }

Write-Host "`n== 4. Mensaje de la Lambda (PROCESSING_STARTED) en la misma cola =="
$env1 = '{"type":"PROCESSING_STARTED","videoId":"22222222-2222-2222-2222-222222222222","occurredAt":"2026-11-04T00:00:00Z"}'
Set-Content -Path "msg1.json" -Value $env1 -Encoding ascii
aws sqs send-message --queue-url $queue --message-body "file://msg1.json" | Out-Null
$m = Receive-One $queue 10
Report ([bool]$m) "SendMessage directo llega a la cola"
if ($m) { aws sqs delete-message --queue-url $queue --receipt-handle $m.ReceiptHandle | Out-Null }
Remove-Item "msg1.json" -Force -ErrorAction SilentlyContinue

Write-Host "`n== 5. DLQ: un mensaje que nunca se borra termina en la DLQ (maxReceiveCount = 3) =="
Set-Content -Path "msg2.json" -Value '{"type":"TRANSCODE_COMPLETE","videoId":"poison"}' -Encoding ascii
aws sqs send-message --queue-url $queue --message-body "file://msg2.json" | Out-Null
Remove-Item "msg2.json" -Force -ErrorAction SilentlyContinue
for ($i = 1; $i -le 4; $i++) {
    $m = Receive-One $queue 5 1     # visibility 1 s, NO se borra
    Write-Host ("   intento {0}: {1}" -f $i, $(if ($m) { "recibido" } else { "vacio (movido a DLQ)" }))
    Start-Sleep -Seconds 2
}
$d = Receive-One $dlq 20 0     # visibility 0: sigue visible para la alarma
Report ([bool]$d) "mensaje aparece en la DLQ" "(timeout)"
if ($d) { Write-Host "   DLQ body: $($d.Body)" }
Write-Host "   (el mensaje se deja en la DLQ para que dispare la alarma)"

Write-Host ""
Write-Host "Alarma: confirma el correo de SNS (revisa tu bandeja) y en 1-5 minutos revisa:"
Write-Host '  aws cloudwatch describe-alarms --alarm-names spike5-dlq-not-empty --query "MetricAlarms[0].StateValue" --output text'
Write-Host "Debe pasar a ALARM y llegarte un correo."
Write-Host ""
if ($script:fail -eq 0) { Write-Host "SPIKE 5 (parte automatica) APROBADO: $($script:pass) pruebas" -ForegroundColor Green }
else { Write-Host "SPIKE 5 CON FALLOS: $($script:fail) de $($script:pass + $script:fail)" -ForegroundColor Red }
