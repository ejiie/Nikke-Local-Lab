using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.CombatSupport;

public enum CombatSupportFactStatus
{
  Ready,
  Unresolved,
  NotApplicable
}

public sealed class CombatSupportFact<T> : IEquatable<CombatSupportFact<T>>
    where T : struct
{
  private CombatSupportFact(CombatSupportFactStatus status, T? value, string? reasonCode)
  {
    Status = status;
    Value = value;
    ReasonCode = reasonCode;
  }

  public CombatSupportFactStatus Status { get; }

  public T? Value { get; }

  public string? ReasonCode { get; }

  public bool IsResolved => Status is CombatSupportFactStatus.Ready or CombatSupportFactStatus.NotApplicable;

  public static CombatSupportFact<T> Ready(T value) =>
      new(CombatSupportFactStatus.Ready, value, null);

  public static CombatSupportFact<T> Unresolved(string reasonCode) =>
      new(
          CombatSupportFactStatus.Unresolved,
          null,
          ControlledCode.Require(reasonCode, nameof(reasonCode)));

  public static CombatSupportFact<T> NotApplicable() =>
      new(CombatSupportFactStatus.NotApplicable, null, null);

  public T RequireValue()
  {
    if (Status != CombatSupportFactStatus.Ready || Value is null)
    {
      throw new InvalidOperationException("Only a ready combat-support fact has a value.");
    }

    return Value.Value;
  }

  public bool Equals(CombatSupportFact<T>? other) =>
      other is not null &&
      Status == other.Status &&
      EqualityComparer<T?>.Default.Equals(Value, other.Value) &&
      string.Equals(ReasonCode, other.ReasonCode, StringComparison.Ordinal);

  public override bool Equals(object? obj) => obj is CombatSupportFact<T> other && Equals(other);

  public override int GetHashCode() => HashCode.Combine(Status, Value, ReasonCode);
}

public readonly record struct CombatSupportExactValue
{
  public CombatSupportExactValue(long unscaledValue, int decimalScale)
  {
    if (decimalScale is < 0 or > 9)
    {
      throw new ArgumentOutOfRangeException(nameof(decimalScale));
    }

    UnscaledValue = unscaledValue;
    DecimalScale = decimalScale;
  }

  public long UnscaledValue { get; }

  public int DecimalScale { get; }

  public decimal ToDecimal() => UnscaledValue / DecimalPowers[DecimalScale];

  private static readonly decimal[] DecimalPowers =
  [
      1m,
    10m,
    100m,
    1_000m,
    10_000m,
    100_000m,
    1_000_000m,
    10_000_000m,
    100_000_000m,
    1_000_000_000m
  ];
}

public sealed class CombatSupportExactRangeFact
{
  private CombatSupportExactRangeFact(
      CombatSupportFactStatus status,
      CombatSupportExactValue? minimum,
      CombatSupportExactValue? maximum,
      string? reasonCode)
  {
    Status = status;
    Minimum = minimum;
    Maximum = maximum;
    ReasonCode = reasonCode;
  }

  public CombatSupportFactStatus Status { get; }

  public CombatSupportExactValue? Minimum { get; }

  public CombatSupportExactValue? Maximum { get; }

  public string? ReasonCode { get; }

  public static CombatSupportExactRangeFact Ready(
      CombatSupportExactValue minimum,
      CombatSupportExactValue maximum)
  {
    if (minimum.ToDecimal() > maximum.ToDecimal())
    {
      throw new ArgumentException("The legal minimum cannot exceed the legal maximum.", nameof(minimum));
    }

    return new CombatSupportExactRangeFact(
        CombatSupportFactStatus.Ready,
        minimum,
        maximum,
        null);
  }

  public static CombatSupportExactRangeFact Unresolved(string reasonCode) =>
      new(
          CombatSupportFactStatus.Unresolved,
          null,
          null,
          ControlledCode.Require(reasonCode, nameof(reasonCode)));

  public static CombatSupportExactRangeFact NotApplicable() =>
      new(CombatSupportFactStatus.NotApplicable, null, null, null);
}
