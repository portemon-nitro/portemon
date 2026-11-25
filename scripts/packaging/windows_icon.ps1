param(
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Executable,
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Icon
)

$ErrorActionPreference = "Stop"
$Executable = [IO.Path]::GetFullPath($Executable)
$Icon = [IO.Path]::GetFullPath($Icon)
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "build_windows: executable does not exist" }
if (-not (Test-Path -LiteralPath $Icon -PathType Leaf)) { throw "build_windows: product icon does not exist" }

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;

internal static class PortemonIconResource
{
    private const int RT_ICON = 3;
    private const int RT_GROUP_ICON = 14;
    private const ushort LANGUAGE_ID = 1033;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr BeginUpdateResourceW(string fileName, bool deleteExistingResources);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool UpdateResourceW(IntPtr update, IntPtr type, IntPtr name,
        IntPtr language, byte[] data, int size);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EndUpdateResourceW(IntPtr update, bool discard);

    public static void Apply(string executable, string icon)
    {
        byte[] source = File.ReadAllBytes(icon);
        if (source.Length < 6 || BitConverter.ToUInt16(source, 0) != 0 || BitConverter.ToUInt16(source, 2) != 1)
            throw new InvalidDataException("build_windows: product icon is not an ICO resource");
        int count = BitConverter.ToUInt16(source, 4);
        if (count == 0 || 6 + count * 16 > source.Length)
            throw new InvalidDataException("build_windows: product icon directory is invalid");

        byte[][] images = new byte[count][];
        byte[] group;
        using (MemoryStream stream = new MemoryStream())
        using (BinaryWriter writer = new BinaryWriter(stream))
        {
            writer.Write((ushort)0);
            writer.Write((ushort)1);
            writer.Write((ushort)count);
            for (int index = 0; index < count; index++)
            {
                int entry = 6 + index * 16;
                int size = BitConverter.ToInt32(source, entry + 8);
                int offset = BitConverter.ToInt32(source, entry + 12);
                if (size <= 0 || offset < 6 + count * 16 || offset > source.Length - size)
                    throw new InvalidDataException("build_windows: product icon image is out of bounds");
                byte[] image = new byte[size];
                Array.Copy(source, offset, image, 0, size);
                images[index] = image;
                writer.Write(source[entry]);
                writer.Write(source[entry + 1]);
                writer.Write(source[entry + 2]);
                writer.Write(source[entry + 3]);
                writer.Write(BitConverter.ToUInt16(source, entry + 4));
                writer.Write(BitConverter.ToUInt16(source, entry + 6));
                writer.Write(size);
                writer.Write((ushort)(index + 1));
            }
            group = stream.ToArray();
        }

        IntPtr update = BeginUpdateResourceW(executable, false);
        if (update == IntPtr.Zero)
            throw new IOException("build_windows: cannot open executable resources: " + Marshal.GetLastWin32Error());
        bool completed = false;
        try
        {
            if (!UpdateResourceW(update, new IntPtr(RT_GROUP_ICON), new IntPtr(1),
                new IntPtr(LANGUAGE_ID), group, group.Length))
                throw new IOException("build_windows: cannot replace product icon group: " + Marshal.GetLastWin32Error());
            for (int index = 0; index < images.Length; index++)
            {
                if (!UpdateResourceW(update, new IntPtr(RT_ICON), new IntPtr(index + 1),
                    new IntPtr(LANGUAGE_ID), images[index], images[index].Length))
                    throw new IOException("build_windows: cannot replace product icon image: " + Marshal.GetLastWin32Error());
            }
            completed = true;
        }
        finally
        {
            if (!EndUpdateResourceW(update, !completed))
                throw new IOException("build_windows: cannot commit product icon resources: " + Marshal.GetLastWin32Error());
        }
    }
}
'@

[PortemonIconResource]::Apply($Executable, $Icon)
