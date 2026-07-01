# GC2026 Full Pipeline — UVG-CWI-DQPC Grand Challenge 2026
# Processing track: Full Pipeline (RGBD bag -> cwipc Stage1 -> SuperPC)
#
# Build:
#   docker build -t gc2026-full-pipeline .
#
# Run (GPU, data mounted):
#   docker run --gpus all -v /path/to/data:/app/data -v /path/to/models:/app/models \
#     gc2026-full-pipeline full
#
# Val smoke only (565 official val frames, CPU-heavy Stage1):
#   docker run --gpus all -v ... gc2026-full-pipeline val-smoke

FROM nvidia/cuda:12.4.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV GC2026_ROOT=/app
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    git wget curl ca-certificates \
    build-essential cmake pkg-config \
    libgl1 libglib2.0-0 libusb-1.0-0-dev libudev-dev \
    python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Miniconda for SuperPC (py3.9 + torch)
RUN wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O /tmp/miniconda.sh \
    && bash /tmp/miniconda.sh -b -p /opt/conda \
    && rm /tmp/miniconda.sh
ENV PATH="/opt/conda/bin:${PATH}"

COPY requirements.txt requirements-docker.txt* /app/
COPY scripts/env_setup.sh /app/scripts/env_setup.sh

# Project code (exclude large data/outputs via .dockerignore)
COPY scripts/ /app/scripts/
COPY code/SuperPC/ /app/code/SuperPC/
COPY submissions/GC2026_Team/src/ /app/submissions/GC2026_Team/src/
COPY models/superpc_pretrained/ /app/models/superpc_pretrained/
COPY data/processed/ /app/data/processed/
COPY data/raw/UVG-CWI-DQPC.json /app/data/raw/UVG-CWI-DQPC.json

COPY docker/entrypoint.sh /app/docker/entrypoint.sh

RUN chmod +x /app/docker/entrypoint.sh /app/scripts/*.sh 2>/dev/null || true

RUN conda create -y -n superpc python=3.9 \
    && /opt/conda/envs/superpc/bin/pip install --no-cache-dir -r /app/requirements.txt \
    && /opt/conda/envs/superpc/bin/pip install --no-cache-dir \
         scipy trimesh pandas rosbags plyfile

# cwipc installed at runtime or bake via: docker run ... install-cwipc
ENV STAGE1_TAG=N0_cwipc_official
ENV UVG_VAL_PAIRS_FILE=/app/data/processed/val_pairs_official_cgv2.txt

ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["full"]
