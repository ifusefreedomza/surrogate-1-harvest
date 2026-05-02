# Costinel / backend

### Highest-Value Incremental Improvement
Based on the provided patterns and lessons learned, the highest-value incremental improvement that can ship in <2h is to implement the HF CDN Bypass pattern to avoid API rate limits when downloading dataset files.

### Implementation Plan
1. **Identify the dataset files to download**: Review the training script and identify the dataset files that need to be downloaded.
2. **Use the HF CDN Bypass pattern**: Instead of using the HF API to download the dataset files, use the CDN URL `https://huggingface.co/datasets/{repo}/resolve/main/{path}` to download the files directly.
3. **Update the training script**: Update the training script to use the CDN URL to download the dataset files.
4. **Test the changes**: Test the changes to ensure that the dataset files are downloaded correctly and the training script runs without errors.

### Code Snippets
```python
import requests

# Define the dataset repository and file path
repo = "axentx/dataset"
file_path = "data/train.parquet"

# Use the HF CDN Bypass pattern to download the file
cdn_url = f"https://huggingface.co/datasets/{repo}/resolve/main/{file_path}"
response = requests.get(cdn_url)

# Save the file to a local directory
with open(f"data/{file_path}", "wb") as f:
    f.write(response.content)
```
### Benefits
The HF CDN Bypass pattern avoids API rate limits when downloading dataset files, allowing for faster and more efficient training script execution. This improvement can be shipped in <2h and provides a significant benefit to the project.
