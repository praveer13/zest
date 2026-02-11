# zest — P2P Acceleration for ML Model Distribution

**zest** accelerates ML model downloads by adding a peer-to-peer layer on top of HuggingFace's [Xet storage](https://huggingface.co/docs/xet/index). Models download from nearby peers first, falling back to HuggingFace CDN — never slower than vanilla `hf_xet`.

## Install

```bash
pip install zest-transfer
```

## Quick Start

### CLI

```bash
# Pull a model (uses P2P when peers available, CDN fallback)
zest pull meta-llama/Llama-3.1-8B

# Files land in standard HF cache — transformers.from_pretrained() just works
python -c "from transformers import AutoModel; AutoModel.from_pretrained('meta-llama/Llama-3.1-8B')"
```

### Python API

```python
import zest

# One-line activation — monkey-patches huggingface_hub
zest.enable()

# Or pull directly
path = zest.pull("meta-llama/Llama-3.1-8B")
```

### Environment Variable

```bash
# Auto-enable on import
ZEST=1 python train.py
```

## How It Works

HuggingFace's Xet protocol breaks files into content-addressed ~64KB chunks grouped into **xorbs**. zest adds a BitTorrent-compatible peer swarm so these immutable xorbs can be served by anyone who already downloaded them.

```
For each xorb needed:
  1. Check local cache
  2. Ask peers (BitTorrent protocol)
  3. Fall back to CDN (presigned S3 URLs)
```

Every download makes the network faster for the next person.

## P2P Testing

```bash
# Server A: pull a model and seed it
zest pull gpt2
zest serve

# Server B: pull from Server A
zest pull gpt2 --peer <server-a-ip>:6881
```

## Links

- [GitHub](https://github.com/praveer13/zest)
- [Xet Protocol](https://huggingface.co/docs/xet/index)
