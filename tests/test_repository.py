from __future__ import annotations

import ast
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class RepositoryTests(unittest.TestCase):
    def test_python_syntax(self) -> None:
        for path in list((ROOT / "scripts").glob("*.py")) + list((ROOT / "benchmarks").glob("*.py")):
            ast.parse(path.read_text(encoding="utf-8"), filename=str(path))

    def test_manifest_is_a_template(self) -> None:
        text = (ROOT / "manifests" / "dgd-template.yaml").read_text(encoding="utf-8")
        for placeholder in (
            "__IMAGE__",
            "__CXL_NODE__",
            "__CACHE_GB__",
            "__TP__",
            "__GPU__",
            "__MEMORY_REQUEST__",
            "__MEMORY_LIMIT__",
        ):
            self.assertIn(placeholder, text)
        self.assertIn("DYN_KVBM_CXL_NUMA_NODE", text)
        self.assertNotIn("DYN_KVBM_DISK_CACHE_GB", text)

    def test_patch_has_strict_guards(self) -> None:
        text = (ROOT / "patches" / "dynamo-v1.3.1-cxl-numa.patch").read_text(encoding="utf-8")
        for required in ("MPOL_BIND", "move_pages", "cuMemHostRegister_v2", "DRAM fallback is forbidden"):
            self.assertIn(required, text)

    def test_no_obvious_secret_material(self) -> None:
        forbidden = re.compile(r"(BEGIN (RSA|OPENSSH) PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|art_v1_[A-Za-z0-9]+)")
        for path in ROOT.rglob("*"):
            if path.is_file() and ".git" not in path.parts:
                text = path.read_text(encoding="utf-8", errors="ignore")
                self.assertIsNone(forbidden.search(text), str(path))


if __name__ == "__main__":
    unittest.main()
