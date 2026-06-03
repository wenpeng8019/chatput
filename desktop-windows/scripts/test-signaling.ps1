$ErrorActionPreference = 'Stop'

function New-Ws($url) {
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.ConnectAsync([Uri]$url, [Threading.CancellationToken]::None).Wait()
    return $ws
}
function Send-Json($ws, $obj) {
    $json = $obj | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = [ArraySegment[byte]]::new($bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
}
function Recv-Json($ws) {
    $buf = [byte[]]::new(8192)
    $seg = [ArraySegment[byte]]::new($buf)
    $res = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $txt = [Text.Encoding]::UTF8.GetString($buf, 0, $res.Count)
    return $txt | ConvertFrom-Json
}

$url = 'ws://127.0.0.1:8080'

# 客户端 A 建房
$a = New-Ws $url
Send-Json $a @{ type = 'create-room' }
$created = Recv-Json $a
Write-Host "room-created: type=$($created.type) roomId=$($created.roomId) token=$($created.token)"

# 客户端 B 加入
$b = New-Ws $url
Send-Json $b @{ type = 'join-room'; roomId = $created.roomId; token = $created.token }
$bJoined = Recv-Json $b
Write-Host "B peer-joined: type=$($bJoined.type) role=$($bJoined.role)"
$aJoined = Recv-Json $a
Write-Host "A peer-joined: type=$($aJoined.type) role=$($aJoined.role)"

# A 发 signal 给 B
Send-Json $a @{ type = 'signal'; data = @{ hello = 'world' } }
$bSignal = Recv-Json $b
Write-Host "B signal: type=$($bSignal.type) data.hello=$($bSignal.data.hello)"

# B 发 message 给 A
Send-Json $b @{ type = 'message'; data = @{ type = 'text'; text = 'hi' } }
$aMsg = Recv-Json $a
Write-Host "A message: type=$($aMsg.type) data.text=$($aMsg.data.text)"

$a.Dispose(); $b.Dispose()
Write-Host "SIGNALING_E2E_OK"
