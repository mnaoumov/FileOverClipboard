#requires -version 2.0

[CmdletBinding()]
param
(
    [string] $FilePath
)

$script:ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
function PSScriptRoot { $MyInvocation.ScriptName | Split-Path }
Trap { throw $_ }

function Main
{
    if ($FilePath)
    {
        Send-FileOverClipboard $FilePath
    }
    else
    {
        Receive-FileOverClipboard
    }
}

function Send-FileOverClipboard
{
    param
    (
        [string] $FilePath
    )

    if (-not (Test-Path $FilePath))
    {
        throw "File $FilePath not exists"
    }

    Register-ClipboardTextChangedEvent -Action `
        {
            param
            (
                $text
            )

            $command = Get-ClipboardCommand $text

            Invoke-SendFileProcessor $command
        }
}

function Receive-FileOverClipboard
{
    Register-ClipboardTextChangedEvent -Action `
        {
            param
            (
                $text
            )

            $command = Get-ClipboardCommand $text

            Invoke-ReceiveFileProcessor $command
        }
}

$CommandPrefix = "===+++"

function Get-ClipboardCommand
{
    param
    (
        [string] $text
    )

    $badCommand = New-Object PSObject -Property `
        @{
            Name = $null;
            Argument = $null;
        }

    if (-not $text)
    {
        return $badCommand
    }

    $lines = $text -split "`n"

    if ($lines.Length -ne 3)
    {
        return $badCommand
    }

    if (-not $lines[0].StartsWith($CommandPrefix))
    {
        return $badCommand
    }

    return New-Object PSObject -Property `
        @{
            Name = $lines[0] -replace "^$CommandPrefix";
            Argument = $lines[1];
        }
}

function Send-ClipboardCommand
{
    param
    (
        [string] $name,
        [string] $argument
    )

    "$CommandPrefix$name`n$argument" | clip
}

function Invoke-SendFileProcessor
{
    param
    (
        $command
    )

    switch ($command.Name)
    {
        $null { return }
    }
}

function Invoke-RecieveFileProcessor
{
    param
    (
        $command
    )

    switch ($command.Name)
    {
        $null { return }
    }
}


function Register-ClipboardWatcher
{
    if (-not (Test-Path Variable:Global:ClipboardWatcher))
    {
        Register-ClipboardWatcherType
        $Global:ClipboardWatcher = New-Object ClipboardWatcher

        Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action `
        {
            Unregister-ClipboardWatcher
        }
    }

    return $Global:ClipboardWatcher
}

function Unregister-ClipboardWatcher
{
    if (Test-Path Variable:Global:ClipboardWatcher)
    {
        $Global:ClipboardWatcher.Dispose();
        Remove-Variable ClipboardWatcher -Scope Global
    }
}

function Register-ClipboardWatcherType
{
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -Language CSharpVersion3 -TypeDefinition `
@"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

public class ClipboardWatcher : IDisposable
{
    readonly Thread _formThread;
    bool _disposed;

    public ClipboardWatcher()
    {
        _formThread = new Thread(() => { new ClipboardWatcherForm(this); })
                      {
                          IsBackground = true
                      };

        _formThread.SetApartmentState(ApartmentState.STA);
        _formThread.Start();
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        Disposed();
        if (_formThread != null && _formThread.IsAlive)
            _formThread.Abort();
        _disposed = true;
        GC.SuppressFinalize(this);
    }

    ~ClipboardWatcher()
    {
        Dispose();
    }

    public event Action<string> ClipboardTextChanged = delegate { };
    public event Action Disposed = delegate { };

    public void OnClipboardTextChanged(string text)
    {
        ClipboardTextChanged(text);
    }
}

public class ClipboardWatcherForm : Form
{
    public ClipboardWatcherForm(ClipboardWatcher clipboardWatcher)
    {
        HideForm();
        RegisterWin32();
        ClipboardTextChanged += clipboardWatcher.OnClipboardTextChanged;
        clipboardWatcher.Disposed += () => InvokeIfRequired(Dispose);
        Disposed += (sender, args) => UnregisterWin32();
        Application.Run(this);
    }

    void InvokeIfRequired(Action action)
    {
        if (InvokeRequired)
            Invoke(action);
        else
            action();
    }

    public event Action<string> ClipboardTextChanged = delegate { };

    void HideForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        Load += (sender, args) => { Size = new Size(0, 0); };
    }

    void RegisterWin32()
    {
        User32.AddClipboardFormatListener(Handle);
    }

    void UnregisterWin32()
    {
        if (IsHandleCreated)
            User32.RemoveClipboardFormatListener(Handle);
    }

    protected override void WndProc(ref Message m)
    {
        switch ((WM) m.Msg)
        {
            case WM.WM_CLIPBOARDUPDATE:
                ClipboardChanged();
                break;

            default:
                base.WndProc(ref m);
                break;
        }
    }

    void ClipboardChanged()
    {
        if (Clipboard.ContainsText())
            ClipboardTextChanged(Clipboard.GetText());
    }
}

public enum WM
{
    WM_CLIPBOARDUPDATE = 0x031D
}

public class User32
{
    const string User32Dll = "User32.dll";

    [DllImport(User32Dll, CharSet = CharSet.Auto)]
    public static extern bool AddClipboardFormatListener(IntPtr hWndObserver);

    [DllImport(User32Dll, CharSet = CharSet.Auto)]
    public static extern bool RemoveClipboardFormatListener(IntPtr hWndObserver);
}
"@

}

function Register-ClipboardTextChangedEvent
{
    param
    (
        [ScriptBlock] $Action
    )

    $watcher = Register-ClipboardWatcher
    Register-ObjectEvent $watcher -EventName ClipboardTextChanged -Action $Action
}

Main