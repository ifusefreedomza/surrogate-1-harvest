# Costinel / quality

### Highest-Value Incremental Improvement
Based on the provided information, the highest-value incremental improvement that can ship in <2h is to implement a fix for the HF API rate limit 429 error. This error occurs when the API is called too frequently, and it can be resolved by avoiding recursive `list_repo_files` calls on big repositories and using `list_repo_tree` with `recursive=False` instead.

### Implementation Plan
To implement this fix, follow these steps:

1. **Identify the affected code**: Locate the code that is making the recursive `list_repo_files` calls on big repositories.
2. **Replace with `list_repo_tree`**: Replace the recursive `list_repo_files` calls with `list_repo_tree` calls using `recursive=False`.
3. **Implement pagination**: If the repository has a large number of files, implement pagination to limit the number of files returned in each API call.
4. **Add retry logic**: Add retry logic to handle cases where the API rate limit is exceeded. Wait for 360 seconds before retrying the API call.

### Code Snippet
Here is an example code snippet that demonstrates how to use `list_repo_tree` with `recursive=False`:
```python
import requests

def list_repo_files(repo_id, path):
    url = f"https://huggingface.co/api/v1/repo/{repo_id}/tree/{path}"
    params = {"recursive": False}
    response = requests.get(url, params=params)
    if response.status_code == 200:
        return response.json()
    else:
        # Handle error cases
        pass
```
### Example Use Case
To use this code snippet, simply call the `list_repo_files` function with the repository ID and path as arguments:
```python
repo_id = "my-repo"
path = "my-path"
files = list_repo_files(repo_id, path)
print(files)
```
This will return a list of files in the specified repository and path, without exceeding the API rate limit.
