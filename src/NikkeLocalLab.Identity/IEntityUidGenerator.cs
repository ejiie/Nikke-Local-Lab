namespace NikkeLocalLab.Identity;

public interface IEntityUidGenerator
{
  EntityUid NewUid();
}

public sealed class RandomEntityUidGenerator : IEntityUidGenerator
{
  public EntityUid NewUid() => EntityUid.New();
}
