import importlib.util
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("cleanup", pathlib.Path(__file__).parents[1] / "scripts/cleanup.py")
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class CleanupTests(unittest.TestCase):
    def test_scoped_deletion_and_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp) / "install"
            root.mkdir()
            (root / ".fusionplay-mac").write_text("fusionplay-mac-v1\n")
            (root / "source").mkdir()
            (root / "data").mkdir()
            (root / "data/identity.json").write_text("private")
            outside = pathlib.Path(tmp) / "shared-tools"
            outside.mkdir()
            (outside / "keep").write_text("keep")
            (root / "cache").symlink_to(outside)
            cleanup.cleanup(root)
            self.assertTrue((root / "data/identity.json").exists())
            cleanup.cleanup(root, False)
            self.assertTrue((root / "source").exists())
            self.assertTrue((outside / "keep").exists())
            self.assertFalse((root / "data").exists())

    def test_missing_marker_refuses_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(RuntimeError):
                cleanup.cleanup(tmp, False)


if __name__ == "__main__":
    unittest.main()
