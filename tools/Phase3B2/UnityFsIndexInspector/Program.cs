using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using K4os.Compression.LZ4;

if (args.Length != 1)
{
    Console.Error.WriteLine("usage: UnityFsIndexInspector <unityfs-bundle>");
    return 2;
}

var inputPath = Path.GetFullPath(args[0]);
await using var stream = new FileStream(
    inputPath, FileMode.Open, FileAccess.Read, FileShare.Read,
    bufferSize: 1024 * 1024, FileOptions.SequentialScan);
var reader = new BigEndianReader(stream);

var signature = reader.ReadCString();
if (!string.Equals(signature, "UnityFS", StringComparison.Ordinal))
    throw new InvalidDataException($"unsupported_signature:{signature}");

var formatVersion = reader.ReadUInt32();
var unityVersion = reader.ReadCString();
var unityRevision = reader.ReadCString();
var declaredSize = reader.ReadInt64();
var compressedInfoSize = reader.ReadUInt32();
var uncompressedInfoSize = reader.ReadUInt32();
var flags = reader.ReadUInt32();

if (formatVersion >= 7)
    reader.Align(16);

var blockDataOffset = stream.Position;
byte[] compressedInfo;
if ((flags & 0x80u) != 0)
{
    var returnPosition = stream.Position;
    stream.Position = stream.Length - compressedInfoSize;
    compressedInfo = reader.ReadBytes(checked((int)compressedInfoSize));
    stream.Position = returnPosition;
}
else
{
    compressedInfo = reader.ReadBytes(checked((int)compressedInfoSize));
    blockDataOffset = stream.Position;
}

if ((flags & 0x200u) != 0)
{
    reader.Align(16);
    blockDataOffset = stream.Position;
}

var infoBytes = Decompress(
    compressedInfo, checked((int)uncompressedInfoSize), flags & 0x3fu);
using var infoStream = new MemoryStream(infoBytes, writable: false);
var infoReader = new BigEndianReader(infoStream);
var infoHash = infoReader.ReadBytes(16);
var blockCount = infoReader.ReadInt32();
if (blockCount < 0 || blockCount > 1_000_000)
    throw new InvalidDataException($"invalid_block_count:{blockCount}");

var blocks = new List<BlockInfo>(blockCount);
long totalUncompressed = 0;
for (var index = 0; index < blockCount; index++)
{
    var uncompressedSize = infoReader.ReadUInt32();
    var compressedSize = infoReader.ReadUInt32();
    var blockFlags = infoReader.ReadUInt16();
    totalUncompressed = checked(totalUncompressed + uncompressedSize);
    blocks.Add(new BlockInfo(
        index, uncompressedSize, compressedSize, blockFlags,
        (uint)(blockFlags & 0x3f)));
}

var nodeCount = infoReader.ReadInt32();
if (nodeCount < 0 || nodeCount > 1_000_000)
    throw new InvalidDataException($"invalid_node_count:{nodeCount}");
var nodes = new List<NodeInfo>(nodeCount);
for (var index = 0; index < nodeCount; index++)
{
    nodes.Add(new NodeInfo(
        index,
        infoReader.ReadInt64(),
        infoReader.ReadInt64(),
        infoReader.ReadUInt32(),
        infoReader.ReadCString()));
}

if (totalUncompressed > int.MaxValue)
    throw new InvalidDataException(
        $"bundle_too_large_for_bounded_inspection:{totalUncompressed}");

stream.Position = blockDataOffset;
var bundleBytes = new byte[checked((int)totalUncompressed)];
var bundleOffset = 0;
foreach (var block in blocks)
{
    var compressed = reader.ReadBytes(checked((int)block.CompressedSize));
    var uncompressed = Decompress(
        compressed, checked((int)block.UncompressedSize),
        block.CompressionType);
    uncompressed.CopyTo(bundleBytes, bundleOffset);
    bundleOffset += uncompressed.Length;
}

var allowList = new[]
{
    "core", "catalog", ".cat", "150.6.b15", "552831",
    "1d5645e", "553076", "cloud.nikke", "ResourceBaseURL",
    "asset-catalog"
};
var stringSignals = EnumerateAsciiStrings(bundleBytes, 4, 1024)
    .Where(item => allowList.Any(pattern =>
        item.Value.Contains(pattern, StringComparison.OrdinalIgnoreCase)))
    .Take(200)
    .Select(item => new
    {
        item.Offset,
        item.ByteLength,
        Value = item.Value.Length <= 512
            ? item.Value
            : item.Value[..512] + "<truncated>"
    })
    .ToArray();

var exactPatterns = new[]
{
    "150.6.b15", "552831", "1d5645e", "553076", "core", "catalog"
};
var exactMatches = exactPatterns.Select(pattern => new
{
    Pattern = pattern,
    Offsets = FindAll(bundleBytes, Encoding.ASCII.GetBytes(pattern), 64)
}).ToArray();

var result = new
{
    ContractId = "nll/unityfs-index-inspection/v1",
    InputRoleCode = "read_only_original_naps_bundle",
    InputByteLength = stream.Length,
    InputSha256 = Convert.ToHexString(SHA256.HashData(
        await File.ReadAllBytesAsync(inputPath))).ToLowerInvariant(),
    Signature = signature,
    FormatVersion = formatVersion,
    UnityVersion = unityVersion,
    UnityRevision = unityRevision,
    DeclaredByteLength = declaredSize,
    Flags = $"0x{flags:x}",
    BlockDataOffset = blockDataOffset,
    BlockInfoHash = Convert.ToHexString(infoHash).ToLowerInvariant(),
    BlockCount = blocks.Count,
    TotalUncompressedByteLength = totalUncompressed,
    Blocks = blocks,
    NodeCount = nodes.Count,
    Nodes = nodes,
    ExactMatches = exactMatches,
    AllowListedStringSignalCount = stringSignals.Length,
    AllowListedStringSignals = stringSignals,
    RawBundleExtracted = false,
    SourceModified = false
};

Console.WriteLine(JsonSerializer.Serialize(result, new JsonSerializerOptions
{
    WriteIndented = true
}));
return 0;

static byte[] Decompress(byte[] compressed, int expectedLength, uint type)
{
    return type switch
    {
        0 when compressed.Length == expectedLength => compressed,
        0 => throw new InvalidDataException(
            $"uncompressed_length_mismatch:{compressed.Length}:{expectedLength}"),
        2 or 3 => DecodeLz4(compressed, expectedLength),
        1 => throw new InvalidDataException("lzma_not_supported"),
        _ => throw new InvalidDataException($"unsupported_compression:{type}")
    };
}

static byte[] DecodeLz4(byte[] compressed, int expectedLength)
{
    var output = new byte[expectedLength];
    var decoded = LZ4Codec.Decode(compressed, output);
    if (decoded != expectedLength)
        throw new InvalidDataException(
            $"lz4_length_mismatch:{decoded}:{expectedLength}");
    return output;
}

static IEnumerable<AsciiSignal> EnumerateAsciiStrings(
    byte[] bytes, int minimumLength, int maximumLength)
{
    var start = -1;
    for (var index = 0; index <= bytes.Length; index++)
    {
        var printable = index < bytes.Length &&
            bytes[index] is >= 0x20 and <= 0x7e;
        if (printable && start < 0)
        {
            start = index;
            continue;
        }
        if (printable || start < 0)
            continue;

        var length = index - start;
        if (length >= minimumLength)
        {
            var boundedLength = Math.Min(length, maximumLength);
            yield return new AsciiSignal(
                start, length,
                Encoding.ASCII.GetString(bytes, start, boundedLength));
        }
        start = -1;
    }
}

static long[] FindAll(byte[] haystack, byte[] needle, int maximumMatches)
{
    var offsets = new List<long>();
    if (needle.Length == 0)
        return offsets.ToArray();
    for (var index = 0;
         index <= haystack.Length - needle.Length &&
            offsets.Count < maximumMatches;
         index++)
    {
        if (haystack.AsSpan(index, needle.Length).SequenceEqual(needle))
            offsets.Add(index);
    }
    return offsets.ToArray();
}

sealed class BigEndianReader(Stream stream)
{
    public byte[] ReadBytes(int count)
    {
        var bytes = new byte[count];
        stream.ReadExactly(bytes);
        return bytes;
    }

    public ushort ReadUInt16()
    {
        Span<byte> bytes = stackalloc byte[2];
        stream.ReadExactly(bytes);
        return BinaryPrimitives.ReadUInt16BigEndian(bytes);
    }

    public uint ReadUInt32()
    {
        Span<byte> bytes = stackalloc byte[4];
        stream.ReadExactly(bytes);
        return BinaryPrimitives.ReadUInt32BigEndian(bytes);
    }

    public int ReadInt32() => unchecked((int)ReadUInt32());

    public long ReadInt64()
    {
        Span<byte> bytes = stackalloc byte[8];
        stream.ReadExactly(bytes);
        return BinaryPrimitives.ReadInt64BigEndian(bytes);
    }

    public string ReadCString()
    {
        var bytes = new List<byte>();
        while (true)
        {
            var value = stream.ReadByte();
            if (value < 0)
                throw new EndOfStreamException();
            if (value == 0)
                return Encoding.UTF8.GetString(bytes.ToArray());
            bytes.Add((byte)value);
        }
    }

    public void Align(int alignment)
    {
        var remainder = stream.Position % alignment;
        if (remainder != 0)
            stream.Position += alignment - remainder;
    }
}

sealed record BlockInfo(
    int Index,
    uint UncompressedSize,
    uint CompressedSize,
    ushort Flags,
    uint CompressionType);

sealed record NodeInfo(
    int Index,
    long Offset,
    long ByteLength,
    uint Flags,
    string Path);

sealed record AsciiSignal(long Offset, int ByteLength, string Value);
