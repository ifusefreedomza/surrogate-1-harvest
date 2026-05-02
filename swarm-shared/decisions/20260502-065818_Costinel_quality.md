# Costinel / quality

### Highest-Value Incremental Improvement
Based on the provided patterns and lessons learned, the highest-value incremental improvement that can ship in <2h is to implement the HF CDN Bypass pattern to avoid API rate-limit blocks during dataset training.

### Implementation Plan
1. **Identify the dataset repository**: Determine the repository containing the dataset used for training.
2. **Get the list of file paths**: Use the `list_repo_tree` API to get the list of file paths for the dataset repository. This can be done with a single API call.
3. **Save the list to a JSON file**: Save the list of file paths to a JSON file that can be embedded in the training script.
4. **Modify the training script**: Modify the training script to use the CDN URLs for downloading the dataset files instead of the API.
5. **Test the modified script**: Test the modified script to ensure that it works as expected and avoids API rate-limit blocks.

### Code Snippets
```bash
# Get the list of file paths using list_repo_tree API
file_paths=$(curl -X GET \
  https://huggingface.co/api/repo/list_repo_tree \
  -H 'Authorization: Bearer YOUR_API_TOKEN' \
  -H 'Content-Type: application/json' \
  -d '{"repo_id": "your_repo_id", "path": "", "recursive": false}')

# Save the list to a JSON file
echo "$file_paths" > file_paths.json
```

```python
# Embed the list of file paths in the training script
import json

with open('file_paths.json') as f:
    file_paths = json.load(f)

# Use the CDN URLs for downloading the dataset files
for file_path in file_paths:
    file_url = f"https://huggingface.co/datasets/{file_path}/resolve/main/{file_path}"
    # Download the file using the CDN URL
    response = requests.get(file_url)
    # Process the downloaded file
```

### Expected Outcome
By implementing the HF CDN Bypass pattern, we can avoid API rate-limit blocks during dataset training, ensuring that our training scripts can run smoothly and efficiently. This improvement can be shipped in <2h and will have a significant impact on the performance of our training pipelines.
