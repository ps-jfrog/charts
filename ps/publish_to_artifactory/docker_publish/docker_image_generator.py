#!/usr/bin/env python3

import argparse
import concurrent.futures
import logging
import os
import random
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import List, Optional, Dict, Tuple
from tqdm import tqdm
import hashlib
import json
import uuid
import time
from datetime import timedelta
import multiprocessing
from concurrent.futures import ProcessPoolExecutor
import threading
from threading import Semaphore
import queue
import io
import backoff
import sys

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Maximum number of retries for Docker operations
MAX_RETRIES = 3
# Initial backoff time in seconds
INITIAL_BACKOFF = 5

@backoff.on_exception(
    backoff.expo,
    (subprocess.CalledProcessError, ConnectionError),
    max_tries=MAX_RETRIES,
    max_time=300,  # Maximum total time for retries (5 minutes)
    giveup=lambda e: "authentication required" in str(e).lower()  # Don't retry auth errors
)
def run_docker_command(cmd: List[str], operation: str) -> None:
    """Run a Docker command with retry logic."""
    try:
        result = subprocess.run(
            cmd,
            check=True,
            capture_output=True,
            text=True
        )
        logger.debug(f"Docker {operation} output: {result.stdout}")
    except subprocess.CalledProcessError as e:
        logger.error(f"Docker {operation} failed: {e.stderr}")
        raise

def configure_insecure_registry(registry: str, insecure_port: Optional[int] = None) -> None:
    """Configure Docker to allow insecure registry access."""
    try:
        # Check if Docker daemon config exists
        config_path = Path.home() / '.docker' / 'daemon.json'
        
        # Format registry URL based on security mode
        port = insecure_port or 80
        registry_url = f"http://{registry}:{port}"
        
        # If config doesn't exist, create it
        if not config_path.exists():
            config_path.parent.mkdir(parents=True, exist_ok=True)
            config = {"insecure-registries": [registry_url]}
            with open(config_path, 'w') as f:
                json.dump(config, f, indent=2)
            logger.info(f"Created new daemon.json with {registry_url} in insecure registries")
            needs_restart = True
        else:
            # Read existing config
            with open(config_path, 'r') as f:
                config = json.load(f)
            
            # Clean up any existing entries for this registry
            if 'insecure-registries' in config:
                config['insecure-registries'] = [
                    r for r in config['insecure-registries']
                    if not r.startswith(registry) and not r.startswith(f"http://{registry}") and not r.startswith(f"https://{registry}")
                ]
            
            # Add the new registry URL
            if 'insecure-registries' not in config:
                config['insecure-registries'] = []
            config['insecure-registries'].append(registry_url)
            
            # Write updated config
            with open(config_path, 'w') as f:
                json.dump(config, f, indent=2)
            logger.info(f"Updated daemon.json with {registry_url} in insecure registries")
            needs_restart = True
        
        # Always inform user about Docker restart status
        if needs_restart:
            logger.info("\nDocker daemon configuration has been updated.")
            logger.info("Please restart Docker Desktop manually to apply the changes.")
        else:
            logger.info("\nDocker daemon configuration is already set up correctly.")
            logger.info("However, please ensure Docker Desktop has been restarted after the last configuration change.")
        
        logger.info("After confirming Docker Desktop is running, press Enter to continue...")
        input()
        
        # Verify Docker is running after restart
        max_wait = 60  # Maximum wait time in seconds
        start_time = time.time()
        while time.time() - start_time < max_wait:
            try:
                subprocess.run(['docker', 'info'], check=True, capture_output=True)
                logger.info("Docker is running. Proceeding with image generation...")
                break
            except subprocess.CalledProcessError:
                logger.info("Waiting for Docker to start...")
                time.sleep(1)
        else:
            raise TimeoutError("Docker failed to start within the timeout period")
    except Exception as e:
        logger.error(f"Failed to configure insecure registry: {str(e)}")
        raise

def create_dockerfile(
    layers: int,
    layer_size_mb: int,
    image_index: int,
    dockerfile_path: Path
) -> None:
    """Create a Dockerfile that generates random data in the container."""
    logger.debug(f"Creating Dockerfile at {dockerfile_path}")
    
    # Generate a unique identifier for this image
    unique_id = str(uuid.uuid4())
    
    with open(dockerfile_path, 'w') as f:
        f.write("FROM alpine\n")
        f.write(f"LABEL image_id={unique_id}\n")
        f.write(f"LABEL image_index={image_index}\n")
        
        # Create data directory
        f.write("RUN mkdir -p /data\n")
        
        # Generate random data for each layer using dd
        for i in range(layers):
            # Calculate size in bytes
            size_bytes = layer_size_mb * 1024 * 1024
            # Generate random data using dd and add metadata
            f.write(f"RUN dd if=/dev/urandom of=/data/layer_{i}.dat bs=1M count={layer_size_mb} && "
                   f"echo 'LAYER_ID={uuid.uuid4()}' >> /data/layer_{i}.dat && "
                   f"echo 'LAYER_INDEX={i}' >> /data/layer_{i}.dat\n")

def build_docker_image(
    image_index: int,
    layer_size_mb: int,
    layers: int,
    registry_url: str,
    tag: str,
    image_count: int
) -> str:
    """Build a single Docker image."""
    start_time = time.time()
    
    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)
        
        # Create Dockerfile that generates data in the container
        dockerfile_path = temp_path / "Dockerfile"
        create_dockerfile(layers, layer_size_mb, image_index, dockerfile_path)
        
        # Build image with optimized settings
        image_name = f"{registry_url}:{tag}_{image_index}"
        try:
            logger.info(f"Building image {image_index + 1}/{image_count}: {image_name}")
            run_docker_command(
                ["docker", "build", "--no-cache", "--compress", "-t", image_name, str(temp_path)],
                "build"
            )
            
            elapsed_time = time.time() - start_time
            logger.info(f"Successfully built image {image_index + 1}/{image_count} in {timedelta(seconds=int(elapsed_time))}")
            return image_name
            
        except Exception as e:
            logger.error(f"Failed to build image {image_index + 1}: {str(e)}")
            raise

def push_docker_image(image_name: str, image_index: int, image_count: int) -> None:
    """Push a single Docker image to the registry."""
    start_time = time.time()
    
    try:
        logger.info(f"Pushing image {image_index + 1}/{image_count}: {image_name}")
        run_docker_command(
            ["docker", "push", image_name],
            "push"
        )
        
        elapsed_time = time.time() - start_time
        logger.info(f"Successfully pushed image {image_index + 1}/{image_count} in {timedelta(seconds=int(elapsed_time))}")
        
    except Exception as e:
        logger.error(f"Failed to push image {image_index + 1}: {str(e)}")
        raise

def remove_docker_image(image_name: str, image_index: int, image_count: int) -> None:
    """Remove a single Docker image from local storage."""
    start_time = time.time()
    
    try:
        logger.info(f"Removing local image {image_index + 1}/{image_count}: {image_name}")
        run_docker_command(
            ["docker", "rmi", image_name],
            "remove"
        )
        
        elapsed_time = time.time() - start_time
        logger.info(f"Successfully removed image {image_index + 1}/{image_count} in {timedelta(seconds=int(elapsed_time))}")
        
    except Exception as e:
        logger.error(f"Failed to remove image {image_index + 1}: {str(e)}")
        raise

class DockerImageGenerator:
    # Lists for generating readable random names
    ADJECTIVES = [
        "swift", "brave", "clever", "bright", "calm", "eager", "fair", "gentle",
        "happy", "jolly", "kind", "lively", "merry", "noble", "proud", "quick",
        "rapid", "smart", "tender", "witty"
    ]
    
    NOUNS = [
        "eagle", "falcon", "hawk", "lion", "tiger", "wolf", "bear", "dolphin",
        "panther", "phoenix", "raven", "shark", "whale", "zebra", "dragon",
        "unicorn", "griffin", "pegasus", "kraken", "hydra"
    ]

    def __init__(
        self,
        image_count: int,
        image_size_mb: int,
        layers: int,
        threads: int,
        registry: str,
        artifactory_repo: str,
        image_name: Optional[str] = None,
        tag: Optional[str] = None,
        username: Optional[str] = None,
        password: Optional[str] = None,
        insecure: bool = False,
        insecure_port: Optional[int] = None,
        build_threads: Optional[int] = None,
        push_threads: Optional[int] = None,
        remove_threads: Optional[int] = None
    ):
        self.image_count = image_count
        self.image_size_mb = image_size_mb
        self.layers = layers
        self.threads = threads
        self.build_threads = build_threads or threads
        self.push_threads = push_threads or threads
        self.remove_threads = remove_threads or threads
        self.registry = registry
        self.artifactory_repo = artifactory_repo
        self.image_name = image_name or self._generate_random_name()
        self.tag = tag or self._generate_random_tag()
        self.insecure = insecure
        self.insecure_port = insecure_port
        self.total_push_time = 0  # Initialize total_push_time attribute
        
        # Get credentials from arguments or environment variables
        self.username = username or os.environ.get('DOCKER_USERNAME')
        self.password = password or os.environ.get('DOCKER_PASSWORD')
        
        if not self.username or not self.password:
            raise ValueError(
                "Docker credentials not found. Please provide them either as command-line arguments "
                "or set DOCKER_USERNAME and DOCKER_PASSWORD environment variables."
            )
        
        # Calculate layer size in MB
        self.layer_size_mb = image_size_mb // layers
        
        # Docker registry URL - use port for insecure registries
        if self.insecure:
            if self.insecure_port:
                self.registry_url = f"{registry}:{self.insecure_port}/{artifactory_repo}/{self.image_name}"
            else:
                self.registry_url = f"{registry}:80/{artifactory_repo}/{self.image_name}"
        else:
            self.registry_url = f"{registry}/{artifactory_repo}/{self.image_name}"
        
        # Calculate optimal number of concurrent builds based on available disk space
        self._calculate_optimal_concurrency()
        
        logger.info(f"Using image name: {self.image_name}")
        logger.info(f"Using tag prefix: {self.tag}")
        logger.info(f"Using registry: {self.registry}")
        logger.info(f"Using {self.build_threads} concurrent builds")
        logger.info(f"Using {self.push_threads} concurrent pushes")
        logger.info(f"Using {self.remove_threads} concurrent removals")
        logger.info(f"Insecure registry mode: {self.insecure}")
        if self.insecure:
            logger.info(f"Insecure registry port: {self.insecure_port or 80}")
        
        # Configure insecure registry if needed
        if self.insecure:
            configure_insecure_registry(self.registry, self.insecure_port)
        
        # Login to Docker registry
        self._docker_login()

    def _calculate_optimal_concurrency(self) -> None:
        """Calculate optimal number of concurrent builds based on available disk space."""
        try:
            # Get available disk space in GB
            stat = os.statvfs('.')
            available_gb = (stat.f_bavail * stat.f_frsize) / (1024 * 1024 * 1024)
            
            # Calculate space needed per build (image size + overhead)
            space_per_build_gb = (self.image_size_mb / 1024) * 1.5  # 50% overhead for build process
            
            # Calculate maximum concurrent builds based on available space
            max_builds = int(available_gb / space_per_build_gb)
            
            # Limit concurrent builds to the minimum of:
            # 1. Available space-based limit
            # 2. User-specified threads
            # 3. Number of CPU cores
            cpu_count = multiprocessing.cpu_count()
            self.build_threads = min(max_builds, self.build_threads, cpu_count)
            self.push_threads = min(self.push_threads, cpu_count)
            self.remove_threads = min(self.remove_threads, cpu_count)
            
            logger.info(f"Available disk space: {available_gb:.1f}GB")
            logger.info(f"Space needed per build: {space_per_build_gb:.1f}GB")
            logger.info(f"Optimal concurrent builds: {self.build_threads}")
            logger.info(f"Optimal concurrent pushes: {self.push_threads}")
            logger.info(f"Optimal concurrent removals: {self.remove_threads}")
            
        except Exception as e:
            logger.warning(f"Could not calculate optimal concurrency: {str(e)}")
            logger.warning("Using default thread counts")

    def _generate_random_name(self) -> str:
        """Generate a random but readable name using adjectives and nouns."""
        adjective = random.choice(self.ADJECTIVES)
        noun = random.choice(self.NOUNS)
        return f"{adjective}-{noun}"

    def _generate_random_tag(self) -> str:
        """Generate a random but readable tag."""
        return f"v{random.randint(1, 999)}.{random.randint(0, 9)}.{random.randint(0, 9)}"

    def _docker_login(self) -> None:
        """Login to Docker registry using provided credentials."""
        logger.info(f"Attempting to login to Docker registry: {self.registry}")
        try:
            # Format registry URL based on security mode and port
            registry_url = self.registry
            if self.insecure:
                port = self.insecure_port or 80
                registry_url = f"{registry_url}:{port}"  # Don't add http:// for login command
            
            # Use password-stdin for secure password handling
            login_cmd = ["docker", "login", registry_url, "-u", self.username, "--password-stdin"]
            process = subprocess.Popen(
                login_cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            stdout, stderr = process.communicate(input=self.password)
            
            if process.returncode != 0:
                raise subprocess.CalledProcessError(process.returncode, login_cmd, stdout, stderr)
            
            logger.info(f"Successfully logged in to {registry_url}")
        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to login to Docker registry: {e.stderr}")
            raise

    def build_images(self) -> List[str]:
        """Build all Docker images in parallel."""
        start_time = time.time()
        logger.info(f"Starting to build {self.image_count} images with {self.build_threads} threads")
        
        built_images = []
        with tqdm(total=self.image_count, desc="Building images", unit="image") as pbar:
            with ProcessPoolExecutor(max_workers=self.build_threads) as executor:
                futures = [
                    executor.submit(
                        build_docker_image,
                        i,
                        self.layer_size_mb,
                        self.layers,
                        self.registry_url,
                        self.tag,
                        self.image_count
                    ) for i in range(self.image_count)
                ]
                
                # Wait for all futures to complete and update progress
                for future in concurrent.futures.as_completed(futures):
                    try:
                        image_name = future.result()
                        built_images.append(image_name)
                        pbar.update(1)
                    except Exception as e:
                        logger.error(f"Error in image build: {str(e)}")
                        raise
        
        total_time = time.time() - start_time
        logger.info(f"Successfully completed all {self.image_count} image builds in {timedelta(seconds=int(total_time))}")
        logger.info(f"Average time per build: {timedelta(seconds=int(total_time/self.image_count))}")
        return built_images

    def push_images(self, image_names: List[str]) -> None:
        """Push all Docker images in parallel."""
        start_time = time.time()
        logger.info(f"Starting to push {len(image_names)} images with {self.push_threads} threads")
        
        with tqdm(total=len(image_names), desc="Pushing images", unit="image") as pbar:
            with ProcessPoolExecutor(max_workers=self.push_threads) as executor:
                futures = [
                    executor.submit(
                        push_docker_image,
                        image_name,
                        i,
                        len(image_names)
                    ) for i, image_name in enumerate(image_names)
                ]
                
                # Wait for all futures to complete and update progress
                for future in concurrent.futures.as_completed(futures):
                    try:
                        future.result()
                        pbar.update(1)
                    except Exception as e:
                        logger.error(f"Error in image push: {str(e)}")
                        raise
        
        total_time = time.time() - start_time
        self.total_push_time = total_time  # Store the total push time
        logger.info(f"Successfully completed all {len(image_names)} image pushes in {timedelta(seconds=int(total_time))}")
        logger.info(f"Average time per push: {timedelta(seconds=int(total_time/len(image_names)))}")

    def remove_local_images(self, image_names: List[str]) -> None:
        """Remove all Docker images from local storage in parallel."""
        start_time = time.time()
        logger.info(f"Starting to remove {len(image_names)} images with {self.remove_threads} threads")
        
        with tqdm(total=len(image_names), desc="Removing images", unit="image") as pbar:
            with ProcessPoolExecutor(max_workers=self.remove_threads) as executor:
                futures = [
                    executor.submit(
                        remove_docker_image,
                        image_name,
                        i,
                        len(image_names)
                    ) for i, image_name in enumerate(image_names)
                ]
                
                # Wait for all futures to complete and update progress
                for future in concurrent.futures.as_completed(futures):
                    try:
                        future.result()
                        pbar.update(1)
                    except Exception as e:
                        logger.error(f"Error in image removal: {str(e)}")
                        raise
        
        total_time = time.time() - start_time
        logger.info(f"Successfully completed all {len(image_names)} image removals in {timedelta(seconds=int(total_time))}")
        logger.info(f"Average time per removal: {timedelta(seconds=int(total_time/len(image_names)))}")

    def generate_images(self) -> None:
        """Generate and push all Docker images in parallel."""
        try:
            # Build all images first
            built_images = self.build_images()
            
            # Push all built images
            self.push_images(built_images)
            
            # Remove all images from local storage
            self.remove_local_images(built_images)
            
            logger.info("Successfully completed all image operations")
        except Exception as e:
            logger.error(f"Failed to complete image operations: {str(e)}")
            raise

def main():
    parser = argparse.ArgumentParser(description="Generate and push Docker images to Artifactory")
    
    # Required arguments
    parser.add_argument("--image-count", type=int, required=True,
                      help="Total number of images to create")
    parser.add_argument("--image-size-mb", type=int, required=True,
                      help="Size of each image in MB")
    parser.add_argument("--layers", type=int, required=True,
                      help="Number of layers per image")
    parser.add_argument("--threads", type=int, required=True,
                      help="Number of concurrent operations (default for all phases)")
    parser.add_argument("--registry", required=True,
                      help="Docker registry URL")
    parser.add_argument("--artifactory-repo", required=True,
                      help="Artifactory repository name")
    
    # Optional arguments
    parser.add_argument("--image-name",
                      help="Docker image name (if not provided, a random name will be generated)")
    parser.add_argument("--tag",
                      help="Base tag for images (if not provided, a random tag will be generated)")
    parser.add_argument("--username",
                      help="Docker registry username (if not provided, DOCKER_USERNAME environment variable will be used)")
    parser.add_argument("--password",
                      help="Docker registry password (if not provided, DOCKER_PASSWORD environment variable will be used)")
    parser.add_argument("--insecure", action="store_true",
                      help="Use insecure registry mode (skip TLS verification)")
    parser.add_argument("--insecure-port", type=int,
                      help="Port to use for insecure registry (defaults to 80 if not specified)")
    
    # Phase-specific thread counts
    parser.add_argument("--build-threads", type=int,
                      help="Number of concurrent builds (defaults to --threads)")
    parser.add_argument("--push-threads", type=int,
                      help="Number of concurrent pushes (defaults to --threads)")
    parser.add_argument("--remove-threads", type=int,
                      help="Number of concurrent removals (defaults to --threads)")
    
    # Phase control
    parser.add_argument("--build-only", action="store_true",
                      help="Only build images, don't push or remove")
    parser.add_argument("--push-only", action="store_true",
                      help="Only push images, don't build or remove")
    parser.add_argument("--remove-only", action="store_true",
                      help="Only remove images, don't build or push")

    args = parser.parse_args()

    # Create generator instance
    generator = DockerImageGenerator(
        image_count=args.image_count,
        image_size_mb=args.image_size_mb,
        layers=args.layers,
        threads=args.threads,
        registry=args.registry,
        artifactory_repo=args.artifactory_repo,
        image_name=args.image_name,
        tag=args.tag,
        username=args.username,
        password=args.password,
        insecure=args.insecure,
        insecure_port=args.insecure_port,
        build_threads=args.build_threads,
        push_threads=args.push_threads,
        remove_threads=args.remove_threads
    )

    try:
        if args.build_only:
            generator.build_images()
        elif args.push_only:
            # For push-only, we need to know the image names
            if not args.image_name or not args.tag:
                raise ValueError("--image-name and --tag are required for --push-only")
            image_names = [f"{generator.registry_url}:{generator.tag}_{i}" for i in range(args.image_count)]
            generator.push_images(image_names)
        elif args.remove_only:
            # For remove-only, we need to know the image names
            if not args.image_name or not args.tag:
                raise ValueError("--image-name and --tag are required for --remove-only")
            image_names = [f"{generator.registry_url}:{generator.tag}_{i}" for i in range(args.image_count)]
            generator.remove_local_images(image_names)
        else:
            generator.generate_images()
        logger.info("Successfully completed all requested operations")
    except Exception as e:
        logger.error(f"Failed to complete operations: {str(e)}")
        raise

if __name__ == "__main__":
    main() 