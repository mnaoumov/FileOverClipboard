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

    $FilePath = Resolve-PathSafe $FilePath

    $Global:FileName = (Get-Item -Path $FilePath).Name
    $Global:ChunksCount = [Math]::Ceiling((Get-Item -Path $FilePath).Length / $BufferSize)
    $Global:CurrentChunk = 0
    $Global:FileReader = [System.IO.File]::OpenRead($FilePath)
    $Global:Party = "Sender"
    $Global:MessageIndex = 0

    Register-ClipboardTextChangedEvent -Action `
        {
            param
            (
                $text
            )

            write-host "text: $text"

            Receive-ClipboardEvent $text
        } | Out-Null

    Register-EngineEvent -SourceIdentifier Receiver.Started -Action `
        {
            Write-Progress -Activity "Sending file $FileName" -Status Starting
            Send-ClipboardEvent -Name Sender.HeaderSent -Argument ("$FileName", "$ChunksCount" -join $Delimiter)
        } | Out-Null

    Register-EngineEvent -SourceIdentifier Receiver.Received -Action `
        {
            $CurrentChunk++
            if ($CurrentChunk -gt $ChunksCount)
            {
                $FileReader.Dispose()
                Send-ClipboardEvent -Name Sender.Completed
            }
            else
            {
                Write-Progress -Activity "Sending file $FileName" -Status "Sending chunk $CurrentChunk of $ChunksCount" -PercentComplete ($CurrentChunk / $ChunksCount * 100)
                $buffer = New-Object byte[] $BufferSize
                $bytesRead = $FileReader.Read($buffer, 0, $BufferSize);
                $base64 = [Convert]::ToBase64String($buffer, 0, $bytesRead)
                Send-ClipboardEvent -Name Sender.Sent -Argument $base64
            }
        } | Out-Null

    Send-ClipboardEvent -Name Sender.Started
    Wait-Event -SourceIdentifier Sender.Completed | Remove-Event
    $MessageIndex = [int]::MaxValue
    Unregister-ClipboardWatcher
    Cleanup-Subscriptions
    $FileReader.Dispose()
}

function Receive-FileOverClipboard
{
    $Global:CurrentChunk = 0
    $Global:Party = "Receiver"
    $Global:MessageIndex = -1

    Register-ClipboardTextChangedEvent -Action `
        {
            param
            (
                $text
            )

            write-host "text: $text"

            Receive-ClipboardEvent $text
        } | Out-Null

    Register-EngineEvent -SourceIdentifier Sender.Started -Action `
        {
            Send-ClipboardEvent -Name Receiver.Started
        } | Out-Null

    Register-EngineEvent -SourceIdentifier Sender.HeaderSent -Action `
        {
            $headers = $Event.SourceArgs -split $Delimiter
            $Global:FileName = $headers[0]
            $Global:ChunksCount = [int] $headers[1]
            $Global:FileWriter = [System.IO.File]::OpenWrite((Resolve-PathSafe $FileName))
            Write-Progress -Activity "Receiving file $FileName" -Status Starting
            Send-ClipboardEvent -Name Receiver.Received
        } | Out-Null


    Register-EngineEvent -SourceIdentifier Sender.Sent -Action `
        {
            $CurrentChunk++
            Write-Progress -Activity "Receiving file $FileName" -Status "Receiving chunk $CurrentChunk of $ChunksCount" -PercentComplete ($CurrentChunk / $ChunksCount * 100)
            $base64 = $Event.SourceArgs
            $bytes = [Convert]::FromBase64String($base64);
            $FileWriter.Write($bytes, 0, $bytes.Length);
            Send-ClipboardEvent -Name Receiver.Received -Argument $base64
        } | Out-Null

    Register-EngineEvent -SourceIdentifier Sender.Completed -Action `
        {
            $FileWriter.Dispose()
            Send-ClipboardEvent -Name Receiver.Completed
        } | Out-Null

    Wait-Event -SourceIdentifier Receiver.Completed | Remove-Event
    $MessageIndex = [int]::MaxValue
    Unregister-ClipboardWatcher
    Cleanup-Subscriptions
}

function Global:Resolve-PathSafe
{
    param
    (
        [string] $Path
    )
     
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
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

$Global:Delimiter = "===Delimiter==="
$Global:BufferSize = 9000

function Global:Receive-ClipboardEvent
{
    param
    (
        [string] $text
    )

    if (-not $text -or ($text -notlike "$Delimiter*"))
    {
        return
    }

    $lines = $text -split "`n"

    $eventMessageIndex = [int] $lines[1]
    $eventParty = $lines[2]
    $eventName = $lines[3]
    $eventArgument = $lines[4]

    if ($eventParty -eq $Party)
    {
        return
    }

    if ($MessageIndex -ge $eventMessageIndex)
    {
        return
    }

    Write-Verbose "Received event $eventName"
    $Global:MessageIndex = $eventMessageIndex + 1
    New-Event -SourceIdentifier Clipboard.MessageDelivered | Out-Null
    New-Event -SourceIdentifier $eventName -EventArguments $eventArgument | Out-Null
}

function Global:Send-ClipboardEvent
{
    param
    (
        [string] $Name,
        [string] $Argument
    )

    $index = $MessageIndex

    Write-Verbose "Sending event $index - $Name"

    $text = @($Delimiter, $index, $Party, $Name, $Argument) -join "`n"

    do
    {
        write-host "sending $index"
        $text | Set-ClipboardText
        Wait-Event Clipboard.MessageDelivered -Timeout 5 | Remove-Event
        write-host "MessageIndex $MessageIndex"
    }
    while ($MessageIndex -le $index)
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