import argparse
import os
import subprocess
import json
from datetime import datetime


# Fetch artifacts list  from the  repository in the given artifactory.
def fetch_repository_data(artifactory, repo, output_file, path_in_repo=None):
    # Got the storage API params from RTDEV-34024
    if path_in_repo:
        # API request with path_in_repo parameter
        command = [
            "jf", "rt", "curl",
            "-X", "GET",
            f"/api/storage/{repo}/{path_in_repo}?list&deep=1&listFolders=0&mdTimestamps=1&statsTimestamps=1&includeRootPath=1",
            "-L", "--server-id", artifactory
        ]
    else:
        # API request without path_in_repo parameter
        command = [
            "jf", "rt", "curl",
            "-X", "GET",
            f"/api/storage/{repo}/?list&deep=1&listFolders=0&mdTimestamps=1&statsTimestamps=1&includeRootPath=1",
            "-L", "--server-id", artifactory
        ]
    print("Executing command:", " ".join(command))
    try:
        with open(output_file, "w") as output:
            subprocess.run(command, stdout=output, stderr=subprocess.PIPE, text=True, check=True)
        print("Command executed successfully.")
    except subprocess.CalledProcessError as e:
        print("Command failed with error:", e.stderr)

# Load the contents of the JSON files
def load_json_file(file_path):
    with open(file_path, 'r') as json_file:
        return json.load(json_file)

# Write the unique URIs to a file in the output folder
def write_unique_uris(output_file, unique_uris,total_size):
    file_extension_counts = {}
    with open(output_file, 'w') as uri_file:
        uri_file.write("******************************\n")
        uri_file.write("Files present in the source repository and are missing in the target repository:\n")
        uri_file.write("******************************\n")
        # sorted_uris = sorted(unique_uris)
        for uri in unique_uris:
            uri_file.write(uri + '\n')
            # Generate the count of files sorted by extension
            file_extension = os.path.splitext(uri)[1]
            file_extension_counts[file_extension] = file_extension_counts.get(file_extension, 0) + 1

        # Generate and print the count of files sorted by extension to console
        print("******************************\n")
        print("        FILE STATS\n")
        print("******************************\n\n")
        print("Here is the count of files sorted according to the file extension that are present in the source repository and are missing in the target repository:")
        for extension, count in sorted(file_extension_counts.items()):
            print(f"{extension}: {count}")

        print("Total Unique URIs in source:", len(unique_uris))
        print("Total Size:", total_size)

        # Generate and print the count of files sorted by extension to the output_file
        uri_file.write("******************************\n")
        uri_file.write("        FILE STATS\n")
        uri_file.write("******************************\n\n")
        uri_file.write("Here is the count of files sorted according to the file extension that are present in the source repository and are missing in the target repository:\n")
        uri_file.write(f"Total Unique URIs in source: {len(unique_uris)}\n")
        uri_file.write(f"Total Size: {total_size}\n")

        for extension, count in sorted(file_extension_counts.items()):
            uri_file.write(f"{extension}: {count}\n")


# Write the unique URIs "with repo prefix" to a file in the output folder
def write_unique_uris_with_repo_prefix(output_file, unique_uris, source_rt_repo_prefix):
    with open(output_file, 'w') as uri_file:
        for uri in unique_uris:
            uri_file.write(source_rt_repo_prefix + "/" + uri + '\n')

# Filter and write the unique URIs "without unwanted files" , to a file in the output folder
def write_filepaths_nometadata(unique_uris,filepaths_nometadata_file):
    with  open(filepaths_nometadata_file, "w") as filepaths_nometadata:
        for uri in unique_uris:
            file_name = uri.strip()
            if any(keyword in file_name for keyword in ["maven-metadata.xml", "Packages.bz2", ".gemspec.rz",
                                                        "Packages.gz", "Release", ".json", "Packages", "by-hash",
                                                        "filelists.xml.gz", "other.xml.gz", "primary.xml.gz",
                                                        "repomd.xml", "repomd.xml.asc", "repomd.xml.key"]):
                print(f"Excluded: as keyword in {file_name}")
            else:
                print(f"Writing: {file_name}")
                filepaths_nometadata.write(file_name + '\n')


#  Get the download stats for every artifact uri in the unique_uris list from the source artifactory. But this takes
#  a long time - 1+ hour for 13K artifacts. So use the write_artifact_stats_from_source_data function instead.
def write_artifact_stats_sort_desc(artifactory, repo, unique_uris, output_file):
    artifact_info = []
    total_commands = len(unique_uris)

    for i, uri in enumerate(unique_uris, start=1):
        full_uri = f"/api/storage/{repo}/{uri.lstrip('/')}?stats"
        command = [
            "jf", "rt", "curl",
            "-X", "GET",
            full_uri,
            "-L", "--server-id", artifactory
        ]

        print(f"Executing command {i}/{total_commands}: {' '.join(command)}")

        try:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
            print("Command executed successfully.")

            # Parse the JSON response
            response_data = json.loads(result.stdout)

            # Extract relevant information
            last_downloaded = response_data["lastDownloaded"]
            timestamp_utc = datetime.utcfromtimestamp(last_downloaded / 1000.0).strftime('%Y-%m-%d %H:%M:%S UTC')

            # Append to the list
            artifact_info.append((uri, last_downloaded, timestamp_utc))
        except subprocess.CalledProcessError as e:
            print("Command failed with error:", e.stderr)

    # Sort the artifact_info list in descending order of lastDownloaded
    sorted_artifact_info = sorted(artifact_info, key=lambda x: x[1], reverse=True)

    # Write the headers to the output file
    with open(output_file, 'w') as out_file:
        out_file.write("lastDownloaded\tTimestamp (Epoch Millis)\tURI\n")

        # Write the values for each artifact in a single line
        for uri, last_downloaded, timestamp_utc in sorted_artifact_info:
            out_file.write(f"{last_downloaded}\t{timestamp_utc}\t{uri}\n")

#  Get the download stats for every artifact uri in the unique_uris list from the mdTimestamps.artifactory.stats in the
#  source_data json itself.
# If the artifact was never downloaded use a default timestamp of "Jan 1 , 1900"  UTC .

def write_artifact_stats_from_source_data(source_data, unique_uris, output_file):
    artifact_info = []

    # Convert source_data['files'] to a dictionary for quick lookup
    source_files_dict = {item['uri'][1:]: item for item in source_data['files']}

    for uri in unique_uris:
        # Find the corresponding entry in source_files_dict by matching the "uri"
        matching_entry = source_files_dict.get(uri, None)

        if matching_entry:
            # Extract the "artifactory.stats" timestamp if available, otherwise use a default timestamp of "Jan 1 , 1900"
            timestamp_utc = matching_entry.get("mdTimestamps", {}).get("artifactory.stats", "1900-01-01T00:00:00.000Z") or "1900-01-01T00:00:00.000Z"

            # Append to the list
            artifact_info.append((uri, timestamp_utc))
        else:
            # If no matching entry is found, use a default timestamp
            artifact_info.append((uri, "1900-01-01T00:00:00.000Z"))

    # Sort the artifact_info list in descending order of timestamp_utc
    sorted_artifact_info = sorted(artifact_info, key=lambda x: x[1], reverse=True)

    # Write the headers to the output file
    with open(output_file, 'w') as out_file:
        out_file.write("Download Timestamp\tURI\n")

        # Write the values for each artifact in a single line
        for uri, timestamp_utc in sorted_artifact_info:
            out_file.write(f"{timestamp_utc}\t{uri}\n")

def extract_file_info(files):
    return {file['uri'][1:]: (file['size'], file['sha1']) for file in files if 'sha1' in file}

def compare_logs(source_files, target_files):
    delta_paths = []

    for uri, (size, sha1) in source_files.items():
        if uri not in target_files:
            delta_paths.append((uri, f"source=({size} , {sha1}) Not in target"))
        elif sha1 != target_files[uri][1]:
            delta_paths.append((uri,  f"SHA1 mismatch: source=({size} , {sha1}), target={target_files[uri]}"))

    return delta_paths



def write_all_filepaths_delta(delta_paths, log_path):
    with open(log_path, 'w') as log_file:
        for uri,  reason in delta_paths:
            log_file.write(f"{uri}  ({reason})\n")

def main():
    # Parse command-line arguments
    parser = argparse.ArgumentParser(description="Check if repo in target Artifactory has all the artifacts from "
                                                 "repo in source Artifactory.")
    parser.add_argument("--source-artifactory", required=True, help="Source Artifactory ID")
    parser.add_argument("--target-artifactory", required=True, help="Target Artifactory ID")
    parser.add_argument("--source-repo", required=True, help="Source repository name")
    parser.add_argument("--target-repo", required=True, help="Target repository name")
    parser.add_argument("--path-in-repo", help="Optional parameter: Path within the repository")
    args = parser.parse_args()

    # Create the output directory if it doesn't exist
    output_dir = f"output/{args.source_repo}"
    os.makedirs(output_dir, exist_ok=True)

    # Fetch data from repositories
    source_log_file = os.path.join(output_dir, "source.log")
    fetch_repository_data(args.source_artifactory, args.source_repo, source_log_file, args.path_in_repo)

    target_log_file = os.path.join(output_dir, "target.log")
    fetch_repository_data(args.target_artifactory, args.target_repo, target_log_file, args.path_in_repo)

    # Load the contents of the JSON files
    source_data = load_json_file(source_log_file)
    target_data = load_json_file(target_log_file)

    try:
        # Create the initial dictionary with the desired URIs and their sizes.
        # Next, filter out URIs that start with ".jfrog" , ".npm" etc.
        source_uris = {
            item['uri'][1:]: [item['size'], item['sha1']]
            for item in source_data['files']
            if item['size'] > 0 and "_uploads/" not in item['uri'] and
               "repository.catalog" not in item['uri'] and
               not item['uri'][1:].startswith(".")
        }
    except KeyError:
        print("Key 'files' not found in source_data. Please check the structure of the JSON file.")
        return

    try:
        # Create the initial dictionary with the desired URIs and their sizes.
        # Next, filter out URIs that start with ".jfrog" , ".npm" etc.
        target_uris = {
            item['uri'][1:]: [item['size'], item['sha1']]
            for item in target_data['files']
            if item['size'] > 0 and "_uploads/" not in item['uri'] and
               "repository.catalog" not in item['uri'] and
               not item['uri'][1:].startswith(".")
        }
    except KeyError:
        print("Key 'files' not found in target_data. Please check the structure of the JSON file.")
        target_uris = {}

    # Handle the scenario when target_uris is empty or not initialized because the "--path-in-repo" does not exist in
    # target Artifactory.
    if not target_uris:
        unique_uris = sorted(source_uris.keys())
    else:
        # Find the unique URIs that are either not in target_uris or have different 'sha1'.
        unique_uris = sorted(
            uri for uri, size in source_uris.items()
            if uri not in target_uris or source_uris[uri][1] != target_uris[uri][1]
        )

    # Calculate the total size of the unique URIs.
    total_size = sum(
        source_uris[uri][0] for uri in unique_uris
    )

    # Write the unique URIs to a file in the output folder
    unique_uris_file = os.path.join(output_dir, "cleanpaths.txt")
    write_unique_uris(unique_uris_file, unique_uris, total_size)

    # Write the unique URIs "with repo prefix" to a file in the output folder
    prefix = f"{args.source_artifactory}/artifactory/{args.source_repo}"
    filepaths_uri_file = os.path.join(output_dir, "filepaths_uri.txt")
    write_unique_uris_with_repo_prefix(filepaths_uri_file, unique_uris, prefix)

    # fetch artifact statistics, extract the relevant information, and sort the lines in descending order of the lastDownloaded timestamp
    # to a file in the output folder
    filepaths_uri_stats_file=os.path.join(output_dir, "filepaths_uri_lastDownloaded_desc.txt")
    # write_artifact_stats_sort_desc(args.source_artifactory, args.source_repo, unique_uris, filepaths_uri_stats_file)
    write_artifact_stats_from_source_data( source_data, unique_uris,
                                           filepaths_uri_stats_file)

    # Filter and write the unique URIs "without unwanted files" , to a file in the output folder
    filepaths_nometadata_file = os.path.join(output_dir, "filepaths_nometadatafiles.txt")
    write_filepaths_nometadata(unique_uris, filepaths_nometadata_file)

    source_files = extract_file_info(source_data['files'])
    target_files = extract_file_info(target_data['files'])

    delta_paths = compare_logs(source_files, target_files)
    delta_log_path = os.path.join(output_dir, "all_delta_paths_with_differnt_sizes.txt")
    write_all_filepaths_delta(delta_paths, delta_log_path)

if __name__ == "__main__":
    main()
