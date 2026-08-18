namespace NikkeLocalLab.Identity;

public readonly record struct EntityUid
{
  public EntityUid(Guid value)
  {
    if (value == Guid.Empty)
    {
      throw new ArgumentException("An entity UID cannot be empty.", nameof(value));
    }

    Value = value;
  }

  public Guid Value { get; }

  public static EntityUid New() => new(Guid.NewGuid());

  public override string ToString() => Value.ToString("D").ToLowerInvariant();
}
