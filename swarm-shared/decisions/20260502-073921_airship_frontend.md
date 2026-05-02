# airship / frontend

### Highest-Value Incremental Improvement
Based on the provided patterns and lessons learned, the highest-value incremental improvement that can ship in <2h is to implement the HF CDN Bypass pattern to avoid API rate-limit blocks during dataset training.

### Implementation Plan
1. **Identify the dataset repository**: Determine the repository containing the dataset to be used for training.
2. **Get the list of file paths**: Use the `list_repo_tree` API to get the list of file paths for the dataset repository. This can be done using a single API call from the Mac.
3. **Save the list to a JSON file**: Save the list of file paths to a JSON file that can be embedded in the training script.
4. **Modify the training script**: Modify the training script to use the CDN-only fetches with zero API calls during data load.
5. **Test the implementation**: Test the implementation to ensure that it works as expected and avoids API rate-limit blocks.

### Code Snippets
```bash
# Get the list of file paths using list_repo_tree API
file_paths=$(curl -X GET \
  https://huggingface.co/api/v1/repo/list_repo_tree \
  -H 'Authorization: Bearer YOUR_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"repo_id": "your_repo_id", "path": "your_path", "recursive": false}')

# Save the list to a JSON file
echo "$file_paths" > file_paths.json
```

```python
# Modify the training script to use CDN-only fetches
import json

with open('file_paths.json') as f:
    file_paths = json.load(f)

# Use the file paths to download the dataset files from the CDN
for file_path in file_paths:
    file_url = f"https://huggingface.co/datasets/{file_path}/resolve/main/{file_path}"
    # Download the file from the CDN
    response = requests.get(file_url)
    # Process the downloaded file
    # ...
```

This implementation plan should take less than 2 hours to complete and will help avoid API rate-limit blocks during dataset training.
