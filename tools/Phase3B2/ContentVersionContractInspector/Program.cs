using System.Formats.Nrbf;
using System.Reflection;
using System.Text.Json;

if (args.Length != 1 || !File.Exists(args[0]))
{
    Console.Error.WriteLine(
        "usage: ContentVersionContractInspector <lcv-path>");
    return 2;
}

using FileStream stream = File.OpenRead(Path.GetFullPath(args[0]));
SerializationRecord decoded = NrbfDecoder.Decode(stream);
if (decoded is not ClassRecord root)
{
    Console.Error.WriteLine("phase3b2_content_version_contract_root_invalid");
    return 3;
}

object result = new
{
    rootType = root.TypeName.FullName,
    rootMembers = DescribeRecord(root, 0)
};
Console.WriteLine(JsonSerializer.Serialize(result,
    new JsonSerializerOptions { WriteIndented = true }));
return 0;

static IReadOnlyList<object> DescribeRecord(ClassRecord record, int depth)
{
    List<object> result = [];
    foreach (string name in record.MemberNames)
    {
        object? value = record.GetRawValue(name);
        result.Add(new
        {
            name,
            runtimeType = value?.GetType().FullName ?? "null",
            classType = value is ClassRecord nested
                ? nested.TypeName.FullName
                : null,
            stringLength = value is string text ? text.Length : (int?)null,
            scalarValue = value is string or int or long or bool
                ? value
                : null,
            members = value is ClassRecord child && depth < 8
                ? DescribeRecord(child, depth + 1)
                : null,
            arrayValues = value is ArrayRecord array && depth < 8
                ? DescribeArray(array, depth + 1)
                : null
        });
    }
    return result;
}

static IReadOnlyList<object?> DescribeArray(ArrayRecord record, int depth)
{
    if (GetArrayValue(record) is not Array values)
    {
        return [];
    }

    List<object?> result = [];
    foreach (object? value in values)
    {
        result.Add(value switch
        {
            ClassRecord nested when depth < 8 => new
            {
                runtimeType = value.GetType().FullName,
                classType = nested.TypeName.FullName,
                scalarValue = (object?)null,
                members = DescribeRecord(nested, depth + 1),
                arrayValues = (object?)null
            },
            ArrayRecord nestedArray when depth < 8 => new
            {
                runtimeType = value.GetType().FullName,
                classType = (string?)null,
                scalarValue = (object?)null,
                members = (object?)null,
                arrayValues = DescribeArray(nestedArray, depth + 1)
            },
            SerializationRecord serializationRecord => new
            {
                runtimeType = value.GetType().FullName,
                classType = (string?)null,
                scalarValue = GetRecordValue(serializationRecord),
                members = (object?)null,
                arrayValues = (object?)null
            },
            _ => value
        });
    }
    return result;
}

static Array? GetArrayValue(ArrayRecord record)
{
    const BindingFlags flags = BindingFlags.Instance |
        BindingFlags.Public | BindingFlags.NonPublic;
    MethodInfo? method = record.GetType().GetMethod(
        "GetArray", flags, binder: null, [typeof(bool)], modifiers: null);
    return method?.Invoke(record, [true]) as Array;
}

static object? GetRecordValue(SerializationRecord record)
{
    const BindingFlags flags = BindingFlags.Instance |
        BindingFlags.Public | BindingFlags.NonPublic;
    MethodInfo? method = record.GetType().GetMethod(
        "GetValue", flags, binder: null, Type.EmptyTypes, modifiers: null);
    return method?.Invoke(record, null);
}
