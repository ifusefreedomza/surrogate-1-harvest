# surrogate-1 / discovery

### Diagnosis
* The project lacks a robust implementation for handling Hugging Face API rate limits, which can block dataset training.
* There is inadequate reuse of existing Lightning Studio instances, leading to wasted quota and potential downtime.
* The data ingestion pipeline can be improved by projecting to {prompt, response} only before upload and moving attribution to filename patterns.
* The project does not have a clear strategy for handling HF commit caps and Lightning H200 GPU availability.
* The surrogate-1 training pipeline can be optimized by avoiding `load_dataset(streaming=True)` for repositories with heterogeneous file schemas.

### Proposed change
The proposed change is to implement a robust Hugging Face API rate limit handling mechanism and optimize the data ingestion pipeline. This will involve modifying the `train.py` script to use the HF CDN bypass strategy and projecting to {prompt, response} only before upload.

### Implementation
To implement the proposed change, follow these steps:
1. Modify the `train.py` script to use the HF CDN bypass strategy by downloading dataset files from `https://huggingface.co/datasets/{repo}/resolve/main/{path}` without authorization headers.
2. Project to {prompt, response} only before upload by modifying the data ingestion pipeline to extract only the required columns.
3. Use the `list_repo_tree` API to pre-list file paths once and embed them in the training script to avoid recursive API calls.
4. Implement a mechanism to reuse existing Lightning Studio instances to avoid wasting quota and potential downtime.

Example code snippet:
```python
import requests
import json

# Pre-list file paths using list_repo_tree API
repo_tree = requests.get(f"https://huggingface.co/api/v1/repo/{repo}/tree?path={path}&recursive=False")
file_paths = [file["path"] for file in repo_tree.json()["files"]]

# Embed file paths in training script
with open("file_paths.json", "w") as f:
    json.dump(file_paths, f)

# Modify train.py to use HF CDN bypass strategy
def load_dataset(repo, path):
    file_paths = json.load(open("file_paths.json"))
    dataset = []
    for file_path in file_paths:
        file_url = f"https://huggingface.co/datasets/{repo}/resolve/main/{file_path}"
        response = requests.get(file_url)
        dataset.extend(response.json())
    return dataset

# Project to {prompt, response} only before upload
def project_data(data):
    return [{"prompt": example["prompt"], "response": example["response"]} for example in data]
```

### Verification
To verify that the proposed change works, follow these steps:
1. Run the modified `train.py` script and check that it can download dataset files from the HF CDN without hitting rate limits.
2. Verify that the data ingestion pipeline is projecting to {prompt, response} only before upload by checking the uploaded files.
3. Check that the Lightning Studio instances are being reused correctly by monitoring the quota usage and instance status.
4. Test the surrogate-1 training pipeline with the optimized data ingestion pipeline and verify that it can handle HF commit caps and Lightning H200 GPU availability correctly.
