using NikkeLocalLab.Application.Importing;
using NikkeLocalLab.Configuration;
using NikkeLocalLab.Provenance;

namespace NikkeLocalLab.Import.Sources;

public sealed class ReadOnlySourceRoot
{
  private readonly string _root;

  public ReadOnlySourceRoot(string sourceRoot, string repositoryRoot, string runtimeRoot)
  {
    try
    {
      _root = PathBoundary.NormalizeAbsoluteLocalPath(sourceRoot, "source_root_invalid");
      var repository = PathBoundary.NormalizeAbsoluteLocalPath(repositoryRoot, "repository_root_invalid");
      var runtime = PathBoundary.NormalizeAbsoluteLocalPath(runtimeRoot, "runtime_root_invalid");

      if (!Directory.Exists(_root))
      {
        throw new SourceBoundaryException("source_root_missing");
      }

      PathBoundary.EnsureDisjoint(_root, repository, "source_repository_overlap");
      PathBoundary.EnsureDisjoint(_root, runtime, "source_runtime_overlap");
      PathBoundary.EnsureNoReparsePoints(_root, true, "source_reparse_rejected");
    }
    catch (SourceBoundaryException)
    {
      throw;
    }
    catch (LabConfigurationException exception)
    {
      throw new SourceBoundaryException(exception.Code);
    }
  }

  public IImportArtifactSource Bind(
      SourceRelativePath relativePath,
      string artifactKind)
  {
    return new ReadOnlyArtifactSource(_root, relativePath, artifactKind);
  }

  private sealed class ReadOnlyArtifactSource : IImportArtifactSource
  {
    private readonly string _fullPath;
    private readonly string _artifactKind;

    public ReadOnlyArtifactSource(
        string root,
        SourceRelativePath relativePath,
        string artifactKind)
    {
      _artifactKind = ControlledCode.Require(artifactKind, nameof(artifactKind));
      _fullPath = Path.GetFullPath(Path.Combine(root, relativePath.Value));
      if (!PathBoundary.IsWithinOrEqual(_fullPath, root))
      {
        throw new SourceBoundaryException("source_path_escape");
      }

      EnsureReadableFile();
    }

    public async Task<SourceArtifactObservation> ObserveAsync(
        CancellationToken cancellationToken = default)
    {
      try
      {
        EnsureReadableFile();
        await using var stream = OpenRead();
        var length = stream.Length;
        var digest = await Sha256Digest.ComputeAsync(stream, cancellationToken).ConfigureAwait(false);
        return new SourceArtifactObservation(_artifactKind, digest, length);
      }
      catch (SourceBoundaryException)
      {
        throw;
      }
      catch
      {
        throw new SourceBoundaryException("source_read_failed");
      }
    }

    public async Task<T> ReadAsync<T>(
        Func<Stream, CancellationToken, Task<T>> reader,
        CancellationToken cancellationToken = default)
    {
      ArgumentNullException.ThrowIfNull(reader);
      FileStream stream;
      try
      {
        EnsureReadableFile();
        stream = OpenRead();
      }
      catch (SourceBoundaryException)
      {
        throw;
      }
      catch
      {
        throw new SourceBoundaryException("source_read_failed");
      }

      await using (stream)
      {
        await using var opaqueStream = new BufferedStream(stream, 64 * 1024);
        return await reader(opaqueStream, cancellationToken).ConfigureAwait(false);
      }
    }

    private FileStream OpenRead() => new(
        _fullPath,
        FileMode.Open,
        FileAccess.Read,
        FileShare.Read,
        bufferSize: 64 * 1024,
        FileOptions.Asynchronous | FileOptions.SequentialScan);

    private void EnsureReadableFile()
    {
      try
      {
        PathBoundary.EnsureNoReparsePoints(_fullPath, true, "source_reparse_rejected");
      }
      catch (LabConfigurationException exception)
      {
        throw new SourceBoundaryException(exception.Code);
      }

      if (!File.Exists(_fullPath))
      {
        throw new SourceBoundaryException("source_file_missing");
      }
    }
  }
}
