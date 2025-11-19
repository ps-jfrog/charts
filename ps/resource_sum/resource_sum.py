#!/usr/bin/env python3
import argparse
import sys
import yaml
"""
resource_sum.py - Summarize total CPU and memory from a YAML resource file, with optional exclusions.

Usage:
  python resource_sum.py -f <yaml_file> -e <component1> <component2>...
  Example:
  python /Users/sureshv/mycode/github-sv/utils/k8s/scripts/resource_sum/resource_sum.py -f k8s/scripts/resource_sum/artifactory-large.yaml \
     --exclude postgresql nginx
  
Note: All resource values shown are PER POD. Multiply by your desired replica count to get total cluster resources.
"""

def parse_quantity(q):
    """Convert K8s-style CPU/memory strings to numeric values (Mi for memory, cores for CPU)."""
    if q is None:
        return 0.0
    q = str(q).strip().lower()
    try:
        if q.endswith("mi"):
            return float(q[:-2])
        elif q.endswith("gi"):
            return float(q[:-2]) * 1024
        elif q.endswith("m"):  # millicores
            return float(q[:-1]) / 1000
        else:
            return float(q)
    except ValueError:
        return 0.0

def format_cpu(cpu_cores):
    """Format CPU cores as a string (matching original format)."""
    if cpu_cores == 0:
        return None
    # Return as string, removing trailing zeros if it's a whole number
    if cpu_cores == int(cpu_cores):
        return str(int(cpu_cores))
    return str(round(cpu_cores, 2)).rstrip('0').rstrip('.')

def format_memory(memory_mi):
    """Format memory in Mi to appropriate unit (Gi or Mi) as string."""
    if memory_mi == 0:
        return None
    # Convert to Gi if >= 1024 Mi, otherwise keep as Mi
    if memory_mi >= 1024:
        memory_gi = memory_mi / 1024
        # Round to 2 decimal places, remove trailing zeros
        if memory_gi == int(memory_gi):
            return f"{int(memory_gi)}Gi"
        formatted = f"{round(memory_gi, 2)}"
        return f"{formatted.rstrip('0').rstrip('.')}Gi"
    else:
        if memory_mi == int(memory_mi):
            return f"{int(memory_mi)}Mi"
        formatted = f"{round(memory_mi, 2)}"
        return f"{formatted.rstrip('0').rstrip('.')}Mi"

def get_default_grouping_component(component_name, flat_structure_type='artifactory'):
    """Determine if a component should be grouped under a default top-level component.
    
    For flat YAML structures:
    - artifactory-large.yaml: group all except nginx, postgresql under 'artifactory'
    - xray-large.yaml: group all except postgresql under 'xray'
    """
    # Infrastructure components that should remain separate
    infrastructure_components = {'nginx', 'postgresql'}
    
    if component_name in infrastructure_components:
        return component_name
    # All other components in a flat structure belong to the platform type
    return flat_structure_type

def sum_resources(data, exclude, prefix="", top_level=None, is_flat_structure=False, flat_structure_type='artifactory'):
    """Aggregate CPU and memory across components, excluding specified ones.
    
    Recursively traverses nested dictionaries to handle structures like postgresql.primary.
    Tracks resources per top-level component (artifactory, xray, distribution).
    Returns totals per top-level component, excluded data, and replica count information.
    """
    # Initialize totals per top-level component
    totals_per_component = {}  # {top_level: {"requests": {...}, "limits": {...}}}
    excluded_data = {}
    replica_counts = {}  # Track components with replicaCount > 1

    for name, section in data.items():
        # Skip non-dict sections (e.g., boolean values like splitServicesToContainers: true)
        if not isinstance(section, dict):
            continue
        
        # Build full path (e.g., "postgresql.primary" or "xray.rabbitmq")
        full_path = f"{prefix}.{name}" if prefix else name
        
        # Determine top-level component (first part of path)
        # If prefix is empty, this is a top-level component
        if prefix == "":
            # For flat structures, group components under the platform type except infrastructure
            if is_flat_structure:
                current_top_level = get_default_grouping_component(name, flat_structure_type)
            else:
                current_top_level = name
        else:
            current_top_level = top_level
        
        # Initialize totals for this top-level component if not exists
        if current_top_level not in totals_per_component:
            totals_per_component[current_top_level] = {
                "requests": {"cpu": 0.0, "memory": 0.0},
                "limits": {"cpu": 0.0, "memory": 0.0}
            }
        
        # Check for replicaCount in this section (for both included and excluded components)
        replica_count = section.get("replicaCount")
        if replica_count and isinstance(replica_count, (int, float)) and replica_count > 1:
            replica_counts[full_path] = int(replica_count)
        
        # Check if this path should be excluded (supports any level like "xray.rabbitmq")
        # Check exact match or if any part of the path matches an exclusion
        is_excluded = False
        if full_path in exclude:
            is_excluded = True
        else:
            # Check if any segment of the path matches an exclusion
            path_parts = full_path.split('.')
            for part in path_parts:
                if part in exclude:
                    is_excluded = True
                    break
        
        if is_excluded:
            # Get resources from this section (may be nested)
            resources = section.get("resources", {})
            if resources:
                excluded_data[full_path] = resources
            # Also recursively check nested sections for resources
            for nested_name, nested_section in section.items():
                if isinstance(nested_section, dict) and "resources" in nested_section:
                    nested_path = f"{full_path}.{nested_name}"
                    if nested_path not in excluded_data:
                        excluded_data[nested_path] = nested_section.get("resources", {})
            continue

        # Check if this section has resources directly
        resources = section.get("resources", {})
        if resources:
            for res_type in ["requests", "limits"]:
                if res_type not in resources:
                    continue
                for field, val in resources[res_type].items():
                    value = parse_quantity(val)
                    totals_per_component[current_top_level][res_type][field] = \
                        totals_per_component[current_top_level][res_type].get(field, 0.0) + value
        
        # Recursively process nested dictionaries
        nested_totals, nested_excluded, nested_replicas = sum_resources(
            section, exclude, full_path, current_top_level, is_flat_structure, flat_structure_type
        )
        # Merge nested totals into current top-level component
        for nested_top_level, nested_total in nested_totals.items():
            if nested_top_level not in totals_per_component:
                totals_per_component[nested_top_level] = {
                    "requests": {"cpu": 0.0, "memory": 0.0},
                    "limits": {"cpu": 0.0, "memory": 0.0}
                }
            for res_type in ["requests", "limits"]:
                for field in ["cpu", "memory"]:
                    totals_per_component[nested_top_level][res_type][field] += \
                        nested_total[res_type][field]
        excluded_data.update(nested_excluded)
        replica_counts.update(nested_replicas)

    return totals_per_component, excluded_data, replica_counts

def main():
    parser = argparse.ArgumentParser(
        description="Summarize total CPU and memory from a YAML resource file, with optional exclusions."
    )
    parser.add_argument(
        "-f", "--file",
        type=argparse.FileType("r"),
        default=sys.stdin,
        help="Path to YAML file (default: read from stdin)."
    )
    parser.add_argument(
        "-e", "--exclude",
        nargs="*",
        default=[],
        help="List of components to exclude (e.g. --exclude postgresql nginx)."
    )
    args = parser.parse_args()

    data = yaml.safe_load(args.file)
    
    # Detect if this is a flat structure (like artifactory-large.yaml or xray-large.yaml)
    # A flat structure has components at the top level that should be grouped
    # vs. a grouped structure (like platform-large.yaml) where top-level keys are platform names
    is_flat_structure = False
    flat_structure_type = 'artifactory'  # Default to artifactory
    if data:
        top_level_keys = [k for k, v in data.items() if isinstance(v, dict)]
        # Known platform top-level keys that indicate a grouped structure
        platform_keys = {'artifactory', 'xray', 'distribution'}
        
        # Check if we have platform keys at top level
        has_platform_keys = any(k in platform_keys for k in top_level_keys)
        
        if has_platform_keys:
            # Check if it's truly grouped (platform key contains nested platform component)
            # vs. flat (platform key is itself a component with siblings)
            # In platform-large.yaml: artifactory.artifactory exists (nested)
            # In artifactory-large.yaml: artifactory exists but no nested artifactory.artifactory
            # In xray-large.yaml: xray exists but no nested xray.xray
            if 'artifactory' in top_level_keys:
                artifactory_section = data.get('artifactory', {})
                if isinstance(artifactory_section, dict) and 'artifactory' in artifactory_section:
                    # Has nested artifactory, so it's grouped - not flat
                    is_flat_structure = False
                else:
                    # No nested artifactory, check if there are other sibling components
                    other_components = [k for k in top_level_keys if k not in {'artifactory', 'nginx', 'postgresql'}]
                    if other_components:
                        is_flat_structure = True
                        flat_structure_type = 'artifactory'
            elif 'xray' in top_level_keys:
                xray_section = data.get('xray', {})
                if isinstance(xray_section, dict) and 'xray' in xray_section:
                    # Has nested xray, so it's grouped - not flat
                    is_flat_structure = False
                else:
                    # No nested xray, check if there are other sibling components
                    other_components = [k for k in top_level_keys if k not in {'xray', 'postgresql'}]
                    if other_components:
                        is_flat_structure = True
                        flat_structure_type = 'xray'
            elif 'distribution' in top_level_keys:
                distribution_section = data.get('distribution', {})
                if isinstance(distribution_section, dict) and 'distribution' in distribution_section:
                    # Has nested distribution, so it's grouped - not flat
                    is_flat_structure = False
                else:
                    # No nested distribution, check if there are other sibling components
                    other_components = [k for k in top_level_keys if k not in {'distribution', 'postgresql'}]
                    if other_components:
                        is_flat_structure = True
                        flat_structure_type = 'distribution'
        else:
            # No platform keys, check if this looks like a flat structure
            # Check for artifactory first
            if 'artifactory' in top_level_keys:
                other_components = [k for k in top_level_keys if k not in {'artifactory', 'nginx', 'postgresql'}]
                if other_components:
                    is_flat_structure = True
                    flat_structure_type = 'artifactory'
            # Check for xray
            elif 'xray' in top_level_keys:
                other_components = [k for k in top_level_keys if k not in {'xray', 'postgresql'}]
                if other_components:
                    is_flat_structure = True
                    flat_structure_type = 'xray'
            # Check for distribution
            elif 'distribution' in top_level_keys:
                other_components = [k for k in top_level_keys if k not in {'distribution', 'postgresql'}]
                if other_components:
                    is_flat_structure = True
                    flat_structure_type = 'distribution'
    
    totals_per_component, excluded, replica_counts = sum_resources(
        data, set(args.exclude), is_flat_structure=is_flat_structure, flat_structure_type=flat_structure_type
    )

    # Format the totals per top-level component
    summary = {
        "summary": {
            "note": "All resource values shown are PER POD. Multiply by your desired replica count to get total cluster resources."
        }
    }
    
    # Format totals for each top-level component
    for component_name, totals in sorted(totals_per_component.items()):
        total_requests = {}
        total_limits = {}
        
        cpu_req = format_cpu(totals["requests"]["cpu"])
        if cpu_req:
            total_requests["cpu"] = cpu_req
        
        memory_req = format_memory(totals["requests"]["memory"])
        if memory_req:
            total_requests["memory"] = memory_req
        
        cpu_lim = format_cpu(totals["limits"]["cpu"])
        if cpu_lim:
            total_limits["cpu"] = cpu_lim
        
        memory_lim = format_memory(totals["limits"]["memory"])
        if memory_lim:
            total_limits["memory"] = memory_lim
        
        # Only add if there are any resources
        if total_requests or total_limits:
            summary[f"total_requests_per_{component_name}"] = total_requests
            summary[f"total_limits_per_{component_name}"] = total_limits

    # Add replica count information if any components have replicaCount > 1
    if replica_counts:
        summary["components_with_replicaCount_gt_1"] = {
            component: {"replicaCount": count} 
            for component, count in sorted(replica_counts.items())
        }
        summary["summary"]["note"] += " Note: Some components in the YAML have replicaCount > 1 (see components_with_replicaCount_gt_1)."

    summary["excluded_components"] = excluded

    print(yaml.dump(summary, sort_keys=False))

if __name__ == "__main__":
    main()
