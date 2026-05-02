# Costinel / backend

### Highest-Value Incremental Improvement
Based on the provided patterns and lessons learned, the highest-value incremental improvement that can ship in <2h is to implement a fix for the HF API rate limit 429 error. This error occurs when the API is called too frequently, and it can block dataset training.

### Implementation Plan
To fix this issue, we will:
1. **Pre-list file paths once**: Make a single API call to `list_repo_tree(path, recursive=False)` for one date folder.
2. **Embed file list in training script**: Save the list of file paths to a JSON file and embed it in the training script.
3. **Use CDN-only fetches**: Modify the training script to use CDN-only fetches with zero API calls during data load.

### Code Snippets
```python
import json
import requests

# Pre-list file paths once
def get_file_paths(repo, path):
    response = requests.get(f"https://huggingface.co/{repo}/tree/main/{path}")
    file_paths = [file["path"] for file in response.json()]
    return file_paths

# Embed file list in training script
file_paths = get_file_paths("axentx", "data")
with open("file_paths.json", "w") as f:
    json.dump(file_paths, f)

# Use CDN-only fetches
def load_data(file_paths):
    data = []
    for file_path in file_paths:
        response = requests.get(f"https://huggingface.co/axentx/resolve/main/{file_path}")
        data.append(response.content)
    return data

# Load data using CDN-only fetches
with open("file_paths.json", "r") as f:
    file_paths = json.load(f)
data = load_data(file_paths)
```
### Benefits
This improvement will:
* Reduce the number of API calls during data load
* Avoid HF API rate limit 429 errors
* Improve the overall performance and reliability of the training script

### Estimated Time to Ship
This improvement can be shipped in <2h, as it only requires modifying the training script and adding a few lines of code to pre-list file paths and embed the file list in the script.
