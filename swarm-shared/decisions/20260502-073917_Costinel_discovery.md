# Costinel / discovery

### Highest-Value Incremental Improvement
Based on the provided patterns and lessons learned, the highest-value incremental improvement that can ship in <2h is to implement the HF CDN Bypass pattern to avoid rate-limit blocks during dataset training.

### Implementation Plan
1. **Identify the dataset repository**: Determine the repository containing the dataset to be used for training.
2. **Get the list of file paths**: Use the `list_repo_tree` API to get the list of file paths for the dataset repository. This should be done only once and the list should be saved to a JSON file.
3. **Embed the file list in the training script**: Modify the training script to read the list of file paths from the JSON file and use the CDN URLs to download the files.
4. **Use CDN URLs for data loading**: Update the data loading code to use the CDN URLs instead of the API to download the files.

### Code Snippets
```python
import json
import requests

# Get the list of file paths
def get_file_paths(repo_id, path):
    url = f"https://huggingface.co/api/repos/{repo_id}/tree/{path}"
    response = requests.get(url)
    file_paths = [file["path"] for file in response.json()]
    return file_paths

# Save the file list to a JSON file
def save_file_list(file_paths, file_name):
    with open(file_name, "w") as f:
        json.dump(file_paths, f)

# Load the file list from the JSON file
def load_file_list(file_name):
    with open(file_name, "r") as f:
        file_paths = json.load(f)
    return file_paths

# Use CDN URLs for data loading
def load_data(file_paths):
    data = []
    for file_path in file_paths:
        url = f"https://huggingface.co/datasets/{repo_id}/resolve/main/{file_path}"
        response = requests.get(url)
        data.append(response.content)
    return data
```
### Example Use Case
```python
repo_id = "my-repo"
path = "my-path"
file_name = "file_paths.json"

# Get the list of file paths and save it to a JSON file
file_paths = get_file_paths(repo_id, path)
save_file_list(file_paths, file_name)

# Load the file list from the JSON file and use CDN URLs for data loading
file_paths = load_file_list(file_name)
data = load_data(file_paths)
```
This implementation plan and code snippets demonstrate how to implement the HF CDN Bypass pattern to avoid rate-limit blocks during dataset training. By using the CDN URLs to download the files, we can bypass the API rate limit and ensure that our training script can access the required data without interruptions.
