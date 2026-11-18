<#
.SYNOPSIS
    Aigo AGS21 (S21): back up the important stock partitions and install OpenWrt
    from Windows over UART and Ethernet.

.DESCRIPTION
    Drives the router from stock firmware to a working OpenWrt by itself:

      1. Loads the OpenWrt U-Boot into RAM over UART with mtk_uartboot (the generic
         MT7981 DDR4 RAM BL2 plus the AGS21 bl31-uboot FIP). Nothing is written to
         flash before the backup is on the PC.
      2. The OpenWrt U-Boot picks up the initramfs-recovery image over TFTP from the
         PC on its own (default environment, boot_tftp_forever), so the router runs
         an OpenWrt initramfs completely from RAM.
      3. Over SSH every important stock partition is copied to the PC and checked
         with sha256: the raw 5 MiB at sector 0 (GPT, BL2 area, u-boot-env, factory
         with the MACs and Wi-Fi calibration), the BL2 boot partition, the stock FIP,
         kernel and rootfs. The 56 GiB permanent_config data partition is NOT backed
         up - it holds only user files and is not touched by the install anyway.
      4. After confirmation the OpenWrt GPT is written, then BL2 (to the eMMC boot
         partition), the bl31-uboot FIP and the sysupgrade FIT (to the production
         volume). Every write is read back and verified with md5, then the router
         reboots into OpenWrt.

    Backup mode runs steps 1-3 and reboots the router into the stock firmware.
    Restore mode boots the initramfs the same way and writes the stock partitions
    back from a backup made earlier. permanent_config is never written, so the
    user files survive both install and restore (the stock firmware may reformat
    it on the first boot after a restore).

.PARAMETER Mode
    Install (default), Backup or Restore.
.PARAMETER Lang
    en or ru: language of the messages. Asked interactively when not given.
.PARAMETER ComPort
    COM port of the USB-UART adapter (COM3 etc.). Picked from a list when not given.
.PARAMETER Firmware
    Your own sysupgrade.itb instead of firmware\...-squashfs-sysupgrade.itb.
    Must be built for aigo,ags21 (mediatek/filogic).
.PARAMETER BackupDir
    Install/Backup: where to put the backup (default backup\<date-time>).
    Restore: folder with an earlier backup.
.EXAMPLE
    .\ags21-flash.ps1 -ComPort COM3
.EXAMPLE
    .\ags21-flash.ps1 -Mode Backup -Lang ru
.EXAMPLE
    .\ags21-flash.ps1 -Mode Restore -BackupDir .\backup\20261118-210000
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Backup', 'Restore')]
    [string]$Mode = 'Install',
    [ValidateSet('', 'en', 'ru')]
    [string]$Lang = '',
    [string]$ComPort = '',
    [string]$Firmware = '',
    [string]$BackupDir = '',
    [string]$PcIp = '192.168.1.254',
    [string]$RouterIp = '192.168.1.1',
    [switch]$SkipNetworkSetup,
    [switch]$Yes,
    [int]$TftpPort = 69,
    # for tests without hardware
    [string]$SshExe = '',
    [int]$TimeScale = 1
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:Tftp = $null
$script:FwRule = $null
$script:NetUndo = $null

$Root = $PSScriptRoot
$FwDir = Join-Path $Root 'firmware'

$UbootTftpFile = 'openwrt-mediatek-filogic-aigo_ags21-initramfs-recovery.itb'
$Files = @{
    RamBl2     = 'mt7981-ram-ddr4-bl2.bin'
    Preloader  = 'openwrt-mediatek-filogic-aigo_ags21-emmc-preloader.bin'
    Fip        = 'openwrt-mediatek-filogic-aigo_ags21-emmc-bl31-uboot.fip'
    Gpt        = 'openwrt-mediatek-filogic-aigo_ags21-emmc-gpt.bin'
    Recovery   = $UbootTftpFile
    Sysupgrade = 'openwrt-mediatek-filogic-aigo_ags21-squashfs-sysupgrade.itb'
}

# eMMC layout in 512-byte sectors: stock GPT (backup/restore) and OpenWrt GPT (install)
$Layout = @{
    GptSectors     = 34        # primary GPT: protective MBR + header + entries
    EnvFirst       = 8192      # u-boot-env, 0x400000
    FactoryFirst   = 9216      # factory (MACs, Wi-Fi calibration), 0x480000
    FipFirst       = 13312     # fip, 0x680000
    StockKernel    = 17408     # stock kernel FIT, 0x880000
    StockRootfs    = 82944     # stock rootfs
    Production     = 131072    # OpenWrt production volume, 0x4000000
    RawBackupCount = 10240     # sectors copied raw: GPT + BL2 area + env + factory
}

# ---------------------------------------------------------------------------
# Helper classes: TFTP server for the recovery image, binary process runner
# ---------------------------------------------------------------------------
if (-not ('AgsTftp' -as [type])) {
    Add-Type -ReferencedAssemblies System -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public class AgsTftp : IDisposable {
    UdpClient udp; Thread th; volatile bool stop;
    readonly Dictionary<string, string> files = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    public volatile string Status = "";
    public long Served;

    public AgsTftp(int port) {
        udp = new UdpClient(new IPEndPoint(IPAddress.Any, port));
        udp.Client.ReceiveTimeout = 500;
        th = new Thread(Loop);
        th.IsBackground = true;
        th.Start();
    }
    public void Add(string name, string path) { lock (files) { files[name] = path; } }

    void Send(byte[] p, IPEndPoint to) { udp.Send(p, p.Length, to); }
    static byte[] Err(int code, string msg) {
        byte[] m = Encoding.ASCII.GetBytes(msg);
        byte[] p = new byte[5 + m.Length];
        p[1] = 5; p[3] = (byte)code;
        Buffer.BlockCopy(m, 0, p, 4, m.Length);
        return p;
    }
    byte[] Receive(out IPEndPoint from) {
        from = new IPEndPoint(IPAddress.Any, 0);
        try { return udp.Receive(ref from); }
        catch (SocketException) { return null; }
    }
    void Loop() {
        while (!stop) {
            IPEndPoint from;
            byte[] p = Receive(out from);
            if (p == null || p.Length < 4 || p[1] != 1) continue;  // RRQ only
            try { Serve(p, from); }
            catch (Exception e) { Status = "error: " + e.Message; }
        }
    }
    void Serve(byte[] rrq, IPEndPoint client) {
        List<string> f = new List<string>();
        int s = 2;
        for (int i = 2; i < rrq.Length; i++)
            if (rrq[i] == 0) { f.Add(Encoding.ASCII.GetString(rrq, s, i - s)); s = i + 1; }
        if (f.Count < 2) return;
        string name = f[0].TrimStart('/');
        string path;
        lock (files) { files.TryGetValue(name, out path); }
        if (path == null || !File.Exists(path)) {
            Send(Err(1, "file not found"), client);
            Status = "not found: " + name;
            return;
        }
        byte[] data = File.ReadAllBytes(path);
        int blk = 512; int tmo = 1;
        List<string> oack = new List<string>();
        for (int i = 2; i + 1 < f.Count; i += 2) {
            string k = f[i].ToLowerInvariant(), v = f[i + 1];
            int n;
            if (k == "blksize" && int.TryParse(v, out n) && n >= 8) { blk = Math.Min(n, 1468); oack.Add(k); oack.Add(blk.ToString()); }
            else if (k == "tsize") { oack.Add(k); oack.Add(data.Length.ToString()); }
            else if (k == "timeout" && int.TryParse(v, out n) && n >= 1 && n <= 255) { tmo = n; oack.Add(k); oack.Add(v); }
        }
        Status = "sending " + name;
        if (oack.Count > 0) {
            MemoryStream ms = new MemoryStream();
            ms.WriteByte(0); ms.WriteByte(6);
            foreach (string o in oack) { byte[] b = Encoding.ASCII.GetBytes(o); ms.Write(b, 0, b.Length); ms.WriteByte(0); }
            if (!Exchange(ms.ToArray(), 0, client, tmo)) { Status = "no ack for oack: " + name; return; }
        }
        int nblocks = data.Length / blk + 1;   // the last block is shorter than blk (may be empty)
        for (int i = 1; i <= nblocks; i++) {
            int off = (i - 1) * blk, len = Math.Min(blk, data.Length - off);
            byte[] pkt = new byte[4 + len];
            pkt[1] = 3; pkt[2] = (byte)((i >> 8) & 0xff); pkt[3] = (byte)(i & 0xff);
            Buffer.BlockCopy(data, off, pkt, 4, len);
            if (!Exchange(pkt, i & 0xffff, client, tmo)) { Status = "timeout: " + name; return; }
        }
        Served++;
        Status = "sent " + name + " " + data.Length;
    }
    // Send a packet and wait for the ACK of block; a new RRQ from the client restarts.
    bool Exchange(byte[] pkt, int block, IPEndPoint client, int tmo) {
        for (int tries = 0; tries < 8 && !stop; tries++) {
            Send(pkt, client);
            DateTime end = DateTime.UtcNow.AddSeconds(tmo);
            while (DateTime.UtcNow < end && !stop) {
                IPEndPoint from;
                byte[] r = Receive(out from);
                if (r == null || r.Length < 4 || !from.Address.Equals(client.Address)) continue;
                if (r[1] == 1) throw new Exception("client restarted the transfer");
                if (r[1] == 5) return false;
                if (r[1] == 4 && ((r[2] << 8) | r[3]) == block) return true;
            }
        }
        return false;
    }
    public void Dispose() { stop = true; try { udp.Close(); } catch (Exception) { } th.Join(1000); }
}

public class AgsProc {
    public int ExitCode = -1;
    public string Out = "";
    public string Err = "";

    static void Copy(Stream from, Stream to) {
        byte[] b = new byte[1 << 20];
        int n;
        while ((n = from.Read(b, 0, b.Length)) > 0) to.Write(b, 0, n);
    }
    // stdinPath/stdoutPath: binary files or an empty string; echo prints stdout line by line.
    public static AgsProc Run(string exe, string args, string stdinPath, string stdoutPath, bool echo, int timeoutMs) {
        ProcessStartInfo si = new ProcessStartInfo(exe, args);
        si.UseShellExecute = false;
        si.CreateNoWindow = true;
        si.RedirectStandardInput = true;
        si.RedirectStandardOutput = true;
        si.RedirectStandardError = true;
        AgsProc r = new AgsProc();
        try {
            if (Console.InputEncoding.GetPreamble().Length > 0) Console.InputEncoding = new UTF8Encoding(false);
        } catch (Exception) { }
        Process p = Process.Start(si);
        StringBuilder err = new StringBuilder();
        p.ErrorDataReceived += delegate (object o, DataReceivedEventArgs e) { if (e.Data != null) lock (err) err.AppendLine(e.Data); };
        p.BeginErrorReadLine();
        Thread inT = new Thread(delegate () {
            try {
                if (!string.IsNullOrEmpty(stdinPath)) using (FileStream fs = File.OpenRead(stdinPath)) Copy(fs, p.StandardInput.BaseStream);
                p.StandardInput.Close();
            } catch (Exception) { }
        });
        inT.IsBackground = true; inT.Start();
        StringBuilder outText = new StringBuilder();
        Thread outT = new Thread(delegate () {
            try {
                if (!string.IsNullOrEmpty(stdoutPath)) {
                    using (FileStream fs = File.Create(stdoutPath)) Copy(p.StandardOutput.BaseStream, fs);
                } else {
                    string line;
                    while ((line = p.StandardOutput.ReadLine()) != null) {
                        outText.AppendLine(line);
                        if (echo) Console.WriteLine("  | " + line);
                    }
                }
            } catch (Exception) { }
        });
        outT.IsBackground = true; outT.Start();
        if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch (Exception) { } }
        p.WaitForExit();
        outT.Join(5000);
        r.ExitCode = p.HasExited ? p.ExitCode : -1;
        r.Out = outText.ToString();
        lock (err) r.Err = err.ToString();
        return r;
    }
}
'@
}

# ---------------------------------------------------------------------------
# Log and messages
# ---------------------------------------------------------------------------
$LogPath = Join-Path $Root ('ags21-flash-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$script:Log = [IO.File]::CreateText($LogPath)
$script:Log.AutoFlush = $true
$script:Lang = ''

function Write-Log([string]$text) { $script:Log.WriteLine($text) }
function Say([string]$text) { Write-Host $text; Write-Log $text }
function Info([string]$text) { Write-Host "    $text"; Write-Log "    $text" }
function Warn([string]$text) { Write-Host "[!] $text" -ForegroundColor Yellow; Write-Log "[!] $text" }
function Fail([string]$text) { throw $text }
function T([string]$en, [string]$ru) { if ($script:Lang -eq 'ru') { return $ru } return $en }

function Confirm-Step([string]$question) {
    if ($Yes) { return }
    $a = Read-Host $question
    if ($a -match '^[nNнН]') { Fail (T 'stopped by user' 'остановлено пользователем') }
}

function Get-Sha256([string]$path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() }
function Get-Md5([string]$path) { (Get-FileHash -Algorithm MD5 -LiteralPath $path).Hash.ToLowerInvariant() }
function Scale([int]$seconds) { [int]($seconds * 1000 / $TimeScale) }

function Test-Bundle {
    $missing = @($Files.Values | Where-Object { -not (Test-Path (Join-Path $FwDir $_)) })
    if ($missing.Count -gt 0) { Fail (T "firmware\ is missing files: $($missing -join ', ')" "в firmware\ нет файлов: $($missing -join ', ')") }
    if (-not (Test-Path (Join-Path $Root 'tools\mtk_uartboot.exe'))) {
        Fail (T 'tools\mtk_uartboot.exe not found' 'tools\mtk_uartboot.exe не найден')
    }
    if (-not $Firmware -and (Test-Path (Join-Path $FwDir 'SHA256SUMS'))) {
        foreach ($f in $Files.Values) {
            $p = Join-Path $FwDir $f
            $want = (Select-String -LiteralPath (Join-Path $FwDir 'SHA256SUMS') -Pattern ([Regex]::Escape($f)) |
                Select-Object -First 1).Line -replace '\s.*$', ''
            if ($want -and (Get-Sha256 $p) -ne $want.ToLower()) {
                Fail (T "sha256 mismatch for $f - firmware\ is damaged" "sha256 не сошёлся для $f - firmware\ повреждён")
            }
        }
    }
}

function Test-Sysupgrade([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)[0..3]
    if (($b[0] -ne 0xd0) -or ($b[1] -ne 0x0d) -or ($b[2] -ne 0xfe) -or ($b[3] -ne 0xed)) {
        Fail (T "not a FIT image: $path" "не FIT-образ: $path")
    }
}

# ---------------------------------------------------------------------------
# Network: give the adapter the PC address the U-Boot expects, then put it back
# ---------------------------------------------------------------------------
function Invoke-Netsh([string]$netshArgs, [switch]$NoFail) {
    $out = cmd.exe /c "netsh $netshArgs 2>&1"
    Write-Log "netsh $netshArgs (rc=$LASTEXITCODE)`n$out"
    if ($LASTEXITCODE -ne 0 -and -not $NoFail) { Fail "netsh $netshArgs : $out" }
}

function Initialize-Network {
    $have = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $PcIp }
    if ($have) {
        Info (T "$PcIp is already set on adapter '$($have[0].InterfaceAlias)'" "адрес $PcIp уже есть на адаптере '$($have[0].InterfaceAlias)'")
        return
    }
    $nics = @(Get-NetAdapter -Physical | Where-Object { $_.MediaType -eq '802.3' } | Sort-Object Name)
    if ($nics.Count -eq 0) { Fail (T 'no wired network adapters found' 'не найдено проводных сетевых адаптеров') }
    Info (T 'Wired adapters:' 'Проводные адаптеры:')
    for ($i = 0; $i -lt $nics.Count; $i++) {
        Info ("  [{0}] {1} - {2} ({3})" -f ($i + 1), $nics[$i].Name, $nics[$i].InterfaceDescription, $nics[$i].Status)
    }
    $n = 1
    if ($nics.Count -gt 1) {
        $n = [int](Read-Host (T 'Number of the adapter connected to the router' 'Номер адаптера, подключённого к роутеру'))
        if ($n -lt 1 -or $n -gt $nics.Count) { Fail (T 'wrong number' 'неверный номер') }
    }
    $nic = $nics[$n - 1]
    Write-Host ''
    Write-Host (T "Adapter '$($nic.Name)' will temporarily get the address $PcIp/24" "На адаптере '$($nic.Name)' будет временно задан адрес $PcIp/24") -ForegroundColor Yellow
    Write-Host (T '(DHCP on it is off until the script ends, then everything is put back).' '(DHCP на нём отключается до конца работы скрипта, потом всё возвращается).') -ForegroundColor Yellow
    if (-not $Yes) {
        $a = Read-Host (T 'Continue? [Y/n]' 'Продолжить? [Y/n]')
        if ($a -match '^[nNнН]') { Fail (T "set $PcIp/24 by hand and run again" "задайте адрес $PcIp/24 вручную и запустите снова") }
    }
    $ipif = Get-NetIPInterface -InterfaceIndex $nic.ifIndex -AddressFamily IPv4
    $script:NetUndo = @{ Index = $nic.ifIndex; Dhcp = [string]$ipif.Dhcp }
    if ($ipif.Dhcp -eq 'Enabled') {
        Invoke-Netsh "interface ipv4 set address name=$($nic.ifIndex) source=static address=$PcIp mask=255.255.255.0"
    } else {
        Invoke-Netsh "interface ipv4 add address name=$($nic.ifIndex) address=$PcIp mask=255.255.255.0"
    }
    Info (T "$PcIp/24 set on '$($nic.Name)'" "адрес $PcIp/24 задан на '$($nic.Name)'")
    $name = 'AGS21 flash TFTP (temporary)'
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol UDP `
        -LocalPort $TftpPort -RemoteAddress '192.168.1.0/24' -Profile Any | Out-Null
    $script:FwRule = $name
    Info (T "temporary firewall rule for TFTP (UDP $TftpPort) added" "временное правило брандмауэра для TFTP (UDP $TftpPort) добавлено")
}

function Restore-Network {
    if ($script:FwRule) {
        Get-NetFirewallRule -DisplayName $script:FwRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        $script:FwRule = $null
    }
    if ($script:NetUndo) {
        $u = $script:NetUndo
        $script:NetUndo = $null
        if ($u.Dhcp -eq 'Enabled') {
            Invoke-Netsh "interface ipv4 set address name=$($u.Index) source=dhcp" -NoFail
        } else {
            Invoke-Netsh "interface ipv4 delete address name=$($u.Index) address=$PcIp" -NoFail
        }
        Info (T 'network adapter settings restored' 'настройки сетевого адаптера возвращены')
    }
}

# ---------------------------------------------------------------------------
# COM port
# ---------------------------------------------------------------------------
function Select-ComPort {
    if ($ComPort) { return $ComPort }
    $ports = @([IO.Ports.SerialPort]::GetPortNames() | Sort-Object -Unique)
    if ($ports.Count -eq 0) { Fail (T 'no COM ports: plug in the USB-UART adapter and install its driver' 'COM-порты не найдены: подключите USB-UART и установите его драйвер') }
    $names = @{}
    Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%(COM%'" -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.Name -match '\((COM\d+)\)') { $names[$Matches[1]] = $_.Name } }
    if ($ports.Count -eq 1) { Info (T "COM port: $($ports[0]) $($names[$ports[0]])" "COM-порт: $($ports[0]) $($names[$ports[0]])"); return $ports[0] }
    Info (T 'COM ports:' 'COM-порты:')
    for ($i = 0; $i -lt $ports.Count; $i++) { Info ("  [{0}] {1}" -f ($i + 1), $names[$ports[$i]]) }
    $n = [int](Read-Host (T 'Number of the USB-UART port' 'Номер порта USB-UART'))
    if ($n -lt 1 -or $n -gt $ports.Count) { Fail (T 'wrong number' 'неверный номер') }
    return $ports[$n - 1]
}

# ---------------------------------------------------------------------------
# ssh/scp against the initramfs (root, no password) and mtk_uartboot
# ---------------------------------------------------------------------------
function Initialize-Ssh([string]$dir) {
    $script:SshDir = $dir
    if ($SshExe) {
        $script:SshExePath = $SshExe
    } else {
        $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
        if (-not $ssh) { Fail (T 'ssh.exe not found: install the Windows OpenSSH client' 'ssh.exe не найден: установите клиент OpenSSH для Windows') }
        $script:SshExePath = $ssh.Source
    }
}

function ConvertTo-Arg([string]$a) {
    if ($a -match '[\s"]') { return '"' + ($a -replace '"', '\"') + '"' }
    return $a
}

function Invoke-Ssh([string]$cmd, [int]$timeout = 60, [string]$OutFile = $null, [switch]$Echo, [switch]$NoFail) {
    $known = Join-Path $SshDir '.known_hosts'
    $argStr = 'user@host -o StrictHostKeyChecking=no -o UserKnownHostsFile=' + $known + ' -o ConnectTimeout=3 ' + (ConvertTo-Arg $cmd)
    $argStr = $argStr.Replace('user@host', "root@$RouterIp")
    Write-Log "ssh $cmd"
    $r = [AgsProc]::Run($script:SshExePath, $argStr, $null, $OutFile, [bool]$Echo, $timeout * 1000)
    if ($r.Err) { Write-Log "ssh stderr: $($r.Err.TrimEnd())" }
    if ($r.ExitCode -ne 0 -and -not $NoFail) {
        Fail (T "ssh failed (rc=$($r.ExitCode)): $cmd`n$($r.Err)" "ssh завершился с ошибкой (rc=$($r.ExitCode)): $cmd`n$($r.Err)")
    }
    return $r
}

function Invoke-Scp([string[]]$localFiles) {
    # -O: the initramfs has no sftp-server, force the legacy scp protocol
    $known = Join-Path $SshDir '.known_hosts'
    $argStr = '-O -o StrictHostKeyChecking=no -o UserKnownHostsFile=' + $known
    foreach ($f in $localFiles) { $argStr += ' ' + (ConvertTo-Arg $f) }
    $argStr += " root@${RouterIp}:/tmp/"
    Write-Log "scp $argStr"
    $r = [AgsProc]::Run($script:SshExePath, $argStr, $null, $null, $true, 600 * 1000)
    if ($r.ExitCode -ne 0) { Fail (T "scp failed`n$($r.Err)`n$($r.Out)" "scp завершился с ошибкой`n$($r.Err)`n$($r.Out)") }
}

function Test-Ssh([int]$minutes) {
    Say (T "Waiting for the router at $RouterIp (ssh)..." "Жду роутер на $RouterIp (ssh)...")
    $deadline = (Get-Date).AddMinutes($minutes)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Ssh 'true' 15 -NoFail
        if ($r -and $r.ExitCode -eq 0) { Say (T 'router is reachable over ssh' 'роутер доступен по ssh'); return $true }
        Start-Sleep -Seconds (Scale 5)
    }
    return $false
}

# mtk_uartboot: load BL2 (RAM init) + FIP (OpenWrt U-Boot) over UART.
# The user power-cycles the router while the tool listens for the bootrom handshake.
function Enter-RamLinux {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Say (T ("Attempt {0} of 3." -f $attempt) ("Попытка {0} из 3." -f $attempt))
        $ub = Join-Path $Root 'tools\mtk_uartboot.exe'
        $bl2 = Join-Path $FwDir $Files.RamBl2
        $fip = Join-Path $FwDir $Files.Fip
        $argStr = "-s $ComPort -p " + (ConvertTo-Arg $bl2) + ' -f ' + (ConvertTo-Arg $fip) + ' -a'
        Write-Log "mtk_uartboot $argStr"
        Say (T 'mtk_uartboot is listening. If the router is running - unplug its power and plug it back in; if it is off - plug it in now.' 'mtk_uartboot ждёт. Если роутер работает - вытащите питание и вставьте обратно; если выключен - просто включите сейчас.')
        $outFile = Join-Path $SshDir ("uartboot-$attempt.log")
        $p = Start-Process -FilePath $ub -ArgumentList $argStr -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err"
        if (-not $p.WaitForExit(120 * 1000)) {
            try { $p.Kill() } catch { }
            Warn (T 'mtk_uartboot timed out, retrying' 'mtk_uartboot не завершился вовремя, повторяю')
            continue
        }
        $out = Get-Content $outFile -Raw
        Write-Log $out
        if ($out -match 'Received FIP') {
            Say (T 'BL2 and the OpenWrt U-Boot are loaded into RAM.' 'BL2 и OpenWrt U-Boot загружены в RAM.')
            return
        }
        Warn (T 'no bootrom handshake: power on the router while the tool is running, retrying' 'bootrom handshake не пойман: включайте роутер, пока работает утилита, повторяю')
    }
    Fail (T 'could not load the OpenWrt U-Boot over UART after 3 attempts' 'не удалось загрузить OpenWrt U-Boot по UART за 3 попытки')
}

# ---------------------------------------------------------------------------
# Flash access over ssh
# ---------------------------------------------------------------------------
# Verify a flash region by reading it back and comparing md5 with a local file.
# head -c trims the 512-byte block padding so the hashes are over the same bytes.
function Test-FlashRegion([string]$device, [long]$skip, [string]$localPath) {
    $localMd5 = Get-Md5 $localPath
    $size = (Get-Item $localPath).Length
    $cmd = "dd if=$device bs=512 skip=$skip 2>/dev/null | head -c $size | md5sum"
    $tmp = Join-Path $SshDir 'readback.md5'
    $null = Invoke-Ssh $cmd 300 -OutFile $tmp
    $txt = (Get-Content $tmp -Raw).Trim()
    $remoteMd5 = ($txt -split '\s+')[0].ToLower()
    if ($remoteMd5 -ne $localMd5) {
        Fail (T "read-back check failed for $device (skip=$skip): flash $remoteMd5 != file $localMd5" "проверка чтения не сошлась для $device (skip=$skip): во флеше $remoteMd5, в файле $localMd5")
    }
    Info (T "verified: $device (skip=$skip) md5 ok" "проверено: $device (skip=$skip) md5 ok")
}

# Copy a flash region to the PC with sha256 verification (device hash vs local file hash).
function Backup-Region([string]$name, [string]$ddCmd, [long]$bytes, [string]$outDir) {
    $file = Join-Path $outDir $name
    Say (T ("Backing up {0} ({1} MiB)..." -f $name, [Math]::Round($bytes / 1MB, 1))) ("Снимаю {0} ({1} МиБ)..." -f $name, [Math]::Round($bytes / 1MB, 1))
    $null = Invoke-Ssh $ddCmd 1800 -OutFile $file
    $got = (Get-Item $file).Length
    if ($got -ne $bytes) {
        Fail (T "size mismatch for ${name}: got $got, expected $bytes" "размер ${name} не сошёлся: получено $got, ожидалось $bytes")
    }
    $tmp = Join-Path $SshDir 'hash.txt'
    $null = Invoke-Ssh "$ddCmd | sha256sum" 1800 -OutFile $tmp
    $remoteHash = ((Get-Content $tmp -Raw).Trim() -split '\s+')[0].ToLower()
    $localHash = Get-Sha256 $file
    if ($remoteHash -ne $localHash) {
        Fail (T "sha256 mismatch for ${name}: flash $remoteHash != file $localHash" "sha256 ${name} не сошёлся: во флеше $remoteHash, в файле $localHash")
    }
    Info (T "${name} backed up, sha256 ok ($localHash)" "${name} снят, sha256 ок ($localHash)")
}

# Is the router running from RAM (initramfs) or from the flashed system?
function Test-Initramfs {
    $r = Invoke-Ssh 'ubus call system board | grep -q initramfs' 30 -NoFail
    return ($r -and $r.ExitCode -eq 0)
}

# Which GPT is on the eMMC: stock (kernel/rootfs/permanent_config) or OpenWrt
# (production/recovery)? Returns 'stock', 'openwrt' or 'unknown'.
function Test-GptLayout {
    $tmp = Join-Path $SshDir 'gpt.txt'
    $null = Invoke-Ssh "dd if=/dev/mmcblk0 bs=512 skip=1 count=32 2>/dev/null | strings" 60 -OutFile $tmp
    $txt = Get-Content $tmp -Raw
    if ($txt -match 'permanent_config') { return 'stock' }
    if ($txt -match 'production') { return 'openwrt' }
    return 'unknown'
}

function Get-FactoryMac([string]$rawBackup) {
    $fs = [IO.File]::OpenRead($rawBackup)
    try {
        $null = $fs.Seek(0x480000 + 0x24, 'Begin')
        $buf = New-Object byte[] 6
        $null = $fs.Read($buf, 0, 6)
        return ((($buf | ForEach-Object { $_.ToString('x2') }) -join ':').ToUpper())
    } finally { $fs.Dispose() }
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
function Enter-Initramfs {
    Enter-RamLinux
    # The OpenWrt U-Boot in RAM boots (default environment: TFTP recovery loop,
    # or the saved environment: the installed system). Echo the serial console
    # while polling for ssh, so the user sees every step until the system is up.
    Say (T 'Waiting for the router to boot; UART log follows, polling ssh...' 'Жду загрузку роутера; ниже лог UART, параллельно опрашиваю ssh...')
    $sp = $null
    try {
        $sp = [IO.Ports.SerialPort]::new($ComPort, 115200, 'None', 8, 'One')
        $sp.ReadTimeout = 200
        $sp.Open()
    } catch { Write-Log "uart echo unavailable: $($_.Exception.Message)"; $sp = $null }

    $deadline = (Get-Date).AddMinutes(6)
    $up = $false
    while ((Get-Date) -lt $deadline) {
        # drain whatever the router printed since the last poll
        if ($sp) {
            try {
                while ($true) {
                    $line = $sp.ReadLine()
                    Write-Host ('  uart| ' + $line)
                    Write-Log ('uart: ' + $line)
                }
            } catch [TimeoutException] { } catch { }
        }
        $r = Invoke-Ssh 'true' 8 -NoFail
        if ($r -and $r.ExitCode -eq 0) { $up = $true; break }
        Start-Sleep -Seconds (Scale 2)
    }
    if ($sp) { try { $sp.Close() } catch { } }
    if (-not $up) {
        Fail (T 'the router did not come up. Check that the LAN cable is between the router and the PC; see the UART log above' 'роутер не поднялся. Проверьте LAN-кабель между роутером и ПК; смотрите лог UART выше')
    }
    Say (T 'Router is reachable over ssh.' 'Роутер доступен по ssh.')
}

function Invoke-Backup([string]$outDir, [switch]$RefuseOpenWrt) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    Initialize-Ssh $outDir

    Enter-Initramfs

    # The authoritative layout check, from the running initramfs: with the
    # OpenWrt GPT there are no stock partitions to back up. Backup mode refuses,
    # Install mode returns the layout so the caller takes the sysupgrade path.
    if ((Test-GptLayout) -eq 'openwrt') {
        if ($RefuseOpenWrt) {
            Fail (T 'OpenWrt is already flashed (the GPT has no stock partitions) - there is nothing to back up. A backup must be taken from the stock firmware.' 'OpenWrt уже прошит (в GPT нет стоковых разделов) — бэкапировать нечего. Бэкап снимается только со стока.')
        }
        Warn (T 'OpenWrt is already flashed - skipping the stock backup.' 'OpenWrt уже прошит — бэкап стока пропускается.')
        return 'openwrt'
    }

    Say (T 'Backing up the important stock partitions (the 56 GiB permanent_config data partition is skipped).' 'Снимаю важные разделы стока (раздел данных permanent_config на 56 ГиБ пропускается).')
    $L = $Layout
    Backup-Region 'raw-gpt-env-factory.img' ("dd if=/dev/mmcblk0 bs=512 count=$($L.RawBackupCount)") (($L.RawBackupCount) * 512) $outDir
    Backup-Region 'bl2-boot0.img' 'dd if=/dev/mmcblk0boot0 bs=512' 4194304 $outDir
    Backup-Region 'stock-fip.img' 'dd if=/dev/mmcblk0p3 bs=512' 2097152 $outDir
    Backup-Region 'stock-kernel.img' 'dd if=/dev/mmcblk0p4 bs=512' 33554432 $outDir
    Backup-Region 'stock-rootfs.img' 'dd if=/dev/mmcblk0p5 bs=512' 268435456 $outDir

    $mac = Get-FactoryMac (Join-Path $outDir 'raw-gpt-env-factory.img')
    ("label WAN MAC: $mac`n") | Set-Content (Join-Path $outDir 'info.txt')
    Info (T "WAN (label) MAC from factory: $mac" "MAC WAN (наклейка) из factory: $mac")

    $sums = Join-Path $outDir 'SHA256SUMS'
    Get-ChildItem $outDir -Filter '*.img' | ForEach-Object {
        '{0}  {1}' -f (Get-Sha256 $_.FullName), $_.Name
    } | Set-Content $sums
    Say (T "Backup saved to $outDir" "Бэкап сохранён в $outDir")
}

function Invoke-Install {
    $L = $Layout
    $sys = if ($Firmware) { $Firmware } else { Join-Path $FwDir $Files.Sysupgrade }
    Test-Sysupgrade $sys

    if (-not $BackupDir) {
        $BackupDir = Join-Path $Root ('backup\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    Initialize-Ssh $BackupDir

    # If a flashed OpenWrt answers at the router address, upgrade it with
    # sysupgrade: no backup of stock partitions exists any more, and writing
    # the production volume with dd while running from it is unsafe.
    $flashed = $false
    Say (T 'Probing the router over ssh (up to 3 s)...' 'Опрашиваю роутер по ssh (до 3 с)...')
    $r = Invoke-Ssh 'true' 10 -NoFail
    if ($r -and $r.ExitCode -eq 0) {
        $flashed = ((Test-GptLayout) -eq 'openwrt')
    }

    $layout = 'stock'
    if (-not $flashed) {
        $layout = Invoke-Backup $BackupDir
    }

    Write-Host ''
    if ($flashed) {
        Write-Host (T 'OpenWrt is already installed - the script will run sysupgrade.' 'OpenWrt уже установлен — скрипт выполнит sysupgrade.') -ForegroundColor Yellow
    } else {
        Write-Host (T "Backup is in $BackupDir" "Бэкап лежит в $BackupDir") -ForegroundColor Yellow
        Write-Host (T 'Everything below writes OpenWrt to the eMMC. The stock firmware can be' 'Ниже начинается запись OpenWrt в eMMC. Сток потом можно вернуть') -ForegroundColor Yellow
        Write-Host (T 'brought back later with -Mode Restore.' 'режимом -Mode Restore.') -ForegroundColor Yellow
    }
    if (-not $Yes) {
        $a = Read-Host (T 'Type yes to write OpenWrt now' 'Введите yes, чтобы писать OpenWrt сейчас')
        if ($a -notmatch '^(y|yes|д|да)$') { Fail (T 'stopped by user' 'остановлено пользователем') }
    }

    if (-not $flashed) {
        # the session from the backup phase is still alive; if not, re-enter it
        $r = Invoke-Ssh 'true' 15 -NoFail
        if (-not ($r -and $r.ExitCode -eq 0)) { Enter-Initramfs }
    }

    if ($flashed -or ($layout -eq 'openwrt')) {
        # OpenWrt is already installed: upgrade with sysupgrade (it writes the
        # production volume safely), no GPT/BL2/FIP writes are needed.
        Say (T 'OpenWrt is already installed - upgrading with sysupgrade...' 'OpenWrt уже установлен — обновляюсь через sysupgrade...')
        Say (T 'Backing up the currently flashed system first...' 'Сначала бэкаплю текущую зашитую систему...')
        Backup-Region 'current-gpt.img' 'dd if=/dev/mmcblk0 bs=512 count=34' (34 * 512) $BackupDir
        Backup-Region 'current-bl2-boot0.img' 'dd if=/dev/mmcblk0boot0 bs=512' 4194304 $BackupDir
        Backup-Region 'current-fip.img' 'dd if=/dev/mmcblk0 bs=512 skip=13312 count=4096' (4096 * 512) $BackupDir
        # the running kernel + rootfs FIT, as exposed by fitblk
        $fitBytes = [long]((Invoke-Ssh 'cat /sys/block/fit0/size' 30).Out.Trim()) * 512
        Backup-Region 'current-fit0.img' 'dd if=/dev/fit0 bs=512' $fitBytes $BackupDir
        Invoke-Scp @($sys)
        $null = Invoke-Ssh "sysupgrade -v /tmp/$(Split-Path $sys -Leaf)" 900
        Say (T 'Rebooting into the upgraded OpenWrt...' 'Перезагружаюсь в обновлённый OpenWrt...')
        Start-Sleep -Seconds (Scale 10)
    } else {
        Say (T 'Uploading the OpenWrt images to /tmp...' 'Загружаю образы OpenWrt в /tmp...')
        Invoke-Scp @((Join-Path $FwDir $Files.Gpt), (Join-Path $FwDir $Files.Preloader),
            (Join-Path $FwDir $Files.Fip), $sys)
        foreach ($f in @($Files.Gpt, $Files.Preloader, $Files.Fip, (Split-Path $sys -Leaf))) {
            $null = Invoke-Ssh "test -f /tmp/$f" 30
        }
        Info (T 'uploaded' 'загружено')

        Say (T 'Writing the OpenWrt GPT (sectors 0-33)...' 'Пишу GPT OpenWrt (сектора 0-33)...')
        $null = Invoke-Ssh "dd if=/tmp/$($Files.Gpt) of=/dev/mmcblk0 bs=512 conv=notrunc" 120
        Say (T 'Writing BL2 to the eMMC boot partition...' 'Пишу BL2 в boot-раздел eMMC...')
        $null = Invoke-Ssh 'echo 0 > /sys/block/mmcblk0boot0/force_ro && dd if=/tmp/emmc-preloader.bin of=/dev/mmcblk0boot0 bs=512 && sync && echo 1 > /sys/block/mmcblk0boot0/force_ro' 120
        Say (T 'Writing the bl31-uboot FIP (sector 13312)...' 'Пишу bl31-uboot FIP (сектор 13312)...')
        $null = Invoke-Ssh "dd if=/tmp/$($Files.Fip) of=/dev/mmcblk0 bs=512 seek=$($L.FipFirst) conv=notrunc" 120
        Say (T 'Writing the sysupgrade FIT to the production volume (sector 131072)...' 'Пишу sysupgrade FIT в том production (сектор 131072)...')
        $null = Invoke-Ssh "dd if=/tmp/$(Split-Path $sys -Leaf) of=/dev/mmcblk0 bs=512 seek=$($L.Production) conv=notrunc" 300
        $null = Invoke-Ssh 'sync' 60

        Say (T 'Verifying by reading back...' 'Проверяю чтением обратно...')
        Test-FlashRegion '/dev/mmcblk0' 0 (Join-Path $FwDir $Files.Gpt)
        Test-FlashRegion '/dev/mmcblk0boot0' 0 (Join-Path $FwDir $Files.Preloader)
        Test-FlashRegion '/dev/mmcblk0' $L.FipFirst (Join-Path $FwDir $Files.Fip)
        Test-FlashRegion '/dev/mmcblk0' $L.Production $sys
    }

    Say (T 'Rebooting into OpenWrt...' 'Перезагружаюсь в OpenWrt...')
    $null = Invoke-Ssh 'sync; sleep 1; reboot' 30 -NoFail
    Start-Sleep -Seconds (Scale 10)

    Say (T "Waiting for OpenWrt to come up at $RouterIp..." "Жду подъёма OpenWrt на $RouterIp...")
    $deadline = (Get-Date).AddMinutes(5)
    $up = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-Connection -ComputerName $RouterIp -Count 1 -Quiet) {
            $r = Invoke-Ssh 'ubus call system board | grep -q aigo' 15 -NoFail
            if ($r -and $r.ExitCode -eq 0) { $up = $true; break }
        }
        Start-Sleep -Seconds (Scale 5)
    }
    if (-not $up) {
        Fail (T 'OpenWrt did not come up in 5 minutes. Check the UART log; recovery: -Mode Restore' 'OpenWrt не поднялся за 5 минут. Смотрите лог UART; восстановление: -Mode Restore')
    }
    $macsOut = Join-Path $SshDir 'macs.txt'
    $null = Invoke-Ssh 'ip -o link show eth0 | grep -o "link/ether [0-9a-f:]*" | head -1; ip -o link show eth1 | grep -o "link/ether [0-9a-f:]*" | head -1' 30 -OutFile $macsOut
    $lines = @(Get-Content $macsOut | ForEach-Object { ($_ -split '\s+')[-1] })
    $labelMac = Get-FactoryMac (Join-Path $BackupDir 'raw-gpt-env-factory.img')
    Say (T 'OpenWrt is running from the eMMC flash.' 'OpenWrt работает с eMMC.')
    Info (T "LAN (eth0) MAC: $($lines[0])   WAN (eth1) MAC: $($lines[1])" "MAC LAN (eth0): $($lines[0])   MAC WAN (eth1): $($lines[1])")
    if ($lines.Count -ge 2 -and $lines[1] -and ($lines[1].ToUpper() -eq $labelMac)) {
        Info (T 'WAN MAC matches the factory value - the factory partition survived.' 'MAC WAN совпадает с заводским — factory-раздел цел.')
    } else {
        Warn (T "WAN MAC does not match the factory value $labelMac - check the factory partition!" "MAC WAN не совпадает с заводским ($labelMac) — проверьте factory-раздел!")
    }
    Say (T 'Done. Web UI: http://192.168.1.1 (no password by default - set one).' 'Готово. Веб-интерфейс: http://192.168.1.1 (пароль по умолчанию пустой — задайте).')
}

function Invoke-Restore {
    if (-not $BackupDir) { Fail (T 'give -BackupDir with an earlier backup' 'укажите -BackupDir с ранее снятым бэкапом') }
    if (-not (Test-Path $BackupDir)) { Fail (T "backup folder not found: $BackupDir" "папка бэкапа не найдена: $BackupDir") }
    $need = @('raw-gpt-env-factory.img', 'bl2-boot0.img', 'stock-fip.img', 'stock-kernel.img', 'stock-rootfs.img')
    foreach ($f in $need) {
        if (-not (Test-Path (Join-Path $BackupDir $f))) { Fail (T "backup is missing $f" "в бэкапе нет файла $f") }
    }

    Say (T 'This writes the stock firmware back and REMOVES OpenWrt.' 'Это вернёт сток и УДАЛИТ OpenWrt.')
    Write-Host (T 'permanent_config (user files) is not touched; the stock firmware may reformat it on the first boot.' 'permanent_config (пользовательские файлы) не затрагивается; сток при первой загрузке может его переформатировать.') -ForegroundColor Yellow
    if (-not $Yes) {
        $a = Read-Host (T 'Type yes to restore the stock firmware' 'Введите yes, чтобы восстановить сток')
        if ($a -notmatch '^(y|yes|д|да)$') { Fail (T 'stopped by user' 'остановлено пользователем') }
    }

    $tmpDir = Join-Path $Root ('tmp\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    Initialize-Ssh $tmpDir

    if (Test-Ssh 2) {
        # OpenWrt is running from flash: with a saved environment the RAM U-Boot
        # would boot it again instead of the TFTP recovery. Wipe the environment
        # so the U-Boot falls back to the default one (TFTP loop).
        if ((Test-GptLayout) -eq 'openwrt') {
            Say (T 'Erasing the U-Boot environment so the recovery TFTP loop starts...' 'Стираю окружение U-Boot, чтобы начался TFTP-цикл recovery...')
            $null = Invoke-Ssh 'dd if=/dev/zero of=/dev/mmcblk0 bs=512 seek=8192 count=1024 && sync' 60
        }
        Say (T 'Rebooting...' 'Перезагружаюсь...')
        $null = Invoke-Ssh 'sync; sleep 1; reboot' 30 -NoFail
        Start-Sleep -Seconds (Scale 10)
    }

    Enter-Initramfs

    Say (T 'Uploading the stock images...' 'Загружаю образы стока...')
    Invoke-Scp @($need | ForEach-Object { Join-Path $BackupDir $_ })

    Say (T 'Writing the stock GPT + env + factory (sectors 0-10239)...' 'Пишу стоковые GPT + env + factory (сектора 0-10239)...')
    $null = Invoke-Ssh 'dd if=/tmp/raw-gpt-env-factory.img of=/dev/mmcblk0 bs=512 conv=notrunc' 300
    Say (T 'Writing the stock BL2 to the boot partition...' 'Пишу стоковый BL2 в boot-раздел...')
    $null = Invoke-Ssh 'echo 0 > /sys/block/mmcblk0boot0/force_ro && dd if=/tmp/bl2-boot0.img of=/dev/mmcblk0boot0 bs=512 && sync && echo 1 > /sys/block/mmcblk0boot0/force_ro' 180
    Say (T 'Writing the stock FIP (sector 13312)...' 'Пишу стоковый FIP (сектор 13312)...')
    $null = Invoke-Ssh 'dd if=/tmp/stock-fip.img of=/dev/mmcblk0 bs=512 seek=13312 conv=notrunc' 180
    Say (T 'Writing the stock kernel (sector 17408)...' 'Пишу стоковый kernel (сектор 17408)...')
    $null = Invoke-Ssh 'dd if=/tmp/stock-kernel.img of=/dev/mmcblk0 bs=512 seek=17408 conv=notrunc' 300
    Say (T 'Writing the stock rootfs (sector 82944)...' 'Пишу стоковый rootfs (сектор 82944)...')
    $null = Invoke-Ssh 'dd if=/tmp/stock-rootfs.img of=/dev/mmcblk0 bs=512 seek=82944 conv=notrunc' 600
    $null = Invoke-Ssh 'sync' 60

    Say (T 'Verifying by reading back...' 'Проверяю чтением обратно...')
    Test-FlashRegion '/dev/mmcblk0' 0 (Join-Path $BackupDir 'raw-gpt-env-factory.img')
    Test-FlashRegion '/dev/mmcblk0boot0' 0 (Join-Path $BackupDir 'bl2-boot0.img')
    Test-FlashRegion '/dev/mmcblk0' 13312 (Join-Path $BackupDir 'stock-fip.img')
    Test-FlashRegion '/dev/mmcblk0' 17408 (Join-Path $BackupDir 'stock-kernel.img')
    Test-FlashRegion '/dev/mmcblk0' 82944 (Join-Path $BackupDir 'stock-rootfs.img')

    Say (T 'Rebooting into the stock firmware...' 'Перезагружаюсь в сток...')
    $null = Invoke-Ssh 'sync; sleep 1; reboot' 30 -NoFail
    Say (T 'Done. The router boots the stock firmware (192.168.8.1).' 'Готово. Роутер загружает сток (192.168.8.1).')
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    if (-not $Lang) {
        $a = Read-Host 'Language / Язык: [en/ru]'
        $script:Lang = if ($a -match '^(ru|рус)') { 'ru' } else { 'en' }
    } else { $script:Lang = $Lang }

    Say ("Aigo AGS21 backup & flash - {0}, log: {1}" -f $Mode, $LogPath)
    Test-Bundle
    $script:ComPort = Select-ComPort
    if (-not $SkipNetworkSetup) { Initialize-Network }

    $workDir = Join-Path $Root ('tmp\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    Initialize-Ssh $workDir

    $script:Tftp = [AgsTftp]::new($TftpPort)
    # the OpenWrt U-Boot asks for the file name baked into its default environment
    $script:Tftp.Add($UbootTftpFile, (Join-Path $FwDir $Files.Recovery))
    Info (T "TFTP server listening on UDP $TftpPort" "TFTP-сервер слушает UDP $TftpPort")

    switch ($Mode) {
        'Install' { Invoke-Install }
        'Backup'  {
            if (-not $BackupDir) { $BackupDir = Join-Path $Root ('backup\' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
            Invoke-Backup $BackupDir -RefuseOpenWrt
            Say (T 'Rebooting into the stock firmware...' 'Перезагружаюсь в сток...')
            $null = Invoke-Ssh 'sync; sleep 1; reboot' 30 -NoFail
            Say (T 'Done.' 'Готово.')
        }
        'Restore' { Invoke-Restore }
    }
} finally {
    if ($script:Tftp) { $script:Tftp.Dispose() }
    Restore-Network
    $script:Log.Dispose()
}
