"""Prove --no-commit non-fast-forward CI merges need only command-local identity."""

import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest


class MergeIdentityTests(unittest.TestCase):
    def test_merge_without_global_identity(self):
        with TemporaryDirectory(prefix="nll-synthetic-merge-") as directory:
            root = Path(directory)
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith("GIT_") and key != "EMAIL"}
            environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                               GIT_TERMINAL_PROMPT="0")
            identity = ["-c", "user.name=github-actions[bot]", "-c",
                        "user.email=41898282+github-actions[bot]@users.noreply.github.com"]
            def git(*args, check=True):
                return subprocess.run(["git", *args], cwd=root, env=environment,
                                      capture_output=True, text=True, check=check)
            git("init", "-b", "main")
            (root / "base.txt").write_text("synthetic base\n")
            git("add", "base.txt")
            git(*identity, "commit", "-m", "Synthetic base")
            git("switch", "-c", "agent/synthetic")
            (root / "feature.txt").write_text("synthetic feature\n")
            git("add", "feature.txt")
            git(*identity, "commit", "-m", "Synthetic feature")
            git("switch", "main")
            (root / "main.txt").write_text("synthetic main\n")
            git("add", "main.txt")
            git(*identity, "commit", "-m", "Synthetic main")
            git("switch", "agent/synthetic")
            head = git("rev-parse", "HEAD").stdout
            self.assertNotEqual(git("merge", "--no-commit", "--no-ff", "main", check=False).returncode, 0)
            git(*identity, "merge", "--no-commit", "--no-ff", "main")
            self.assertEqual(git("rev-parse", "HEAD").stdout, head)
            self.assertEqual(git("rev-parse", "MERGE_HEAD").stdout, git("rev-parse", "main").stdout)
            self.assertEqual(set(git("ls-files").stdout.splitlines()), {"base.txt", "feature.txt", "main.txt"})
            self.assertNotEqual(git("config", "--local", "--get", "user.name", check=False).returncode, 0)


if __name__ == "__main__":
    unittest.main()
