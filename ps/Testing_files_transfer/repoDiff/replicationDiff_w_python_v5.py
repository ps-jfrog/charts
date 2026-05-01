import json

# Load the contents of the JSON files
with open('output/source.log', 'r') as source_file:
    source_data = json.load(source_file)

with open('output/target.log', 'r') as target_file:
    target_data = json.load(target_file)

# Extract the "uri" values from both source and target files
source_uris = {item['uri'] for item in source_data['files']}
target_uris = {item['uri'] for item in target_data['files']}

# Find the unique URIs and calculate the total size
unique_uris = source_uris - target_uris
total_size = sum(item['size'] for item in source_data['files'] if item['uri'] in unique_uris)

# Print the results
print("Unique URIs:")
for uri in unique_uris:
    print(uri)

print("Total Unique uris in source is {}".format(len(unique_uris)))
print("Total Size:", total_size)
