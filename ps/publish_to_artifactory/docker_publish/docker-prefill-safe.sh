#!/bin/bash

set -e

# === CONFIGURATION ===
IMAGE_COUNT=${IMAGE_COUNT:-1000}         # Total number of images
IMAGE_SIZE_MB=${IMAGE_SIZE_MB:-1024}     # Size per image in MB
LAYERS=${LAYERS:-10}                     # Number of layers per image
THREADS=${THREADS:-5}                    # Parallel jobs (lower if you're low on space)

DOCKER_REGISTRY=${DOCKER_REGISTRY:-docker.jfrog.io}
REPO_NAMESPACE=${REPO_NAMESPACE:-myrepo}
REPO_NAME=${REPO_NAME:-testimage}
IMAGE_TAG=${IMAGE_TAG:-latest}

ARTIUSER=${ARTIUSER:-admin}
PASSWORD=${PASSWORD:-password}

# === CALCULATED ===
LAYER_SIZE_MB=$((IMAGE_SIZE_MB / LAYERS))
TEMP_BASE=$(mktemp -d /tmp/docker-prefill.XXXX)
echo "Using temporary base directory: $TEMP_BASE"

# === FUNCTIONS ===
build_and_push_image() {
  local image_num=$1
  local image_name="$DOCKER_REGISTRY/$REPO_NAMESPACE/$REPO_NAME-$image_num:$IMAGE_TAG"
  local build_dir="$TEMP_BASE/image-$image_num"

  mkdir -p "$build_dir"

  echo "FROM scratch" > "$build_dir/Dockerfile"

  for ((i = 1; i <= LAYERS; i++)); do
    dd if=/dev/urandom of="$build_dir/layer-$i.dat" bs=1M count=$LAYER_SIZE_MB status=none
    echo "ADD layer-$i.dat /data/layer-$i.dat" >> "$build_dir/Dockerfile"
  done

  docker build -t "$image_name" "$build_dir"
  docker push "$image_name"

  echo "Cleaning up image $image_name"
  docker rmi "$image_name" >/dev/null 2>&1 || true
  rm -rf "$build_dir"
}

# === SETUP ===
echo "Logging into Docker registry: $DOCKER_REGISTRY"
docker login -u "$ARTIUSER" -p "$PASSWORD" "$DOCKER_REGISTRY"

# === PARALLEL BUILD ===
export -f build_and_push_image
export LAYERS LAYER_SIZE_MB TEMP_BASE \
       DOCKER_REGISTRY REPO_NAMESPACE REPO_NAME IMAGE_TAG

seq 1 "$IMAGE_COUNT" | parallel -j "$THREADS" build_and_push_image {}

echo "✅ All images pushed. Cleaning temp base."
rm -rf "$TEMP_BASE"
