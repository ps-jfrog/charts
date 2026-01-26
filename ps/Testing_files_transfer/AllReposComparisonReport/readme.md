# Generate  Comparison Report for Repositories in Source and Target Artifactory Instances

This Python script [compare_repo_list_details_in_source_vs_target_rt_after_migration.py](compare_repo_list_details_in_source_vs_target_rt_after_migration.py) is designed to compare repository details between source and target Artifactory Instances and generate a comprehensive comparison report. It also assists in generating transfer commands for migrating repositories from a source Artifactory to a target Artifactory.

If  any repos in the source Artifactory have files that have not been transferred to the corresponding  target 
Artifactory repos  the report also generates the necessary [repodiff.py](../repoDiff/repodiff.py) commands  that 
can be run to get the delta in the `"output/<source-repo>/cleanpaths.txt"` as explained in the [readme.md](../repoDiff/readme.md)

**cleanpaths.txt**: Contains the URIs of artifacts present in the source repository but missing in the target repository. It also provides statistics on the total size and file extensions.

## Recent Improvements

The script has been enhanced with improved error handling and reliability features:

### Enhanced Error Handling & Retry Logic
- **Exponential Backoff Retry**: Implements intelligent retry logic with exponential backoff (5s, 10s, 20s) instead of fixed delays
- **Comprehensive Error Reporting**: Provides detailed error messages with context for better troubleshooting
- **JSON Response Validation**: Validates JSON responses after successful command execution to catch malformed data
- **Robust Exception Handling**: Handles various types of exceptions including network timeouts, API errors, and file system issues

### Improved AQL Query Execution
- **Generic Query Function**: Eliminates code duplication with a unified `execute_aql_query()` function
- **Better Progress Logging**: Shows detailed progress with attempt numbers and retry delays
- **Query Type Identification**: Uses different file names for different query types (docker_uploads, dot_folders)
- **Directory Management**: Automatically creates output directories as needed

### Enhanced Reliability Features
- **Graceful Degradation**: When AQL queries fail, the script continues with fallback values and clear warnings
- **Better Command Logging**: Displays full commands being executed for debugging purposes
- **Consistent Error Handling**: Both Docker and non-Docker repository queries use the same robust error handling pattern
- **Detailed Success/Failure Reporting**: Clear indication of which repositories were processed successfully vs. those that failed

### Code Quality Improvements
- **Comprehensive Documentation**: Added detailed docstrings for all functions
- **Type Safety**: Clear return type specifications and parameter validation
- **Consistent Naming**: Improved variable and function names for better readability
- **Modular Design**: Better separation of concerns with dedicated functions for different operations

These improvements make the script more reliable for production use, especially when dealing with large repositories or network connectivity issues during Artifactory migrations.

## Prerequisites

Before using this script, make sure you have the following prerequisites installed:

- Python 3.x

## Installation

1. Copy the `compare_repo_list_details_in_source_vs_target_rt_after_migration.py` to a machine that has access to 
   both the source and target Artifactory Instances , say to `/home/sureshv/comparison_report` :

```
cd /home/sureshv/comparison_report
```

2. Calculate the storage for the source and target Artifactory Instances  
Note: To wait for the  exact time for the API to complete  you can invoke the same API from the UI in 
   `Admin Panel > Monitoring >  Storage`   and  click  on the `Refresh` button.
```
jf rt curl -X POST "/api/storageinfo/calculate" --server-id=source
jf rt curl -X POST "/api/storageinfo/calculate" --server-id=target  
``` 

**Output:**
```
{"info":"Calculating storage summary scheduled to run successfully"}
```

3. wait for Approximately 2 min for calculation to complete if using the `calculate` API. 


4. Generate the storage details for all repos for the source and target Artifactory Instances
```
jf rt curl -X GET "/api/storageinfo" --server-id=source > source_storageinfo.json
jf rt curl -X GET "/api/storageinfo" --server-id=target > target_storageinfo.json
```

5. Get the list of `local` repos you want to compare:
```
jf rt curl  -X GET "/api/repositories?type=local"  --server-id=source | jq -r '.[] | .key' >> all_local_repos_in_source.txt
```

Note: If you want list of `local` repos in semicolon seperated format:
```
jf rt curl -X GET "/api/repositories?type=local" -s --server-id=app2 \
| jq -r '.[].key' \
| paste -sd ';' -
```


If you don't have `jq` you can use:
```
jf rt curl -X GET "/api/repositories?type=local" -s --server-id=source | \
grep '"key"' | cut -d'"' -f4 >> all_local_repos_in_source.txt

or

jf rt curl -X GET "/api/repositories?type=local" -s --server-id=source | \
grep -o '"key" *: *"[^"]*"' | \
sed -E 's/"key" *: *"([^"]*)"/\1/' >> all_local_repos_in_source.txt

or

jf rt curl -X GET "/api/repositories?type=local" -s --server-id=psemea | \
awk -F'"key"[[:space:]]*:[[:space:]]*' '{for (i=2; i<=NF; i++) print $i}' | \
awk -F'"' '{print $2}' >> all_local_repos_in_source.txt

```
Next sort this list of repos using:
```
sort -o all_local_repos_in_source.txt all_local_repos_in_source.txt
```
If you want to exclude some repos (listed in `exclude_these_cust-responsibility_repos.txt`)  from all_local_repos_in_source.txt you can do:
```
comm -23 <(sort all_local_repos_in_source.txt) <(sort exclude_these_cust-resposibility_repos.txt) > ps_currently_migrating_for_group2.txt
```

Note:  For a  list of Federated repos you want to compare use:
```
jf rt curl  -X GET "/api/repositories?type=federated"  --server-id=source-server | jq -r '.[] | .key' >> all_federated_repos_in_source.txt

sort -o all_federated_repos_in_source.txt all_federated_repos_in_source.txt
```


## Usage
Assume the list of repos we want to compare is  [all_repos_to_compare.txt](input/all_repos_to_compare.txt)

6. Generate the comparison report (comparison_report_jun17_2024.txt) in the "output" folder using:
```
python AllReposComparisonReport/compare_repo_list_details_in_source_vs_target_rt_after_migration.py \
 --source source_storageinfo.json \
 --target target_storageinfo.json \
 --repos AllReposComparisonReport/input/all_repos_to_compare.txt \
 --out comparison_report_jun17_2024.txt \
 --source_server_id source \
 --target_server_id target

```
This will generate the report in [comparison_report_jun17_2024.txt](output/comparison_report_jun17_2024.txt)

## Troubleshooting

### Common Issues and Solutions

#### AQL Query Failures
If you encounter AQL query failures, the script will now provide detailed error messages. Common causes and solutions:

- **Network Timeouts**: The script automatically retries with exponential backoff. If persistent, check network connectivity to Artifactory instances
- **Authentication Issues**: Verify your JFrog CLI configuration with `jf c show`
- **API Rate Limiting**: The exponential backoff helps mitigate rate limiting issues
- **Invalid Repository Names**: Ensure repository names in the input file are correct and exist in both source and target

#### JSON Response Errors
- **Malformed JSON**: The script validates JSON responses and will retry if the response is invalid
- **Empty Results**: Some repositories may have no files matching the query criteria - this is normal and handled gracefully

#### Performance Considerations
- **Large Repositories**: For very large repositories, AQL queries may take longer. The script shows progress indicators
- **Multiple Concurrent Queries**: The script processes repositories sequentially to avoid overwhelming the Artifactory API

#### Error Messages
The script now provides more informative error messages:
- `[Attempt X/Y] Executing AQL command...` - Shows retry progress
- `Warning: Using fallback values (0, 0) for {repo_key} due to AQL failure` - Indicates when fallback values are used
- `Failed to execute {query_type} query for {repo_key}: {error_msg}` - Shows specific failure reasons

### Debug Mode
For additional debugging information, you can modify the script to enable verbose logging by setting environment variables:
```bash
export JFROG_CLI_LOG_LEVEL=DEBUG
```

## Command-line arguments:
```

--source: Path to the source JSON file containing repository details.
--target: Path to the target JSON file containing repository details.
--repos: Path to the text file containing repoKeys that the customer wants to migrate.
--out: the output comparison file where the report will be generated in the "ouput" folder.
--source_server_id: Server ID of the source Artifactory.
--target_server_id: Server ID of the target Artifactory.
--total_repos_customer_will_migrate (optional): Specify the number of repositories that the customer is responsible for migrating.
--num_buckets_for_migrating_remaining_repos (optional): Specify the number of Client VMs  used to run "jf rt transfer-files" . So that
                                                  the comparison report can bucket the repos and genetrate the "jf rt transfer-files" command.
--repo_threshold_in_gb (optional): Threshold in gigabytes (GB) for source repositories to generate alternate migrate commands.
--print_alternative_transfer (optional): Include this flag to print alternative transfer methods for large source repositories.
```
**Note:** For "Docker" packageType repos in the "--repos" list  , the comparison excludes 
a) the  "repository.catalog" and 
"*_uploads" in the (source/target)_files_count 
     and (source/target)_space_in_bytes calculation , as the files in "*_uploads" from source will not be replicated to the target artifactory instance.
b) also for other non docker repos we need to exclude the ` {"path": {"$match": ".*"}}` , for example the `"path" : ".npm/accepts"`
in  npm repo. .conan paths in conan repo etc

**Note:** Steps 2 - 6 can be done using [prepare_and_generate_comparison_report.sh](prepare_and_generate_comparison_report.sh). See [prepare_and_generate_comparison_report_README.md](prepare_and_generate_comparison_report_README.md) for detailed usage instructions.

7.  To download  the comparison_report_jun17_2024.txt  via ssh you can run:

```
cd /Users/sureshv/Documents/From_Customer/<customerName>

scp -i ~/.ssh/id_rsa sureshv@p-gp2-artifactoryha1-2.imovetv.com:/home/sureshv/comparison_report/output/comparison_report_jun17_2024.txt .
```

8. On the machine in step1:

   ```cd /home/sureshv/comparison_report```

   Run all the `"python3` [repodiff.py](../repoDiff/repodiff.py)" commands from 
[comparison_report_jun17_2024.txt](output/comparison_report_jun17_2024.txt)

All the delta file paths in each of the repos ,  that should be transferred  to the target repo are saved in 
`/home/sureshv/comparison_report/output/<repoName>/cleanpaths.txt` .
If you want to know  all the binaries that exist in source but not in target repo check the
`/home/sureshv/comparison_report/output/<repoName>/all_delta_paths_with_differnt_sizes.txt`

9. You can use the `rsync` command with filters to selectively download only these  relevant  files like `cleanpaths.
   txt` , `all_delta_paths_with_differnt_sizes.txt` , `filepaths_nometadatafiles.txt`  , `filepaths_uri_lastDownloaded_desc`, 
   and  `filepaths_uri.txt`  using:

```bash
rsync -avz -e "ssh -i ~/.ssh/id_rsa" --include="*/" --include="*.txt" \
--exclude="*" sureshv@p-gp2-artifactoryha1-2.imovetv.com:/home/sureshv/comparison_report/output/ ./output
```
**Explanation:**
- `-avz`: This tells `rsync` to use archive mode, be verbose, and compress the data during the transfer.
- `-e "ssh -i ~/.ssh/id_rsa"`: Specifies the SSH key to use for authentication.
- `--include="*/"`: Includes all directories (necessary for preserving the directory structure).
- `--include="*.txt"`: Includes the `cleanpaths.txt` , etc files.
- `--exclude="*"`: Excludes all other files.
- `sureshv@p-gp2-artifactoryha1-2.example.com:/home/sureshv/comparison_report/output/`: The source directory on the 
  remote server.
- `./output`: The destination directory on your local machine.

10. For each file located at `output/<repoName>/cleanpaths.txt`, search for the string `"Total Unique URIs in source"`. Extract the lines containing this string along with the corresponding `output/<repoName>/cleanpaths.txt` filename, but exclude any lines that contain `"Total Unique URIs in source: 0"`.

```
grep -rH "Total Unique URIs in source" output/*/cleanpaths.txt | grep -v "Total Unique URIs in source: 0" >  
repos_with_delta.txt
```

The `repos_with_delta.txt` will contain the number of delta files  in each repo that are in the 
`Source` Artifactory but not yet transferred to the `target` Artifactory

```
output/aa-debian-local/cleanpaths.txt:Total Unique URIs in source: 28
output/adapt-mvn-local/cleanpaths.txt:Total Unique URIs in source: 2
output/artifactory-build-info/cleanpaths.txt:Total Unique URIs in source: 6
output/b-aa-debian-local/cleanpaths.txt:Total Unique URIs in source: 18
output/dba-debian-local/cleanpaths.txt:Total Unique URIs in source: 6
output/debian-beta/cleanpaths.txt:Total Unique URIs in source: 27
output/debian-dev/cleanpaths.txt:Total Unique URIs in source: 27
output/debian-production/cleanpaths.txt:Total Unique URIs in source: 27
output/devops-debian-local/cleanpaths.txt:Total Unique URIs in source: 35
output/dvrcloud-fr/cleanpaths.txt:Total Unique URIs in source: 27
output/dvrcloudnew/cleanpaths.txt:Total Unique URIs in source: 6
output/encoder-local/cleanpaths.txt:Total Unique URIs in source: 27
output/poc-debian-gpg-key1/cleanpaths.txt:Total Unique URIs in source: 18
output/qa-debian-local/cleanpaths.txt:Total Unique URIs in source: 35
output/yum-shared/cleanpaths.txt:Total Unique URIs in source: 6
```

11. Next Transfer this delta for the repos in `repos_with_delta.txt` ( i.e the files  in source repo and has not 
    been  transferred to the target repo) using [transfer_cleanpaths_delta_from_repoDiff.py](../fix_the_repoDiff/transfer_cleanpaths_delta_from_repoDiff.py)

Note: You can process the `repos_with_delta.txt` using the [generate_repo_list_for_cleanpaths_to_process.py](../repoDiff/generate_repo_list_for_cleanpaths_to_process.py)
to get the semicolon seperated list of  repos with delta by running following:
```
python ../repoDiff/generate_repo_list_for_cleanpaths_to_process.py --input-file repos_with_delta.txt
```
which will output:
```aa-debian-local;adapt-mvn-local;artifactory-build-info;b-aa-debian-local;dba-debian-local;debian-beta;debian-dev;debian-production;devops-debian-local;dvrcloud-fr;dvrcloudnew;encoder-local;poc-debian-gpg-key1;qa-debian-local;yum-shared```

Next use this as input to the `transfer_cleanpaths_delta_from_repoDiff.py`.
Please review the [readme.md](../fix_the_repoDiff/readme.md) of  this script on the usage. It reads the  cleanpaths.txt
and transfers only the missing files to the target repository in the SAAS instance.

I have another handy script [generate_transfer_cleanpaths_commands_for_repolist.py](../fix_the_repoDiff/generate_transfer_cleanpaths_commands_for_repolist.py)
that takes in the semicolon seperated list of repos to generate the required 
`transfer_cleanpaths_delta_from_repoDiff.py` commands that you can run.

```
python generate_transfer_cleanpaths_commands_for_repolist.py  "aa-debian-local;adapt-mvn-local;artifactory-build-info;b-aa-debian-local;dba-debian-local;debian-beta;debian-dev;debian-production;devops-debian-local;dvrcloud-fr;dvrcloudnew;encoder-local;poc-debian-gpg-key1;qa-debian-local;yum-shared" > /Users/sureshv/Documents/From_Customer/<customerName>/output/transfer_cleanpaths.txt

```
Now run the commands from [transfer_cleanpaths.txt](../fix_the_repoDiff/transfer_cleanpaths.txt) to transfer the 
delta files from source Artifactory to target Artifactory

12. Repeat Steps 1-11 until the SAAS cutover  to be sure that all the delta binaries in the `Source` Artifactory have 
    been  transferred to the `target` i.e the JFrog SAAS instance.
