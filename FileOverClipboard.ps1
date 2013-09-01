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

    $global:a = 0

    Register-ClipboardTextChangedEvent -Action `
        {
            param
            (
                $text
            )

            Receive-ClipboardEvent $text
        } | Out-Null

    Register-EngineEvent -SourceIdentifier Receiver.Started -Action `
        {
            Write-Host "Sending file"
            Send-ClipboardEvent -Name Sender.Sent -Argument "TODO"
        } | Out-Null

    Register-EngineEvent -SourceIdentifier Receiver.Received -Action `
        {
            Write-Host "Received"
            $a++
            if ($a -eq 10)
            {
                Write-Host "Done!"
                Send-ClipboardEvent -Name Sender.Completed
            }
            else {
                Write-Host "Sending file"
                Send-ClipboardEvent -Name Sender.Sent -Argument "TODO"
            }
            
        } | Out-Null

    Send-ClipboardEvent -Name Sender.Started
    Wait-Event -SourceIdentifier Sender.Completed | Remove-Event
    Unregister-ClipboardWatcher
    Cleanup-Subscriptions
}

function Receive-FileOverClipboard
{
    Register-ClipboardTextChangedEvent -Action `
        {
            param
            (
                $text
            )

            Receive-ClipboardEvent $text
        } | Out-Null

    Register-EngineEvent -SourceIdentifier Sender.Started -Action `
        {
            Send-ClipboardEvent -Name Receiver.Started
        } | Out-Null

    Register-EngineEvent -SourceIdentifier Sender.Sent -Action `
        {
            Write-Host "Received $($Event.SourceEventArgs)"
            Send-ClipboardEvent -Name Receiver.Received
        } | Out-Null

    Register-EngineEvent -SourceIdentifier Sender.Completed -Action `
        {
            Send-ClipboardEvent -Name Receiver.Completed
        } | Out-Null

    Send-ClipboardEvent -Name Receiver.Started
    Wait-Event -SourceIdentifier Receiver.Completed | Remove-Event
    Unregister-ClipboardWatcher
    Cleanup-Subscriptions
}

function Cleanup-Subscriptions
{
    Get-Event Sender.* | Remove-Event
    Get-Event Receiver.* | Remove-Event
    Get-EventSubscriber -SourceIdentifier Sender.* | Unregister-Event
    Get-EventSubscriber -SourceIdentifier Receiver.* | Unregister-Event
    Get-Job -Name Sender.* | Remove-Job
    Get-Job -Name Receiver.* | Remove-Job
}

$Global:ClipboardEventPrefix = "===+++"

function Global:Receive-ClipboardEvent
{
    param
    (
        [string] $text
    )

    Write-Verbose "Received text: $text"

    if (-not $text)
    {
        return
    }

    $lines = $text -split "`n"

    if ($lines.Length -ne 3)
    {
        return
    }

    if (-not $lines[0].StartsWith($ClipboardEventPrefix))
    {
        return
    }

    $eventName = $lines[0].Substring($ClipboardEventPrefix.Length)
    $eventArgument = $lines[1]

    Write-Verbose "Received event $eventName with argument $eventArgument"

    New-Event -SourceIdentifier $eventName -EventArguments $eventArgument | Out-Null
}

function Global:Send-ClipboardEvent
{
    param
    (
        [string] $Name,
        [string] $Argument
    )

    Write-Verbose "Sending event $Name with argument $Argument"

    "$ClipboardEventPrefix$Name`n$Argument" | Set-ClipboardText
}

function Global:Set-ClipboardText
{
    param
    (
        [Parameter(ValueFromPipeline = $true)]
        [string] $text
    )

    $text | clip
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
        Unregister-Event -SourceIdentifier ClipboardWatcher
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
        {
            string text = "";
            for (int i = 0; i < 10; i++)
            {
                text = Clipboard.GetText();
                if (string.IsNullOrEmpty(text))
                {
                    Thread.Sleep(10);
                }
                else
                {
                    break;
                }
            }

            ClipboardTextChanged(text);
        }
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
    Register-ObjectEvent $watcher -EventName ClipboardTextChanged -Action $Action -SourceIdentifier ClipboardWatcher
}

Main