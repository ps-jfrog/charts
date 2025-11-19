#!/usr/bin/env python3
"""
Extract all details from Artifactory license file and write to output.txt

Usage: ./extract_all_details.py <path_to_license_file>
"""

import base64
import re
import sys
import pathlib
import subprocess
import json

def extract_jwt_payload(token):
    """Extract and decode JWT payload."""
    try:
        parts = token.split('.')
        if len(parts) >= 2:
            payload_b64 = parts[1]
            padding = 4 - (len(payload_b64) % 4)
            if padding != 4:
                payload_b64 += '=' * padding
            payload_json = base64.urlsafe_b64decode(payload_b64)
            return json.loads(payload_json)
    except Exception:
        pass
    return None

def main():
    if len(sys.argv) != 2:
        print("Usage: {} <path_to_license_file>".format(sys.argv[0]), file=sys.stderr)
        sys.exit(1)
    
    licfile = sys.argv[1]
    path = pathlib.Path(licfile)
    
    if not path.exists():
        print(f"File not found: {licfile}", file=sys.stderr)
        sys.exit(1)
    
    output_lines = []
    output_lines.append("=" * 80)
    output_lines.append(f"COMPLETE LICENSE FILE ANALYSIS")
    output_lines.append(f"File: {licfile}")
    output_lines.append("=" * 80)
    output_lines.append("")
    
    # Decode the first (outermost) base64 layer
    try:
        result = subprocess.run(
            ['base64', '-d'],
            input=path.read_bytes(),
            capture_output=True,
            check=True
        )
        outer = result.stdout
        outer_str = outer.decode('utf-8', errors='ignore')
    except subprocess.CalledProcessError as e:
        output_lines.append(f"ERROR: Top-level base64 decode failed: {e}")
        with open('output.txt', 'w') as f:
            f.write('\n'.join(output_lines))
        return
    except Exception as e:
        output_lines.append(f"ERROR: Top-level base64 decode failed: {e}")
        with open('output.txt', 'w') as f:
            f.write('\n'.join(output_lines))
        return
    
    # Show outer structure
    output_lines.append("OUTER LICENSE STRUCTURE:")
    output_lines.append("-" * 80)
    output_lines.append(outer_str[:2000])
    if len(outer_str) > 2000:
        output_lines.append(f"\n... (truncated, total length: {len(outer_str)} chars)")
    output_lines.append("")
    
    # Search for signature in outer structure
    output_lines.append("SIGNATURE SEARCH IN OUTER STRUCTURE:")
    output_lines.append("-" * 80)
    
    # Look for signature field in outer structure
    sig_match_outer = re.search(rb'signature:\s*([^\n]+)', outer)
    if sig_match_outer:
        sig_val = sig_match_outer.group(1).decode('utf-8', errors='ignore').strip()
        output_lines.append(f"  signature field: {sig_val}")
        if sig_val.lower() == '6728c04fbb0343e54c28de40ab5de2ad33ad3f0b':
            output_lines.append(f"  *** MATCH FOUND: {sig_val} ***")
    
    # Search for hex signature patterns in outer structure
    hex_patterns = [
        rb'\b([0-9a-f]{32})\b',      # 32 hex chars
        rb'\b([0-9a-f]{40})\b',      # 40 hex chars (SHA-1) - matches the example
        rb'\b([0-9a-f]{64})\b',      # 64 hex chars
    ]
    
    found_outer_sigs = []
    for pattern in hex_patterns:
        matches = re.findall(pattern, outer, re.IGNORECASE)
        for match in matches:
            sig_hex = match.decode() if isinstance(match, bytes) else match
            if sig_hex.lower() == '6728c04fbb0343e54c28de40ab5de2ad33ad3f0b':
                output_lines.append(f"  *** MATCH FOUND: {sig_hex} (hex signature pattern) ***")
            found_outer_sigs.append(sig_hex)
    
    if found_outer_sigs:
        output_lines.append(f"  Found {len(found_outer_sigs)} hex signature pattern(s) in outer structure:")
        for sig in set(found_outer_sigs):  # Remove duplicates
            output_lines.append(f"    {sig}")
    else:
        output_lines.append("  No hex signature patterns found in outer structure")
    output_lines.append("")
    
    # Find all license blocks
    licenses = re.findall(rb'license:\s*([^\n]+)', outer)
    if not licenses:
        output_lines.append("No license blocks found inside decoded data.")
        with open('output.txt', 'w') as f:
            f.write('\n'.join(output_lines))
        return
    
    output_lines.append(f"Found {len(licenses)} license block(s)")
    output_lines.append("")
    
    block_num = 0
    for lic in licenses:
        try:
            lic_clean = b''.join(lic.split())
            decoded_license = base64.b64decode(lic_clean)
            decoded_str = decoded_license.decode('utf-8', errors='ignore')
        except Exception as e:
            output_lines.append(f"ERROR decoding license block: {e}")
            continue
        
        block_num += 1
        output_lines.append("")
        output_lines.append("=" * 80)
        output_lines.append(f"LICENSE BLOCK {block_num}")
        output_lines.append("=" * 80)
        output_lines.append("")
        
        # Show decoded license structure
        output_lines.append("DECODED LICENSE STRUCTURE:")
        output_lines.append("-" * 80)
        output_lines.append(decoded_str)
        output_lines.append("")
        
        # Extract all key-value pairs from outer license block
        output_lines.append("OUTER LICENSE BLOCK FIELDS:")
        output_lines.append("-" * 80)
        outer_fields = re.findall(rb'^([a-zA-Z_][a-zA-Z0-9_]*):\s*(.+?)(?=\n[a-zA-Z_]|\n\n|$)', decoded_license, re.MULTILINE | re.DOTALL)
        for key, value in outer_fields:
            key_str = key.decode('utf-8', errors='ignore')
            val_str = value.decode('utf-8', errors='ignore').strip()
            if len(val_str) > 500:
                val_str = val_str[:500] + "... (truncated)"
            output_lines.append(f"  {key_str}: {val_str}")
        output_lines.append("")
        
        # Search for hex signatures in outer license block
        output_lines.append("SIGNATURE SEARCH IN OUTER LICENSE BLOCK:")
        output_lines.append("-" * 80)
        
        # Look for signature field
        sig_match = re.search(rb'signature:\s*([^\n]+)', decoded_license)
        if sig_match:
            sig_val = sig_match.group(1).decode('utf-8', errors='ignore').strip()
            output_lines.append(f"  signature field: {sig_val}")
            if sig_val.lower() == '6728c04fbb0343e54c28de40ab5de2ad33ad3f0b':
                output_lines.append(f"  *** MATCH FOUND: {sig_val} ***")
        
        # Search for hex signature patterns (32, 40, 64 hex chars - common hash lengths)
        hex_patterns = [
            rb'\b([0-9a-f]{32})\b',      # 32 hex chars (MD5, SHA-256 truncated)
            rb'\b([0-9a-f]{40})\b',      # 40 hex chars (SHA-1)
            rb'\b([0-9a-f]{64})\b',      # 64 hex chars (SHA-256)
        ]
        
        found_sigs = []
        for pattern in hex_patterns:
            matches = re.findall(pattern, decoded_license, re.IGNORECASE)
            for match in matches:
                sig_hex = match.decode() if isinstance(match, bytes) else match
                if sig_hex.lower() == '6728c04fbb0343e54c28de40ab5de2ad33ad3f0b':
                    output_lines.append(f"  *** MATCH FOUND: {sig_hex} (hex signature pattern) ***")
                found_sigs.append(sig_hex)
        
        if found_sigs:
            output_lines.append(f"  Found {len(found_sigs)} hex signature pattern(s):")
            for sig in set(found_sigs):  # Remove duplicates
                output_lines.append(f"    {sig}")
        else:
            output_lines.append("  No hex signature patterns found")
        output_lines.append("")
        
        # Find product blocks
        product_blocks = re.findall(
            rb'([a-zA-Z]+):\s*\n\s*product:\s*([A-Za-z0-9+/=]+)',
            decoded_license,
        )
        
        if not product_blocks:
            product_blocks = re.findall(
                rb'^([a-zA-Z]+):.*?^    product:\s*([A-Za-z0-9+/=]+)',
                decoded_license,
                re.MULTILINE | re.DOTALL
            )
        
        output_lines.append(f"PRODUCTS FOUND: {len(product_blocks)}")
        output_lines.append("")
        
        for product, blob in product_blocks:
            name = product.decode()
            blob_clean = blob.strip()
            
            output_lines.append("")
            output_lines.append("-" * 80)
            output_lines.append(f"PRODUCT: {name.upper()}")
            output_lines.append("-" * 80)
            output_lines.append("")
            
            try:
                inner = base64.b64decode(blob_clean)
                inner_str = inner.decode('utf-8', errors='ignore')
                
                # Show complete decoded product data
                output_lines.append("COMPLETE DECODED PRODUCT DATA:")
                output_lines.append("-" * 80)
                output_lines.append(inner_str)
                output_lines.append("")
                
                # Extract all fields line by line
                output_lines.append("ALL FIELDS EXTRACTED:")
                output_lines.append("-" * 80)
                lines = inner_str.split('\n')
                current_key = None
                current_value = []
                fields = {}
                
                for line in lines:
                    if ':' in line and not line.strip().startswith(' '):
                        if current_key:
                            fields[current_key] = '\n'.join(current_value).strip()
                        parts = line.split(':', 1)
                        if len(parts) == 2:
                            current_key = parts[0].strip()
                            current_value = [parts[1].strip()] if parts[1].strip() else []
                        else:
                            current_key = None
                            current_value = []
                    elif current_key and (line.startswith(' ') or line.startswith('\t')):
                        current_value.append(line.strip())
                    else:
                        if current_key:
                            fields[current_key] = '\n'.join(current_value).strip()
                            current_key = None
                            current_value = []
                
                if current_key:
                    fields[current_key] = '\n'.join(current_value).strip()
                
                # Display all fields
                for key, value in sorted(fields.items()):
                    output_lines.append(f"  {key}:")
                    if value:
                        # Show full value, but wrap long values
                        if len(value) > 500:
                            output_lines.append(f"    {value[:500]}... (truncated, full length: {len(value)})")
                        else:
                            output_lines.append(f"    {value}")
                    else:
                        output_lines.append(f"    (empty)")
                    output_lines.append("")
                
                # Extract specific important fields
                output_lines.append("IMPORTANT FIELDS:")
                output_lines.append("-" * 80)
                
                # Expiry
                match = re.search(rb'expires:\s*([0-9TZ:-]+)', inner)
                if match:
                    output_lines.append(f"  expires: {match.group(1).decode()}")
                
                # ID
                id_match = re.search(rb'id:\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', inner, re.IGNORECASE)
                if id_match:
                    output_lines.append(f"  id: {id_match.group(1).decode()}")
                
                # Owner
                owner_match = re.search(rb'owner:\s*([^\n]+)', inner)
                if owner_match:
                    output_lines.append(f"  owner: {owner_match.group(1).decode().strip()}")
                
                # Type
                type_match = re.search(rb'type:\s*([^\n]+)', inner)
                if type_match:
                    output_lines.append(f"  type: {type_match.group(1).decode().strip()}")
                
                # Trial
                trial_match = re.search(rb'trial:\s*([^\n]+)', inner)
                if trial_match:
                    output_lines.append(f"  trial: {trial_match.group(1).decode().strip()}")
                
                # ValidFrom
                valid_from_match = re.search(rb'validFrom:\s*([0-9TZ.:-]+)', inner)
                if valid_from_match:
                    output_lines.append(f"  validFrom: {valid_from_match.group(1).decode()}")
                
                # TermedLicense
                termed_match = re.search(rb'termedLicense:\s*([^\n]+)', inner)
                if termed_match:
                    output_lines.append(f"  termedLicense: {termed_match.group(1).decode().strip()}")
                
                # Signature - detailed search
                output_lines.append("SIGNATURE ANALYSIS:")
                output_lines.append("-" * 80)
                
                sig_match = re.search(rb'signature:\s*([^\n]+)', inner)
                if sig_match:
                    sig_val = sig_match.group(1).decode().strip()
                    output_lines.append(f"  signature field: {sig_val}")
                    if sig_val.lower() == '6728c04fbb0343e54c28de40ab5de2ad33ad3f0b':
                        output_lines.append(f"  *** MATCH FOUND: {sig_val} ***")
                    elif sig_val.lower() == 'null':
                        output_lines.append(f"  signature is null")
                else:
                    output_lines.append(f"  No signature field found")
                
                # Search for hex signature patterns in product data
                hex_patterns = [
                    rb'\b([0-9a-f]{32})\b',      # 32 hex chars (MD5, SHA-256 truncated)
                    rb'\b([0-9a-f]{40})\b',      # 40 hex chars (SHA-1) - matches the example
                    rb'\b([0-9a-f]{64})\b',      # 64 hex chars (SHA-256)
                ]
                
                found_hex_sigs = []
                for pattern in hex_patterns:
                    matches = re.findall(pattern, inner, re.IGNORECASE)
                    for match in matches:
                        sig_hex = match.decode() if isinstance(match, bytes) else match
                        if sig_hex.lower() == '6728c04fbb0343e54c28de40ab5de2ad33ad3f0b':
                            output_lines.append(f"  *** MATCH FOUND: {sig_hex} (hex signature pattern) ***")
                        found_hex_sigs.append(sig_hex)
                
                if found_hex_sigs:
                    output_lines.append(f"  Found {len(found_hex_sigs)} hex signature pattern(s) in product data:")
                    for sig in set(found_hex_sigs):  # Remove duplicates
                        output_lines.append(f"    {sig}")
                else:
                    output_lines.append(f"  No hex signature patterns found in product data")
                
                output_lines.append("")
                
                # Extract registrationKeyToken and decode JWT
                token_match = re.search(rb'registrationKeyToken:\s*([^\n]+)', inner)
                if token_match:
                    token = token_match.group(1).decode('utf-8', errors='ignore').strip()
                    output_lines.append("REGISTRATION KEY TOKEN (JWT):")
                    output_lines.append("-" * 80)
                    output_lines.append(f"  Full Token: {token}")
                    output_lines.append("")
                    
                    # Decode JWT payload
                    payload = extract_jwt_payload(token)
                    if payload:
                        output_lines.append("  JWT Payload (decoded):")
                        for key, value in payload.items():
                            if isinstance(value, str) and len(value) > 200:
                                output_lines.append(f"    {key}: {value[:200]}... (truncated)")
                            else:
                                output_lines.append(f"    {key}: {value}")
                        
                        # Extract registration key from ext field if present
                        if 'ext' in payload:
                            try:
                                ext_data = json.loads(payload['ext'])
                                output_lines.append("")
                                output_lines.append("  JWT Extended Data (ext field):")
                                for key, value in ext_data.items():
                                    output_lines.append(f"    {key}: {value}")
                            except:
                                pass
                    output_lines.append("")
                
                # Search for subscription/account/email patterns
                output_lines.append("SEARCH FOR SUBSCRIPTION/ACCOUNT/EMAIL:")
                output_lines.append("-" * 80)
                
                sub_patterns = [
                    rb'subscription[_\s]?id:?\s*([^\s\n]+)',
                    rb'subscriptionId:?\s*([^\s\n]+)',
                    rb'sub_id:?\s*([^\s\n]+)',
                ]
                
                email_patterns = [
                    rb'email:?\s*([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})',
                    rb'emailAddress:?\s*([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})',
                ]
                
                account_patterns = [
                    rb'account[_\s]?number:?\s*([^\s\n]+)',
                    rb'accountNumber:?\s*([^\s\n]+)',
                    rb'account[_\s]?id:?\s*([^\s\n]+)',
                    rb'accountId:?\s*([^\s\n]+)',
                ]
                
                found_any = False
                for pattern in sub_patterns:
                    matches = re.findall(pattern, inner, re.IGNORECASE)
                    if matches:
                        found_any = True
                        for match in matches:
                            val = match.decode() if isinstance(match, bytes) else match
                            output_lines.append(f"  Subscription ID: {val}")
                
                for pattern in email_patterns:
                    matches = re.findall(pattern, inner, re.IGNORECASE)
                    if matches:
                        found_any = True
                        for match in matches:
                            val = match.decode() if isinstance(match, bytes) else match
                            output_lines.append(f"  Email: {val}")
                
                for pattern in account_patterns:
                    matches = re.findall(pattern, inner, re.IGNORECASE)
                    if matches:
                        found_any = True
                        for match in matches:
                            val = match.decode() if isinstance(match, bytes) else match
                            output_lines.append(f"  Account Number/ID: {val}")
                
                if not found_any:
                    output_lines.append("  No subscription ID, email, or account number found")
                
                output_lines.append("")
                
            except Exception as e:
                output_lines.append(f"ERROR parsing product {name}: {e}")
                output_lines.append("")
    
    # Write to output file
    output_file = pathlib.Path('output.txt')
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write('\n'.join(output_lines))
    
    print(f"All details extracted and written to: {output_file.absolute()}")

if __name__ == '__main__':
    main()

