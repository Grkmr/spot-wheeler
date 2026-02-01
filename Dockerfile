# syntax=docker/dockerfile:1.6
FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim AS build

# Build deps: autotools + compiler + swig + auditwheel prereq
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential autoconf automake libtool pkg-config \
    swig bison flex \
    patchelf file \
    libgmp-dev \
    libtool libltdl-dev \
    git \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ARG SPOT_REPO="https://gitlab.lre.epita.fr/spot/spot.git"
ARG SPOT_REF="spot-2-14-5"   

WORKDIR /src
RUN git clone --branch "${SPOT_REF}" --depth 1 "${SPOT_REPO}" spot
WORKDIR /src/spot

RUN uv venv /opt/venv --python 3.13
ENV VIRTUAL_ENV=/opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN uv pip install -U setuptools wheel build auditwheel

RUN mkdir -p doc/tl doc/org \
 && touch doc/tl/tl.pdf \
 && touch doc/org-stamp \
 && for f in ltlsynt satmin arch hierarchy; do : > "doc/org/$f.svg"; done

RUN autoreconf -vfi \
 && ./configure PYTHON="$VIRTUAL_ENV/bin/python" \
 && make -j"$(nproc)"

# Create minimal packaging files for a local wheel build
RUN cat > pyproject.toml <<'TOML'
[build-system]
requires = ["setuptools>=68", "wheel"]
build-backend = "setuptools.build_meta"
TOML

RUN cat > setup.py <<'PY'
from __future__ import annotations
import pathlib, shutil, sysconfig
from setuptools import setup, find_packages
from setuptools.command.build_py import build_py as _build_py

ROOT = pathlib.Path(__file__).resolve().parent

def _ext_suffixes():
    suf = sysconfig.get_config_var("EXT_SUFFIX")
    if suf:
        return [suf]
    return [".so", ".pyd", ".dylib"]

def _glob_ext(pattern_base: str):
    out = []
    for suf in _ext_suffixes():
        out.extend(ROOT.glob(pattern_base + "*" + suf + "*"))
    if not out:
        out = list(ROOT.glob(pattern_base + "*.so*")) + list(ROOT.glob(pattern_base + "*.pyd")) + list(ROOT.glob(pattern_base + "*.dylib*"))
    return out

class build_py(_build_py):
    def run(self):
        needed = [
            ROOT / "python/spot/impl.py",
            ROOT / "python/spot/gen.py",
            ROOT / "python/spot/ltsmin.py",
            ROOT / "python/buddy.py",
        ]
        missing = [p for p in needed if not p.exists()]
        if missing:
            raise RuntimeError(
                "Missing generated files. Run ./configure && make -C python first. "
                f"Missing: {', '.join(str(p) for p in missing)}"
            )

        super().run()

        build_lib = pathlib.Path(self.build_lib)

        # spot extension modules
        for mod in ("_impl", "_gen", "_ltsmin"):
            for src in _glob_ext(f"python/spot/.libs/{mod}"):
                dst = build_lib / "spot" / src.name
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)

        # buddy extension module (top-level)
        for src in _glob_ext("python/.libs/_buddy"):
            shutil.copy2(src, build_lib / src.name)

setup(
    name="spot-local",
    version="2.14.5.dev0",
    packages=find_packages("python"),
    package_dir={"": "python"},
    py_modules=["buddy"],
    include_package_data=True,
    package_data={"spot": ["*.so*", "*.pyd", "*.dylib*"]},
    cmdclass={"build_py": build_py},
)
PY

RUN python -m build --wheel

ENV LD_LIBRARY_PATH="/src/spot/spot/.libs:/src/spot/spot/gen/.libs:/src/spot/spot/ltsmin/.libs:/src/spot/buddy/.libs"
RUN mkdir -p /wheelhouse \
 && auditwheel show dist/*.whl \
 && auditwheel repair dist/*.whl -w /wheelhouse

FROM scratch AS export
COPY --from=build /wheelhouse/ /wheelhouse/

FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim AS test
COPY --from=build /wheelhouse/*.whl /tmp/

RUN uv pip install --system /tmp/*.whl && rm -f /tmp/*.whl

# optional: hard-check that nothing is missing at link time
RUN python - <<'PY'
import site, pathlib, subprocess, sys
roots=[pathlib.Path(p) for p in site.getsitepackages()]
sos=[]
for r in roots:
    sos += list(r.rglob("_impl*.so"))
    sos += list(r.rglob("_gen*.so"))
    sos += list(r.rglob("_ltsmin*.so"))
    sos += list(r.rglob("_buddy*.so"))
bad=False
for so in sos:
    out = subprocess.check_output(["ldd", str(so)], text=True)
    if "not found" in out:
        bad=True
        print("MISSING:", so)
        print(out)
sys.exit(1 if bad else 0)
PY

# Make `docker run` execute the smoke test (uv image defaults ENTRYPOINT=uv)
ENTRYPOINT []
CMD ["python", "-c", "import spot, buddy; import spot.gen, spot.ltsmin; print('OK')"]
