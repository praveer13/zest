"""Example: download a small model with zest and verify it works."""

import subprocess
import sys


def main():
    repo = "openai-community/gpt2"  # ~550 MB, smallest GPT-2

    print(f"Downloading {repo} via zest...")
    result = subprocess.run(["zest", "pull", repo])
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
