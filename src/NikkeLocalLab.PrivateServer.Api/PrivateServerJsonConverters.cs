using System.Text.Json;
using System.Text.Json.Serialization;
using NikkeLocalLab.Identity;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.PrivateServer.Api;

internal sealed class EntityUidJsonConverter : JsonConverter<EntityUid>
{
  public override EntityUid Read(
      ref Utf8JsonReader reader,
      Type typeToConvert,
      JsonSerializerOptions options)
  {
    if (reader.TokenType != JsonTokenType.String)
    {
      throw new JsonException("entity_uid_invalid");
    }

    var value = reader.GetString();
    if (!Guid.TryParseExact(value, "D", out var guid) || guid == Guid.Empty)
    {
      throw new JsonException("entity_uid_invalid");
    }

    return new EntityUid(guid);
  }

  public override void Write(
      Utf8JsonWriter writer,
      EntityUid value,
      JsonSerializerOptions options) => writer.WriteStringValue(value.ToString());
}

internal sealed class Sha256DigestJsonConverter : JsonConverter<Sha256Digest>
{
  public override Sha256Digest Read(
      ref Utf8JsonReader reader,
      Type typeToConvert,
      JsonSerializerOptions options)
  {
    if (reader.TokenType != JsonTokenType.String)
    {
      throw new JsonException("sha256_invalid");
    }

    if (!Sha256Digest.TryParse(reader.GetString(), out var digest))
    {
      throw new JsonException("sha256_invalid");
    }

    return digest;
  }

  public override void Write(
      Utf8JsonWriter writer,
      Sha256Digest value,
      JsonSerializerOptions options) => writer.WriteStringValue(value.ToString());
}
