# Costinel / backend

### Highest-Value Incremental Improvement
Based on the provided patterns and lessons learned, the highest-value incremental improvement that can ship in <2h is to implement a fix for the HF API rate limit 429 error. This error occurs when the API is called too frequently, and it can be resolved by avoiding recursive `list_repo_files` calls on large repositories and using `list_repo_tree` with `recursive=False` instead.

### Implementation Plan
1. **Identify the affected code**: Locate the code that is making the recursive `list_repo_files` calls.
2. **Replace with `list_repo_tree`**: Modify the code to use `list_repo_tree` with `recursive=False` to fetch files from the repository.
3. **Implement pagination**: If the repository has a large number of files, implement pagination to fetch files in batches.
4. **Add retry logic**: Implement retry logic to wait for 360 seconds before retrying the API call if a 429 error occurs.

### Code Snippet
```python
import requests
import time

def fetch_files(repo_id, path):
    try:
        response = requests.get(f"https://huggingface.co/api/v1/repo/{repo_id}/tree/{path}", params={"recursive": False})
        response.raise_for_status()
        return response.json()
    except requests.exceptions.HTTPError as errh:
        if errh.response.status_code == 429:
            print("Rate limit exceeded. Waiting for 360 seconds before retrying.")
            time.sleep(360)
            return fetch_files(repo_id, path)
        else:
            raise errh
```
This code snippet demonstrates how to fetch files from a repository using `list_repo_tree` with `recursive=False` and implement retry logic to handle 429 errors.

### Deployment
To deploy this change, update the affected code with the new implementation and test it thoroughly to ensure that it resolves the HF API rate limit 429 error.
