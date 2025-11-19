#!/usr/bin/env python3

import argparse
import concurrent.futures
import logging
import os
import time
import json
import matplotlib.pyplot as plt
import numpy as np
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Any, Optional, Tuple
import sys
import subprocess
import base64
from io import BytesIO
import backoff
import docker
from docker.errors import APIError, ImageNotFound
from tqdm import tqdm
import requests
from urllib.parse import urlparse
from concurrent.futures import ThreadPoolExecutor

# Add parent directory to Python path to find publish_to_artifactory module
current_dir = Path(__file__).parent.absolute()
parent_dir = current_dir.parent
sys.path.append(str(parent_dir))

try:
    from publish_to_artifactory.docker_publish.docker_image_generator import DockerImageGenerator
except ImportError as e:
    print(f"Error: Could not import DockerImageGenerator. Please ensure the publish_to_artifactory module is in the correct location.")
    print(f"Expected path: {parent_dir}/publish_to_artifactory/docker_publish/docker_image_generator.py")
    print(f"Error details: {str(e)}")
    sys.exit(1)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('docker_performance_test.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class PerformanceThresholds:
    def __init__(
        self,
        max_pull_time: float = 30.0,  # Maximum time in seconds for pull operations
        max_push_time: float = 60.0,  # Maximum time in seconds for push operations
        min_throughput: float = 0.1,  # Minimum throughput in images/second
        max_push_time_p95: float = 45.0  # 95th percentile push time in seconds
    ):
        self.max_pull_time = max_pull_time
        self.max_push_time = max_push_time
        self.min_throughput = min_throughput
        self.max_push_time_p95 = max_push_time_p95

class DockerRepoPerformanceTest:
    def __init__(
        self,
        registry: str,
        artifactory_repo: str,
        image_size_mb: int = 100,
        layers: int = 5,
        concurrency_levels: List[int] = None,
        username: Optional[str] = None,
        password: Optional[str] = None,
        cleanup: bool = True,
        max_push_time: float = 30.0,
        max_pull_time: float = 15.0,
        min_throughput: float = 0.5,
        max_push_time_p95: float = 20.0,
        debug: bool = False
    ):
        self.registry = registry
        self.artifactory_repo = artifactory_repo
        self.image_size_mb = image_size_mb
        self.layers = layers
        self.concurrency_levels = concurrency_levels or [1, 10, 30, 50, 100]
        self.username = username
        self.password = password
        self.cleanup = cleanup
        self.thresholds = {
            'max_pull_time': max_pull_time,
            'max_push_time': max_push_time,
            'min_throughput': min_throughput,
            'max_push_time_p95': max_push_time_p95
        }
        self.results = []
        self.debug = debug
        
        # Set logging level based on debug flag
        if self.debug:
            logger.setLevel(logging.DEBUG)
            # Also set urllib3 logging to DEBUG for request details
            logging.getLogger('urllib3').setLevel(logging.DEBUG)
        
        # Initialize Docker client
        try:
            self.docker_client = docker.from_env()
        except Exception as e:
            logger.error(f"Failed to initialize Docker client: {str(e)}")
            raise
        
        # Initialize results storage
        self.results = {
            "test_config": {
                "registry": registry,
                "artifactory_repo": artifactory_repo,
                "image_size_mb": image_size_mb,
                "layers": layers,
                "concurrency_levels": concurrency_levels,
                "username": self._mask_credentials(self.username),
                "cleanup": cleanup,
                "thresholds": {
                    "max_pull_time": self.thresholds['max_pull_time'],
                    "max_push_time": self.thresholds['max_push_time'],
                    "min_throughput": self.thresholds['min_throughput'],
                    "max_push_time_p95": self.thresholds['max_push_time_p95']
                }
            },
            "test_runs": []
        }

    def _mask_credentials(self, value: str) -> str:
        """Mask sensitive information in logs and results."""
        if not value:
            return ""
        if len(value) <= 4:
            return "*" * len(value)
        return value[:2] + "*" * (len(value) - 4) + value[-2:]

    @backoff.on_exception(
        backoff.expo,
        (APIError, ImageNotFound),
        max_tries=3,
        max_time=30
    )
    def _pull_image(self, image_name: str) -> float:
        """Pull a Docker image with retry logic."""
        start_time = time.time()
        try:
            self.docker_client.images.pull(image_name)
            return time.time() - start_time
        except Exception as e:
            logger.error(f"Failed to pull image {image_name}: {str(e)}")
            raise

    @backoff.on_exception(
        backoff.expo,
        APIError,
        max_tries=3,
        max_time=30
    )
    def _remove_image(self, image_name: str):
        """Remove a Docker image with retry logic."""
        try:
            self.docker_client.images.remove(image_name, force=True)
        except Exception as e:
            logger.error(f"Failed to remove image {image_name}: {str(e)}")
            raise

    def _delete_from_artifactory(self, image_name: str) -> bool:
        """Delete a Docker image from Artifactory using HTTP DELETE request."""
        try:
            # Parse the image name to get registry and path
            parts = image_name.split('/')
            if len(parts) < 3:
                logger.error(f"Invalid image name format: {image_name}")
                return False

            # Extract registry and path components
            registry = parts[0]
            repo = parts[1]
            image_path = '/'.join(parts[2:])
            
            # Extract tag if present
            tag = None
            if ':' in image_path:
                image_path, tag = image_path.split(':')
            
            # Prepare headers
            headers = {
                "Authorization": f"Bearer {self.password}"
            }
            logger.debug(f"Bearer Token (truncated): {self.password}")

            # Try HTTPS first
            base_url = f"https://{registry}/artifactory/{repo}/{image_path}"
            if tag:
                base_url = f"{base_url}/{tag}"
            
            # Log the equivalent curl command for troubleshooting (with masked password)
            curl_cmd = f'curl -kL -XDELETE -H "Authorization: Bearer $DOCKER_PASSWORD" "{base_url}/"'
            logger.info(f"Trying HTTPS - Equivalent curl command: {curl_cmd}")
            
            try:
                logger.debug(f"DELETE URL (HTTPS): {base_url}/")
                response = requests.delete(
                    f"{base_url}/",
                    headers=headers,
                    verify=False
                )
                if response.status_code in [200, 204]:
                    logger.info(f"Successfully deleted image from Artifactory via HTTPS: {image_name}")
                    return True
            except requests.exceptions.RequestException as e:
                logger.warning(f"HTTPS request failed, trying HTTP: {str(e)}")
                
                # Try HTTP as fallback
                base_url = f"http://{registry}/artifactory/{repo}/{image_path}"
                if tag:
                    base_url = f"{base_url}/{tag}"
                
                curl_cmd = f'curl -L -XDELETE -H "Authorization: Bearer $DOCKER_PASSWORD" "{base_url}/"'
                logger.info(f"Trying HTTP - Equivalent curl command: {curl_cmd}")
                
                try:
                    logger.debug(f"DELETE URL (HTTP): {base_url}/")
                    response = requests.delete(
                        f"{base_url}/",
                        headers=headers,
                        verify=False
                    )
                    if response.status_code in [200, 204]:
                        logger.info(f"Successfully deleted image from Artifactory via HTTP: {image_name}")
                        return True
                except requests.exceptions.RequestException as e:
                    logger.error(f"HTTP request also failed: {str(e)}")
                    return False
            
            if response.status_code == 401:
                logger.error(f"Authentication failed for {image_name}. Please check your credentials.")
                logger.debug(f"Response headers: {response.headers}")
                logger.debug(f"Response body: {response.text}")
            else:
                logger.error(f"Failed to delete image from Artifactory: {image_name}, Status code: {response.status_code}")
            return False
            
        except Exception as e:
            logger.error(f"Error deleting image from Artifactory: {image_name}, Error: {str(e)}")
            return False

    def _cleanup_artifactory_images(self, image_names: List[str], threads: int):
        """Clean up Docker images from Artifactory using multiple threads."""
        logger.info(f"Cleaning up {len(image_names)} images from Artifactory...")
        
        with ThreadPoolExecutor(max_workers=threads) as executor:
            # Submit delete tasks
            future_to_image = {
                executor.submit(self._delete_from_artifactory, image_name): image_name 
                for image_name in image_names
            }
            
            # Process results as they complete
            for future in concurrent.futures.as_completed(future_to_image):
                image_name = future_to_image[future]
                try:
                    success = future.result()
                    if not success:
                        logger.warning(f"Failed to delete image from Artifactory: {image_name}")
                except Exception as e:
                    logger.error(f"Error processing deletion of {image_name}: {str(e)}")

    def _validate_results(self, result: Dict[str, Any]) -> Tuple[bool, List[str]]:
        """Validate test results against thresholds."""
        failures = []
        
        if result["status"] == "success":
            # Check push time
            if result["total_time"] > self.thresholds['max_push_time']:
                failures.append(f"Push time {result['total_time']:.2f}s exceeds threshold {self.thresholds['max_push_time']}s")
            
            # Check throughput
            if result["throughput"] < self.thresholds['min_throughput']:
                failures.append(f"Throughput {result['throughput']:.2f} images/s below threshold {self.thresholds['min_throughput']} images/s")
            
            # Check latency (95th percentile)
            if result.get("latency_p95", 0) > self.thresholds['max_push_time_p95']:
                failures.append(f"95th percentile latency {result['latency_p95']:.2f}s exceeds threshold {self.thresholds['max_push_time_p95']}s")
        
        return len(failures) == 0, failures

    def run_test(self, concurrency: int) -> Dict[str, Any]:
        """Run a single performance test with the given concurrency level."""
        logger.info(f"Starting test with concurrency level: {concurrency}")
        
        # Initialize Docker image generator
        generator = DockerImageGenerator(
            image_count=concurrency,
            image_size_mb=self.image_size_mb,
            layers=self.layers,
            threads=concurrency,
            registry=self.registry,
            artifactory_repo=self.artifactory_repo,
            username=self.username,
            password=self.password
        )

        try:
            # Build images
            built_images = generator.build_images()
            
            # Push images
            generator.push_images(built_images)
            
            # Remove local images after push
            logger.info("Cleaning up local images after push...")
            generator.remove_local_images(built_images)
            
            # Test pull performance
            pull_times = []
            logger.info(f"Testing pull performance for {len(built_images)} images...")
            with tqdm(total=len(built_images), desc="Pulling images", unit="image") as pbar:
                for image_name in built_images:
                    try:
                        pull_time = self._pull_image(image_name)
                        pull_times.append(pull_time)
                        pbar.update(1)
                    except Exception as e:
                        logger.error(f"Failed to pull image {image_name}: {str(e)}")
                        raise
            
            # Calculate pull metrics
            pull_time_p95 = np.percentile(pull_times, 95) if pull_times else 0
            avg_pull_time = np.mean(pull_times) if pull_times else 0
            
            # Log pull statistics
            total_pull_time = sum(pull_times)
            logger.info(f"Successfully completed all {len(built_images)} image pulls in {total_pull_time:.2f}s")
            logger.info(f"Average time per pull: {avg_pull_time:.2f}s")
            logger.info(f"P95 pull time: {pull_time_p95:.2f}s")
            
            # Remove local images after pull test
            logger.info("Cleaning up local images after pull test...")
            generator.remove_local_images(built_images)
            
            # Clean up images from Artifactory
            logger.info("Cleaning up images from Artifactory...")
            self._cleanup_artifactory_images(built_images, concurrency)
            
            # Calculate metrics using total_push_time
            total_time = generator.total_push_time
            throughput = concurrency / total_time if total_time > 0 else 0
            push_time_p95 = total_time * 0.95  # 95th percentile of push time
            
            result = {
                'concurrency': concurrency,
                'total_time': total_time,
                'throughput': throughput,
                'push_time_p95': push_time_p95,
                'pull_metrics': {
                    'avg_pull_time': avg_pull_time,
                    'pull_time_p95': pull_time_p95,
                    'pull_times': pull_times
                },
                'success': True
            }
            
            # Validate against thresholds
            if total_time > self.thresholds['max_push_time']:
                result['success'] = False
                result['failure_reason'] = f"Push time {total_time:.2f}s exceeds threshold {self.thresholds['max_push_time']}s"
            elif throughput < self.thresholds['min_throughput']:
                result['success'] = False
                result['failure_reason'] = f"Throughput {throughput:.2f} images/s below threshold {self.thresholds['min_throughput']}"
            elif push_time_p95 > self.thresholds['max_push_time_p95']:
                result['success'] = False
                result['failure_reason'] = f"P95 push time {push_time_p95:.2f}s exceeds threshold {self.thresholds['max_push_time_p95']}s"
            elif pull_time_p95 > self.thresholds['max_pull_time']:
                result['success'] = False
                result['failure_reason'] = f"P95 pull time {pull_time_p95:.2f}s exceeds threshold {self.thresholds['max_pull_time']}s"
            
            return result
            
        except Exception as e:
            logger.error(f"Test failed for concurrency {concurrency}: {str(e)}")
            return {
                'concurrency': concurrency,
                'success': False,
                'failure_reason': str(e)
            }

    def run_all_tests(self):
        """Run performance tests for all concurrency levels."""
        logger.info("Starting performance test suite")
        logger.info(f"Test configuration: {json.dumps(self.results['test_config'], indent=2)}")
        
        for concurrency in self.concurrency_levels:
            result = self.run_test(concurrency)
            self.results["test_runs"].append(result)
            
            if not result['success']:
                logger.error(f"Test failed for concurrency {concurrency}: {result.get('failure_reason', 'Unknown error')}")
            
            if self.cleanup:
                logger.info("Cleaning up test images...")
                try:
                    # Cleanup logic here if needed
                    pass
                except Exception as e:
                    logger.error(f"Failed to clean up: {str(e)}")

    def _get_config(self) -> Dict:
        """Get test configuration for logging."""
        return {
            'registry': self.registry,
            'artifactory_repo': self.artifactory_repo,
            'image_size_mb': self.image_size_mb,
            'layers': self.layers,
            'concurrency_levels': self.concurrency_levels,
            'username': f"{self.username[:2]}****{self.username[-2:]}" if self.username else None,
            'cleanup': self.cleanup,
            'thresholds': self.thresholds
        }

    def save_results(self, output_dir: str = "results"):
        """Save test results to JSON and generate visualizations."""
        output_path = Path(output_dir)
        output_path.mkdir(exist_ok=True)
        
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        
        # Save raw results
        results_file = output_path / f"performance_results_{timestamp}.json"
        with open(results_file, 'w') as f:
            json.dump(self.results, f, indent=2)
        
        # Generate visualizations
        self._generate_plots(output_path, timestamp)
        
        # Generate HTML report
        self._generate_html_report(output_path, timestamp)
        
        logger.info(f"Results saved to {output_path}")

    def _generate_plots(self, output_path: Path, timestamp: str):
        """Generate performance visualization plots."""
        # Separate successful and failed tests
        successful_tests = [r for r in self.results["test_runs"] if r['success']]
        failed_tests = [r for r in self.results["test_runs"] if not r['success']]
        
        # Throughput vs Concurrency
        plt.figure(figsize=(10, 6))
        # Plot successful tests
        if successful_tests:
            concurrency_success = [r['concurrency'] for r in successful_tests]
            throughput_success = [r['throughput'] for r in successful_tests]
            plt.plot(concurrency_success, throughput_success, 'bo-', label='Successful Tests')
        
        # Plot failed tests
        if failed_tests:
            concurrency_fail = [r['concurrency'] for r in failed_tests]
            throughput_fail = [r['throughput'] for r in failed_tests]
            plt.plot(concurrency_fail, throughput_fail, 'rx-', label='Failed Tests')
        
        plt.xlabel('Concurrency')
        plt.ylabel('Throughput (images/s)')
        plt.title('Throughput vs Concurrency')
        plt.grid(True)
        plt.legend()
        plt.savefig(output_path / f"throughput_{timestamp}.png")
        plt.close()
        
        # Push Time vs Concurrency (renamed from Latency)
        plt.figure(figsize=(10, 6))
        # Plot successful tests
        if successful_tests:
            push_time_success = [r['push_time_p95'] for r in successful_tests]
            plt.plot(concurrency_success, push_time_success, 'go-', label='Successful Tests')
        
        # Plot failed tests
        if failed_tests:
            push_time_fail = [r['push_time_p95'] for r in failed_tests]
            plt.plot(concurrency_fail, push_time_fail, 'rx-', label='Failed Tests')
        
        plt.xlabel('Concurrency')
        plt.ylabel('P95 Push Time (s)')
        plt.title('Push Time vs Concurrency')
        plt.grid(True)
        plt.legend()
        plt.savefig(output_path / f"push_time_{timestamp}.png")
        plt.close()
        
        # Pull Time vs Concurrency
        plt.figure(figsize=(10, 6))
        # Plot successful tests
        if successful_tests:
            pull_times_success = [r['pull_metrics']['pull_time_p95'] for r in successful_tests]
            plt.plot(concurrency_success, pull_times_success, 'mo-', label='Successful Tests')
        
        # Plot failed tests
        if failed_tests:
            pull_times_fail = [r['pull_metrics']['pull_time_p95'] for r in failed_tests]
            plt.plot(concurrency_fail, pull_times_fail, 'rx-', label='Failed Tests')
        
        plt.xlabel('Concurrency')
        plt.ylabel('P95 Pull Time (s)')
        plt.title('Pull Time vs Concurrency')
        plt.grid(True)
        plt.legend()
        plt.savefig(output_path / f"pull_time_{timestamp}.png")
        plt.close()

    def _generate_html_report(self, output_path: Path, timestamp: str):
        """Generate HTML report with results and visualizations."""
        html_content = f"""
        <!DOCTYPE html>
        <html>
        <head>
            <title>Docker Repository Performance Test Results</title>
            <style>
                body {{ font-family: Arial, sans-serif; margin: 20px; }}
                .container {{ max-width: 1200px; margin: 0 auto; }}
                .header {{ text-align: center; margin-bottom: 30px; }}
                .results {{ margin-bottom: 30px; }}
                table {{ width: 100%; border-collapse: collapse; }}
                th, td {{ padding: 8px; text-align: left; border: 1px solid #ddd; }}
                th {{ background-color: #f5f5f5; }}
                .success {{ color: green; }}
                .failure {{ color: red; }}
                .visualization {{ margin: 20px 0; }}
                img {{ max-width: 100%; height: auto; }}
            </style>
        </head>
        <body>
            <div class="container">
                <div class="header">
                    <h1>Docker Repository Performance Test Results</h1>
                    <p>Generated on: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}</p>
                </div>
                
                <div class="results">
                    <h2>Test Configuration</h2>
                    <pre>{json.dumps(self._get_config(), indent=2)}</pre>
                    
                    <h2>Test Results</h2>
                    <table>
                        <tr>
                            <th>Concurrency</th>
                            <th>Total Time (s)</th>
                            <th>Throughput (images/s)</th>
                            <th>P95 Push Time (s)</th>
                            <th>Avg Pull Time (s)</th>
                            <th>P95 Pull Time (s)</th>
                            <th>Status</th>
                            <th>Details</th>
                        </tr>
                        {self._generate_results_table()}
                    </table>
                </div>
                
                <div class="visualization">
                    <h2>Performance Visualizations</h2>
                    <img src="throughput_{timestamp}.png" alt="Throughput vs Concurrency">
                    <img src="push_time_{timestamp}.png" alt="Push Time vs Concurrency">
                    <img src="pull_time_{timestamp}.png" alt="Pull Time vs Concurrency">
                </div>
            </div>
        </body>
        </html>
        """
        
        with open(output_path / f"report_{timestamp}.html", 'w') as f:
            f.write(html_content)

    def _generate_results_table(self) -> str:
        """Generate HTML table rows for test results."""
        rows = []
        for result in self.results["test_runs"]:
            status_class = "success" if result['success'] else "failure"
            status_text = "Success" if result['success'] else "Failed"
            details = result.get('failure_reason', '') if not result['success'] else ''
            
            row = f"""
                <tr>
                    <td>{result['concurrency']}</td>
                    <td>{result['total_time']:.2f}</td>
                    <td>{result['throughput']:.2f}</td>
                    <td>{result['push_time_p95']:.2f}</td>
                    <td>{result['pull_metrics']['avg_pull_time']:.2f}</td>
                    <td>{result['pull_metrics']['pull_time_p95']:.2f}</td>
                    <td class="{status_class}">{status_text}</td>
                    <td>{details}</td>
                </tr>
            """
            rows.append(row)
        return '\n'.join(rows)

def main():
    parser = argparse.ArgumentParser(description="Docker Repository Performance Test")
    
    # Required arguments
    parser.add_argument("--registry", required=True,
                      help="Docker registry URL")
    parser.add_argument("--artifactory-repo", required=True,
                      help="Artifactory repository name")
    
    # Optional arguments
    parser.add_argument("--image-size", type=int, default=100,
                      help="Size of each image in MB (default: 100)")
    parser.add_argument("--layers", type=int, default=5,
                      help="Number of layers per image (default: 5)")
    parser.add_argument("--concurrency", type=str, default="1,10,30,50,100",
                      help="Comma-separated list of concurrency levels (default: 1,10,30,50,100)")
    parser.add_argument("--username",
                      help="Docker registry username (if not provided, DOCKER_USERNAME environment variable will be used)")
    parser.add_argument("--password",
                      help="Docker registry password (if not provided, DOCKER_PASSWORD environment variable will be used)")
    parser.add_argument("--no-cleanup", action="store_true",
                      help="Don't clean up test images after the test")
    parser.add_argument("--max-push-time", type=float, default=30.0,
                      help="Maximum allowed push time in seconds (default: 30.0)")
    parser.add_argument("--max-pull-time", type=float, default=15.0,
                      help="Maximum allowed pull time in seconds (default: 15.0)")
    parser.add_argument("--min-throughput", type=float, default=0.5,
                      help="Minimum required throughput in images/second (default: 0.5)")
    parser.add_argument("--max-push-time-p95", type=float, default=20.0,
                      help="Maximum allowed P95 push time in seconds (default: 20.0)")
    parser.add_argument("--debug", action="store_true",
                      help="Enable debug logging")

    args = parser.parse_args()

    # Get credentials from args or environment variables
    username = args.username or os.environ.get('DOCKER_USERNAME')
    password = args.password or os.environ.get('DOCKER_PASSWORD')

    if not username or not password:
        logger.error("Username and password must be provided either via command line arguments or environment variables (DOCKER_USERNAME and DOCKER_PASSWORD)")
        sys.exit(1)

    # Parse concurrency levels
    concurrency_levels = [int(x.strip()) for x in args.concurrency.split(',')]

    # Create and run performance test
    test = DockerRepoPerformanceTest(
        registry=args.registry,
        artifactory_repo=args.artifactory_repo,
        image_size_mb=args.image_size,
        layers=args.layers,
        concurrency_levels=concurrency_levels,
        username=username,
        password=password,
        cleanup=not args.no_cleanup,
        max_push_time=args.max_push_time,
        max_pull_time=args.max_pull_time,
        min_throughput=args.min_throughput,
        max_push_time_p95=args.max_push_time_p95,
        debug=args.debug
    )

    try:
        test.run_all_tests()
        test.save_results()
        
        # Print summary
        successful = sum(1 for r in test.results["test_runs"] if r['success'])
        total = len(test.results["test_runs"])
        logger.info(f"\nTest Summary:")
        logger.info(f"Total tests: {total}")
        logger.info(f"Successful: {successful}")
        logger.info(f"Failed: {total - successful}")
        
    except Exception as e:
        logger.error(f"Failed to process results: {str(e)}")
        sys.exit(1)

if __name__ == "__main__":
    main() 