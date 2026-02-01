# Spot wheel Docker build (uv + auditwheel)

Builds Spot’s Python bindings into a wheel inside a Docker image and bundles required shared libraries with `auditwheel`.

## Requirements

- Docker (BuildKit recommended)

## Build

```bash
docker build -t spot-wheel-test .
```

Optional: choose Spot repo/ref

```bash
docker build -t spot-wheel-test . \
  --build-arg SPOT_REPO="https://gitlab.lre.epita.fr/spot/spot.git" \
  --build-arg SPOT_REF="spot-2-14-5"
```

## Test (imports + link check)

```bash
docker run --rm spot-wheel-test
```

Hard check inside the container (no env help):

```bash
docker run --rm --entrypoint sh spot-wheel-test -lc '
unset LD_LIBRARY_PATH
python -c "import spot, buddy; import spot.gen, spot.ltsmin; print(\"imports OK\")"
'
```

## Export the wheel to your host

### BuildKit `--output` (recommended)

```bash
DOCKER_BUILDKIT=1 docker build --target export \
  --output type=local,dest=./wheelhouse .
# wheels are in ./wheelhouse/*.whl
```

### `docker cp` fallback

```bash
docker build --target export -t spot-wheel-export .
cid=$(docker create spot-wheel-export)
docker cp "$cid:/wheelhouse" ./wheelhouse
docker rm "$cid"
```
