param(
    [string]$Out = "$PSScriptRoot\..\target\settings-shot.png",
    [string]$Tab = ""
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$exe = Join-Path $PSScriptRoot '..\target\debug\chatput.exe'
$env:CHATPUT_OPEN_SETTINGS = '1'

Get-Process chatput -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

$p = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 2

$sig = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Win {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type $sig

$hwnd = [Win]::FindWindow('ChatputSettings', $null)
if ($hwnd -eq [IntPtr]::Zero) { Write-Error 'settings window not found'; $p | Stop-Process -Force; exit 1 }
[Win]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 300

$r = New-Object Win+RECT
[Win]::GetWindowRect($hwnd, [ref]$r) | Out-Null
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Host "saved $Out ($w x $h)"
Stop-Process -Id $p.Id -Force
