# Starts Factorio with the Zenith bridge's UDP port open and, while it runs, starts Zenith when
# Ctrl+F9 ("Show in Zenith") is pressed in the game with no Zenith connected to it. Zenith then
# joins the game (single-player or a game you host), comes to the front and minimises Factorio;
# Ctrl+F9 in Zenith brings Factorio back.
#
# Steam: Factorio > Properties > Launch options:
#   powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "<Zenith>\server\factorio-with-zenith.ps1" %command%
# Without Steam: run it with factorio.exe's path and any arguments after it.
#
# Zenith must have been started once (any way): it writes how to start it to its user folder
# (launch.json), and that is what Ctrl+F9 starts. The bridge asks on 127.0.0.1:34209.
param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Command)

$LaunchPort = 34209
if (-not $Command -or $Command.Count -eq 0) {
  Write-Error "Give factorio.exe's path (Steam: put %command% after this script in the launch options)."
  exit 1
}
$exe = $Command[0]
$rest = @($Command | Select-Object -Skip 1)

# The port Factorio opens for the bridge: the one given, or 34200 as Zenith expects.
$udp = 34200
$i = [Array]::IndexOf($rest, "--enable-lua-udp")
if ($i -ge 0 -and $i + 1 -lt $rest.Count) { $udp = [int]$rest[$i + 1] } else { $rest += @("--enable-lua-udp", "$udp") }

# Start-Process joins its arguments with spaces, so quote the ones that have them.
function Join-Args([string[]] $list) {
  ($list | ForEach-Object { if ($_ -match '\s' -and $_ -notmatch '^".*"$') { '"' + $_ + '"' } else { $_ } }) -join " "
}

# A normal window, not the hidden style this script itself may run with.
$game = Start-Process -FilePath $exe -ArgumentList (Join-Args $rest) -WindowStyle Normal -PassThru
$listener = New-Object System.Net.Sockets.UdpClient ([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, $LaunchPort))
$listener.Client.ReceiveTimeout = 1000
$info = Join-Path $env:APPDATA "Godot\app_userdata\Zenith\launch.json"
$zenith = $null

# Tells the bridge this helper is here, so it doesn't show its "launcher not set up" window; with
# `need` the bridge shows in the game what is missing instead (a Windows dialog can hide behind
# a fullscreen Factorio).
function Send-Reply([string] $json) {
  $reply = [Text.Encoding]::UTF8.GetBytes($json)
  try { $null = $listener.Send($reply, $reply.Length, [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, $udp)) } catch { }
}

while (-not $game.HasExited) {
  try {
    $from = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0)
    $bytes = $listener.Receive([ref]$from)
  } catch {
    continue  # a second without a request
  }
  if ([Text.Encoding]::UTF8.GetString($bytes) -notmatch '"launch"') { continue }
  if ($zenith -and -not $zenith.HasExited) { Send-Reply '{"t":"launching"}'; continue }  # still starting: it comes to the front when joined
  $l = if (Test-Path $info) { Get-Content $info -Raw | ConvertFrom-Json }
  if (-not $l -or -not $l.exe -or -not (Test-Path $l.exe)) {
    # Never opened on this PC, or moved or removed since: the bridge's window says what to do.
    Send-Reply ('{"t":"launching","need":"zenith","moved":' + $(if ($l -and $l.exe) { 1 } else { 0 }) + '}')
    continue
  }
  Send-Reply '{"t":"launching"}'
  # Already open (its menu). launch.json keeps the pid after Zenith closes, and Windows reuses
  # pids, so the process must also be the program it names.
  $open = if ($l.pid) { Get-Process -Id $l.pid -ErrorAction SilentlyContinue }
  if ($open -and $open.Path -and ($open.Path -ieq [IO.Path]::GetFullPath($l.exe))) {
    # Open but not in this game (its menu): bring it forward so the key does something you can see.
    $null = (New-Object -ComObject WScript.Shell).AppActivate($open.Id)
    continue
  }
  $zargs = @($l.args) + @("--", "--factorio-port=$udp", "--from-factorio")
  $zenith = Start-Process -FilePath $l.exe -ArgumentList (Join-Args $zargs) -WorkingDirectory $l.dir -WindowStyle Normal -PassThru
}
$listener.Close()
