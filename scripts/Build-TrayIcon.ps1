#requires -Version 7.2
param(
    [Parameter(Mandatory)] [string] $BrowserPath
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $BrowserPath)) { throw "Chromium browser not found: $BrowserPath" }
$directory = Join-Path ([IO.Path]::GetTempPath()) "AwakeMate-icon-$([guid]::NewGuid().ToString('N'))"
$null = [IO.Directory]::CreateDirectory($directory)
try {
    [xml] $svg = Get-Content (Join-Path $PSScriptRoot '..\awakemate.svg') -Raw
    $svg.DocumentElement.SetAttribute('viewBox', '350 90 860 570')
    $svg.DocumentElement.SetAttribute('width', '256')
    $svg.DocumentElement.SetAttribute('height', '256')
    $html = Join-Path $directory 'icon.html'
    [IO.File]::WriteAllText($html, "<html><body style='margin:0;width:256px;height:256px'>$($svg.OuterXml)</body></html>")
    $png = Join-Path $directory 'icon.png'
    $profile = Join-Path $directory 'profile'
    $arguments = "--headless --disable-gpu --no-first-run --hide-scrollbars --user-data-dir=`"$profile`" --screenshot=`"$png`" --window-size=256,256 `"$( [uri]::new($html).AbsoluteUri )`""
    $process = Start-Process $BrowserPath -ArgumentList $arguments -PassThru
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($png)) {
        if ($timer.Elapsed.TotalSeconds -ge 30) { throw 'SVG rendering timed out.' }
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 500
    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::new($png)
    try {
        if ($bitmap.Width -ne 256 -or $bitmap.Height -ne 256) { throw 'Expected a 256x256 rendered icon.' }
        $colored = 0
        for ($y = 0; $y -lt 256; $y += 4) {
            for ($x = 0; $x -lt 256; $x += 4) {
                $pixel = $bitmap.GetPixel($x, $y)
                if ($pixel.R -lt 240 -or $pixel.G -lt 240 -or $pixel.B -lt 240) { $colored++ }
            }
        }
        if ($colored -lt 100) { throw 'Rendered SVG appears empty.' }
    }
    finally { $bitmap.Dispose() }
    $bytes = [IO.File]::ReadAllBytes($png)
    $stream = [IO.File]::Create((Join-Path $PSScriptRoot 'awakemate.ico'))
    $writer = [IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([uint16] 0)
        $writer.Write([uint16] 1)
        $writer.Write([uint16] 1)
        $writer.Write([byte[]] @(0, 0, 0, 0))
        $writer.Write([uint16] 1)
        $writer.Write([uint16] 32)
        $writer.Write([uint32] $bytes.Length)
        $writer.Write([uint32] 22)
        $writer.Write($bytes)
    }
    finally { $writer.Dispose() }
}
finally {
    $renderers = Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe' OR Name = 'chrome-headless-shell.exe' OR Name = 'chrome.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($directory) }
    foreach ($renderer in $renderers) {
        $running = Get-Process -Id $renderer.ProcessId -ErrorAction Ignore
        if ($running) {
            Stop-Process -Id $renderer.ProcessId
            $null = $running.WaitForExit(5000)
        }
    }
    Remove-Item -LiteralPath $directory -Recurse -Force
}
