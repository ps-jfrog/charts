# resource_sum.py

A Python utility for summarizing total CPU and memory resources from Kubernetes YAML resource files, with support for excluding specific components.

This tool is particularly useful for analyzing and summarizing sizing templates in the [JFrog Helm charts repository](https://github.com/jfrog/charts/tree/master/stable/), specifically for:
- `jfrog/artifactory` - Artifactory Helm chart sizing templates
- `jfrog/jfrog-platform` - JFrog Platform Helm chart sizing templates

## Features

- Aggregates CPU and memory requests and limits across all components in a YAML file
- **Shows per-pod resource values** - clearly indicates that all values are per pod
- Identifies components with `replicaCount > 1` in the YAML
- Supports excluding specific components (e.g., postgresql, nginx)
- Handles nested component keys (e.g., `postgresql.primary`)
- Converts Kubernetes resource units (Mi, Gi, millicores) to standardized values
- Supports reading from stdin or a file
- Outputs results in YAML format matching the original resource format

## Requirements

- Python 3
- PyYAML library

## Installation

```bash
pip install pyyaml
```

## Usage

### Basic Syntax

```bash
python k8s/scripts/resource_sum/resource_sum.py [OPTIONS]
```

### Options

- `-f, --file FILE`: Path to YAML file (default: read from stdin)
- `-e, --exclude COMPONENT [COMPONENT ...]`: List of components to exclude from the summary

## Example Usage

### 1️⃣ Artifactory YAML excluding postgresql and nginx:

```bash
python k8s/scripts/resource_sum/resource_sum.py -f k8s/scripts/resource_sum/artifactory-large.yaml \
     --exclude postgresql nginx
```

### 2️⃣ Artifactory YAML excluding only postgresql:

```bash
python k8s/scripts/resource_sum/resource_sum.py -f k8s/scripts/resource_sum/artifactory-large.yaml \
     --exclude postgresql
```

### 3️⃣ Xray YAML excluding postgresql:

```bash
python k8s/scripts/resource_sum/resource_sum.py -f k8s/scripts/resource_sum/xray-large.yaml \
     --exclude postgresql
```

### 4️⃣ Platform YAML with multiple exclusions:

```bash
python k8s/scripts/resource_sum/resource_sum.py -f k8s/scripts/resource_sum/platform-large.yaml \
     --exclude artifactory.postgresql artifactory.nginx distribution.postgresql
```

### 5️⃣ Platform YAML excluding artifactory components only:

```bash
python k8s/scripts/resource_sum/resource_sum.py -f k8s/scripts/resource_sum/platform-large.yaml \
     --exclude artifactory.postgresql artifactory.nginx
```

### 6️⃣ Platform YAML with nested exclusions:

```bash
python k8s/scripts/resource_sum/resource_sum.py -f k8s/scripts/resource_sum/platform-large.yaml \
     --exclude xray.rabbitmq xray.postgresql artifactory.postgresql artifactory.nginx
```

**Note:** These examples demonstrate:
- Per top-level component totals (artifactory, xray, distribution)
- Exclusions at any nesting level (e.g., `xray.rabbitmq`, `artifactory.postgresql`)
- Flat structure handling (artifactory-large.yaml, xray-large.yaml) where components are automatically grouped

## Example Output

### For single-component YAML (artifactory-large.yaml):

```yaml
summary:
  note: 'All resource values shown are PER POD. Multiply by your desired replica count to get total cluster resources. Note: Some components in the YAML have replicaCount > 1 (see components_with_replicaCount_gt_1).'
  total_requests_per_artifactory:
    cpu: '6.9'
    memory: 23.55Gi
  total_limits_per_artifactory:
    memory: 33.24Gi
components_with_replicaCount_gt_1:
  artifactory:
    replicaCount: 3
excluded_components:
  nginx:
    requests:
      cpu: '1'
      memory: 500Mi
    limits:
      memory: 1Gi
  postgresql.primary:
    requests:
      memory: 64Gi
      cpu: '16'
    limits:
      memory: 64Gi
```

### For multi-component YAML (platform-large.yaml):

```yaml
summary:
  note: 'All resource values shown are PER POD. Multiply by your desired replica count to get total cluster resources. Note: Some components in the YAML have replicaCount > 1 (see components_with_replicaCount_gt_1).'
total_requests_per_artifactory:
  cpu: '7.9'
  memory: 24.04Gi
total_limits_per_artifactory:
  memory: 34.24Gi
total_requests_per_distribution:
  cpu: '0.31'
  memory: 1.1Gi
total_limits_per_distribution:
  memory: 3.37Gi
total_requests_per_xray:
  cpu: '1.13'
  memory: 2.37Gi
total_limits_per_xray:
  memory: 59.24Gi
components_with_replicaCount_gt_1:
  artifactory.artifactory:
    replicaCount: 3
  artifactory.nginx:
    replicaCount: 2
  distribution:
    replicaCount: 2
  xray:
    replicaCount: 2
excluded_components:
  artifactory.postgresql.primary:
    requests:
      memory: 64Gi
      cpu: '16'
    limits:
      memory: 64Gi
  xray.postgresql.primary:
    requests:
      memory: 32Gi
      cpu: '16'
    limits:
      memory: 32Gi
  xray.rabbitmq:
    requests:
      cpu: 200m
      memory: 500Mi
    limits:
      memory: 4Gi
```

**Important Notes:**
- All resource values (`total_requests_per_<component>`, `total_limits_per_<component>`, and `excluded_components`) are **per pod**
- For multi-component YAMLs, totals are separated by top-level component (artifactory, xray, distribution)
- The `components_with_replicaCount_gt_1` section lists components that have `replicaCount > 1` in the YAML file
- To calculate total cluster resources, multiply the per-pod values by your desired replica count
- Exclusions can be specified at any nesting level (e.g., `xray.rabbitmq`, `artifactory.postgresql`)

## Resource Unit Conversion

The script automatically converts Kubernetes resource units:

- **Memory**: 
  - `Mi` → MiB (no conversion)
  - `Gi` → MiB (multiplied by 1024)
  
- **CPU**:
  - `m` (millicores) → cores (divided by 1000)
  - Numeric values → cores (no conversion)

## Use Case

This tool is designed to help analyze resource requirements from JFrog Helm chart sizing templates. When working with sizing templates from the [JFrog charts repository](https://github.com/jfrog/charts/tree/master/stable/), you can use this script to:

- Calculate per-pod resource requirements for sizing your Kubernetes nodes
- Exclude infrastructure components (like databases or reverse proxies) to focus on application resources
- Identify which components have multiple replicas configured in the YAML
- Plan node sizing by understanding per-pod resource needs and multiplying by your desired replica count

## Notes

- **All resource values are per pod** - multiply by your desired replica count to get total cluster resources
- For multi-component YAMLs (like platform-large.yaml), totals are separated by top-level component (e.g., `total_requests_per_artifactory`, `total_requests_per_xray`, `total_requests_per_distribution`)
- Components can be excluded by their base name (e.g., `postgresql`) or at any nesting level (e.g., `xray.rabbitmq`, `artifactory.postgresql`)
- The script handles missing resource fields gracefully (defaults to 0)
- Output values are formatted as strings with units (e.g., `'6.9'` for CPU, `'23.55Gi'` for memory) to match the original YAML format
- The script automatically identifies and reports components with `replicaCount > 1` from the YAML file (including excluded components)
- Memory values >= 1024 Mi are automatically converted to Gi for readability

