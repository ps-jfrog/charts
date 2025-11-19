#!/usr/bin/env python3
"""
Show license expiry details from Artifactory license files.

Usage: ./show_license_expiry.py <path_to_license_file>
Example: python3 /Users/sureshv/mycode/github-sv/utils/license_parser/show_license_expiry.py /Users/sureshv/mycode/github.jfrog.info/jpd-manager/artifactory-license1.lic 

Works on macOS and Linux, supports multiple base64-encoded license blobs.
"""

import base64
import re
import sys
import pathlib
import subprocess


def main():
    if len(sys.argv) != 2:
        print("Usage: {} <path_to_license_file>".format(sys.argv[0]), file=sys.stderr)
        sys.exit(1)
    
    licfile = sys.argv[1]
    path = pathlib.Path(licfile)
    
    if not path.exists():
        print(f"File not found: {licfile}", file=sys.stderr)
        sys.exit(1)
    
    # Decode the first (outermost) base64 layer using subprocess to match 'base64 -d' behavior
    # Python's base64.b64decode() stops at padding, but 'base64 -d' continues decoding
    # Using the system command ensures we get the same result as the user's working command
    try:
        result = subprocess.run(
            ['base64', '-d'],
            input=path.read_bytes(),
            capture_output=True,
            check=True
        )
        outer = result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Top-level base64 decode failed: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Top-level base64 decode failed: {e}", file=sys.stderr)
        sys.exit(1)
    
    # Find ALL base64 license payloads inside
    # Match from "license:" until newline before "signature:"
    # The base64 is on a single line, so we match until \n followed by signature:
    licenses = re.findall(rb'license:\s*([^\n]+)', outer)
    if not licenses:
        print("No license blocks found inside decoded data.", file=sys.stderr)
        sys.exit(1)
    
    block_num = 0
    for lic in licenses:
        try:
            # Remove whitespace/newlines from base64 string before decoding
            lic_clean = b''.join(lic.split())
            decoded_license = base64.b64decode(lic_clean)
        except Exception:
            continue
        
        # Each decoded license may contain multiple products
        # Find all product entries: match product name, then product: followed by base64
        product_blocks = re.findall(
            rb'([a-zA-Z]+):\s*\n\s*product:\s*([A-Za-z0-9+/=]+)',
            decoded_license,
        )
        
        if not product_blocks:
            # Try alternative pattern if first doesn't match
            product_blocks = re.findall(
                rb'^([a-zA-Z]+):.*?^    product:\s*([A-Za-z0-9+/=]+)',
                decoded_license,
                re.MULTILINE | re.DOTALL
            )
        
        if not product_blocks:
            continue
        
        block_num += 1
        print(f"\n===== License Block {block_num} =====")
        
        # Collect all product IDs from this license block
        license_ids = {}
        
        for product, blob in product_blocks:
            name = product.decode()
            # Clean up the blob - remove any trailing whitespace/newlines
            blob_clean = blob.strip()
            try:
                inner = base64.b64decode(blob_clean)
                inner_str = inner.decode('utf-8', errors='ignore')
                
                # Extract all useful fields
                fields = {}
                
                # Extract expiry date
                match = re.search(rb'expires:\s*([0-9TZ:-]+)', inner)
                if match:
                    fields['expires'] = match.group(1).decode()
                
                # Extract unique ID (GUID/UUID)
                id_match = re.search(rb'id:\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', inner, re.IGNORECASE)
                if id_match:
                    fields['id'] = id_match.group(1).decode()
                    license_ids[name] = fields['id']
                
                # Extract owner
                owner_match = re.search(rb'owner:\s*([^\n]+)', inner)
                if owner_match:
                    fields['owner'] = owner_match.group(1).decode().strip()
                
                # Extract license type
                type_match = re.search(rb'type:\s*([^\n]+)', inner)
                if type_match:
                    fields['type'] = type_match.group(1).decode().strip()
                
                # Extract trial status
                trial_match = re.search(rb'trial:\s*([^\n]+)', inner)
                if trial_match:
                    fields['trial'] = trial_match.group(1).decode().strip()
                
                # Extract validFrom date
                valid_from_match = re.search(rb'validFrom:\s*([0-9TZ.:-]+)', inner)
                if valid_from_match:
                    fields['validFrom'] = valid_from_match.group(1).decode()
                
                # Extract termedLicense status
                termed_match = re.search(rb'termedLicense:\s*([^\n]+)', inner)
                if termed_match:
                    fields['termedLicense'] = termed_match.group(1).decode().strip()
                
                # Display all extracted fields
                print(f"\n{name}:")
                if 'id' in fields:
                    print(f"  ID: {fields['id']}")
                if 'type' in fields:
                    print(f"  Type: {fields['type']}")
                if 'owner' in fields:
                    print(f"  Owner: {fields['owner']}")
                if 'expires' in fields:
                    print(f"  Expires: {fields['expires']}")
                if 'validFrom' in fields:
                    print(f"  Valid From: {fields['validFrom']}")
                if 'trial' in fields:
                    print(f"  Trial: {fields['trial']}")
                if 'termedLicense' in fields:
                    print(f"  Termed License: {fields['termedLicense']}")
                
            except Exception as e:
                print(f"{name}: Error parsing - {e}")
        
        # Display summary of unique identifiers for this license block
        if license_ids:
            print(f"\nLicense Block {block_num} Unique IDs:")
            for product_name, product_id in license_ids.items():
                print(f"  {product_name}: {product_id}")
    
    if block_num == 0:
        print("No valid product sections found.")


if __name__ == '__main__':
    main()

