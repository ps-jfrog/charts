
### 🛠️ `run_repodiff_for_all_local_repos.sh`

#### 📌 Purpose

The [run_repodiff_for_all_local_repos.sh](run_repodiff_for_all_local_repos.sh) script automates the process of running [repodiff.py](repodiff.py) for all local repositories in a JFrog Artifactory instance. It:

1. Retrieves the list of all local repositories from the source Artifactory.
2. Saves and sorts them into a specified file.
3. Iterates through the list and runs `repodiff.py` for each repository, using the same repo name as both the source and target.

This is useful when validating post-migration consistency of all local repositories across two Artifactory instances.

#### ▶️ Usage

```bash
./run_repodiff_for_all_local_repos.sh <SOURCE_ARTIFACTORY_ID> <TARGET_ARTIFACTORY_ID> <REPO_LIST_FILE> <FULL_PATH_TO_PYTHON_SCRIPT>
```

#### 🧪 Example

```bash
./run_repodiff_for_all_local_repos.sh source-jpd target-jpd local_repos.txt repodiff.py
```

#### 🔧 Parameters

| Parameter               | Description                                                  |
|------------------------|--------------------------------------------------------------|
| `SOURCE_ARTIFACTORY_ID`| JFrog CLI server ID for the source Artifactory instance.     |
| `TARGET_ARTIFACTORY_ID`| JFrog CLI server ID for the target Artifactory instance.     |
| `REPO_LIST_FILE`       | Output file to store the sorted list of local repositories.  |
| `PYTHON_SCRIPT`        | Path to the `repodiff.py` script.                            |

> ✅ Make sure `jq`, `jf`, and `python` are installed and configured properly in your environment.

