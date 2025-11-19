# Docker Image Generator

This script generates and pushes a large number of synthetic Docker images to an Artifactory Docker registry. It's designed to prefill the registry with a specified total size of images, with each image containing multiple unique layers.

## Features

- Generates Docker images with configurable size and number of layers
- Ensures each layer is unique to prevent Docker layer deduplication
- Separate control over build, push, and remove operations
- Configurable concurrency levels for each operation phase
- Parallel image building, pushing, and removal
- Efficient disk space usage by cleaning up after each push
- Configurable via command-line arguments
- Detailed logging of progress with a progress bar
- Step-by-step operation logging
- Automatic generation of readable random names and tags when not specified
- Flexible credential handling via command-line arguments or environment variables
- Automatic retry mechanism for network-related issues
- Smart resource management with optimal concurrency calculation
- Efficient data generation inside containers
- Support for insecure Docker registries
- Performance metrics tracking including total push time

## Performance Metrics

The script tracks various performance metrics that can be accessed programmatically:

### Push Performance
- `total_push_time`: Total time taken to push all images (in seconds)
- Average time per push
- Push throughput (images per second)

Example of accessing push metrics:
```python
generator = DockerImageGenerator(...)
generator.push_images(image_names)
print(f"Total push time: {generator.total_push_time:.2f} seconds")
print(f"Average time per push: {generator.total_push_time / len(image_names):.2f} seconds")
print(f"Push throughput: {len(image_names) / generator.total_push_time:.2f} images/second")
```

## Requirements

- Python 3.6+
- Docker CLI installed and configured
- Access to a Docker registry (e.g., Artifactory)
- Required Python packages:
  - tqdm (`pip install tqdm`)
  - backoff (`pip install backoff`)

## Usage

### Basic Usage

```bash
python docker_image_generator.py \
    --image-count 1000 \
    --image-size-mb 1024 \
    --layers 10 \
    --threads 4 \
    --registry "your-registry.example.com" \
    --artifactory-repo "your-repo" \
    --username "your-username" \
    --password "your-password"
```

### Phase-Specific Operations

You can run specific phases of the process using the following flags:

```bash
# Build only
python docker_image_generator.py \
    --image-count 1000 \
    --image-size-mb 1024 \
    --layers 10 \
    --threads 4 \
    --registry "your-registry.example.com" \
    --artifactory-repo "your-repo" \
    --build-only

# Push only (requires image-name and tag)
python docker_image_generator.py \
    --image-count 1000 \
    --image-size-mb 1024 \
    --layers 10 \
    --threads 4 \
    --registry "your-registry.example.com" \
    --artifactory-repo "your-repo" \
    --image-name "test-image" \
    --tag "v1.0" \
    --push-only

# Remove only (requires image-name and tag)
python docker_image_generator.py \
    --image-count 1000 \
    --image-size-mb 1024 \
    --layers 10 \
    --threads 4 \
    --registry "your-registry.example.com" \
    --artifactory-repo "your-repo" \
    --image-name "test-image" \
    --tag "v1.0" \
    --remove-only
```

### Phase-Specific Concurrency

You can specify different concurrency levels for each phase:

```bash
python docker_image_generator.py \
    --image-count 1000 \
    --image-size-mb 1024 \
    --layers 10 \
    --threads 4 \
    --registry "your-registry.example.com" \
    --artifactory-repo "your-repo" \
    --build-threads 3 \
    --push-threads 8 \
    --remove-threads 4
```

### Using Environment Variables

```bash
# Set Docker credentials as environment variables
export DOCKER_USERNAME="your-username"
export DOCKER_PASSWORD="your-password"

# Run the script without credential arguments
python docker_image_generator.py \
    --image-count 1000 \
    --image-size-mb 1024 \
    --layers 10 \
    --threads 4 \
    --registry "your-registry.example.com" \
    --artifactory-repo "your-repo"
```

### Using Insecure Registry

For insecure Docker registries (HTTP without TLS), use the `--insecure` flag. Optionally specify a custom port with `--insecure-port`:

```bash
# Using default port 80
python docker_image_generator.py \
    --image-count 1000 \
    --image-size-mb 1024 \
    --layers 10 \
    --threads 4 \
    --registry "your-registry.example.com" \
    --artifactory-repo "your-repo" \
    --insecure

# Using custom port
python docker_image_generator.py \
    --image-count 1000 \
    --image-size-mb 1024 \
    --layers 10 \
    --threads 4 \
    --registry "your-registry.example.com" \
    --artifactory-repo "your-repo" \
    --insecure \
    --insecure-port 8081
```

### Arguments

#### Required Arguments
- `--image-count`: Total number of images to create
- `--image-size-mb`: Size of each image in MB
- `--layers`: Number of layers per image
- `--threads`: Number of concurrent operations (default for all phases)
- `--registry`: Docker registry URL
- `--artifactory-repo`: Artifactory repository name

#### Optional Arguments
- `--image-name`: Docker image name (if not provided, a random name will be generated)
- `--tag`: Base tag for images (if not provided, a random tag will be generated)
- `--username`: Docker registry username (if not provided, DOCKER_USERNAME environment variable will be used)
- `--password`: Docker registry password (if not provided, DOCKER_PASSWORD environment variable will be used)
- `--insecure`: Use insecure registry mode (skip TLS verification)
- `--insecure-port`: Port to use for insecure registry (defaults to 80 if not specified)

#### Phase Control Arguments
- `--build-only`: Only build images, don't push or remove
- `--push-only`: Only push images, don't build or remove
- `--remove-only`: Only remove images, don't build or push

#### Phase-Specific Thread Counts
- `--build-threads`: Number of concurrent builds (defaults to --threads)
- `--push-threads`: Number of concurrent pushes (defaults to --threads)
- `--remove-threads`: Number of concurrent removals (defaults to --threads)

### Credential Handling

The script supports three ways to provide Docker registry credentials:

1. Command-line arguments (highest priority):
   ```bash
   --username "your-username" --password "your-password"
   ```

2. Environment variables:
   ```bash
   export DOCKER_USERNAME="your-username"
   export DOCKER_PASSWORD="your-password"
   ```

3. Mix of both (command-line arguments take precedence over environment variables)

If credentials are not provided through either method, the script will exit with an error.

### Random Name Generation

When `--image-name` is not provided, the script generates a random but readable name using a combination of adjectives and nouns. For example:
- swift-eagle
- brave-lion
- clever-dragon

When `--tag` is not provided, the script generates a random semantic version tag. For example:
- v123.4.5
- v42.7.9
- v999.0.1

## Example Scenarios

### 1. Full Process with Different Concurrency Levels

```bash
python docker_image_generator.py \
    --image-count 1000 \
    --image-size-mb 1024 \
    --layers 10 \
    --threads 4 \
    --registry "artifactory.example.com" \
    --artifactory-repo "docker-local" \
    --build-threads 3 \
    --push-threads 8 \
    --remove-threads 4
```

This will:
1. Build 1000 images using 3 concurrent builds
2. Push all images using 8 concurrent pushes
3. Remove all images using 4 concurrent removals

### 2. Build Only with Custom Thread Count

```bash
python docker_image_generator.py \
    --image-count 1000 \
    --image-size-mb 1024 \
    --layers 10 \
    --threads 4 \
    --registry "artifactory.example.com" \
    --artifactory-repo "docker-local" \
    --build-threads 3 \
    --build-only
```

This will only build the images using 3 concurrent builds.

### 3. Push Only with Custom Thread Count

```bash
python docker_image_generator.py \
    --image-count 1000 \
    --image-size-mb 1024 \
    --layers 10 \
    --threads 4 \
    --registry "artifactory.example.com" \
    --artifactory-repo "docker-local" \
    --image-name "test-image" \
    --tag "v1.0" \
    --push-threads 8 \
    --push-only
```

This will only push the images using 8 concurrent pushes.

## Progress Tracking

The script provides two levels of progress tracking:

1. A progress bar showing the overall completion status for each phase
2. Detailed logging of each operation:
   - Docker registry login
   - Layer file generation
   - Dockerfile creation
   - Image building
   - Image pushing
   - Local image cleanup

## Error Handling and Resilience

The script includes several features to handle errors and ensure reliable operation:

1. **Automatic Retry Mechanism**:
   - Exponential backoff for failed operations
   - Maximum of 3 retries per operation
   - Maximum retry time of 5 minutes
   - Smart retry logic that won't retry authentication errors

2. **Network Resilience**:
   - Handles temporary network issues gracefully
   - Retries failed pushes with increasing delays
   - Proper cleanup of resources after failures

3. **Resource Management**:
   - Automatically calculates optimal concurrency based on:
     - Available disk space
     - CPU cores
     - User-specified thread count
   - Prevents disk space exhaustion
   - Efficient memory usage

4. **Error Recovery**:
   - Cleans up local images even when push fails
   - Provides detailed error messages
   - Maintains operation logs for debugging

## Notes

- The script uses temporary directories for building images, which are automatically cleaned up after each push
- Each layer contains random data to ensure uniqueness
- Progress is logged to the console with timestamps
- The script will exit with an error if any image fails to build or push after all retries
- Make sure you have sufficient disk space for the temporary files during build
- The script uses the Docker CLI, so ensure it's installed and configured correctly
- Credentials can be provided via command-line arguments or environment variables
- Command-line arguments take precedence over environment variables
- The script automatically handles network issues and retries failed operations
- Resource usage is optimized based on available system resources
- For insecure registries, the script will automatically configure Docker daemon.json
- When using insecure registry mode, Docker Desktop needs to be restarted after configuration changes
- When using phase-specific operations (--build-only, --push-only, --remove-only), make sure to provide the required image-name and tag for push and remove operations 

---
The script does something simailar to the following to publish the docker images :

echo -e "FROM alpine:3.18\n\nRUN echo \"Layer 2\" > /layer2.txt" > Dockerfile
docker build -t psazuse.jfrog.io/sup016-docker-qa-local/layer-test:v1 .
docker push example.jfrog.io/sup016-docker-qa-local/layer-test:v1

This tag can be cleaned up in Artifactory using:
```
curl -kL -X DELETE \
  -H "Authorization: Bearer $DOCKER_PASSWORD" \
  "https://example.jfrog.io/artifactory/sup016-docker-qa-local/layer-test/v1"
```
---