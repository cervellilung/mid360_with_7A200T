import json
import tempfile
import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools import glm_delegate


class GlmDelegateTests(unittest.TestCase):
    def test_endpoint_is_openai_compatible(self):
        self.assertEqual(
            glm_delegate.build_endpoint("https://api.z.ai/api/paas/v4/"),
            "https://api.z.ai/api/paas/v4/chat/completions",
        )

    def test_rejects_non_https_endpoint(self):
        with self.assertRaises(glm_delegate.DelegateError):
            glm_delegate.build_endpoint("http://api.example.test/v4")

    def test_rejects_context_outside_project(self):
        with tempfile.NamedTemporaryFile(suffix=".md") as outside:
            with self.assertRaises(glm_delegate.DelegateError):
                glm_delegate.resolve_context(outside.name)

    def test_rejects_known_key_in_task(self):
        with self.assertRaises(glm_delegate.DelegateError):
            glm_delegate.validate_no_secrets("secret-key-value", ["secret-key-value"], "task")

    def test_parses_required_markdown_shape(self):
        content = "\n\n".join(f"{heading}\n内容" for heading in glm_delegate.REQUIRED_HEADINGS)
        parsed, info = glm_delegate.parse_response(
            {"id": "x", "model": "glm", "choices": [{"message": {"content": content}, "finish_reason": "stop"}], "usage": {"total_tokens": 10}}
        )
        self.assertIn("## TODO", parsed)
        self.assertEqual(info["usage"]["total_tokens"], 10)

    def test_metadata_has_no_secret_field(self):
        with tempfile.TemporaryDirectory(dir=glm_delegate.PROJECT_ROOT) as directory:
            target = Path(directory)
            glm_delegate.write_metadata(target, {"status": "success", "model": "glm"})
            data = json.loads((target / "metadata.json").read_text(encoding="utf-8"))
            self.assertEqual(set(data), {"status", "model"})


if __name__ == "__main__":
    unittest.main()
