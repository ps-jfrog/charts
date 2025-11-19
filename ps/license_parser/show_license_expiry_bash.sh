#!/bin/bash
# Usage: ./show_license_expiry_bash.sh <path_to_license_file>
# Example: bash /Users/sureshv/mycode/github-sv/utils/license_parser/show_license_expiry_bash.sh /Users/sureshv/mycode/github.jfrog.info/jpd-manager/artifactory-license1.lic 

# Works on macOS and Linux, supports multiple base64-encoded license blobs
# Pure bash implementation (no Python)
set -euo pipefail

licfile="$1"

if [[ ! -f "$licfile" ]]; then
  echo "File not found: $licfile" >&2
  exit 1
fi

# Decode the first (outermost) base64 layer
# Use base64 -d to handle multi-block base64 files correctly
decoded_outer=$(base64 -d < "$licfile" 2>/dev/null)
if [[ $? -ne 0 ]]; then
  echo "Error: Failed to decode license file" >&2
  exit 1
fi

block_num=0

# Extract all license blocks - find lines starting with "license:"
# Use process substitution to avoid subshell issues
while IFS= read -r line; do
  if [[ "$line" =~ ^license:[[:space:]]*(.+)$ ]]; then
    license_base64="${BASH_REMATCH[1]}"
    
    # Remove any whitespace from the base64 string
    license_base64=$(echo "$license_base64" | tr -d '[:space:]')
    
    # Decode this license block
    decoded_license=$(echo "$license_base64" | base64 -d 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$decoded_license" ]]; then
      continue
    fi
    
    block_num=$((block_num + 1))
    echo ""
    echo "===== License Block $block_num ====="
    
    # Parse the decoded license to find products
    # Structure: products:\n  product_name:\n    product: base64_data
    # We need to match indented product sections (2 spaces) not the top-level "products:"
    current_product=""
    license_ids_list=""
    
    # Read line by line to track state
    while IFS= read -r lic_line || [[ -n "$lic_line" ]]; do
      # Check if this is an indented product section header (2 spaces, then name:)
      # Examples: "  artifactory:", "  xray:", "  distribution:"
      if [[ "$lic_line" =~ ^[[:space:]]{2}([a-zA-Z]+):[[:space:]]*$ ]]; then
        current_product="${BASH_REMATCH[1]}"
      # Check if this is the "product:" line with base64 data (4 spaces)
      elif [[ -n "$current_product" ]] && [[ "$lic_line" =~ ^[[:space:]]{4}product:[[:space:]]+(.+)$ ]]; then
        product_base64="${BASH_REMATCH[1]}"
        
        # Remove any whitespace from product base64
        product_base64=$(echo "$product_base64" | tr -d '[:space:]')
        
        # Decode the product's inner base64
        product_decoded=$(echo "$product_base64" | base64 -d 2>/dev/null)
        if [[ $? -eq 0 ]] && [[ -n "$product_decoded" ]]; then
          echo ""
          echo "${current_product}:"
          
          # Extract ID (GUID/UUID format)
          id=$(echo "$product_decoded" | grep -iE "^id:[[:space:]]*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})" | sed -E 's/^[Ii][Dd]:[[:space:]]*//' | head -1 | tr -d '\r\n')
          if [[ -n "$id" ]]; then
            echo "  ID: $id"
            # Store product:ID pairs in a simple string format
            if [[ -z "$license_ids_list" ]]; then
              license_ids_list="${current_product}:${id}"
            else
              license_ids_list="${license_ids_list}|${current_product}:${id}"
            fi
          fi
          
          # Extract type
          type=$(echo "$product_decoded" | grep -iE "^type:[[:space:]]*" | sed -E 's/^[Tt][Yy][Pp][Ee]:[[:space:]]*//' | head -1 | tr -d '\r\n')
          if [[ -n "$type" ]]; then
            echo "  Type: $type"
          fi
          
          # Extract owner
          owner=$(echo "$product_decoded" | grep -iE "^owner:[[:space:]]*" | sed -E 's/^[Oo][Ww][Nn][Ee][Rr]:[[:space:]]*//' | head -1 | tr -d '\r\n')
          if [[ -n "$owner" ]]; then
            echo "  Owner: $owner"
          fi
          
          # Extract expiry date
          expiry=$(echo "$product_decoded" | grep -iE "^expires:[[:space:]]*" | sed -E 's/^[Ee][Xx][Pp][Ii][Rr][Ee][Ss]:[[:space:]]*//' | head -1 | tr -d '\r\n')
          if [[ -n "$expiry" ]]; then
            echo "  Expires: $expiry"
          fi
          
          # Extract validFrom
          valid_from=$(echo "$product_decoded" | grep -iE "^validFrom:[[:space:]]*" | sed -E 's/^[Vv][Aa][Ll][Ii][Dd][Ff][Rr][Oo][Mm]:[[:space:]]*//' | head -1 | tr -d '\r\n')
          if [[ -n "$valid_from" ]]; then
            echo "  Valid From: $valid_from"
          fi
          
          # Extract trial status
          trial=$(echo "$product_decoded" | grep -iE "^trial:[[:space:]]*" | sed -E 's/^[Tt][Rr][Ii][Aa][Ll]:[[:space:]]*//' | head -1 | tr -d '\r\n')
          if [[ -n "$trial" ]]; then
            echo "  Trial: $trial"
          fi
          
          # Extract termedLicense (can be on its own line or in properties section)
          termed=$(echo "$product_decoded" | grep -iE "(^termedLicense:|termedLicense:[[:space:]]*)" | sed -E 's/.*[Tt][Ee][Rr][Mm][Ee][Dd][Ll][Ii][Cc][Ee][Nn][Ss][Ee]:[[:space:]]*//' | head -1 | tr -d '\r\n')
          if [[ -n "$termed" ]]; then
            echo "  Termed License: $termed"
          fi
        fi
        current_product=""
      fi
    done <<< "$decoded_license"
    
    # Display summary of unique identifiers for this license block
    if [[ -n "$license_ids_list" ]]; then
      echo ""
      echo "License Block $block_num Unique IDs:"
      # Split the list by | and display each product:ID pair
      IFS='|' read -ra ID_PAIRS <<< "$license_ids_list"
      for pair in "${ID_PAIRS[@]}"; do
        product_name="${pair%%:*}"
        product_id="${pair#*:}"
        echo "  $product_name: $product_id"
      done
    fi
  fi
done <<< "$decoded_outer"

if [[ $block_num -eq 0 ]]; then
  echo "No valid product sections found."
fi
