namespace NikkeLocalLab.Admin.Api;

internal sealed record ChallengePolicyValuesRequest(
    string? PolicyUid,
    string? PolicyId,
    int? DailyEntryLimit,
    string? EntryConsumptionPoint,
    string? ActiveRunAtReset,
    string? DailyCounterScope,
    string? MockBattleCapability,
    string? LocalRankingCapability);

internal sealed record PublishChallengePolicyRequest(
    string? OperationUid,
    string? PolicyUid,
    string? PolicyId,
    int? DailyEntryLimit,
    string? EntryConsumptionPoint,
    string? ActiveRunAtReset,
    string? DailyCounterScope,
    string? MockBattleCapability,
    string? LocalRankingCapability);

internal sealed record ActivateChallengePolicyRequest(
    string? OperationUid,
    string? PolicyUid,
    string? ExpectedPolicySha256);
