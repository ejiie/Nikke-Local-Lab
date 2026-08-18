namespace NikkeLocalLab.Character.UnitTests;

public sealed class CanonicalizationTests
{
  [Fact]
  public void Content_hash_is_stable_and_excludes_character_version_and_dataset_identity()
  {
    var content = CharacterTestData.ReadyContent();
    var first = CharacterTestData.Version(content, characterUid: 1, versionUid: 2, datasetUid: 3);
    var second = CharacterTestData.Version(content, characterUid: 11, versionUid: 12, datasetUid: 13);

    Assert.Equal(first.ContentSha256, second.ContentSha256);
    Assert.Equal(
        CharacterDefinitionCanonicalizer.ComputeContentHash(content),
        first.ContentSha256);

    var canonical = CharacterDefinitionCanonicalizer.ToCanonicalText(content);
    Assert.StartsWith("nll/character-definition-content/v1\n", canonical, StringComparison.Ordinal);
    Assert.DoesNotContain(first.CharacterUid.ToString(), canonical, StringComparison.Ordinal);
    Assert.DoesNotContain(first.DefinitionVersionUid.ToString(), canonical, StringComparison.Ordinal);
    Assert.DoesNotContain(first.DatasetSnapshotUid.ToString(), canonical, StringComparison.Ordinal);
    Assert.False(canonical.EndsWith('\n'));
  }

  [Fact]
  public void Canonical_content_distinguishes_ready_unresolved_and_not_applicable()
  {
    var ready = CharacterTestData.ReadyContent(
        maximumFavoriteLevel: NormalizedFact<int>.Ready(30));
    var unresolved = CharacterTestData.ReadyContent(
        maximumFavoriteLevel: NormalizedFact<int>.Unresolved("favorite_relation_missing"));
    var notApplicable = CharacterTestData.ReadyContent(
        maximumFavoriteLevel: NormalizedFact<int>.NotApplicable());

    var readyText = CharacterDefinitionCanonicalizer.ToCanonicalText(ready);
    var unresolvedText = CharacterDefinitionCanonicalizer.ToCanonicalText(unresolved);
    var notApplicableText = CharacterDefinitionCanonicalizer.ToCanonicalText(notApplicable);

    Assert.Contains("capability.favorite.maximum-level=ready:30", readyText, StringComparison.Ordinal);
    Assert.Contains(
        "capability.favorite.maximum-level=unresolved:favorite_relation_missing",
        unresolvedText,
        StringComparison.Ordinal);
    Assert.Contains(
        "capability.favorite.maximum-level=not_applicable",
        notApplicableText,
        StringComparison.Ordinal);
    Assert.NotEqual(
        CharacterDefinitionCanonicalizer.ComputeContentHash(ready),
        CharacterDefinitionCanonicalizer.ComputeContentHash(unresolved));
    Assert.NotEqual(
        CharacterDefinitionCanonicalizer.ComputeContentHash(unresolved),
        CharacterDefinitionCanonicalizer.ComputeContentHash(notApplicable));
  }

  [Fact]
  public void Catalog_manifest_is_sorted_path_free_and_deterministic()
  {
    var later = CharacterTestData.Version(characterUid: 20, versionUid: 21, datasetUid: 30);
    var earlier = CharacterTestData.Version(characterUid: 10, versionUid: 11, datasetUid: 30);

    var first = CharacterCatalogManifest.Create(new[] { later, earlier });
    var second = CharacterCatalogManifest.Create(new[] { earlier, later });

    Assert.Equal(first.CanonicalText, second.CanonicalText);
    Assert.Equal(first.Sha256, second.Sha256);
    Assert.Equal(2, first.Count);
    Assert.Equal(earlier.CharacterUid, first.Entries[0].CharacterUid);
    Assert.Equal(later.CharacterUid, first.Entries[1].CharacterUid);
    Assert.Equal(Sha256Digest.ComputeUtf8(first.CanonicalText), first.Sha256);
    Assert.False(first.CanonicalText.EndsWith('\n'));
    Assert.DoesNotContain(earlier.DefinitionVersionUid.ToString(), first.CanonicalText, StringComparison.Ordinal);
    Assert.DoesNotContain(later.DefinitionVersionUid.ToString(), first.CanonicalText, StringComparison.Ordinal);
  }

  [Fact]
  public void Catalog_manifest_rejects_ambiguous_membership()
  {
    var first = CharacterTestData.Version(characterUid: 1, versionUid: 2, datasetUid: 10);
    var duplicateCharacter = CharacterTestData.Version(characterUid: 1, versionUid: 3, datasetUid: 10);
    var otherDataset = CharacterTestData.Version(characterUid: 4, versionUid: 5, datasetUid: 11);

    Assert.Throws<ArgumentException>(() => CharacterCatalogManifest.Create(Array.Empty<CharacterDefinitionVersion>()));
    Assert.Throws<ArgumentException>(() => CharacterCatalogManifest.Create(new[] { first, duplicateCharacter }));
    Assert.Throws<ArgumentException>(() => CharacterCatalogManifest.Create(new[] { first, otherDataset }));
  }

  [Fact]
  public void Catalog_manifest_entry_overload_preserves_the_domain_contract()
  {
    var later = CharacterTestData.Version(characterUid: 20, versionUid: 21, datasetUid: 30);
    var earlier = CharacterTestData.Version(characterUid: 10, versionUid: 11, datasetUid: 30);
    var fromVersions = CharacterCatalogManifest.Create([later, earlier]);
    var fromEntries = CharacterCatalogManifest.Create(
        earlier.DatasetSnapshotUid,
        [
            new CharacterCatalogManifestEntry(later.CharacterUid, later.ContentSha256),
          new CharacterCatalogManifestEntry(earlier.CharacterUid, earlier.ContentSha256)
        ]);

    Assert.Equal(fromVersions.CanonicalText, fromEntries.CanonicalText);
    Assert.Equal(fromVersions.Sha256, fromEntries.Sha256);
    Assert.Throws<ArgumentException>(() => CharacterCatalogManifest.Create(
        earlier.DatasetSnapshotUid,
        [
            new CharacterCatalogManifestEntry(earlier.CharacterUid, earlier.ContentSha256),
          new CharacterCatalogManifestEntry(earlier.CharacterUid, later.ContentSha256)
        ]));
  }
}
