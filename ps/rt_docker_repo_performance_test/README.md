# Docker Repository Performance Test

This script implements the OpenStack performance test plan for Docker repositories. It tests the performance of an Artifactory Docker repository by pushing and pulling multiple Docker images with different concurrency levels.

## Features

- Tests repository performance with configurable concurrency levels
- Measures both push and pull performance
- Generates Docker images with configurable size and number of layers
- Measures throughput, push time, and total time for each concurrency level
- Validates results against configurable performance thresholds
- Automatic cleanup of test images (optional)
- Generates visual performance graphs
- Saves detailed test results in JSON format
- Generates HTML reports with embedded visualizations
- Supports credentials via environment variables or command line

## Prerequisites

- Python 3.6 or higher
- Docker installed and running
- Access to an Artifactory Docker repository
- Required Python packages (install using `pip install -r requirements.txt`):
  - matplotlib
  - numpy
  - tqdm
  - backoff
  - docker

## Installation

1. Clone the repository and navigate to the test directory:
```bash
cd rt_docker_repo_performance_test
```

2. Install the required Python packages:
```bash
pip install -r requirements.txt
```

3. Ensure the `publish_to_artifactory` module is in the correct location:
   - The module should be in the parent directory of `rt_docker_repo_performance_test`
   - Expected structure:
     ```
     utils/
     ├── publish_to_artifactory/
     │   └── docker_publish/
     │       └── docker_image_generator.py
     └── rt_docker_repo_performance_test/
         └── docker_repo_performance_test.py
     ```

4. Ensure Docker is running and you have access to your Artifactory repository.

## Usage

### Authentication Methods

You can provide Docker registry credentials in two ways:

1. Using Environment Variables:
```bash
export DOCKER_USERNAME="admin"
export DOCKER_PASSWORD="password123"
```

2. Using Command Line Arguments:
```bash
--username admin --password password123
```

### Basic Usage

The simplest way to run the test is with just the required parameters:

```bash
# Using environment variables for credentials
export DOCKER_USERNAME="admin"
export DOCKER_PASSWORD="password123"
python docker_repo_performance_test.py \
    --registry artifactory.example.com \
    --artifactory-repo docker-local
```

Or using command line arguments for credentials:

```bash
python docker_repo_performance_test.py \
    --registry artifactory.example.com \
    --artifactory-repo docker-local \
    --username admin \
    --password password123
```

This will run the test with default values:
- Image size: 100 MB
- Layers per image: 5
- Results directory: "results"
- Concurrency levels: [1, 10, 30, 50, 100]
- Cleanup: Enabled
- Performance thresholds:
  - Max push time: 60 seconds
  - Max pull time: 30 seconds
  - Min throughput: 0.1 images/second
  - Max 95th percentile latency: 45 seconds

### Advanced Usage

Here's an example with all available options:

```bash
# Using environment variables
export DOCKER_USERNAME="admin"
export DOCKER_PASSWORD="password123"
python docker_repo_performance_test.py \
    --registry artifactory.example.com \
    --artifactory-repo docker-local \
    --image-size 200 \
    --layers 10 \
    --results-dir custom_results \
    --concurrency 1,10,30,50,100 \
    --max-push-time 90 \
    --max-pull-time 45 \
    --min-throughput 0.2 \
    --max-push-time-p95 60
```

Or using command line arguments for all options:

```bash
python docker_repo_performance_test.py \
    --registry artifactory.example.com \
    --artifactory-repo docker-local \
    --username admin \
    --password password123 \
    --image-size 200 \
    --layers 10 \
    --results-dir custom_results \
    --concurrency 1,10,30,50,100 \
    --max-push-time 90 \
    --max-pull-time 45 \
    --min-throughput 0.2 \
    --max-push-time-p95 60
```

### Command Line Options

#### Required Arguments

- `--registry`: The URL of your Docker registry
  ```bash
  --registry artifactory.example.com
  ```

- `--artifactory-repo`: The name of your Artifactory repository
  ```bash
  --artifactory-repo docker-local
  ```

#### Optional Arguments

- `--username`: Your registry username (optional if DOCKER_USERNAME env var is set)
  ```bash
  --username admin
  ```

- `--password`: Your registry password (optional if DOCKER_PASSWORD env var is set)
  ```bash
  --password password123
  ```

- `--image-size`: Size of each Docker image in MB (default: 100)
  ```bash
  --image-size 200  # Creates 200MB images
  ```

- `--layers`: Number of layers per Docker image (default: 5)
  ```bash
  --layers 10  # Creates images with 10 layers
  ```

- `--results-dir`: Directory to store test results (default: "results")
  ```bash
  --results-dir custom_results  # Saves results in custom_results directory
  ```

- `--concurrency`: Comma-separated list of concurrency levels to test (default: "1,10,30,50,100")
  ```bash
  --concurrency 1,5,10,20  # Tests with 1, 5, 10, and 20 concurrent operations
  ```

- `--no-cleanup`: Disable automatic cleanup of test images
  ```bash
  --no-cleanup  # Keep test images after the test
  ```

- `--max-push-time`: Maximum allowed push time in seconds (default: 60.0)
  ```bash
  --max-push-time 90  # Allow up to 90 seconds for push operations
  ```

- `--max-pull-time`: Maximum allowed pull time in seconds (default: 30.0)
  ```bash
  --max-pull-time 45  # Allow up to 45 seconds for pull operations
  ```

- `--min-throughput`: Minimum required throughput in images/second (default: 0.1)
  ```bash
  --min-throughput 0.2  # Require at least 0.2 images/second throughput
  ```

- `--max-push-time-p95`: Maximum allowed 95th percentile push time in seconds (default: 45.0)
  ```bash
  --max-push-time-p95 60  # Allow up to 60 seconds for 95th percentile push time
  ```

## Understanding Performance Metrics

### Throughput
Throughput is a key performance metric that measures how many Docker images can be pushed to the repository per second. It is calculated as:
```
Throughput = Number of Images / Total Time (in seconds)
```

For example:
- If 10 images are pushed in 20 seconds, the throughput is 0.5 images/second
- If 100 images are pushed in 50 seconds, the throughput is 2 images/second

Higher throughput indicates better repository performance. The script measures throughput at different concurrency levels to help identify:
- The optimal concurrency level for your repository
- The maximum sustainable throughput
- Performance bottlenecks under load

### Push Time and Pull Time Metrics

The script measures two distinct timing metrics:

1. **Push Time (P95)**
   - This is a proxy metric calculated as 95% of the total push time
   - Formula: `push_time_p95 = total_time * 0.95`
   - Represents an approximation of the 95th percentile of the overall image push process duration
   - Note: This is not a true latency measurement, but rather an estimate based on push time
   - Used to validate against the `max_push_time_p95` threshold

2. **Pull Time Metrics**
   - **Average Pull Time**: Mean time taken to pull each image
   - **P95 Pull Time**: 95th percentile of individual image pull durations
   - Calculated from actual pull operations using `docker pull`
   - More accurate measure of repository read performance
   - Used to validate against the `max_pull_time` threshold

Example:
```
For a test with 10 images:
- Total push time: 20 seconds
- Push Time (P95): 19 seconds (20 * 0.95)
- Individual pull times: [2.1, 2.3, 2.0, 2.4, 2.2, 2.1, 2.3, 2.0, 2.2, 2.1]
- Average Pull Time: 2.17 seconds
- P95 Pull Time: 2.3 seconds
```

### Concurrency and Performance
The concurrency parameter determines how many Docker images are pushed and pulled simultaneously. The script:

1. Creates multiple Docker images in parallel
2. Pushes these images concurrently to the repository
3. Pulls the images back to measure read performance
4. Measures total time, throughput, and latency at each concurrency level

For example, with `--concurrency 1,10,30`:
- First test: Pushes and pulls 1 image (baseline performance)
- Second test: Pushes and pulls 10 images concurrently
- Third test: Pushes and pulls 30 images concurrently

This helps understand how the repository performs under different load conditions.

## Example Scenarios

### 1. Quick Test with Environment Variables
```bash
export DOCKER_USERNAME="admin"
export DOCKER_PASSWORD="password123"
python docker_repo_performance_test.py \
    --registry artifactory.example.com \
    --artifactory-repo docker-local
```

### 2. Large Image Test with Command Line Credentials
```bash
python docker_repo_performance_test.py \
    --registry artifactory.example.com \
    --artifactory-repo docker-local \
    --username admin \
    --password password123 \
    --image-size 500 \
    --layers 20
```

### 3. Custom Results Directory with Environment Variables
```bash
export DOCKER_USERNAME="admin"
export DOCKER_PASSWORD="password123"
python docker_repo_performance_test.py \
    --registry artifactory.example.com \
    --artifactory-repo docker-local \
    --results-dir /path/to/custom/results
```

### 4. Minimal Image Test
```bash
export DOCKER_USERNAME="admin"
export DOCKER_PASSWORD="password123"
python docker_repo_performance_test.py \
    --registry artifactory.example.com \
    --artifactory-repo docker-local \
    --image-size 50 \
    --layers 2
```

### 5. Custom Concurrency Levels
```bash
export DOCKER_USERNAME="admin"
export DOCKER_PASSWORD="password123"
python docker_repo_performance_test.py \
    --registry artifactory.example.com \
    --artifactory-repo docker-local \
    --concurrency 1,5,10,20,30
```

### 6. Strict Performance Requirements
```bash
export DOCKER_USERNAME="admin"
export DOCKER_PASSWORD="password123"
python docker_repo_performance_test.py \
    --registry artifactory.example.com \
    --artifactory-repo docker-local \
    --max-push-time 30 \
    --max-pull-time 15 \
    --min-throughput 0.5 \
    --max-push-time-p95 20
```

### 7. Keep Test Images
```bash
export DOCKER_USERNAME="admin"
export DOCKER_PASSWORD="password123"
python docker_repo_performance_test.py \
    --registry artifactory.example.com \
    --artifactory-repo docker-local \
    --no-cleanup
```

## Output

The script generates three types of output in the results directory:

1. JSON Results File (`performance_results_YYYYMMDD_HHMMSS.json`):
   - Contains detailed test results for each concurrency level
   - Includes timestamps, throughput, latency, and total time measurements
   - Example:
   ```json
   {
     "test_config": {
       "registry": "artifactory.example.com",
       "artifactory_repo": "docker-local",
       "image_size_mb": 200,
       "layers": 10,
       "concurrency_levels": [1, 10, 30, 50, 100],
       "username": "ad**in",
       "cleanup": true,
       "thresholds": {
         "max_pull_time": 30.0,
         "max_push_time": 60.0,
         "min_throughput": 0.1,
         "max_push_time_p95": 45.0
       }
     },
     "test_runs": [
       {
         "concurrency": 1,
         "total_time": 15.23,
         "throughput": 0.066,
         "push_time_p95": 14.47,
         "pull_metrics": {
           "avg_pull_time": 1.8,
           "pull_time_p95": 2.5,
           "pull_times": [1.7, 1.8, 1.9, 2.0, 2.5]
         },
         "status": "success"
       }
     ]
   }
   ```

2. Performance Visualizations:
   The script generates three graphs to visualize performance metrics:

   a. Throughput vs Concurrency:
   - X-axis: Number of concurrent operations (1, 10, 30, 50, 100)
   - Y-axis: Throughput in images per second
   - Blue line with circles: Successful test runs
   - Red line with X's: Failed test runs
   - Shows how the repository's throughput changes with increasing concurrency
   - Helps identify the optimal concurrency level for maximum throughput

   b. Push Time vs Concurrency:
   - X-axis: Number of concurrent operations
   - Y-axis: 95th percentile of push time (proxy metric)
   - Green line with circles: Successful test runs
   - Red line with X's: Failed test runs
   - Shows how push time increases with concurrency
   - Note: This is a proxy metric based on push time, not true latency

   c. Pull Time vs Concurrency:
   - X-axis: Number of concurrent operations
   - Y-axis: 95th percentile of actual pull times
   - Magenta line with circles: Successful test runs
   - Red line with X's: Failed test runs
   - Shows how pull performance degrades with concurrency
   - Based on actual pull operation measurements

3. HTML Report (`performance_report_YYYYMMDD_HHMMSS.html`):
   - Interactive web page with all test results
   - Embedded visualizations
   - Detailed test configuration including thresholds
   - Results table with the following columns:

   | Column | Description | Example | Notes |
   |--------|-------------|---------|-------|
   | Concurrency | Number of simultaneous operations | 10 | Number of images pushed/pulled at once |
   | Total Time (s) | Total time taken for all operations | 15.23 | Time to complete all operations |
   | Throughput (images/s) | Number of images processed per second | 0.66 | 10 images in 15.23 seconds |
   | P95 Push Time (s) | 95% of total push time | 14.47 | Proxy metric based on push time |
   | Avg Pull Time (s) | Average time to pull each image | 1.8 | Actual pull operation average |
   | P95 Pull Time (s) | 95th percentile of pull times | 2.5 | Actual pull operation P95 |
   | Status | Test result status | Success/Failed | Overall test outcome |
   | Details | Additional information or failure reason | "Push time 45.2s exceeds threshold 30s" | Failure explanation if any |

   The table helps you:
   - Track performance metrics at each concurrency level
   - Identify when and why tests fail
   - Compare performance across different concurrency levels
   - Validate results against performance thresholds

   Example row from the results table:
   ```
   Concurrency: 10
   Total Time: 15.23s
   Throughput: 0.66 images/s
   P95 Push Time: 14.47s (proxy metric)
   Avg Pull Time: 1.8s
   P95 Pull Time: 2.5s
   Status: Success
   Details: (empty for successful tests)
   ```

   Failed test example:
   ```
   Concurrency: 50
   Total Time: 45.2s
   Throughput: 1.11 images/s
   P95 Push Time: 42.94s (proxy metric)
   Avg Pull Time: 3.2s
   P95 Pull Time: 35.8s
   Status: Failed
   Details: "Push time 45.2s exceeds threshold 30s"
   ```

## Notes

- The script uses the Docker image generator from the `publish_to_artifactory` module
- Test results are saved after each concurrency level test
- Visualizations and HTML reports are updated after each test run
- The script handles errors gracefully and continues with remaining tests if one fails
- HTML reports are self-contained and can be shared or viewed offline
- Each test run generates timestamped files to prevent overwriting previous results
- Credentials are masked in logs and output files for security
- Failed test runs are clearly marked in the results
- Performance thresholds help identify when the repository is not meeting requirements
- Automatic cleanup helps manage storage usage (can be disabled with --no-cleanup)

## Troubleshooting

1. If you get authentication errors:
   - Verify your registry credentials (either in environment variables or command line)
   - Ensure your Artifactory repository is accessible
   - Check if your Docker daemon is running

2. If you get Docker-related errors:
   - Ensure Docker is running
   - Check if you have sufficient disk space
   - Verify your Docker daemon configuration

3. If the script fails to generate visualizations:
   - Ensure matplotlib is installed correctly
   - Check if you have write permissions in the results directory
   - Verify that at least one test run was successful

4. If you get credential-related errors:
   - Check if DOCKER_USERNAME and DOCKER_PASSWORD are set correctly
   - Verify that the credentials are valid for your registry
   - Try using command line arguments instead of environment variables

5. If you get module import errors:
   - Verify that the `publish_to_artifactory` module is in the correct location
   - Check that the directory structure matches the expected layout
   - Ensure you're running the script from the correct directory
   - Try running the script with the full path to ensure correct module resolution

6. If tests fail due to performance thresholds:
   - Review the performance metrics in the HTML report
   - Consider adjusting the thresholds if they're too strict
   - Check for network or system resource issues
   - Verify that the Artifactory server is not overloaded

7. If cleanup fails:
   - Check Docker daemon logs for errors
   - Verify that you have sufficient permissions
   - Try running with --no-cleanup to skip cleanup
   - Manually remove test images if needed 