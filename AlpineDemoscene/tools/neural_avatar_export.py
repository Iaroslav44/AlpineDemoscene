"""Export the public gDNA THuman checkpoint without executing pickle globals.

Only trained inference tensors are retained. In particular the SMPL template,
training examples, optimiser and discriminator are NOT part of the runtime file.
The NAV1 file is plain little-endian FP32, not a Python/PyTorch dependency.
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import io
import json
from pathlib import Path
import pickle
import struct
import urllib.request
import zipfile
import zlib

import numpy as np

SOURCE = "https://dataset.ait.ethz.ch/downloads/gdna/trained_models.zip"
SOURCE_CHECKPOINT_SHA256 = "23386f2ff110a305e9fe78a7003b9252307c2a75103413f83d74156c05c0d3a4"
SOURCE_CHECKPOINT_BYTES = 321395490
ROOT = Path(__file__).resolve().parents[1]


class CheckpointMarker:
    """Inert dictionary key occurring in Lightning metadata."""


class TensorDescriptor:
    def __init__(self, storage, offset, shape, stride, *unused):
        self.storage, self.offset, self.shape, self.stride = storage, offset, shape, stride


class RestrictedCheckpointReader(pickle.Unpickler):
    def find_class(self, module, name):
        whitelist = {
            ("collections", "OrderedDict"): collections.OrderedDict,
            ("pytorch_lightning.callbacks.model_checkpoint", "ModelCheckpoint"): CheckpointMarker,
            ("torch", "FloatStorage"): "FloatStorage",
            ("torch", "LongStorage"): "LongStorage",
            ("torch._utils", "_rebuild_tensor_v2"): TensorDescriptor,
        }
        if (module, name) not in whitelist:
            raise pickle.UnpicklingError(f"Unsupported checkpoint global: {module}.{name}")
        return whitelist[module, name]

    def persistent_load(self, value):
        if len(value) != 5 or value[0] != "storage" or value[1] not in ("FloatStorage", "LongStorage"):
            raise pickle.UnpicklingError("Unexpected storage descriptor")
        return value


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch_checkpoint(path):
    """Fetch only THuman ZIP member (295 MB compressed), not both models."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.stat().st_size == SOURCE_CHECKPOINT_BYTES and digest(path) == SOURCE_CHECKPOINT_SHA256:
        return
    # Offset is checked against the ZIP local header and published member name.
    request = urllib.request.Request(SOURCE, headers={"Range": "bytes=224-317"})
    with urllib.request.urlopen(request) as response:
        if response.status != 206:
            raise RuntimeError("Source server did not honour range request")
        header = response.read()
    fields = struct.unpack("<4s5H3L2H", header[:30])
    name = header[30:30 + fields[9]]
    if fields[0] != b"PK\x03\x04" or fields[3] != 8 or name != b"outputs/thuman/checkpoints/last.ckpt":
        raise RuntimeError("Published source archive changed")
    start = 224 + 30 + fields[9] + fields[10]
    compressed_bytes = fields[7]
    request = urllib.request.Request(SOURCE, headers={"Range": f"bytes={start}-{start+compressed_bytes-1}"})
    temporary = path.with_suffix(".download")
    inflater = zlib.decompressobj(-15)
    with urllib.request.urlopen(request) as response, temporary.open("wb") as stream:
        if response.status != 206:
            raise RuntimeError("Source server did not honour range request")
        while chunk := response.read(1024 * 1024):
            stream.write(inflater.decompress(chunk))
        stream.write(inflater.flush())
    if not inflater.eof or temporary.stat().st_size != SOURCE_CHECKPOINT_BYTES or digest(temporary) != SOURCE_CHECKPOINT_SHA256:
        raise RuntimeError("Downloaded checkpoint did not match pinned SHA-256")
    temporary.replace(path)


def read_tensors(path):
    if digest(path) != SOURCE_CHECKPOINT_SHA256:
        raise ValueError("Checkpoint SHA-256 mismatch")
    result = {}
    with zipfile.ZipFile(path) as archive:
        checkpoint = RestrictedCheckpointReader(io.BytesIO(archive.read("archive/data.pkl"))).load()
        for name, descriptor in checkpoint["state_dict"].items():
            if not name.startswith(("network.", "generator.", "deformer.", "norm_network.", "z_shapes.", "z_details.")):
                continue
            if not isinstance(descriptor, TensorDescriptor) or descriptor.storage[1] != "FloatStorage":
                raise ValueError(f"Unexpected tensor {name}")
            raw = archive.read("archive/data/" + descriptor.storage[2])
            base = np.frombuffer(raw, dtype="<f4")
            shape, strides = tuple(descriptor.shape), tuple(x * 4 for x in descriptor.stride)
            tensor = np.ndarray(shape, dtype="<f4", buffer=base, offset=descriptor.offset * 4, strides=strides).copy()
            if not np.isfinite(tensor).all():
                raise ValueError(f"Non-finite tensor {name}")
            result[name] = tensor
    return result


def inference_tensors(state):
    output = collections.OrderedDict()
    for name, value in state.items():
        if name.startswith("z_") or name.endswith(".weight_g") or name == "generator.lin2.weight" or name == "generator.lin2.bias":
            continue
        if name.endswith(".weight_v"):
            # PyTorch weight_norm dim=0: norm over every other dimension.
            norm = np.sqrt(np.sum(value * value, axis=tuple(range(1, value.ndim)), keepdims=True))
            value = value * (state[name[:-8] + "weight_g"] / norm)
            name = name[:-8] + "weight"
        output[name] = np.asarray(value, dtype="<f4")
    for source, target in (("z_shapes.weight", "latent.shape"), ("z_details.weight", "latent.detail")):
        output[target + ".mean"] = state[source].mean(axis=0, dtype=np.float32)
        output[target + ".std"] = state[source].std(axis=0, ddof=1, dtype=np.float32)
    return output


def write_nav(path, tensors, magic=b"NAV1"):
    # Header16, directory128/tensor. Tensor names80, rank, shape5, offset,
    # length, type=1(float32), reserved2. Offsets are absolute bytes.
    data_offset = (16 + len(tensors) * 128 + 15) & ~15
    records, payload, summaries = [], bytearray(), []
    for name, value in tensors.items():
        if len(name.encode()) >= 80 or value.ndim > 5:
            raise ValueError("NAV1 directory limit exceeded")
        while len(payload) % 16:
            payload.append(0)
        offset = data_offset + len(payload)
        raw = np.ascontiguousarray(value, dtype="<f4").tobytes()
        shape = list(value.shape) + [1] * (5 - value.ndim)
        record = struct.pack("<80s12I", name.encode(), value.ndim, *shape, offset, len(raw), 1, 0, 0, 0)
        assert len(record) == 128
        records.append(record)
        payload.extend(raw)
        summaries.append({"name": name, "shape": list(value.shape), "offset": offset, "bytes": len(raw)})
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as stream:
        stream.write(struct.pack("<4s3I", magic, 1, len(tensors), data_offset))
        stream.write(b"".join(records))
        stream.write(bytes(data_offset - stream.tell()))
        stream.write(payload)
    return summaries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, default=ROOT / "build/neural_source/gdna-thuman.ckpt")
    parser.add_argument("--output", type=Path, default=ROOT / "models/avatar/gdna-thuman.nav")
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    if args.download:
        fetch_checkpoint(args.checkpoint)
    tensors = inference_tensors(read_tensors(args.checkpoint))
    summaries = write_nav(args.output, tensors)
    manifest = {
        "schema": 1,
        "model": "gDNA THuman2.0 pretrained (CVPR 2022)",
        "source_repository": "https://github.com/xuchen-ethz/gdna",
        "source_checkpoint_url": SOURCE,
        "source_checkpoint_member": "outputs/thuman/checkpoints/last.ckpt",
        "source_checkpoint_sha256": SOURCE_CHECKPOINT_SHA256,
        "training_data": "THuman2.0 scans of real clothed people",
        "code_license": "MIT; model/data/SMPL conditions are separate",
        "export": "Only inference neural tensors; weight_norm folded; no SMPL templates, training examples, discriminator or optimiser",
        "runtime_input": "64D sampled shape/detail latent codes and 3D query positions; no input photograph",
        "limitations": ["No learned albedo/PBR material generator", "Not photorealistic face generation", "Canonical-shape mode does not implement full SMPL body deformation"],
        "resource_id": 200, "path": args.output.relative_to(ROOT).as_posix(),
        "bytes": args.output.stat().st_size, "sha256": digest(args.output), "magic_hex": "4e415631",
        "tensors": summaries,
    }
    args.output.with_suffix(".json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k:manifest[k] for k in ("model", "bytes", "sha256", "resource_id")}, indent=2))


if __name__ == "__main__":
    main()
