#region C# Source — RunAsUser Process Extensions
# Embedded C# type for Win32 CreateProcessAsUser.
# Compiled once per session via Add-Type. Provides:
#   [RunAsUser.ProcessExtensions]::StartProcessAsCurrentUser()
#   [RunAsUser.ProcessExtensions]::GetTokenPrivileges()
$script:CSharpSource = @"
using Microsoft.Win32.SafeHandles;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;

namespace RunAsUser
{
    internal class NativeHelpers
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct LUID
        {
            public int LowPart;
            public int HighPart;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct LUID_AND_ATTRIBUTES
        {
            public LUID Luid;
            public PrivilegeAttributes Attributes;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFO
        {
            public int cb;
            public String lpReserved;
            public String lpDesktop;
            public String lpTitle;
            public uint dwX;
            public uint dwY;
            public uint dwXSize;
            public uint dwYSize;
            public uint dwXCountChars;
            public uint dwYCountChars;
            public uint dwFillAttribute;
            public uint dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct TOKEN_PRIVILEGES
        {
            public int PrivilegeCount;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 1)]
            public LUID_AND_ATTRIBUTES[] Privileges;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct WTS_SESSION_INFO
        {
            public readonly UInt32 SessionID;
            [MarshalAs(UnmanagedType.LPWStr)]
            public readonly String pWinStationName;
            public readonly WTS_CONNECTSTATE_CLASS State;
        }
        public struct SECURITY_ATTRIBUTES
        {
            public Int32 nLength;
            public IntPtr lpSecurityDescriptor;
            public int bInheritHandle;
        }
    }
    internal class NativeMethods
    {
        [DllImport("kernel32", SetLastError = true)]
        public static extern int WaitForSingleObject(
          IntPtr hHandle,
          int dwMilliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(
            IntPtr hSnapshot);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateProcess(
            IntPtr hProcess,
            uint uExitCode);
        [DllImport("userenv.dll", SetLastError = true)]
        public static extern bool CreateEnvironmentBlock(
            ref IntPtr lpEnvironment,
            SafeHandle hToken,
            bool bInherit);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcessAsUserW(
            SafeHandle hToken,
            String lpApplicationName,
            StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes,
            IntPtr lpThreadAttributes,
            bool bInheritHandle,
            uint dwCreationFlags,
            IntPtr lpEnvironment,
            String lpCurrentDirectory,
            ref NativeHelpers.STARTUPINFO lpStartupInfo,
            out NativeHelpers.PROCESS_INFORMATION lpProcessInformation);
        [DllImport("userenv.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DestroyEnvironmentBlock(
            IntPtr lpEnvironment);
        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool DuplicateTokenEx(
            SafeHandle ExistingTokenHandle,
            uint dwDesiredAccess,
            IntPtr lpThreadAttributes,
            SECURITY_IMPERSONATION_LEVEL ImpersonationLevel,
            TOKEN_TYPE TokenType,
            out SafeNativeHandle DuplicateTokenHandle);
        [DllImport("kernel32")]
        public static extern IntPtr GetCurrentProcess();
        // Bug #4 fix: SafeHandle overload for actual data retrieval
        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool GetTokenInformation(
            SafeHandle TokenHandle,
            uint TokenInformationClass,
            SafeMemoryBuffer TokenInformation,
            int TokenInformationLength,
            out int ReturnLength);
        // Bug #4 fix: IntPtr overload for buffer-size query (avoids SafeHandle invalid-zero crash)
        [DllImport("advapi32.dll", EntryPoint = "GetTokenInformation", SetLastError = true)]
        public static extern bool GetTokenInformationRaw(
            SafeHandle TokenHandle,
            uint TokenInformationClass,
            IntPtr TokenInformation,
            int TokenInformationLength,
            out int ReturnLength);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool LookupPrivilegeName(
            string lpSystemName,
            ref NativeHelpers.LUID lpLuid,
            StringBuilder lpName,
            ref Int32 cchName);
        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool OpenProcessToken(
            IntPtr ProcessHandle,
            TokenAccessLevels DesiredAccess,
            out SafeNativeHandle TokenHandle);
        [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool WTSEnumerateSessions(
            IntPtr hServer,
            int Reserved,
            int Version,
            ref IntPtr ppSessionInfo,
            ref int pCount);
        [DllImport("wtsapi32.dll")]
        public static extern void WTSFreeMemory(
            IntPtr pMemory);
        [DllImport("kernel32.dll")]
        public static extern uint WTSGetActiveConsoleSessionId();
        [DllImport("Wtsapi32.dll", SetLastError = true)]
        public static extern bool WTSQueryUserToken(
            uint SessionId,
            out SafeNativeHandle phToken);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr CreatePipe(
            ref IntPtr hReadPipe,
            ref IntPtr hWritePipe,
            ref NativeHelpers.SECURITY_ATTRIBUTES lpPipeAttributes,
            Int32 nSize);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetHandleInformation(
            IntPtr hObject,
            int dwMask,
            int dwFlags);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool ReadFile(
            IntPtr hFile,
            byte[] lpBuffer,
            int nNumberOfBytesToRead,
            ref int lpNumberOfBytesRead,
            IntPtr lpOverlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool PeekNamedPipe(
            IntPtr handle,
            byte[] buffer,
            uint nBufferSize,
            ref uint bytesRead,
            ref uint bytesAvail,
            ref uint BytesLeftThisMessage);
    }
    internal class SafeMemoryBuffer : SafeHandleZeroOrMinusOneIsInvalid
    {
        public SafeMemoryBuffer(int cb) : base(true)
        {
            base.SetHandle(Marshal.AllocHGlobal(cb));
        }
        public SafeMemoryBuffer(IntPtr handle) : base(true)
        {
            base.SetHandle(handle);
        }
        protected override bool ReleaseHandle()
        {
            Marshal.FreeHGlobal(handle);
            return true;
        }
    }
    internal class SafeNativeHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public SafeNativeHandle() : base(true) { }
        public SafeNativeHandle(IntPtr handle) : base(true) { this.handle = handle; }
        protected override bool ReleaseHandle()
        {
            return NativeMethods.CloseHandle(handle);
        }
    }
    internal enum SECURITY_IMPERSONATION_LEVEL
    {
        SecurityAnonymous = 0,
        SecurityIdentification = 1,
        SecurityImpersonation = 2,
        SecurityDelegation = 3,
    }
    internal enum SW
    {
        SW_HIDE = 0,
        SW_SHOWNORMAL = 1,
        SW_NORMAL = 1,
        SW_SHOWMINIMIZED = 2,
        SW_SHOWMAXIMIZED = 3,
        SW_MAXIMIZE = 3,
        SW_SHOWNOACTIVATE = 4,
        SW_SHOW = 5,
        SW_MINIMIZE = 6,
        SW_SHOWMINNOACTIVE = 7,
        SW_SHOWNA = 8,
        SW_RESTORE = 9,
        SW_SHOWDEFAULT = 10,
        SW_MAX = 10
    }
    internal enum TokenElevationType
    {
        TokenElevationTypeDefault = 1,
        TokenElevationTypeFull,
        TokenElevationTypeLimited,
    }
    internal enum TOKEN_TYPE
    {
        TokenPrimary = 1,
        TokenImpersonation = 2
    }
    internal enum WTS_CONNECTSTATE_CLASS
    {
        WTSActive,
        WTSConnected,
        WTSConnectQuery,
        WTSShadow,
        WTSDisconnected,
        WTSIdle,
        WTSListen,
        WTSReset,
        WTSDown,
        WTSInit
    }
    [Flags]
    public enum PrivilegeAttributes : uint
    {
        Disabled = 0x00000000,
        EnabledByDefault = 0x00000001,
        Enabled = 0x00000002,
        Removed = 0x00000004,
        UsedForAccess = 0x80000000,
    }
    public class Win32Exception : System.ComponentModel.Win32Exception
    {
        private string _msg;
        public Win32Exception(string message) : this(Marshal.GetLastWin32Error(), message) { }
        public Win32Exception(int errorCode, string message) : base(errorCode)
        {
            _msg = String.Format("{0} ({1}, Win32ErrorCode {2} - 0x{2:X8})", message, base.Message, errorCode);
        }
        public override string Message { get { return _msg; } }
        public static explicit operator Win32Exception(string message) { return new Win32Exception(message); }
    }
    public static class ProcessExtensions
    {
        #region Win32 Constants
        private const int CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        private const int CREATE_NO_WINDOW = 0x08000000;
        private const int CREATE_NEW_CONSOLE = 0x00000010;
        private const uint INVALID_SESSION_ID = 0xFFFFFFFF;
        private static readonly IntPtr WTS_CURRENT_SERVER_HANDLE = IntPtr.Zero;
        private const int HANDLE_FLAG_INHERIT = 0x00000001;
        private const int STARTF_USESTDHANDLES = 0x00000100;
        private const int CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
        private const int BUFSIZE = 4096;
        private const int WAIT_TIMEOUT = 0x00000102;
        #endregion
        private static SafeNativeHandle GetSessionUserToken(bool elevated)
        {
            var activeSessionId = INVALID_SESSION_ID;
            var pSessionInfo = IntPtr.Zero;
            var sessionCount = 0;
            if (NativeMethods.WTSEnumerateSessions(WTS_CURRENT_SERVER_HANDLE, 0, 1, ref pSessionInfo, ref sessionCount))
            {
                try
                {
                    var arrayElementSize = Marshal.SizeOf(typeof(NativeHelpers.WTS_SESSION_INFO));
                    var current = pSessionInfo;
                    for (var i = 0; i < sessionCount; i++)
                    {
                        var si = (NativeHelpers.WTS_SESSION_INFO)Marshal.PtrToStructure(
                            current, typeof(NativeHelpers.WTS_SESSION_INFO));
                        current = IntPtr.Add(current, arrayElementSize);
                        if (si.State == WTS_CONNECTSTATE_CLASS.WTSActive)
                        {
                            activeSessionId = si.SessionID;
                            break;
                        }
                    }
                }
                finally
                {
                    NativeMethods.WTSFreeMemory(pSessionInfo);
                }
            }
            if (activeSessionId == INVALID_SESSION_ID)
            {
                activeSessionId = NativeMethods.WTSGetActiveConsoleSessionId();
            }
            SafeNativeHandle hImpersonationToken;
            if (!NativeMethods.WTSQueryUserToken(activeSessionId, out hImpersonationToken))
            {
                throw new Win32Exception("WTSQueryUserToken failed to get access token.");
            }
            using (hImpersonationToken)
            {
                TokenElevationType elevationType = GetTokenElevationType(hImpersonationToken);
                if (elevationType == TokenElevationType.TokenElevationTypeLimited && elevated == true)
                {
                    using (var linkedToken = GetTokenLinkedToken(hImpersonationToken))
                        return DuplicateTokenAsPrimary(linkedToken);
                }
                else
                {
                    return DuplicateTokenAsPrimary(hImpersonationToken);
                }
            }
        }
        // Pipe handles are method-local (thread-safe), stderr merged into stdout.
        public static string StartProcessAsCurrentUser(string appPath, string cmdLine = null, string workDir = null, bool visible = true, int wait = -1, bool elevated = true, bool redirectOutput = true, bool breakaway = false)
        {
            IntPtr out_read = IntPtr.Zero;
            IntPtr out_write = IntPtr.Zero;

            // R2-Bug #3 fix: master try/finally so pipe handles are cleaned up
            // even if GetSessionUserToken or CreateEnvironmentBlock throws
            try
            {
                NativeHelpers.SECURITY_ATTRIBUTES saAttr = new NativeHelpers.SECURITY_ATTRIBUTES();
                saAttr.nLength = Marshal.SizeOf(typeof(NativeHelpers.SECURITY_ATTRIBUTES));
                saAttr.bInheritHandle = 0x1;
                saAttr.lpSecurityDescriptor = IntPtr.Zero;
                if (redirectOutput)
                {
                    NativeMethods.CreatePipe(ref out_read, ref out_write, ref saAttr, 0);
                    NativeMethods.SetHandleInformation(out_read, HANDLE_FLAG_INHERIT, 0);
                }
                var startInfo = new NativeHelpers.STARTUPINFO();
                startInfo.cb = Marshal.SizeOf(startInfo);
                // Map process to the interactive user's desktop.
                // Previous ERROR_INVALID_NAME was caused by ANSI/Unicode marshaling
                // mismatch (STARTUPINFO lacked CharSet.Unicode). Now fixed.
                startInfo.lpDesktop = @"winsta0\default";
                uint dwCreationFlags = CREATE_UNICODE_ENVIRONMENT | (uint)(breakaway ? CREATE_BREAKAWAY_FROM_JOB : 0) | (uint)(visible ? CREATE_NEW_CONSOLE : CREATE_NO_WINDOW);
                // STARTF_USESHOWWINDOW so wShowWindow is respected by the API
                startInfo.dwFlags = 0x00000001;
                startInfo.wShowWindow = (short)(visible ? SW.SW_SHOW : SW.SW_HIDE);
                if (redirectOutput)
                {
                    startInfo.hStdOutput = out_write;
                    startInfo.hStdError = out_write;
                    startInfo.dwFlags |= (uint)STARTF_USESTDHANDLES;
                }
                StringBuilder commandLine = new StringBuilder(cmdLine);
                var procInfo = new NativeHelpers.PROCESS_INFORMATION();
                using (var hUserToken = GetSessionUserToken(elevated))
                {
                    IntPtr pEnv = IntPtr.Zero;
                    if (!NativeMethods.CreateEnvironmentBlock(ref pEnv, hUserToken, false))
                    {
                        throw new Win32Exception("CreateEnvironmentBlock failed.");
                    }
                    try
                    {
                        if (!NativeMethods.CreateProcessAsUserW(hUserToken,
                            appPath,
                            commandLine,
                            IntPtr.Zero,
                            IntPtr.Zero,
                            redirectOutput,
                            dwCreationFlags,
                            pEnv,
                            workDir,
                            ref startInfo,
                            out procInfo))
                        {
                            throw new Win32Exception("CreateProcessAsUser failed.");
                        }
                        try
                        {
                            if (redirectOutput)
                            {
                                // Close parent's write handle so ReadFile sees EOF
                                NativeMethods.CloseHandle(out_write);
                                out_write = IntPtr.Zero;

                                // R2-Bug #2 fix: read pipe on a background thread so the
                                // main thread can enforce the timeout via WaitForSingleObject.
                                // If the child hangs, ReadFile blocks the reader thread but
                                // WaitForSingleObject returns WAIT_TIMEOUT on the main thread,
                                // which then kills the child, breaking the pipe and unblocking
                                // the reader.
                                var sb = new StringBuilder();
                                var readDone = new ManualResetEvent(false);
                                // Capture out_read in a local for the closure
                                IntPtr pipeHandle = out_read;
                                ThreadPool.QueueUserWorkItem(delegate
                                {
                                    try
                                    {
                                        byte[] buf = new byte[BUFSIZE];
                                        // R2-Bug #5 fix: Decoder maintains state across chunks
                                        // so multi-byte UTF-8 chars split at buffer boundaries
                                        // are decoded correctly instead of producing \uFFFD.
                                        Decoder decoder = Encoding.UTF8.GetDecoder();
                                        int dwRead = 0;
                                        while (true)
                                        {
                                            uint bytesRead = 0;
                                            uint bytesAvail = 0;
                                            uint bytesLeft = 0;
                                            bool bPeek = NativeMethods.PeekNamedPipe(pipeHandle, null, 0, ref bytesRead, ref bytesAvail, ref bytesLeft);
                                            if (!bPeek)
                                                break;
                                            if (bytesAvail == 0)
                                            {
                                                Thread.Sleep(50);
                                                continue;
                                            }
                                            bool bSuccess = NativeMethods.ReadFile(pipeHandle, buf, BUFSIZE, ref dwRead, IntPtr.Zero);
                                            if (!bSuccess || dwRead == 0)
                                                break;
                                            int charCount = decoder.GetCharCount(buf, 0, dwRead);
                                            char[] chars = new char[charCount];
                                            decoder.GetChars(buf, 0, dwRead, chars, 0);
                                            sb.Append(chars, 0, charCount);
                                        }
                                    }
                                    catch { /* pipe broken = expected on timeout kill */ }
                                    finally { readDone.Set(); }
                                });

                                // Main thread: enforce the timeout
                                int waitResult = NativeMethods.WaitForSingleObject(procInfo.hProcess, wait);
                                if (waitResult == WAIT_TIMEOUT)
                                {
                                    // Kill the hung process — this breaks the pipe,
                                    // unblocking the reader thread's ReadFile call
                                    NativeMethods.TerminateProcess(procInfo.hProcess, 1);
                                }
                                // Wait for the reader thread to finish (give it 5s after process exit)
                                readDone.WaitOne(5000);

                                NativeMethods.CloseHandle(out_read);
                                out_read = IntPtr.Zero;

                                return sb.ToString();
                            }
                            else
                            {
                                int waitResult = NativeMethods.WaitForSingleObject(procInfo.hProcess, wait);
                                if (waitResult == WAIT_TIMEOUT)
                                {
                                    NativeMethods.TerminateProcess(procInfo.hProcess, 1);
                                }
                                return procInfo.dwProcessId.ToString();
                            }
                        }
                        finally
                        {
                            NativeMethods.CloseHandle(procInfo.hThread);
                            NativeMethods.CloseHandle(procInfo.hProcess);
                        }
                    }
                    finally
                    {
                        NativeMethods.DestroyEnvironmentBlock(pEnv);
                    }
                }
            }
            finally
            {
                // Master cleanup: handles are closed regardless of where the exception was thrown
                if (out_read != IntPtr.Zero) NativeMethods.CloseHandle(out_read);
                if (out_write != IntPtr.Zero) NativeMethods.CloseHandle(out_write);
            }
        }
        private static SafeNativeHandle DuplicateTokenAsPrimary(SafeHandle hToken)
        {
            SafeNativeHandle pDupToken;
            if (!NativeMethods.DuplicateTokenEx(hToken, 0, IntPtr.Zero, SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation,
                TOKEN_TYPE.TokenPrimary, out pDupToken))
            {
                throw new Win32Exception("DuplicateTokenEx failed.");
            }
            return pDupToken;
        }
        public static Dictionary<String, PrivilegeAttributes> GetTokenPrivileges()
        {
            Dictionary<string, PrivilegeAttributes> privileges = new Dictionary<string, PrivilegeAttributes>();
            using (SafeNativeHandle hToken = OpenProcessToken(NativeMethods.GetCurrentProcess(), TokenAccessLevels.Query))
            using (SafeMemoryBuffer tokenInfo = GetTokenInformation(hToken, 3))
            {
                NativeHelpers.TOKEN_PRIVILEGES privilegeInfo = (NativeHelpers.TOKEN_PRIVILEGES)Marshal.PtrToStructure(
                    tokenInfo.DangerousGetHandle(), typeof(NativeHelpers.TOKEN_PRIVILEGES));
                IntPtr ptrOffset = IntPtr.Add(tokenInfo.DangerousGetHandle(), Marshal.SizeOf(privilegeInfo.PrivilegeCount));
                for (int i = 0; i < privilegeInfo.PrivilegeCount; i++)
                {
                    NativeHelpers.LUID_AND_ATTRIBUTES info = (NativeHelpers.LUID_AND_ATTRIBUTES)Marshal.PtrToStructure(ptrOffset,
                        typeof(NativeHelpers.LUID_AND_ATTRIBUTES));
                    int nameLen = 0;
                    NativeHelpers.LUID privLuid = info.Luid;
                    NativeMethods.LookupPrivilegeName(null, ref privLuid, null, ref nameLen);
                    StringBuilder name = new StringBuilder(nameLen + 1);
                    if (!NativeMethods.LookupPrivilegeName(null, ref privLuid, name, ref nameLen))
                    {
                        throw new Win32Exception("LookupPrivilegeName() failed");
                    }
                    privileges[name.ToString()] = info.Attributes;
                    ptrOffset = IntPtr.Add(ptrOffset, Marshal.SizeOf(typeof(NativeHelpers.LUID_AND_ATTRIBUTES)));
                }
            }
            return privileges;
        }
        private static TokenElevationType GetTokenElevationType(SafeHandle hToken)
        {
            using (SafeMemoryBuffer tokenInfo = GetTokenInformation(hToken, 18))
            {
                return (TokenElevationType)Marshal.ReadInt32(tokenInfo.DangerousGetHandle());
            }
        }
        private static SafeNativeHandle GetTokenLinkedToken(SafeHandle hToken)
        {
            using (SafeMemoryBuffer tokenInfo = GetTokenInformation(hToken, 19))
            {
                return new SafeNativeHandle(Marshal.ReadIntPtr(tokenInfo.DangerousGetHandle()));
            }
        }
        // Bug #4 fix: use IntPtr.Zero directly for buffer-size probe instead of
        // new SafeMemoryBuffer(IntPtr.Zero) which throws ArgumentException
        private static SafeMemoryBuffer GetTokenInformation(SafeHandle hToken, uint infoClass)
        {
            int returnLength;
            bool res = NativeMethods.GetTokenInformationRaw(hToken, infoClass, IntPtr.Zero, 0,
                out returnLength);
            int errCode = Marshal.GetLastWin32Error();
            if (!res && errCode != 24 && errCode != 122)
            {
                throw new Win32Exception(errCode, String.Format("GetTokenInformation({0}) failed to get buffer length", infoClass));
            }
            SafeMemoryBuffer tokenInfo = new SafeMemoryBuffer(returnLength);
            if (!NativeMethods.GetTokenInformation(hToken, infoClass, tokenInfo, returnLength, out returnLength))
                throw new Win32Exception(String.Format("GetTokenInformation({0}) failed", infoClass));
            return tokenInfo;
        }
        private static SafeNativeHandle OpenProcessToken(IntPtr process, TokenAccessLevels access)
        {
            SafeNativeHandle hToken = null;
            if (!NativeMethods.OpenProcessToken(process, access, out hToken))
            {
                throw new Win32Exception("OpenProcessToken() failed");
            }
            return hToken;
        }
    }
}
"@
#endregion

#region Module State
$script:IndagoState = @{
    ModuleRoot       = $PSScriptRoot
    ScriptletCatalog = $null
    LogPath          = $null
    LoggedOnUser     = $null
    TypeLoaded       = $false
}
#endregion

#region C# Type Compilation
if (-not ('RunAsUser.ProcessExtensions' -as [type])) {
    try {
        Add-Type -TypeDefinition $script:CSharpSource -Language CSharp -ErrorAction Stop
        $script:IndagoState.TypeLoaded = $true
        Write-Verbose 'Indago: C# ProcessExtensions type compiled successfully.'
    }
    catch {
        Write-Warning "Indago: Failed to compile C# type. User-context tasks will not be available. Error: $($_.Exception.Message)"
    }
}
else {
    $script:IndagoState.TypeLoaded = $true
    Write-Verbose 'Indago: C# ProcessExtensions type already loaded.'
}
#endregion

#region Resolve Log Path
$logDir = Join-Path -Path 'C:\ProgramData\Indago' -ChildPath 'Logs'
if (-not (Test-Path -Path $logDir)) {
    try {
        $null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction Stop
    }
    catch {
        # Fall back to Windows temp if ProgramData is somehow unavailable
        $logDir = Join-Path -Path $env:SystemRoot -ChildPath 'Temp'
    }
}
$script:IndagoState.LogPath = $logDir
#endregion

#region Dot-Source Private and Public Functions
$privatePath = Join-Path -Path $PSScriptRoot -ChildPath 'Private'
if (Test-Path -Path $privatePath) {
    foreach ($file in Get-ChildItem -Path $privatePath -Filter '*.ps1') {
        . $file.FullName
    }
}

$publicPath = Join-Path -Path $PSScriptRoot -ChildPath 'Public'
if (Test-Path -Path $publicPath) {
    foreach ($file in Get-ChildItem -Path $publicPath -Filter '*.ps1') {
        . $file.FullName
    }
}
#endregion

#region Load Scriptlet Catalog on Import
# Bug #10 fix: use the validation function instead of raw ConvertFrom-Json
$script:IndagoState.ScriptletCatalog = Import-ScriptletCatalog
if (@($script:IndagoState.ScriptletCatalog).Count -gt 0) {
    Write-Verbose "Indago: Loaded $(@($script:IndagoState.ScriptletCatalog).Count) validated scriptlets from catalog."
}
else {
    Write-Warning 'Indago: No valid scriptlets loaded. Check the catalog file and run Invoke-SelfTest.'
}
#endregion

Export-ModuleMember -Function 'Invoke-Indago', 'Get-IndagoList', 'Get-IndagoHelp', 'Get-LoggedOnUser'
