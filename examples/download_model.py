"""Example: download a small model with zest and verify it works."""

import subprocess
import sys
from pathlib import Path
from shutil import which


def find_zest() -> str:
    """Find zest binary: PATH (pip install) → local build → fail."""
    # 1. On PATH (pip install zest-transfer)
    on_path = which("zest")
    if on_path:
        return on_path

    # 2. Local build (zig build)
    repo_root = Path(__file__).resolve().parent.parent
    local = repo_root / "zig-out" / "bin" / "zest"
    if local.is_file():
        return str(local)

    print("error: zest binary not found", file=sys.stderr)
    print("Install with: pip install zest-transfer", file=sys.stderr)
    print("Or build from source: zig build -Doptimize=ReleaseFast", file=sys.stderr)
    sys.exit(1)


def main():
    repo = "openai-community/gpt2"  # ~550 MB, smallest GPT-2
    zest = find_zest()

    print(f"Using zest at: {zest}")
    print(f"Downloading {repo} via zest...")
    result = subprocess.run([zest, "pull", repo])
    if result.returncode != 0:
        print("zest pull failed", file=sys.stderr)
        sys.exit(1)

    print("\nVerifying with transformers...")
    try:
        from transformers import AutoTokenizer, AutoModelForCausalLM

        tokenizer = AutoTokenizer.from_pretrained(repo)
        model = AutoModelForCausalLM.from_pretrained(repo)

        prompt = "The future of AI is"
        inputs = tokenizer(prompt, return_tensors="pt")
        outputs = model.generate(**inputs, max_new_tokens=20, do_sample=True)
        print(f"\nPrompt: {prompt}")
        print(f"Output: {tokenizer.decode(outputs[0], skip_special_tokens=True)}")
    except ImportError:
        print("transformers not installed, skipping verification")
        print("  pip install transformers torch")


if __name__ == "__main__":
    main()
