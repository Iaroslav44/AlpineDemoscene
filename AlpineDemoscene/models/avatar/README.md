# Pretrained neural avatar: gDNA / THuman2.0

This directory contains a compact **inference-weight export**, not a mesh,
photograph, precomputed feature volume, animation frame, or randomly initialised
network. The original pretrained model was published by the gDNA authors:

- Official implementation: https://github.com/xuchen-ethz/gdna
- Paper/project: https://xuchen-ethz.github.io/gdna/
- Author-hosted checkpoint archive:
  https://dataset.ait.ethz.ch/downloads/gdna/trained_models.zip
- Selected member: `outputs/thuman/checkpoints/last.ckpt`.
- Source member size: 321,395,490 bytes.
- SHA-256: `23386f2ff110a305e9fe78a7003b9252307c2a75103413f83d74156c05c0d3a4`.
- Training source: THuman2.0 scans of real clothed people, as identified in the
  official release. This is a learned human-geometry model, not an environment
  generator or a photorealistic face/material generator.

`gdna-thuman.json` records the runtime export's tensor shapes, byte ranges, hash,
size and limitations. The exporter uses a restricted pickle reader with an
explicit five-global whitelist; it never imports or executes PyTorch/Lightning
checkpoint code. Every source byte is checked against the pinned checksum.

## What is retained

The export contains the learned latent-conditioned 3D feature generator,
occupancy decoder, normal decoder and deformation/skinning networks. Weight
normalisation is folded into dense weights. The learned latent distribution is
represented by its mean and unbiased standard deviation.

The export excludes optimiser states, discriminator, training-example latent
tables and all SMPL template meshes, pose/shape blendshapes and joint regressors.
The two output-inactive linear parameters `generator.lin2` are omitted. The
prototype uses the network's canonical-shape path, so it needs no input picture
or prebuilt SMPL mesh. A seed samples new latent codes at runtime.

## Runtime graph

1. Sample 64 shape and 64 detail latent values using the exported statistics.
2. Evaluate the learned 256-channel 2×8×8 initial feature, adaptive instance
   normalisation and three trilinear-upsample/3D-convolution stages.
3. Query the implicit occupancy network over a 65×129×49 spatial grid.
4. Extract a zero-level mesh with marching tetrahedra.
5. Evaluate learned fine normals and the learned 24-joint skinning field at its
   unique vertices. Keep the largest four weights, normalised to sum to one.
6. Upload the generated mesh for ordinary Direct3D animation and lighting.

The neural stages execute once at startup through `src/neural_avatar.hlsl`.
`src/neural_avatar_runtime.cpp` handles D3D resources, cancellation, extraction and
validation. It requires no CUDA, Python, PyTorch, ONNX runtime or external DLL.
All intermediate fields are released after generation. Meshes remain in GPU
memory for the demo; they are not stored inside the EXE.

The source canonical coordinates are Y-up, with a T-pose upper body and the two
hip joints rotated ±π/6 around Z. The output is uniformly scaled to 1.75 m high,
with the feet at Y=0. The renderer supplies authored joint motion; the prototype
does not reproduce full SMPL deformation or physical cloth.

## Reproduction and verification

Run `tools/neural_avatar_export.py --download` with NumPy available to recover
the pinned public source member and reproduce the NAV1 export. It downloads only
the THuman member of the ZIP archive. Downloaded source stays in ignored
`build/neural_source/` and is never packaged.

`tools/neural_avatar_reference.py` independently evaluates the graph with NumPy.
The render probe's `--dump-neural` option exposes intermediate arrays through an
optional diagnostic callback. Passing that directory to `--gpu-dir` compares
latent sampling, all generated features, occupancy queries, fine normals and
skinning weights against the CPU reference. Production leaves this callback
unset and does not write diagnostic files.

## Rights and scope

The upstream code's MIT notice is preserved in `LICENSE.gdna.txt`. The author
release identifies THuman2.0 as the training source; conditions governing the
dataset and model weights are separate from the code license. This local
research prototype does not assert unrestricted redistribution rights for the
checkpoint or training data. No source scan or SMPL template is redistributed in
the exported runtime tensor file.

The current output is a neural human-geometry prototype. Photorealistic faces,
learned albedo/PBR properties, hair, teeth and facial expression generation are
not implemented by this model and must not be claimed as completed.
