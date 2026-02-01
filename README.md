# Spot wheel in Docker (uv + auditwheel)

This repository builds the Python bindings for **Spot** (model-checking library) into a **wheel** inside a Docker container based on:

- `ghcr.io/astral-sh/uv:python3.13-bookworm-slim`

It uses:

- **Autotools + SWIG** to build Spot’s Python extension modules
- **uv** to manage the build virtualenv and Python deps
- **auditwheel** (with `patchelf`) to vendor required shared libraries into the wheel
- a **multi-stage Docker build** so the final image is small and only contains the installed wheel

The result is an image where `import spot` works without needing the Spot build tree or custom `LD_LIBRARY_PATH` hacks at runtime.

## What this builds

Inside the build stage we compile the Spot Python extensions (e.g. `_impl`, `_gen`, `_ltsmin`, `_buddy`) and then run `auditwheel repair` to bundle non-system shared library dependencies into the wheel (typically into `*.libs/` inside site-packages) and rewrite ELF RPATH/RUNPATH accordingly.

The runtime stage installs the repaired wheel and runs a small import smoke test.

## Requirements

- Docker (BuildKit recommended)
- Internet access during the build (to clone Spot and install build deps)

## Usage

### Build the image

```bash
docker build -t spot-wheel-test .
```

### Run the smoke test

```bash
docker run --rm spot-wheel-test
```

You should see something like:

```
OK /usr/local/lib/python3.13/site-packages/spot/__init__.py
```

## How to verify shared libraries are correctly bundled

### 1) Confirm imports work without environment variables

```bash
docker run --rm --entrypoint sh spot-wheel-test -lc '
unset LD_LIBRARY_PATH
python -c "import spot, buddy; import spot.gen, spot.ltsmin; print(\"imports OK\")"
'
```

### 2) Run `ldd` on the extension modules

```bash
docker run --rm --entrypoint sh spot-wheel-test -lc '
python - <<PY
import site, pathlib
sp = pathlib.Path(site.getsitepackages()[0]) / "spot"
for pat in ("_impl*.so","_gen*.so","_ltsmin*.so"):
    for p in sp.glob(pat):
        print(p)
PY
'
```

Copy one printed path and run:

```bash
docker run --rm --entrypoint sh spot-wheel-test -lc 'ldd /path/to/_impl*.so | grep -E "not found|libspot|=>"'
```

There should be **no** `not found` entries. Spot-related libraries should typically resolve from a `.../site-packages/<dist>.libs/...` directory if `auditwheel` bundled them.

## Customizing which Spot version is built

If your Dockerfile uses build args like `SPOT_REPO` / `SPOT_REF`, you can build a specific tag or commit:

```bash
docker build \
  --build-arg SPOT_REPO="https://github.com/<owner>/<repo>.git" \
  --build-arg SPOT_REF="<tag-or-commit>" \
  -t spot-wheel-test .
```

Pinning `SPOT_REF` to a commit SHA makes builds reproducible.

## Notes

- This project focuses on "works inside this container" rather than producing a manylinux wheel for PyPI.
- Documentation generation is intentionally avoided because it pulls in large toolchains (TeX, `latexmk`, `pdf2svg`, etc.). Only the Python bindings are built.
- If you want a portable manylinux wheel, build in a manylinux container and then run `auditwheel repair` there.

## License

This repo contains build scripts only. Spot itself is downloaded during the Docker build and is licensed separately by its upstream project.
