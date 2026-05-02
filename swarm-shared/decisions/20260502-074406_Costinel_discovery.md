# Costinel / discovery

### Highest-Value Incremental Improvement
Based on the provided patterns and lessons learned, the highest-value incremental improvement that can ship in <2h is to implement the HF CDN Bypass pattern to avoid API rate limits when downloading dataset files.

### Implementation Plan
1. **Identify dataset files**: Pre-list file paths once using the `list_repo_tree` API call and embed the list in the training script.
2. **Use CDN URLs**: Modify the training script to download dataset files from the CDN URLs (`https://huggingface.co/datasets/{repo}/resolve/main/{path}`) instead of using the API.
3. **Remove API calls**: Remove API calls from the training script to avoid rate limits.

### Code Snippets
```python
import json
import requests

# Pre-list file paths and save to JSON
def get_file_paths(repo, path):
    response = requests.get(f"https://huggingface.co/api/v1/datasets/{repo}/tree?path={path}&recursive=False")
    file_paths = response.json()["files"]
    with open("file_paths.json", "w") as f:
        json.dump(file_paths, f)

# Load file paths from JSON and download files from CDN
def download_files(repo, path):
    with open("file_paths.json", "r") as f:
        file_paths = json.load(f)
    for file_path in file_paths:
        file_url = f"https://huggingface.co/datasets/{repo}/resolve/main/{file_path}"
        response = requests.get(file_url)
        with open(file_path, "wb") as f:
            f.write(response.content)
```
### Example Use Case
To use the HF CDN Bypass pattern, simply call the `get_file_paths` function to pre-list file paths and save them to a JSON file. Then, call the `download_files` function to download the dataset files from the CDN URLs.
```python
repo = "my-repo"
path = "my-path"
get_file_paths(repo, path)
download_files(repo, path)
```
This implementation plan and code snippets should take less than 2 hours to complete and will help avoid API rate limits when downloading dataset files.
