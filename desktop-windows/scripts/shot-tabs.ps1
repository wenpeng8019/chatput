$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$sig = @'
using System;
using System.Runtime.InteropServices;
public class TabShot {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr c, string cls, string win);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
'@
Add-Type $sig

$p = Get-Process chatput | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Error 'app not running'; exit 1 }
$hwnd = $p.MainWindowHandle
$tab = [TabShot]::FindWindowEx($hwnd, [IntPtr]::Zero, 'SysTabControl32', $null)

$TCM_GETITEMRECT = 0x130A

for ($i = 0; $i -lt 5; $i++) {
  [TabShot]::SetForegroundWindow($hwnd) | Out-Null
  $sz = [System.Runtime.InteropServices.Marshal]::SizeOf([type][TabShot+RECT])
  $ptr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($sz)
  [TabShot]::SendMessage($tab, $TCM_GETITEMRECT, [IntPtr]$i, $ptr) | Out-Null
  $rc = [System.Runtime.InteropServices.Marshal]::PtrToStructure($ptr, [type][TabShot+RECT])
  [System.Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)
  $cx = [int](($rc.Left + $rc.Right) / 2)
  $cy = [int](($rc.Top + $rc.Bottom) / 2)
  $pt = New-Object TabShot+POINT; $pt.X = $cx; $pt.Y = $cy
  [TabShot]::ClientToScreen($tab, [ref]$pt) | Out-Null
  [TabShot]::SetCursorPos($pt.X, $pt.Y) | Out-Null
  Start-Sleep -Milliseconds 80
  [TabShot]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
  [TabShot]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 350

  $r = New-Object TabShot+RECT
  [TabShot]::GetWindowRect($hwnd, [ref]$r) | Out-Null
  $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
  $out = Join-Path $PSScriptRoot "..\target\tab$i.png"
  $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  Write-Host "saved tab$i ($w x $h)"
}
