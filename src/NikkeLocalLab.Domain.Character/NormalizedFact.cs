using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Domain.Character;

public enum FactStatus
{
  Ready,
  Unresolved,
  NotApplicable,
}

/// <summary>
/// A normalized value which never collapses missing evidence or inapplicability into a sentinel value.
/// </summary>
/// <typeparam name="T">A normalized, value-type domain value.</typeparam>
public sealed class NormalizedFact<T> : IEquatable<NormalizedFact<T>>
    where T : struct
{
  private NormalizedFact(FactStatus status, T? value, string? reasonCode)
  {
    Status = status;
    Value = value;
    ReasonCode = reasonCode;
  }

  public FactStatus Status { get; }

  public T? Value { get; }

  public string? ReasonCode { get; }

  public bool IsResolved => Status is FactStatus.Ready or FactStatus.NotApplicable;

  public static NormalizedFact<T> Ready(T value) => new(FactStatus.Ready, value, null);

  public static NormalizedFact<T> Unresolved(string reasonCode) =>
      new(FactStatus.Unresolved, null, ControlledCode.Require(reasonCode, nameof(reasonCode)));

  public static NormalizedFact<T> NotApplicable() => new(FactStatus.NotApplicable, null, null);

  public T RequireValue()
  {
    if (Status != FactStatus.Ready || Value is null)
    {
      throw new InvalidOperationException("Only a ready fact has a value.");
    }

    return Value.Value;
  }

  public bool Equals(NormalizedFact<T>? other) =>
      other is not null &&
      Status == other.Status &&
      EqualityComparer<T?>.Default.Equals(Value, other.Value) &&
      string.Equals(ReasonCode, other.ReasonCode, StringComparison.Ordinal);

  public override bool Equals(object? obj) => obj is NormalizedFact<T> other && Equals(other);

  public override int GetHashCode() => HashCode.Combine(Status, Value, ReasonCode);
}
