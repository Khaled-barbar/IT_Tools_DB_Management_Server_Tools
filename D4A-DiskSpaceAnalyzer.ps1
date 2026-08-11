#Requires -Version 5.1

<#
.SYNOPSIS
    Fast, interactive disk-space analyzer for Windows Server and Windows clients.

.DESCRIPTION
    Maps an NTFS volume by enumerating its Master File Table (MFT) through the
    native FSCTL_ENUM_USN_DATA API and reads exact logical file sizes in
    parallel. It first reports folders above 1 GB through three directory
    levels, then searches the cached snapshot for files globally or below a
    pasted directory using a user-selected threshold.

    Run from an elevated Windows PowerShell session to use MFT mode. If MFT mode
    is unavailable, Auto mode falls back to a normal directory traversal.

.EXAMPLE
    .\D4A-FastDiskSpaceAnalyzer.ps1 -Verbose

.EXAMPLE
    .\D4A-FastDiskSpaceAnalyzer.ps1 -Drive C: -ThresholdMB 2048

.EXAMPLE
    .\D4A-FastDiskSpaceAnalyzer.ps1 -Drive D: -SearchDirectory 'D:\Backups' -ThresholdMB 512

.EXAMPLE
    .\D4A-FastDiskSpaceAnalyzer.ps1 -Drive D: -ThresholdMB 512 -NoGui -SingleRun

.NOTES
    - Windows PowerShell 5.1 compatible.
    - No third-party modules are required.
    - Directory sizes are logical sizes. NTFS compression, sparse allocation,
      deduplication, and alternate data streams can make allocated size differ.
    - MFT enumeration is local-volume only. Mounted child volumes are not rolled
      into the parent volume's totals.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Drive,

    [Parameter()]
    [string]$SearchDirectory,

    [Parameter()]
    [ValidateRange(0, 9.22e12)]
    [double]$ThresholdMB = 0,

    [Parameter()]
    [ValidateSet('Auto', 'MFT', 'Traversal')]
    [string]$ScanMode = 'Auto',

    [Parameter()]
    [ValidateRange(10, 500)]
    [int]$TreemapItemLimit = 80,

    [Parameter()]
    [ValidateRange(0, 1000000)]
    [int]$ConsoleItemLimit = 100,

    [Parameter()]
    [string]$ExportDirectory,

    [Parameter()]
    [switch]$NoGui,

    [Parameter()]
    [switch]$SingleRun,

    [Parameter(DontShow)]
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AnalyzerName = 'D4A Fast Disk Space Analyzer'
$script:DefaultThresholdMB = 1024.0
$script:LastVerboseProgress = -10

function Initialize-NativeScanner {
    [CmdletBinding()]
    param()

    if ('D4A.Storage.V3.FastVolumeScanner' -as [type]) {
        return
    }

    Write-Verbose '  0% Loading native NTFS scanner.'

    $source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace D4A.Storage.V3
{
    public sealed class ScanItem
    {
        public int Rank { get; set; }
        public string Path { get; set; }
        public string Name { get; set; }
        public string Extension { get; set; }
        public string Kind { get; set; }
        public long Length { get; set; }
        public long FileCount { get; set; }
    }

    public sealed class VolumeScanResult
    {
        public string RootPath { get; set; }
        public string FileSearchScope { get; set; }
        public string ScanMethod { get; set; }
        public long TotalBytes { get; set; }
        public long TotalFiles { get; set; }
        public long TotalDirectories { get; set; }
        public long SkippedFiles { get; set; }
        public long SkippedDirectories { get; set; }
        public long ThresholdBytes { get; set; }
        public long FolderThresholdBytes { get; set; }
        public TimeSpan Elapsed { get; set; }
        public List<ScanItem> LargeFiles { get; set; }
        public List<ScanItem> LargeFolders { get; set; }
        internal Dictionary<ulong, MftNode> Nodes;
        internal Dictionary<ulong, string> DirectoryPaths;

        public VolumeScanResult()
        {
            LargeFiles = new List<ScanItem>();
            LargeFolders = new List<ScanItem>();
        }
    }

    internal sealed class MftNode
    {
        public ulong Id;
        public ulong ParentId;
        public string Name;
        public bool IsDirectory;
        public string DirectoryPath;
        public long Length;
        public long AggregateLength;
        public long FileCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MftEnumDataV0
    {
        public ulong StartFileReferenceNumber;
        public long LowUsn;
        public long HighUsn;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Win32FileAttributeData
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint FileSizeHigh;
        public uint FileSizeLow;
    }

    public static class FastVolumeScanner
    {
        private const uint GenericRead = 0x80000000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint FsctlGetNtfsVolumeData = 0x00090064;
        private const uint FsctlEnumUsnData = 0x000900B3;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const int ErrorHandleEof = 38;
        private const ulong RecordNumberMask = 0x0000FFFFFFFFFFFFUL;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", EntryPoint = "DeviceIoControl", SetLastError = true)]
        private static extern bool DeviceIoControlEnum(
            SafeFileHandle device,
            uint controlCode,
            ref MftEnumDataV0 inBuffer,
            int inBufferSize,
            [Out]
            byte[] outBuffer,
            int outBufferSize,
            out int bytesReturned,
            IntPtr overlapped);

        [DllImport("kernel32.dll", EntryPoint = "DeviceIoControl", SetLastError = true)]
        private static extern bool DeviceIoControlNoInput(
            SafeFileHandle device,
            uint controlCode,
            IntPtr inBuffer,
            int inBufferSize,
            [Out]
            byte[] outBuffer,
            int outBufferSize,
            out int bytesReturned,
            IntPtr overlapped);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileAttributesEx(
            string name,
            int fileInfoLevel,
            out Win32FileAttributeData fileData);

        private static void Report(Action<int, string> progress, int percentage, string message)
        {
            if (progress == null)
            {
                return;
            }

            try
            {
                progress(Math.Max(0, Math.Min(100, percentage)), message);
            }
            catch
            {
                // A display callback must never abort a scan.
            }
        }

        private static string NormalizeRoot(string rootPath)
        {
            if (String.IsNullOrWhiteSpace(rootPath))
            {
                throw new ArgumentException("A drive root is required.", "rootPath");
            }

            string full = Path.GetFullPath(rootPath.Trim());
            string root = Path.GetPathRoot(full);
            if (String.IsNullOrEmpty(root) || root.Length < 2 || root[1] != ':')
            {
                throw new ArgumentException("MFT mode requires a local drive such as C:\\.", "rootPath");
            }

            return root.TrimEnd('\\') + "\\";
        }

        private static string ToExtendedPath(string path)
        {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal))
            {
                return path;
            }

            if (path.StartsWith(@"\\", StringComparison.Ordinal))
            {
                return @"\\?\UNC\" + path.Substring(2);
            }

            return @"\\?\" + path;
        }

        private static long GetMftRecordEstimate(SafeFileHandle volume)
        {
            byte[] volumeData = new byte[128];
            int returned;
            if (!DeviceIoControlNoInput(
                    volume,
                    FsctlGetNtfsVolumeData,
                    IntPtr.Zero,
                    0,
                    volumeData,
                    volumeData.Length,
                    out returned,
                    IntPtr.Zero) || returned < 64)
            {
                return 0;
            }

            uint bytesPerRecord = BitConverter.ToUInt32(volumeData, 48);
            long mftValidDataLength = BitConverter.ToInt64(volumeData, 56);
            if (bytesPerRecord == 0 || mftValidDataLength <= 0)
            {
                return 0;
            }

            return Math.Max(1, mftValidDataLength / bytesPerRecord);
        }

        private static Dictionary<ulong, MftNode> EnumerateMft(
            SafeFileHandle volume,
            long recordEstimate,
            Action<int, string> progress)
        {
            Dictionary<ulong, MftNode> nodes = new Dictionary<ulong, MftNode>();
            MftEnumDataV0 input = new MftEnumDataV0();
            input.StartFileReferenceNumber = 0;
            input.LowUsn = 0;
            input.HighUsn = Int64.MaxValue;

            byte[] output = new byte[1024 * 1024];
            int returned;
            ulong previousStart = UInt64.MaxValue;

            while (true)
            {
                bool ok = DeviceIoControlEnum(
                    volume,
                    FsctlEnumUsnData,
                    ref input,
                    Marshal.SizeOf(typeof(MftEnumDataV0)),
                    output,
                    output.Length,
                    out returned,
                    IntPtr.Zero);

                if (!ok)
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error == ErrorHandleEof)
                    {
                        break;
                    }

                    throw new Win32Exception(error, "Unable to enumerate the NTFS Master File Table.");
                }

                if (returned < 8)
                {
                    break;
                }

                ulong nextStart = BitConverter.ToUInt64(output, 0);
                int offset = 8;

                while (offset + 60 <= returned)
                {
                    int recordLength = BitConverter.ToInt32(output, offset);
                    if (recordLength < 60 || offset + recordLength > returned)
                    {
                        break;
                    }

                    ushort majorVersion = BitConverter.ToUInt16(output, offset + 4);
                    if (majorVersion == 2)
                    {
                        ulong id = BitConverter.ToUInt64(output, offset + 8);
                        ulong parentId = BitConverter.ToUInt64(output, offset + 16);
                        uint attributes = BitConverter.ToUInt32(output, offset + 52);
                        ushort nameLength = BitConverter.ToUInt16(output, offset + 56);
                        ushort nameOffset = BitConverter.ToUInt16(output, offset + 58);

                        bool isRootRecord = (id & RecordNumberMask) == 5;
                        bool hasValidName =
                            nameLength > 0 &&
                            nameOffset >= 60 &&
                            nameOffset + nameLength <= recordLength;

                        // The NTFS root (MFT record 5) can be returned with an
                        // empty file name. Keep it so path reconstruction can
                        // anchor all of its children to the drive root.
                        if (hasValidName || (isRootRecord && nameLength == 0))
                        {
                            string name = hasValidName
                                ? Encoding.Unicode.GetString(output, offset + nameOffset, nameLength)
                                : String.Empty;
                            MftNode node = new MftNode();
                            node.Id = id;
                            node.ParentId = parentId;
                            node.Name = name;
                            node.IsDirectory = (attributes & FileAttributeDirectory) != 0;
                            node.Length = -1;
                            nodes[id] = node;
                        }
                    }

                    offset += recordLength;
                }

                int percentage;
                if (recordEstimate > 0)
                {
                    percentage = 5 + (int)Math.Min(25.0, (nodes.Count * 25.0) / recordEstimate);
                }
                else
                {
                    percentage = 15;
                }

                Report(
                    progress,
                    percentage,
                    String.Format("Enumerating MFT records ({0:N0} mapped)", nodes.Count));

                if (nextStart == previousStart || nextStart == input.StartFileReferenceNumber)
                {
                    break;
                }

                previousStart = input.StartFileReferenceNumber;
                input.StartFileReferenceNumber = nextStart;
            }

            return nodes;
        }

        private static MftNode FindRootNode(Dictionary<ulong, MftNode> nodes)
        {
            MftNode selfParent = null;
            ulong inferredRootId = 0;
            foreach (MftNode node in nodes.Values)
            {
                // MFT record number 5 is the NTFS volume root. Trust the
                // record number even if a particular server reports unusual
                // attributes for its USN record.
                if ((node.Id & RecordNumberMask) == 5)
                {
                    node.IsDirectory = true;
                    if (node.Name == null)
                    {
                        node.Name = String.Empty;
                    }
                    return node;
                }

                if (node.IsDirectory && node.Id == node.ParentId)
                {
                    selfParent = node;
                }

                // Some NTFS implementations omit the root's own USN record,
                // while returning children whose parent reference is record
                // 5. Capture that exact reference (including its sequence
                // number) so a synthetic root can be created safely.
                if ((node.ParentId & RecordNumberMask) == 5)
                {
                    inferredRootId = node.ParentId;
                }
            }

            if (selfParent != null)
            {
                return selfParent;
            }

            if (inferredRootId != 0)
            {
                MftNode inferredRoot = new MftNode();
                inferredRoot.Id = inferredRootId;
                inferredRoot.ParentId = inferredRootId;
                inferredRoot.Name = String.Empty;
                inferredRoot.IsDirectory = true;
                inferredRoot.Length = 0;
                nodes[inferredRootId] = inferredRoot;
                return inferredRoot;
            }

            return null;
        }

        private static string ResolveDirectoryPath(
            MftNode requested,
            MftNode root,
            string rootPath,
            Dictionary<ulong, MftNode> nodes,
            Dictionary<ulong, string> cache)
        {
            string known;
            if (cache.TryGetValue(requested.Id, out known))
            {
                return known;
            }

            List<MftNode> chain = new List<MftNode>();
            HashSet<ulong> visited = new HashSet<ulong>();
            MftNode current = requested;

            while (current != null && !cache.TryGetValue(current.Id, out known))
            {
                if (!visited.Add(current.Id))
                {
                    return null;
                }

                chain.Add(current);
                MftNode parent;
                if (!nodes.TryGetValue(current.ParentId, out parent) || !parent.IsDirectory)
                {
                    return null;
                }

                current = parent;
            }

            if (String.IsNullOrEmpty(known))
            {
                known = rootPath;
            }

            for (int index = chain.Count - 1; index >= 0; index--)
            {
                MftNode part = chain[index];
                if (part.Id == root.Id)
                {
                    cache[part.Id] = rootPath;
                    known = rootPath;
                    continue;
                }

                known = known.EndsWith("\\", StringComparison.Ordinal)
                    ? known + part.Name
                    : known + "\\" + part.Name;
                cache[part.Id] = known;
                part.DirectoryPath = known;
            }

            return known;
        }

        private static bool TryGetLength(string path, out long length)
        {
            Win32FileAttributeData data;
            if (!GetFileAttributesEx(ToExtendedPath(path), 0, out data))
            {
                length = -1;
                return false;
            }

            ulong value = ((ulong)data.FileSizeHigh << 32) | data.FileSizeLow;
            if (value > Int64.MaxValue)
            {
                length = -1;
                return false;
            }

            length = (long)value;
            return true;
        }

        private static string CombineDisplayPath(string directoryPath, string name)
        {
            return directoryPath.EndsWith("\\", StringComparison.Ordinal)
                ? directoryPath + name
                : directoryPath + "\\" + name;
        }

        private static VolumeScanResult BuildResult(
            string rootPath,
            string method,
            long thresholdBytes,
            Dictionary<ulong, MftNode> nodes,
            Dictionary<ulong, string> directoryPaths,
            MftNode root,
            long skippedFiles,
            long skippedDirectories,
            DateTime started,
            Action<int, string> progress)
        {
            List<MftNode> directories = new List<MftNode>();
            List<MftNode> files = new List<MftNode>();

            foreach (MftNode node in nodes.Values)
            {
                if (node.IsDirectory)
                {
                    if (directoryPaths.ContainsKey(node.Id))
                    {
                        node.AggregateLength = 0;
                        node.FileCount = 0;
                        directories.Add(node);
                    }
                }
                else
                {
                    files.Add(node);
                }
            }

            foreach (MftNode file in files)
            {
                if (file.Length < 0)
                {
                    continue;
                }

                MftNode parent;
                if (nodes.TryGetValue(file.ParentId, out parent) && parent.IsDirectory)
                {
                    parent.AggregateLength += file.Length;
                    parent.FileCount++;
                }
            }

            directories.Sort(delegate(MftNode left, MftNode right)
            {
                string leftPath;
                string rightPath;
                directoryPaths.TryGetValue(left.Id, out leftPath);
                directoryPaths.TryGetValue(right.Id, out rightPath);
                int leftLength = leftPath == null ? 0 : leftPath.Length;
                int rightLength = rightPath == null ? 0 : rightPath.Length;
                return rightLength.CompareTo(leftLength);
            });

            int directoryIndex = 0;
            foreach (MftNode directory in directories)
            {
                if (directory.Id != root.Id)
                {
                    MftNode parent;
                    if (nodes.TryGetValue(directory.ParentId, out parent) && parent.IsDirectory)
                    {
                        parent.AggregateLength += directory.AggregateLength;
                        parent.FileCount += directory.FileCount;
                    }
                }

                directoryIndex++;
                if ((directoryIndex % 5000) == 0)
                {
                    int percent = 82 + (int)((directoryIndex * 10.0) / Math.Max(1, directories.Count));
                    Report(
                        progress,
                        percent,
                        String.Format("Aggregating directory totals ({0:N0}/{1:N0})", directoryIndex, directories.Count));
                }
            }

            Report(progress, 93, "Ranking large folders and files");

            VolumeScanResult result = new VolumeScanResult();
            result.RootPath = rootPath;
            result.ScanMethod = method;
            result.ThresholdBytes = thresholdBytes;
            result.FolderThresholdBytes = thresholdBytes;
            result.TotalFiles = files.Count;
            result.TotalDirectories = directories.Count;
            result.SkippedFiles = skippedFiles;
            result.SkippedDirectories = skippedDirectories;
            result.TotalBytes = root.AggregateLength;
            result.Nodes = nodes;
            result.DirectoryPaths = directoryPaths;

            foreach (MftNode file in files)
            {
                if (file.Length < thresholdBytes)
                {
                    continue;
                }

                string parentPath;
                if (!directoryPaths.TryGetValue(file.ParentId, out parentPath))
                {
                    continue;
                }

                ScanItem item = new ScanItem();
                item.Path = CombineDisplayPath(parentPath, file.Name);
                item.Name = file.Name;
                item.Extension = Path.GetExtension(file.Name);
                item.Kind = "File";
                item.Length = file.Length;
                item.FileCount = 1;
                result.LargeFiles.Add(item);
            }

            foreach (MftNode directory in directories)
            {
                if (directory.AggregateLength < thresholdBytes)
                {
                    continue;
                }

                string path;
                if (!directoryPaths.TryGetValue(directory.Id, out path))
                {
                    continue;
                }

                ScanItem item = new ScanItem();
                item.Path = path;
                item.Name = directory.Id == root.Id ? rootPath : directory.Name;
                item.Extension = String.Empty;
                item.Kind = "Folder";
                item.Length = directory.AggregateLength;
                item.FileCount = directory.FileCount;
                result.LargeFolders.Add(item);
            }

            result.LargeFiles.Sort(delegate(ScanItem left, ScanItem right)
            {
                return right.Length.CompareTo(left.Length);
            });
            result.LargeFolders.Sort(delegate(ScanItem left, ScanItem right)
            {
                return right.Length.CompareTo(left.Length);
            });

            for (int index = 0; index < result.LargeFiles.Count; index++)
            {
                result.LargeFiles[index].Rank = index + 1;
            }

            for (int index = 0; index < result.LargeFolders.Count; index++)
            {
                result.LargeFolders[index].Rank = index + 1;
            }

            result.Elapsed = DateTime.UtcNow - started;
            Report(progress, 100, "Analysis complete");
            return result;
        }

        public static List<ScanItem> FindLargeFiles(
            VolumeScanResult snapshot,
            string scopePath,
            long thresholdBytes,
            Action<int, string> progress)
        {
            if (snapshot == null || snapshot.Nodes == null || snapshot.DirectoryPaths == null)
            {
                throw new ArgumentException("The scan snapshot is unavailable.", "snapshot");
            }
            if (thresholdBytes < 0)
            {
                throw new ArgumentOutOfRangeException("thresholdBytes");
            }

            string scope = Path.GetFullPath(scopePath).TrimEnd('\\');
            string root = snapshot.RootPath.TrimEnd('\\');
            if (!scope.Equals(root, StringComparison.OrdinalIgnoreCase) &&
                !scope.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException("The search directory is outside the scanned volume.", "scopePath");
            }

            string scopePrefix = scope + "\\";
            List<ScanItem> matches = new List<ScanItem>();
            int processed = 0;
            foreach (MftNode file in snapshot.Nodes.Values)
            {
                if (file.IsDirectory)
                {
                    continue;
                }

                processed++;
                if (file.Length >= thresholdBytes)
                {
                    string parentPath;
                    if (snapshot.DirectoryPaths.TryGetValue(file.ParentId, out parentPath))
                    {
                        string normalizedParent = parentPath.TrimEnd('\\');
                        bool inScope =
                            normalizedParent.Equals(scope, StringComparison.OrdinalIgnoreCase) ||
                            normalizedParent.StartsWith(scopePrefix, StringComparison.OrdinalIgnoreCase);
                        if (inScope)
                        {
                            ScanItem item = new ScanItem();
                            item.Path = CombineDisplayPath(parentPath, file.Name);
                            item.Name = file.Name;
                            item.Extension = Path.GetExtension(file.Name);
                            item.Kind = "File";
                            item.Length = file.Length;
                            item.FileCount = 1;
                            matches.Add(item);
                        }
                    }
                }

                if ((processed % 5000) == 0)
                {
                    int percent = (int)((processed * 100.0) / Math.Max(1L, snapshot.TotalFiles));
                    Report(
                        progress,
                        percent,
                        String.Format("Filtering cached file metadata ({0:N0}/{1:N0})", processed, snapshot.TotalFiles));
                }
            }

            matches.Sort(delegate(ScanItem left, ScanItem right)
            {
                return right.Length.CompareTo(left.Length);
            });
            for (int index = 0; index < matches.Count; index++)
            {
                matches[index].Rank = index + 1;
            }

            Report(
                progress,
                100,
                String.Format("File search complete ({0:N0} matches)", matches.Count));
            return matches;
        }

        public static VolumeScanResult ScanMft(
            string rootPath,
            long thresholdBytes,
            Action<int, string> progress)
        {
            DateTime started = DateTime.UtcNow;
            string root = NormalizeRoot(rootPath);
            string volumeName = @"\\.\" + root.Substring(0, 2);
            Report(progress, 1, "Opening the NTFS volume");

            using (SafeFileHandle volume = CreateFile(
                volumeName,
                GenericRead,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                0,
                IntPtr.Zero))
            {
                if (volume.IsInvalid)
                {
                    int error = Marshal.GetLastWin32Error();
                    throw new Win32Exception(
                        error,
                        "Unable to open the volume. Run Windows PowerShell as Administrator.");
                }

                long estimate = GetMftRecordEstimate(volume);
                Dictionary<ulong, MftNode> nodes = EnumerateMft(volume, estimate, progress);
                if (nodes.Count == 0)
                {
                    throw new InvalidOperationException("The MFT enumeration returned no records.");
                }

                Report(progress, 31, "Resolving directory paths");
                MftNode rootNode = FindRootNode(nodes);
                if (rootNode == null)
                {
                    throw new InvalidOperationException("The NTFS root directory record was not found.");
                }

                Dictionary<ulong, string> directoryPaths = new Dictionary<ulong, string>();
                directoryPaths[rootNode.Id] = root;
                rootNode.DirectoryPath = root;

                int resolved = 0;
                long unresolvedDirectories = 0;
                foreach (MftNode node in nodes.Values)
                {
                    if (!node.IsDirectory)
                    {
                        continue;
                    }

                    string path = ResolveDirectoryPath(node, rootNode, root, nodes, directoryPaths);
                    if (String.IsNullOrEmpty(path))
                    {
                        unresolvedDirectories++;
                    }
                    else
                    {
                        node.DirectoryPath = path;
                    }

                    resolved++;
                    if ((resolved % 5000) == 0)
                    {
                        int percent = 31 + (int)Math.Min(9.0, (resolved * 9.0) / Math.Max(1, nodes.Count));
                        Report(
                            progress,
                            percent,
                            String.Format("Resolving directory paths ({0:N0} processed)", resolved));
                    }
                }

                List<MftNode> files = new List<MftNode>();
                foreach (MftNode node in nodes.Values)
                {
                    if (!node.IsDirectory)
                    {
                        files.Add(node);
                    }
                }

                int completed = 0;
                long skippedFiles = 0;
                int workers = Math.Max(2, Math.Min(8, Environment.ProcessorCount * 2));
                Report(
                    progress,
                    41,
                    String.Format("Reading exact file sizes with {0} workers", workers));

                Task sizeTask = Task.Factory.StartNew(delegate
                {
                    Parallel.ForEach(
                        files,
                        new ParallelOptions { MaxDegreeOfParallelism = workers },
                        delegate(MftNode file)
                        {
                            try
                            {
                                string parentPath;
                                if (!directoryPaths.TryGetValue(file.ParentId, out parentPath))
                                {
                                    Interlocked.Increment(ref skippedFiles);
                                    return;
                                }

                                long length;
                                string path = CombineDisplayPath(parentPath, file.Name);
                                if (TryGetLength(path, out length))
                                {
                                    file.Length = length;
                                }
                                else
                                {
                                    Interlocked.Increment(ref skippedFiles);
                                }
                            }
                            catch
                            {
                                Interlocked.Increment(ref skippedFiles);
                            }
                            finally
                            {
                                Interlocked.Increment(ref completed);
                            }
                        });
                });

                while (!sizeTask.Wait(250))
                {
                    int percent = 41 + (int)((completed * 40.0) / Math.Max(1, files.Count));
                    Report(
                        progress,
                        percent,
                        String.Format("Reading file sizes ({0:N0}/{1:N0})", completed, files.Count));
                }

                sizeTask.Wait();
                Report(progress, 82, "File size collection complete");

                return BuildResult(
                    root,
                    "NTFS MFT",
                    thresholdBytes,
                    nodes,
                    directoryPaths,
                    rootNode,
                    skippedFiles,
                    unresolvedDirectories,
                    started,
                    progress);
            }
        }

        public static VolumeScanResult ScanTraversal(
            string rootPath,
            long thresholdBytes,
            Action<int, string> progress)
        {
            DateTime started = DateTime.UtcNow;
            string root = Path.GetFullPath(rootPath);
            if (!Directory.Exists(root))
            {
                throw new DirectoryNotFoundException("Scan target not found: " + root);
            }

            root = root.TrimEnd('\\') + "\\";
            Dictionary<ulong, MftNode> nodes = new Dictionary<ulong, MftNode>();
            Dictionary<ulong, string> directoryPaths = new Dictionary<ulong, string>();
            Stack<MftNode> pending = new Stack<MftNode>();
            ulong nextId = 1;

            MftNode rootNode = new MftNode();
            rootNode.Id = nextId++;
            rootNode.ParentId = rootNode.Id;
            rootNode.Name = root;
            rootNode.IsDirectory = true;
            rootNode.DirectoryPath = root;
            rootNode.Length = 0;
            nodes[rootNode.Id] = rootNode;
            directoryPaths[rootNode.Id] = root;
            pending.Push(rootNode);

            long skippedFiles = 0;
            long skippedDirectories = 0;
            long discovered = 0;
            Report(progress, 5, "Starting directory traversal");

            while (pending.Count > 0)
            {
                MftNode parent = pending.Pop();
                string[] entries;
                try
                {
                    entries = Directory.GetFileSystemEntries(parent.DirectoryPath);
                }
                catch
                {
                    skippedDirectories++;
                    continue;
                }

                foreach (string entry in entries)
                {
                    try
                    {
                        FileAttributes attributes = File.GetAttributes(entry);
                        bool isDirectory = (attributes & FileAttributes.Directory) != 0;
                        bool isReparse = (attributes & FileAttributes.ReparsePoint) != 0;

                        if (isDirectory)
                        {
                            if (isReparse)
                            {
                                skippedDirectories++;
                                continue;
                            }

                            MftNode directory = new MftNode();
                            directory.Id = nextId++;
                            directory.ParentId = parent.Id;
                            directory.Name = Path.GetFileName(entry.TrimEnd('\\'));
                            directory.IsDirectory = true;
                            directory.DirectoryPath = entry;
                            directory.Length = 0;
                            nodes[directory.Id] = directory;
                            directoryPaths[directory.Id] = entry;
                            pending.Push(directory);
                        }
                        else
                        {
                            FileInfo info = new FileInfo(entry);
                            MftNode file = new MftNode();
                            file.Id = nextId++;
                            file.ParentId = parent.Id;
                            file.Name = Path.GetFileName(entry);
                            file.IsDirectory = false;
                            file.Length = info.Length;
                            nodes[file.Id] = file;
                        }
                    }
                    catch
                    {
                        skippedFiles++;
                    }

                    discovered++;
                    if ((discovered % 1000) == 0)
                    {
                        Report(
                            progress,
                            35,
                            String.Format(
                                "Traversing folders ({0:N0} items found; total is not known yet)",
                                discovered));
                    }
                }
            }

            Report(progress, 75, "Traversal complete; calculating directory totals");
            return BuildResult(
                root,
                "Directory traversal",
                thresholdBytes,
                nodes,
                directoryPaths,
                rootNode,
                skippedFiles,
                skippedDirectories,
                started,
                progress);
        }
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp
}

function Test-IsAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-FriendlySize {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [long]$Bytes
    )

    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    # Avoid Math.Max overload inference: an untyped zero makes Windows
    # PowerShell select Int32, which fails for normal drive-sized values.
    $value = if ($Bytes -lt 0) { [double]0 } else { [double]$Bytes }
    $unitIndex = 0
    while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $value /= 1024
        $unitIndex++
    }

    if ($unitIndex -eq 0) {
        return ('{0:N0} {1}' -f $value, $units[$unitIndex])
    }

    return ('{0:N2} {1}' -f $value, $units[$unitIndex])
}

function Resolve-ScanDrive {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$RequestedDrive
    )

    $candidate = $RequestedDrive
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $available = @(
            [System.IO.DriveInfo]::GetDrives() |
                Where-Object { $_.IsReady -and $_.DriveType -in @('Fixed', 'Removable') }
        )

        Write-Host ''
        Write-Host 'Available local drives:' -ForegroundColor Cyan
        foreach ($item in $available) {
            $used = $item.TotalSize - $item.AvailableFreeSpace
            Write-Host (
                '  {0}  {1,-8}  Used {2,10} of {3,10}  {4}' -f
                $item.Name,
                $item.DriveFormat,
                (ConvertTo-FriendlySize $used),
                (ConvertTo-FriendlySize $item.TotalSize),
                $item.VolumeLabel
            )
        }

        $defaultDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
        $candidate = Read-Host "Drive to analyze [$defaultDrive]"
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $candidate = $defaultDrive
        }
    }

    $candidate = $candidate.Trim()
    if ($candidate -match '^[A-Za-z]$') {
        $candidate += ':'
    }

    if ($candidate -match '^[A-Za-z]:$') {
        $candidate += '\'
    }

    if ($candidate -notmatch '^[A-Za-z]:\\$') {
        throw "Enter a local drive such as C: or D:. Received: '$candidate'."
    }

    $root = $candidate.Substring(0, 1).ToUpperInvariant() + ':\'
    if (-not [System.IO.Directory]::Exists($root)) {
        throw "Drive '$root' is not ready or does not exist."
    }

    return $root
}

function Read-ThresholdMB {
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [double]$InitialValue
    )

    if ($InitialValue -gt 0) {
        return $InitialValue
    }

    while ($true) {
        $answer = Read-Host 'Large-file threshold in MB [1024]'
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $script:DefaultThresholdMB
        }

        $parsed = 0.0
        $styles = [Globalization.NumberStyles]::Float -bor [Globalization.NumberStyles]::AllowThousands
        $culture = [Globalization.CultureInfo]::CurrentCulture
        if ([double]::TryParse($answer, $styles, $culture, [ref]$parsed) -and $parsed -gt 0) {
            return $parsed
        }

        Write-Warning 'Enter a number greater than zero, or press Enter for 1024 MB.'
    }
}

function Read-FileSearchScope {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [string]$InitialDirectory
    )

    while ($true) {
        $candidate = $InitialDirectory
        $InitialDirectory = $null

        if ([string]::IsNullOrWhiteSpace($candidate)) {
            Write-Host ''
            Write-Host 'FILE SEARCH SCOPE' -ForegroundColor Cyan
            Write-Host '-----------------'
            Write-Host 'Paste a directory with Ctrl+V, or press Enter for a global drive search.'
            $candidate = Read-Host "Directory [$Root]"
        }

        if ([string]::IsNullOrWhiteSpace($candidate) -or
            $candidate.Trim().Equals('G', [StringComparison]::OrdinalIgnoreCase) -or
            $candidate.Trim().Equals('GLOBAL', [StringComparison]::OrdinalIgnoreCase)) {
            return $Root
        }

        $candidate = [Environment]::ExpandEnvironmentVariables(
            $candidate.Trim().Trim('"').Trim("'")
        )

        try {
            $resolved = [System.IO.Path]::GetFullPath($candidate).TrimEnd('\')
            $rootTrimmed = $Root.TrimEnd('\')
            $insideVolume = $resolved.Equals($rootTrimmed, [StringComparison]::OrdinalIgnoreCase) -or
                $resolved.StartsWith($rootTrimmed + '\', [StringComparison]::OrdinalIgnoreCase)

            if (-not $insideVolume) {
                Write-Warning "The directory must be located on the scanned drive $Root."
                continue
            }
            if (-not [System.IO.Directory]::Exists($resolved)) {
                Write-Warning "Directory not found: $resolved"
                continue
            }

            if ($resolved.Equals($rootTrimmed, [StringComparison]::OrdinalIgnoreCase)) {
                return $Root
            }
            return $resolved
        }
        catch {
            Write-Warning "Invalid directory: $candidate"
        }
    }
}

function Get-DriveFormat {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )

    try {
        $driveInfo = New-Object System.IO.DriveInfo($Root)
        return $driveInfo.DriveFormat
    }
    catch {
        return 'Unknown'
    }
}

function New-ProgressCallback {
    [CmdletBinding()]
    [OutputType([Action[int, string]])]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [string]$Activity
    )

    $script:LastVerboseProgress = -10
    if ([string]::IsNullOrWhiteSpace($Activity)) {
        $Activity = "Analyzing $Root"
    }
    $callback = [Action[int, string]] {
        param(
            [int]$Percentage,
            [string]$Status
        )

        Write-Progress -Id 71 -Activity $Activity -Status $Status -PercentComplete $Percentage

        $bucket = [int]([Math]::Floor($Percentage / 5.0) * 5)
        if ($bucket -ge ($script:LastVerboseProgress + 5) -or $Percentage -eq 100) {
            Write-Verbose ('{0,3}% {1}' -f $Percentage, $Status)
            $script:LastVerboseProgress = $bucket
        }
    }.GetNewClosure()

    return $callback
}

function Invoke-VolumeAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [long]$ThresholdBytes,

        [Parameter(Mandatory)]
        [ValidateSet('Auto', 'MFT', 'Traversal')]
        [string]$Mode
    )

    $format = Get-DriveFormat -Root $Root
    $isAdministrator = Test-IsAdministrator
    $callback = New-ProgressCallback -Root $Root
    $useMft = $Mode -eq 'MFT' -or ($Mode -eq 'Auto' -and $format -eq 'NTFS' -and $isAdministrator)

    if ($Mode -eq 'MFT' -and $format -ne 'NTFS') {
        throw "MFT mode requires NTFS. Drive $Root uses '$format'."
    }

    if ($Mode -eq 'MFT' -and -not $isAdministrator) {
        throw 'MFT mode requires an elevated Windows PowerShell session (Run as Administrator).'
    }

    if ($useMft) {
        try {
            Write-Host "Scan method: Native NTFS MFT enumeration" -ForegroundColor Green
            return [D4A.Storage.V3.FastVolumeScanner]::ScanMft($Root, $ThresholdBytes, $callback)
        }
        catch {
            Write-Progress -Id 71 -Activity "Analyzing $Root" -Completed
            if ($Mode -eq 'MFT') {
                throw
            }

            Write-Warning "MFT scan was unavailable: $($_.Exception.Message)"
            Write-Warning 'Continuing with directory traversal. This will be slower.'
        }
    }
    else {
        if ($Mode -eq 'Auto' -and $format -eq 'NTFS' -and -not $isAdministrator) {
            Write-Warning 'The session is not elevated, so direct MFT access is unavailable.'
            Write-Warning 'Run Windows PowerShell as Administrator for the fastest scan.'
        }
        elseif ($Mode -eq 'Auto' -and $format -ne 'NTFS') {
            Write-Warning "Drive $Root uses '$format'; direct MFT access is NTFS-only."
        }
    }

    Write-Host 'Scan method: Directory traversal fallback' -ForegroundColor Yellow
    return [D4A.Storage.V3.FastVolumeScanner]::ScanTraversal($Root, $ThresholdBytes, $callback)
}

function Invoke-CachedFileSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [D4A.Storage.V3.VolumeScanResult]$Result,

        [Parameter(Mandatory)]
        [string]$Scope,

        [Parameter(Mandatory)]
        [long]$ThresholdBytes
    )

    $callback = New-ProgressCallback -Root $Result.RootPath -Activity "Searching files in $Scope"
    $matches = [D4A.Storage.V3.FastVolumeScanner]::FindLargeFiles(
        $Result,
        $Scope,
        $ThresholdBytes,
        $callback
    )
    Write-Progress -Id 71 -Activity "Searching files in $Scope" -Completed

    $Result.FileSearchScope = $Scope
    $Result.ThresholdBytes = $ThresholdBytes
    $Result.LargeFiles = $matches
    return $Result
}

function Test-SystemOrProtectedPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root
    )

    $normalized = $Path.TrimEnd('\')
    $rootTrimmed = $Root.TrimEnd('\')

    $systemPrefixes = @(
        "$rootTrimmed\Windows",
        "$rootTrimmed\Program Files",
        "$rootTrimmed\Program Files (x86)",
        "$rootTrimmed\ProgramData",
        "$rootTrimmed\System Volume Information",
        "$rootTrimmed\`$Recycle.Bin",
        "$rootTrimmed\Recovery",
        "$rootTrimmed\Boot",
        "$rootTrimmed\EFI",
        "$rootTrimmed\PerfLogs",
        "$rootTrimmed\Documents and Settings",
        "$rootTrimmed\Users\Default",
        "$rootTrimmed\Users\Default User",
        "$rootTrimmed\Users\All Users",
        "$rootTrimmed\Users\Public"
    )

    if ($normalized.Equals($rootTrimmed, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    if ($normalized.Equals("$rootTrimmed\Users", [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    foreach ($prefix in $systemPrefixes) {
        if ($normalized.Equals($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            $normalized.StartsWith($prefix + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    $leaf = [System.IO.Path]::GetFileName($normalized)
    $protectedRootFiles = @(
        'pagefile.sys',
        'hiberfil.sys',
        'swapfile.sys',
        'bootmgr',
        'bootnxt',
        'memory.dmp'
    )
    if ($protectedRootFiles -contains $leaf.ToLowerInvariant()) {
        return $true
    }

    $upperPath = $normalized.ToUpperInvariant()
    if ($upperPath -match '\\APPDATA\\(?!LOCAL\\TEMP(?:\\|$))') {
        return $true
    }

    $protectedExtensions = @('.mdf', '.ndf', '.ldf', '.edb', '.vhd', '.vhdx', '.avhdx', '.pst', '.ost')
    $extension = [System.IO.Path]::GetExtension($normalized).ToLowerInvariant()
    return $protectedExtensions -contains $extension
}

function Get-PurgeRecommendations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [D4A.Storage.V3.VolumeScanResult]$Result
    )

    $recommendations = New-Object System.Collections.Generic.List[object]
    $candidateExtensions = @(
        '.tmp', '.temp', '.dmp', '.dump', '.bak', '.old', '.log', '.etl',
        '.evtx', '.zip', '.7z', '.rar', '.iso', '.img', '.cab'
    )
    $candidatePathPattern = '\\(Temp|Tmp|Cache|Caches|Logs?|CrashDumps?|Dumps?|Downloads?|Backups?|Archives?)(\\|$)'

    foreach ($file in $Result.LargeFiles) {
        if (Test-SystemOrProtectedPath -Path $file.Path -Root $Result.RootPath) {
            continue
        }

        $extension = $file.Extension.ToLowerInvariant()
        $isStrongCandidate = $candidateExtensions -contains $extension -or $file.Path -match $candidatePathPattern
        $reason = if ($isStrongCandidate) {
            'Likely temporary, diagnostic, backup, archive, or downloaded content. Verify retention needs before removal.'
        }
        else {
            'Large non-system file. Confirm ownership, backup, and application dependencies before removal.'
        }

        $priority = if ($isStrongCandidate) { 1 } else { 2 }
        $recommendations.Add([pscustomobject]@{
                Priority = $priority
                Kind     = 'File'
                Length   = [long]$file.Length
                Size     = ConvertTo-FriendlySize $file.Length
                Path     = $file.Path
                Reason   = $reason
            })
    }

    foreach ($folder in $Result.LargeFolders) {
        if (Test-SystemOrProtectedPath -Path $folder.Path -Root $Result.RootPath) {
            continue
        }

        $isStrongCandidate = $folder.Path -match $candidatePathPattern
        $isBroadProfile = $folder.Path -match '^[A-Za-z]:\\Users\\[^\\]+$'
        if ($isBroadProfile) {
            continue
        }

        $reason = if ($isStrongCandidate) {
            'Likely cache, temporary, log, download, backup, dump, or archive folder. Review contents and retention first.'
        }
        else {
            'Large non-system folder. Review with its owner; remove only confirmed obsolete contents.'
        }

        $priority = if ($isStrongCandidate) { 1 } else { 3 }
        $recommendations.Add([pscustomobject]@{
                Priority = $priority
                Kind     = 'Folder'
                Length   = [long]$folder.Length
                Size     = ConvertTo-FriendlySize $folder.Length
                Path     = $folder.Path
                Reason   = $reason
            })
    }

    return @(
        $recommendations |
            Sort-Object Priority, @{ Expression = 'Length'; Descending = $true }, Path
    )
}

function Get-ConsoleSubset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [int]$Limit
    )

    if ($Limit -eq 0 -or $Items.Count -le $Limit) {
        return $Items
    }

    return @($Items | Select-Object -First $Limit)
}

function Write-RankedConsoleTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [object[]]$Items,

        [Parameter()]
        [int]$Limit = 100,

        [Parameter()]
        [switch]$ShowFileCount
    )

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * [Math]::Min(100, [Math]::Max(20, $Title.Length)))

    if ($Items.Count -eq 0) {
        Write-Host '  None found at or above the selected threshold.' -ForegroundColor DarkGray
        return
    }

    $displayItems = @(Get-ConsoleSubset -Items $Items -Limit $Limit)
    $rank = 0
    foreach ($item in $displayItems) {
        $rank++
        if ($ShowFileCount) {
            Write-Host (
                '{0,4}. {1,12}  {2,10:N0} files  {3}' -f
                $rank,
                (ConvertTo-FriendlySize $item.Length),
                $item.FileCount,
                $item.Path
            )
        }
        else {
            Write-Host (
                '{0,4}. {1,12}  {2}' -f
                $rank,
                (ConvertTo-FriendlySize $item.Length),
                $item.Path
            )
        }
    }

    if ($displayItems.Count -lt $Items.Count) {
        Write-Host (
            '  Showing {0:N0} of {1:N0}. The searchable window contains the full list.' -f
            $displayItems.Count,
            $Items.Count
        ) -ForegroundColor Yellow
    }
}

function Get-RelativeDirectoryDepth {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root
    )

    $rootWithSlash = $Root.TrimEnd('\') + '\'
    if (-not $Path.StartsWith($rootWithSlash, [StringComparison]::OrdinalIgnoreCase)) {
        return 0
    }

    $relative = $Path.Substring($rootWithSlash.Length).Trim('\')
    if ([string]::IsNullOrWhiteSpace($relative)) {
        return 0
    }

    return @($relative.Split('\') | Where-Object { $_.Length -gt 0 }).Count
}

function Write-QuickFolderReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [D4A.Storage.V3.VolumeScanResult]$Result,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$MaximumDepth = 3,

        [Parameter()]
        [int]$ItemLimit = 100
    )

    Write-Progress -Id 71 -Activity "Analyzing $($Result.RootPath)" -Completed
    Write-Host ''
    Write-Host ('=' * 100) -ForegroundColor DarkGray
    Write-Host $script:AnalyzerName -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host ''
    Write-Host 'QUICK FOLDER SCAN COMPLETE' -ForegroundColor Green
    Write-Host '--------------------------'
    Write-Host ('Drive:             {0}' -f $Result.RootPath)
    Write-Host ('Method:            {0}' -f $Result.ScanMethod)
    Write-Host ('Elapsed:           {0}' -f $Result.Elapsed.ToString('hh\:mm\:ss'))
    Write-Host ('Folder threshold:  {0}' -f (ConvertTo-FriendlySize $Result.FolderThresholdBytes))
    Write-Host ('Mapped:            {0:N0} files, {1:N0} folders, {2}' -f
        $Result.TotalFiles,
        $Result.TotalDirectories,
        (ConvertTo-FriendlySize $Result.TotalBytes))
    Write-Host ''
    Write-Host (
        "Largest directories and subdirectories through level $MaximumDepth " +
        "(each at least $(ConvertTo-FriendlySize $Result.FolderThresholdBytes)):"
    ) -ForegroundColor Cyan

    $foundAny = $false
    for ($depth = 1; $depth -le $MaximumDepth; $depth++) {
        $atDepth = @(
            $Result.LargeFolders |
                Where-Object {
                    (Get-RelativeDirectoryDepth -Path $_.Path -Root $Result.RootPath) -eq $depth
                } |
                Sort-Object -Property @{ Expression = 'Length'; Descending = $true }
        )

        if ($atDepth.Count -eq 0) {
            continue
        }

        $foundAny = $true
        Write-Host ''
        Write-Host ("Level {0} ({1:N0} matching folders)" -f $depth, $atDepth.Count) -ForegroundColor Yellow
        $display = @(Get-ConsoleSubset -Items $atDepth -Limit $ItemLimit)
        $index = 0
        foreach ($folder in $display) {
            $index++
            $indent = '  ' * $depth
            Write-Host (
                '{0}{1,3}. {2,12}  {3,10:N0} files  {4}' -f
                $indent,
                $index,
                (ConvertTo-FriendlySize $folder.Length),
                $folder.FileCount,
                $folder.Path
            )
        }

        if ($display.Count -lt $atDepth.Count) {
            Write-Host (
                '  Showing {0:N0} of {1:N0} folders at this level.' -f
                $display.Count,
                $atDepth.Count
            ) -ForegroundColor DarkYellow
        }
    }

    if (-not $foundAny) {
        Write-Host '  No folders above 1 GB were found within the first three levels.' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host 'The disk snapshot is cached; the next file search does not rescan the volume.' -ForegroundColor Green
}

function Get-ResultSummaryText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [D4A.Storage.V3.VolumeScanResult]$Result,

        [Parameter(Mandatory)]
        [object[]]$Recommendations
    )

    $lines = @(
        $script:AnalyzerName
        ('=' * $script:AnalyzerName.Length)
        ''
        "Drive:                  $($Result.RootPath)"
        "Scan method:            $($Result.ScanMethod)"
        "Elapsed:                $($Result.Elapsed.ToString('hh\:mm\:ss'))"
        "File search scope:       $($Result.FileSearchScope)"
        "File threshold:          $(ConvertTo-FriendlySize $Result.ThresholdBytes)"
        "Folder threshold:        $(ConvertTo-FriendlySize $Result.FolderThresholdBytes)"
        "Logical bytes mapped:   $(ConvertTo-FriendlySize $Result.TotalBytes)"
        "Files mapped:           $($Result.TotalFiles.ToString('N0'))"
        "Folders mapped:         $($Result.TotalDirectories.ToString('N0'))"
        "Files above threshold:  $($Result.LargeFiles.Count.ToString('N0'))"
        "Folders above threshold:$($Result.LargeFolders.Count.ToString('N0'))"
        "Unreadable/stale files: $($Result.SkippedFiles.ToString('N0'))"
        "Unresolved folders:     $($Result.SkippedDirectories.ToString('N0'))"
        "Review recommendations: $($Recommendations.Count.ToString('N0'))"
        ''
        'Safety note'
        '-----------'
        'Recommendations exclude Windows, Program Files, ProgramData, recovery, boot,'
        'system metadata, standard paging/hibernation files, application databases,'
        'virtual disks, Outlook data, and most AppData content. A recommendation is'
        'not an instruction to delete: confirm ownership, retention, backups, and'
        'application dependencies first.'
        ''
        'Size note'
        '---------'
        'Values are logical sizes. Allocated disk usage can differ for compressed,'
        'sparse, deduplicated, hard-linked, or alternate-stream data.'
    )

    return $lines -join [Environment]::NewLine
}

function Write-ScanReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [D4A.Storage.V3.VolumeScanResult]$Result,

        [Parameter(Mandatory)]
        [object[]]$Recommendations,

        [Parameter(Mandatory)]
        [int]$ItemLimit
    )

    Write-Progress -Id 71 -Activity "Analyzing $($Result.RootPath)" -Completed
    Clear-Host

    Write-Host $script:AnalyzerName -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host ''
    Write-Host ('Drive:       {0}' -f $Result.RootPath)
    Write-Host ('Method:      {0}' -f $Result.ScanMethod)
    Write-Host ('Elapsed:     {0}' -f $Result.Elapsed.ToString('hh\:mm\:ss'))
    Write-Host ('File scope:  {0}' -f $Result.FileSearchScope)
    Write-Host ('File limit:  {0}' -f (ConvertTo-FriendlySize $Result.ThresholdBytes))
    Write-Host ('Folder limit:{0}' -f (ConvertTo-FriendlySize $Result.FolderThresholdBytes))
    Write-Host ('Mapped:      {0:N0} files, {1:N0} folders, {2}' -f
        $Result.TotalFiles,
        $Result.TotalDirectories,
        (ConvertTo-FriendlySize $Result.TotalBytes))
    Write-Host ('Skipped:     {0:N0} files, {1:N0} folders' -f
        $Result.SkippedFiles,
        $Result.SkippedDirectories)

    $folders = @($Result.LargeFolders | Where-Object {
            -not $_.Path.TrimEnd('\').Equals(
                $Result.RootPath.TrimEnd('\'),
                [StringComparison]::OrdinalIgnoreCase)
        })

    Write-RankedConsoleTable `
        -Title "LARGEST FOLDERS AT OR ABOVE $(ConvertTo-FriendlySize $Result.FolderThresholdBytes)" `
        -Items $folders -Limit $ItemLimit -ShowFileCount
    Write-RankedConsoleTable -Title 'LARGE FILES AT OR ABOVE THRESHOLD' `
        -Items @($Result.LargeFiles) -Limit $ItemLimit

    Write-Host ''
    Write-Host 'RECOMMENDATIONS FOR REVIEW' -ForegroundColor Yellow
    Write-Host '--------------------------'
    Write-Host (
        'System and protected application paths are intentionally excluded. ' +
        'Never delete an item solely because it appears here.'
    ) -ForegroundColor DarkYellow

    if ($Recommendations.Count -eq 0) {
        Write-Host '  No non-system review candidates were found at this threshold.' -ForegroundColor DarkGray
    }
    else {
        $recommendationSubset = @(Get-ConsoleSubset -Items $Recommendations -Limit $ItemLimit)
        $index = 0
        foreach ($item in $recommendationSubset) {
            $index++
            Write-Host ('{0,4}. [{1}] {2,12}  {3}' -f $index, $item.Kind, $item.Size, $item.Path)
            Write-Host ('      {0}' -f $item.Reason) -ForegroundColor DarkGray
        }

        if ($recommendationSubset.Count -lt $Recommendations.Count) {
            Write-Host (
                '  Showing {0:N0} of {1:N0} recommendations.' -f
                $recommendationSubset.Count,
                $Recommendations.Count
            ) -ForegroundColor Yellow
        }
    }
}

function Export-ScanData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [D4A.Storage.V3.VolumeScanResult]$Result,

        [Parameter(Mandatory)]
        [object[]]$Recommendations,

        [Parameter(Mandatory)]
        [string]$Directory
    )

    if (-not [System.IO.Directory]::Exists($Directory)) {
        $null = New-Item -ItemType Directory -Path $Directory -Force
    }

    $resolvedDirectory = [System.IO.Path]::GetFullPath($Directory)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $driveLabel = $Result.RootPath.Substring(0, 1)
    $prefix = Join-Path $resolvedDirectory "DiskAnalysis_${driveLabel}_$stamp"

    $fileRows = foreach ($item in $Result.LargeFiles) {
        [pscustomobject]@{
            Rank      = $item.Rank
            SizeBytes = $item.Length
            Size      = ConvertTo-FriendlySize $item.Length
            Extension = $item.Extension
            Path      = $item.Path
        }
    }

    $folderRows = foreach ($item in $Result.LargeFolders) {
        [pscustomobject]@{
            Rank      = $item.Rank
            SizeBytes = $item.Length
            Size      = ConvertTo-FriendlySize $item.Length
            FileCount = $item.FileCount
            Path      = $item.Path
        }
    }

    $filePath = "${prefix}_LargeFiles.csv"
    $folderPath = "${prefix}_LargeFolders.csv"
    $recommendationPath = "${prefix}_Recommendations.csv"
    $summaryPath = "${prefix}_Summary.txt"

    @($fileRows) | Export-Csv -LiteralPath $filePath -NoTypeInformation -Encoding UTF8
    @($folderRows) | Export-Csv -LiteralPath $folderPath -NoTypeInformation -Encoding UTF8
    @($Recommendations) | Export-Csv -LiteralPath $recommendationPath -NoTypeInformation -Encoding UTF8
    Get-ResultSummaryText -Result $Result -Recommendations $Recommendations |
        Set-Content -LiteralPath $summaryPath -Encoding UTF8

    return [pscustomobject]@{
        Summary        = $summaryPath
        LargeFiles     = $filePath
        LargeFolders   = $folderPath
        Recommendations = $recommendationPath
    }
}

function New-ResultDataTable {
    [CmdletBinding()]
    [OutputType([System.Data.DataTable])]
    param(
        [Parameter(Mandatory)]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [ValidateSet('File', 'Folder', 'Recommendation')]
        [string]$TableType
    )

    $table = New-Object System.Data.DataTable
    $null = $table.Columns.Add('Rank', [int])
    $null = $table.Columns.Add('Size (GiB)', [double])
    $null = $table.Columns.Add('Size', [string])
    $null = $table.Columns.Add('Kind', [string])
    $null = $table.Columns.Add('Files', [long])
    $null = $table.Columns.Add('Extension', [string])
    $null = $table.Columns.Add('Path', [string])
    $null = $table.Columns.Add('Recommendation', [string])

    $rank = 0
    foreach ($item in $Items) {
        $rank++
        $row = $table.NewRow()
        $row['Rank'] = if ($item.PSObject.Properties['Rank']) { [int]$item.Rank } else { $rank }
        $row['Size (GiB)'] = [Math]::Round(([double]$item.Length / 1GB), 4)
        $row['Size'] = ConvertTo-FriendlySize $item.Length
        $row['Kind'] = if ($item.PSObject.Properties['Kind']) { $item.Kind } else { $TableType }
        $row['Files'] = if ($item.PSObject.Properties['FileCount']) { [long]$item.FileCount } else { 1 }
        $row['Extension'] = if ($item.PSObject.Properties['Extension']) { $item.Extension } else { '' }
        $row['Path'] = $item.Path
        $row['Recommendation'] = if ($item.PSObject.Properties['Reason']) { $item.Reason } else { '' }
        $table.Rows.Add($row)
    }

    Write-Output -NoEnumerate $table
}

function Add-SearchableGridTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabControl]$TabControl,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [System.Data.DataTable]$DataTable,

        [Parameter(Mandatory)]
        [ValidateSet('File', 'Folder', 'Recommendation')]
        [string]$TableType
    )

    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = "$Title ($($DataTable.Rows.Count.ToString('N0')))"

    $searchPanel = New-Object System.Windows.Forms.Panel
    $searchPanel.Dock = 'Top'
    $searchPanel.Height = 42

    $searchLabel = New-Object System.Windows.Forms.Label
    $searchLabel.Text = 'Search:'
    $searchLabel.AutoSize = $true
    $searchLabel.Left = 10
    $searchLabel.Top = 13

    $searchBox = New-Object System.Windows.Forms.TextBox
    $searchBox.Left = 70
    $searchBox.Top = 9
    $searchBox.Width = 500
    $searchBox.Anchor = 'Top,Left,Right'

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Click a column heading to sort.'
    $hint.AutoSize = $true
    $hint.Top = 13
    $hint.Left = 585
    $hint.ForeColor = [System.Drawing.Color]::DimGray

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AutoGenerateColumns = $true
    $grid.AutoSizeRowsMode = 'None'
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.RowHeadersVisible = $false
    $grid.DataSource = $DataTable.DefaultView

    $searchHandler = {
        try {
            $value = $searchBox.Text.Replace("'", "''").Replace('[', '[[]').Replace('%', '[%]').Replace('*', '[*]')
            if ([string]::IsNullOrWhiteSpace($value)) {
                $DataTable.DefaultView.RowFilter = ''
            }
            else {
                $DataTable.DefaultView.RowFilter = (
                    "[Path] LIKE '%$value%' OR [Extension] LIKE '%$value%' OR " +
                    "[Kind] LIKE '%$value%' OR [Recommendation] LIKE '%$value%'"
                )
            }
        }
        catch {
            $DataTable.DefaultView.RowFilter = ''
        }
    }.GetNewClosure()
    $searchBox.Add_TextChanged($searchHandler)

    $gridHandler = {
        if ($grid.Columns['Rank']) {
            $grid.Columns['Rank'].Width = 55
        }
        if ($grid.Columns['Size (GiB)']) {
            $grid.Columns['Size (GiB)'].Width = 90
            $grid.Columns['Size (GiB)'].DefaultCellStyle.Format = 'N3'
        }
        if ($grid.Columns['Size']) {
            $grid.Columns['Size'].Width = 90
        }
        if ($grid.Columns['Kind']) {
            $grid.Columns['Kind'].Width = 70
        }
        if ($grid.Columns['Files']) {
            $grid.Columns['Files'].Width = 90
            $grid.Columns['Files'].DefaultCellStyle.Format = 'N0'
            $grid.Columns['Files'].Visible = $TableType -eq 'Folder'
        }
        if ($grid.Columns['Extension']) {
            $grid.Columns['Extension'].Width = 85
            $grid.Columns['Extension'].Visible = $TableType -eq 'File'
        }
        if ($grid.Columns['Recommendation']) {
            $grid.Columns['Recommendation'].Width = 440
            $grid.Columns['Recommendation'].Visible = $TableType -eq 'Recommendation'
        }
        if ($grid.Columns['Path']) {
            $grid.Columns['Path'].AutoSizeMode = 'Fill'
            $grid.Columns['Path'].MinimumWidth = 300
        }
    }.GetNewClosure()
    $grid.Add_DataBindingComplete($gridHandler)
    & $gridHandler

    $searchPanel.Controls.Add($searchLabel)
    $searchPanel.Controls.Add($searchBox)
    $searchPanel.Controls.Add($hint)
    $tab.Controls.Add($grid)
    $tab.Controls.Add($searchPanel)
    $TabControl.TabPages.Add($tab)
}

function Get-TreemapRectangles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [System.Drawing.RectangleF]$Bounds
    )

    $output = New-Object System.Collections.Generic.List[object]

    function Add-RectangleGroup {
        param(
            [object[]]$Group,
            [System.Drawing.RectangleF]$Area
        )

        if ($Group.Count -eq 0 -or $Area.Width -lt 2 -or $Area.Height -lt 2) {
            return
        }

        if ($Group.Count -eq 1) {
            $output.Add([pscustomobject]@{
                    Item      = $Group[0]
                    Rectangle = $Area
                })
            return
        }

        $total = [double](($Group | Measure-Object -Property Length -Sum).Sum)
        if ($total -le 0) {
            return
        }

        $half = $total / 2.0
        $running = 0.0
        $splitIndex = 0
        for ($index = 0; $index -lt ($Group.Count - 1); $index++) {
            $running += [double]$Group[$index].Length
            $splitIndex = $index + 1
            if ($running -ge $half) {
                break
            }
        }

        if ($splitIndex -le 0 -or $splitIndex -ge $Group.Count) {
            $splitIndex = [Math]::Max(1, [int]($Group.Count / 2))
            $running = [double](($Group[0..($splitIndex - 1)] | Measure-Object -Property Length -Sum).Sum)
        }

        $ratio = [Math]::Max(0.05, [Math]::Min(0.95, $running / $total))
        $first = @($Group[0..($splitIndex - 1)])
        $second = @($Group[$splitIndex..($Group.Count - 1)])

        if ($Area.Width -ge $Area.Height) {
            $firstWidth = [single]($Area.Width * $ratio)
            $firstArea = New-Object System.Drawing.RectangleF(
                $Area.X,
                $Area.Y,
                $firstWidth,
                $Area.Height
            )
            $secondArea = New-Object System.Drawing.RectangleF(
                ($Area.X + $firstWidth),
                $Area.Y,
                ($Area.Width - $firstWidth),
                $Area.Height
            )
        }
        else {
            $firstHeight = [single]($Area.Height * $ratio)
            $firstArea = New-Object System.Drawing.RectangleF(
                $Area.X,
                $Area.Y,
                $Area.Width,
                $firstHeight
            )
            $secondArea = New-Object System.Drawing.RectangleF(
                $Area.X,
                ($Area.Y + $firstHeight),
                $Area.Width,
                ($Area.Height - $firstHeight)
            )
        }

        Add-RectangleGroup -Group $first -Area $firstArea
        Add-RectangleGroup -Group $second -Area $secondArea
    }

    Add-RectangleGroup -Group $Items -Area $Bounds
    return @($output | ForEach-Object { $_ })
}

function Get-TreemapColor {
    [CmdletBinding()]
    [OutputType([System.Drawing.Color])]
    param(
        [Parameter(Mandatory)]
        [object]$Item
    )

    if ($Item.Kind -eq 'Folder') {
        return [System.Drawing.Color]::FromArgb(63, 111, 166)
    }

    $palette = @(
        [System.Drawing.Color]::FromArgb(225, 87, 89),
        [System.Drawing.Color]::FromArgb(242, 142, 43),
        [System.Drawing.Color]::FromArgb(89, 161, 79),
        [System.Drawing.Color]::FromArgb(118, 183, 178),
        [System.Drawing.Color]::FromArgb(176, 122, 161),
        [System.Drawing.Color]::FromArgb(237, 201, 72),
        [System.Drawing.Color]::FromArgb(255, 157, 167),
        [System.Drawing.Color]::FromArgb(156, 117, 95)
    )
    $key = if ($Item.Extension) { $Item.Extension.ToLowerInvariant() } else { $Item.Name }
    $index = [int]([Math]::Abs([long]$key.GetHashCode()) % $palette.Count)
    return $palette[$index]
}

function Add-TreemapTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Forms.TabControl]$TabControl,

        [Parameter(Mandatory)]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [int]$ItemLimit
    )

    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = 'Treemap'

    $heading = New-Object System.Windows.Forms.Label
    $heading.Dock = 'Top'
    $heading.Height = 44
    $heading.Padding = New-Object System.Windows.Forms.Padding(8, 7, 8, 4)
    $heading.Text = (
        'Largest folders (blue) and files (colors by extension), shown as independent ranked consumers. ' +
        'Hover over a block for its full path and size.'
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Fill'
    $panel.BackColor = [System.Drawing.Color]::WhiteSmoke
    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 15000
    $toolTip.InitialDelay = 250
    $toolTip.ReshowDelay = 100

    $treeItems = @(
        $Items |
            Sort-Object -Property @{ Expression = 'Length'; Descending = $true } |
            Select-Object -First $ItemLimit
    )
    # Windows Forms events run in a child callback scope. Capture the helper
    # scriptblocks explicitly so they remain callable when the tab is entered
    # or the panel is resized.
    $layoutCommand = ${function:Get-TreemapRectangles}
    $colorCommand = ${function:Get-TreemapColor}
    $sizeCommand = ${function:ConvertTo-FriendlySize}

    $refresh = {
        $panel.SuspendLayout()
        try {
            $panel.Controls.Clear()
            if ($treeItems.Count -eq 0 -or $panel.ClientSize.Width -lt 20 -or $panel.ClientSize.Height -lt 20) {
                return
            }

            $bounds = New-Object System.Drawing.RectangleF(
                2,
                2,
                [single]($panel.ClientSize.Width - 4),
                [single]($panel.ClientSize.Height - 4)
            )
            $rectangles = @(& $layoutCommand -Items $treeItems -Bounds $bounds)
            foreach ($entry in $rectangles) {
                $rectangle = $entry.Rectangle
                if ($rectangle.Width -lt 3 -or $rectangle.Height -lt 3) {
                    continue
                }

                $item = $entry.Item
                $label = New-Object System.Windows.Forms.Label
                $label.Left = [int][Math]::Round($rectangle.X + 1)
                $label.Top = [int][Math]::Round($rectangle.Y + 1)
                $label.Width = [Math]::Max(1, [int][Math]::Round($rectangle.Width - 2))
                $label.Height = [Math]::Max(1, [int][Math]::Round($rectangle.Height - 2))
                $label.BackColor = & $colorCommand -Item $item
                $label.ForeColor = [System.Drawing.Color]::White
                $label.BorderStyle = 'FixedSingle'
                $label.Padding = New-Object System.Windows.Forms.Padding(3)
                $label.AutoEllipsis = $true
                $label.TextAlign = 'MiddleCenter'

                if ($label.Width -ge 90 -and $label.Height -ge 35) {
                    $label.Text = "$($item.Name)`r`n$(& $sizeCommand -Bytes $item.Length)"
                }
                elseif ($label.Width -ge 45 -and $label.Height -ge 18) {
                    $label.Text = $item.Name
                }

                $toolTip.SetToolTip(
                    $label,
                    "$($item.Kind): $($item.Path)`r`nLogical size: $(& $sizeCommand -Bytes $item.Length)"
                )
                $panel.Controls.Add($label)
            }
        }
        finally {
            $panel.ResumeLayout()
        }
    }.GetNewClosure()

    $panel.Add_Resize($refresh)
    $tab.Add_Enter($refresh)
    $tab.Controls.Add($panel)
    $tab.Controls.Add($heading)
    $TabControl.TabPages.Add($tab)
}

function Show-ResultWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [D4A.Storage.V3.VolumeScanResult]$Result,

        [Parameter(Mandatory)]
        [object[]]$Recommendations,

        [Parameter(Mandatory)]
        [int]$TreemapLimit
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Data

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$script:AnalyzerName - $($Result.RootPath)"
    $form.StartPosition = 'CenterScreen'
    $form.Width = 1400
    $form.Height = 850
    $form.MinimumSize = New-Object System.Drawing.Size(1000, 650)
    $form.Icon = [System.Drawing.SystemIcons]::Information

    $topPanel = New-Object System.Windows.Forms.Panel
    $topPanel.Dock = 'Top'
    $topPanel.Height = 58
    $topPanel.BackColor = [System.Drawing.Color]::FromArgb(28, 55, 84)

    $title = New-Object System.Windows.Forms.Label
    $title.AutoSize = $true
    $title.Left = 14
    $title.Top = 10
    $title.ForeColor = [System.Drawing.Color]::White
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $title.Text = (
        "$($Result.RootPath)  |  $($Result.ScanMethod)  |  " +
        "Files >= $(ConvertTo-FriendlySize $Result.ThresholdBytes)  |  " +
        "Folders >= $(ConvertTo-FriendlySize $Result.FolderThresholdBytes)"
    )

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.AutoSize = $true
    $subtitle.Left = 16
    $subtitle.Top = 37
    $subtitle.ForeColor = [System.Drawing.Color]::Gainsboro
    $subtitle.Text = (
        '{0:N0} files, {1:N0} folders, {2} logical, completed in {3}' -f
        $Result.TotalFiles,
        $Result.TotalDirectories,
        (ConvertTo-FriendlySize $Result.TotalBytes),
        $Result.Elapsed.ToString('hh\:mm\:ss')
    )
    $topPanel.Controls.Add($title)
    $topPanel.Controls.Add($subtitle)

    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = 'Bottom'
    $bottomPanel.Height = 52

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close results'
    $closeButton.Width = 120
    $closeButton.Height = 30
    $closeButton.Top = 10
    $closeButton.Anchor = 'Top,Right'
    $closeButton.Left = $form.ClientSize.Width - 140
    $closeButton.Add_Click({ $form.Close() }.GetNewClosure())

    $exportButton = New-Object System.Windows.Forms.Button
    $exportButton.Text = 'Export CSV report...'
    $exportButton.Width = 150
    $exportButton.Height = 30
    $exportButton.Top = 10
    $exportButton.Left = 12
    $exportCommand = ${function:Export-ScanData}
    $exportButton.Add_Click({
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Choose a folder for the CSV and summary reports.'
            $dialog.ShowNewFolderButton = $true
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                try {
                    $paths = & $exportCommand -Result $Result `
                        -Recommendations $Recommendations -Directory $dialog.SelectedPath
                    [System.Windows.Forms.MessageBox]::Show(
                        "Reports exported to:`r`n$($dialog.SelectedPath)",
                        $script:AnalyzerName,
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Information
                    )
                }
                catch {
                    [System.Windows.Forms.MessageBox]::Show(
                        $_.Exception.Message,
                        'Export failed',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error
                    )
                }
            }
            $dialog.Dispose()
        }.GetNewClosure())

    $bottomPanel.Controls.Add($exportButton)
    $bottomPanel.Controls.Add($closeButton)
    $bottomPanel.Add_Resize({
            $closeButton.Left = $bottomPanel.ClientSize.Width - $closeButton.Width - 12
        }.GetNewClosure())

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'

    $summaryTab = New-Object System.Windows.Forms.TabPage
    $summaryTab.Text = 'Summary'
    $summaryBox = New-Object System.Windows.Forms.RichTextBox
    $summaryBox.Dock = 'Fill'
    $summaryBox.ReadOnly = $true
    $summaryBox.BackColor = [System.Drawing.Color]::White
    $summaryBox.Font = New-Object System.Drawing.Font('Consolas', 10)
    $summaryBox.Text = Get-ResultSummaryText -Result $Result -Recommendations $Recommendations
    $summaryTab.Controls.Add($summaryBox)
    $tabs.TabPages.Add($summaryTab)

    $folderItems = @($Result.LargeFolders | Where-Object {
            -not $_.Path.TrimEnd('\').Equals(
                $Result.RootPath.TrimEnd('\'),
                [StringComparison]::OrdinalIgnoreCase)
        })
    $treemapItems = @(
        @($folderItems | Select-Object -First ([Math]::Ceiling($TreemapLimit / 2.0)))
        @($Result.LargeFiles | Select-Object -First ([Math]::Floor($TreemapLimit / 2.0)))
    )
    Add-TreemapTab -TabControl $tabs -Items $treemapItems -ItemLimit $TreemapLimit

    $fileTable = New-ResultDataTable -Items @($Result.LargeFiles) -TableType File
    Add-SearchableGridTab -TabControl $tabs -Title 'Large files' -DataTable $fileTable -TableType File

    $folderTable = New-ResultDataTable -Items $folderItems -TableType Folder
    Add-SearchableGridTab -TabControl $tabs -Title 'Large folders' -DataTable $folderTable -TableType Folder

    $recommendationTable = New-ResultDataTable -Items $Recommendations -TableType Recommendation
    Add-SearchableGridTab -TabControl $tabs -Title 'Recommendations' `
        -DataTable $recommendationTable -TableType Recommendation

    $form.Controls.Add($tabs)
    $form.Controls.Add($bottomPanel)
    $form.Controls.Add($topPanel)
    $form.Add_Shown({
            $form.Activate()
            $tabs.SelectedIndex = 1
        }.GetNewClosure())

    $null = $form.ShowDialog()
    $form.Dispose()
}

function Invoke-AnalyzerSelfTest {
    [CmdletBinding()]
    param()

    Write-Host 'Running non-destructive analyzer self-test...' -ForegroundColor Cyan
    Initialize-NativeScanner

    $sizes = @(
        @{ Bytes = 0; Expected = '0 B' }
        @{ Bytes = 1KB; Expected = '1.00 KB' }
        @{ Bytes = 1GB; Expected = '1.00 GB' }
        @{ Bytes = 142442938368L; Expected = '132.66 GB' }
        @{ Bytes = 5TB; Expected = '5.00 TB' }
    )
    foreach ($case in $sizes) {
        $actual = ConvertTo-FriendlySize -Bytes $case.Bytes
        if ($actual -ne $case.Expected) {
            throw "Size formatting test failed. Expected '$($case.Expected)', got '$actual'."
        }
    }

    if (-not (Test-SystemOrProtectedPath -Path 'C:\Windows\WinSxS' -Root 'C:\')) {
        throw 'System-folder exclusion test failed.'
    }
    if (-not (Test-SystemOrProtectedPath -Path 'C:\pagefile.sys' -Root 'C:\')) {
        throw 'System-file exclusion test failed.'
    }
    if (Test-SystemOrProtectedPath -Path 'C:\Data\Archive\old.zip' -Root 'C:\') {
        throw 'Non-system path exclusion test failed.'
    }

    Add-Type -AssemblyName System.Drawing
    $mapItems = @(
        [pscustomobject]@{ Name = 'one'; Kind = 'Folder'; Extension = ''; Length = 60L; Path = 'C:\one' }
        [pscustomobject]@{ Name = 'two.bin'; Kind = 'File'; Extension = '.bin'; Length = 40L; Path = 'C:\two.bin' }
    )
    $mapBounds = New-Object System.Drawing.RectangleF(0, 0, 100, 100)
    $mapRectangles = @(Get-TreemapRectangles -Items $mapItems -Bounds $mapBounds)
    if ($mapRectangles.Count -ne 2) {
        throw 'Treemap layout test failed.'
    }

    $testRoot = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        'D4A-DiskAnalyzer-' + [Guid]::NewGuid().ToString('N')
    )
    try {
        $null = [System.IO.Directory]::CreateDirectory($testRoot)
        $child = [System.IO.Directory]::CreateDirectory(
            [System.IO.Path]::Combine($testRoot, 'Archive')
        )
        [System.IO.File]::WriteAllBytes(
            [System.IO.Path]::Combine($testRoot, 'large.bin'),
            (New-Object byte[] 4096)
        )
        [System.IO.File]::WriteAllBytes(
            [System.IO.Path]::Combine($child.FullName, 'old.zip'),
            (New-Object byte[] 2048)
        )

        $testResult = [D4A.Storage.V3.FastVolumeScanner]::ScanTraversal(
            $testRoot,
            1024,
            [Action[int, string]]$null
        )
        if ($testResult.TotalFiles -ne 2 -or
            $testResult.LargeFiles.Count -ne 2 -or
            $testResult.TotalBytes -ne 6144) {
            throw 'Directory traversal or size aggregation test failed.'
        }
        if ((Get-RelativeDirectoryDepth -Path $child.FullName -Root $testRoot) -ne 1) {
            throw 'Quick-folder depth calculation test failed.'
        }

        $scopedMatches = [D4A.Storage.V3.FastVolumeScanner]::FindLargeFiles(
            $testResult,
            $child.FullName,
            1,
            [Action[int, string]]$null
        )
        if ($scopedMatches.Count -ne 1 -or $scopedMatches[0].Name -ne 'old.zip') {
            throw 'Cached scoped-file search test failed.'
        }

        Add-Type -AssemblyName System.Data
        $testTable = New-ResultDataTable -Items @($testResult.LargeFiles) -TableType File
        if ($testTable -isnot [System.Data.DataTable] -or $testTable.Rows.Count -ne 2) {
            throw 'Searchable result-table test failed.'
        }

        Add-Type -AssemblyName System.Windows.Forms
        $testTabs = New-Object System.Windows.Forms.TabControl
        $testForm = New-Object System.Windows.Forms.Form
        try {
            $testForm.ShowInTaskbar = $false
            $testForm.StartPosition = 'Manual'
            $testForm.Location = New-Object System.Drawing.Point(-32000, -32000)
            $testTabs.Dock = 'Fill'
            Add-SearchableGridTab -TabControl $testTabs -Title 'Files' `
                -DataTable $testTable -TableType File
            Add-TreemapTab -TabControl $testTabs -Items @($testResult.LargeFiles) -ItemLimit 10
            if ($testTabs.TabPages.Count -ne 2) {
                throw 'Windows results-interface construction test failed.'
            }
            $testForm.Controls.Add($testTabs)
            $testForm.Show()
            $testTabs.SelectedIndex = 1
            [System.Windows.Forms.Application]::DoEvents()
        }
        finally {
            $testForm.Close()
            $testForm.Dispose()
            $testTabs.Dispose()
        }
    }
    finally {
        if ([System.IO.Directory]::Exists($testRoot)) {
            [System.IO.Directory]::Delete($testRoot, $true)
        }
    }

    Write-Host (
        'Self-test passed: native code compiled; traversal, aggregation, cached scoped search, ' +
        'treemap callbacks, formatting, and safety helpers behaved as expected.'
    ) -ForegroundColor Green
}

function Invoke-FastDiskSpaceAnalyzer {
    [CmdletBinding()]
    param()

    Initialize-NativeScanner
    $firstRun = $true

    while ($true) {
        try {
            Clear-Host
            Write-Host $script:AnalyzerName -ForegroundColor White -BackgroundColor DarkBlue
            Write-Host 'Fast NTFS mapping, large-item ranking, search, treemap, and cautious review guidance.'

            $requestedDrive = if ($firstRun) { $Drive } else { $null }
            $root = Resolve-ScanDrive -RequestedDrive $requestedDrive
            $quickFolderThreshold = [long](1GB)

            Write-Host ''
            Write-Host (
                'Building a quick folder map for {0}; showing folders above {1} through depth 3.' -f
                $root,
                (ConvertTo-FriendlySize $quickFolderThreshold)
            ) -ForegroundColor Cyan
            Write-Host 'Press Ctrl+C to cancel the active scan.' -ForegroundColor DarkGray
            Write-Host ''

            $result = Invoke-VolumeAnalysis `
                -Root $root `
                -ThresholdBytes $quickFolderThreshold `
                -Mode $ScanMode
            Write-QuickFolderReport `
                -Result $result `
                -MaximumDepth 3 `
                -ItemLimit $ConsoleItemLimit

            $requestedSearchDirectory = if ($firstRun) { $SearchDirectory } else { $null }
            $scope = Read-FileSearchScope `
                -Root $root `
                -InitialDirectory $requestedSearchDirectory

            $requestedThreshold = if ($firstRun) { $ThresholdMB } else { 0 }
            $selectedThresholdMB = Read-ThresholdMB -InitialValue $requestedThreshold
            $thresholdBytesDouble = $selectedThresholdMB * 1MB
            if ($thresholdBytesDouble -gt [long]::MaxValue) {
                throw 'The selected threshold is too large.'
            }
            $thresholdBytes = [long][Math]::Round($thresholdBytesDouble)

            Write-Host ''
            Write-Host (
                'Searching cached metadata under {0} for files at least {1}.' -f
                $scope,
                (ConvertTo-FriendlySize $thresholdBytes)
            ) -ForegroundColor Cyan
            $result = Invoke-CachedFileSearch `
                -Result $result `
                -Scope $scope `
                -ThresholdBytes $thresholdBytes

            $recommendations = @(Get-PurgeRecommendations -Result $result)
            Write-ScanReport -Result $result -Recommendations $recommendations -ItemLimit $ConsoleItemLimit

            if (-not [string]::IsNullOrWhiteSpace($ExportDirectory)) {
                $exports = Export-ScanData -Result $result -Recommendations $recommendations -Directory $ExportDirectory
                Write-Host ''
                Write-Host "Full report exported to: $([System.IO.Path]::GetDirectoryName($exports.Summary))" -ForegroundColor Green
            }

            if (-not $NoGui) {
                try {
                    Show-ResultWindow -Result $result -Recommendations $recommendations -TreemapLimit $TreemapItemLimit
                }
                catch {
                    Write-Warning "The graphical results window could not be displayed: $($_.Exception.Message)"
                    Write-Warning 'The console report remains available. Use -NoGui on Server Core.'
                }
            }
        }
        catch {
            Write-Progress -Id 71 -Activity 'Disk analysis' -Completed
            Write-Host ''
            if ($SingleRun) {
                throw
            }
            Write-Error -ErrorRecord $_ -ErrorAction Continue
        }

        if ($SingleRun) {
            return
        }

        $firstRun = $false
        while ($true) {
            Write-Host ''
            $choice = (Read-Host 'Press [R] to restart with different options or [Q] to quit').Trim()
            if ($choice.Equals('R', [StringComparison]::OrdinalIgnoreCase)) {
                break
            }
            if ($choice.Equals('Q', [StringComparison]::OrdinalIgnoreCase)) {
                Write-Host 'Analyzer finished. The PowerShell session remains open.' -ForegroundColor Cyan
                return
            }
            Write-Warning 'Enter R to restart or Q to quit.'
        }
    }
}

if ($SelfTest) {
    Invoke-AnalyzerSelfTest
    return
}

Invoke-FastDiskSpaceAnalyzer
