# surrogate-1 / discovery

### Diagnosis
* The project lacks a robust implementation for handling Hugging Face API rate limits, which can block dataset training.
* The existing implementation may not be reusing existing Lightning Studio instances efficiently, leading to wasted resources.
* The project does not have a clear strategy for handling the HF commit cap, which can limit the ingestion of data.
* The implementation of the knowledge-rag pipeline for business research is not well-defined.
* The project does not have a clear plan for handling the Lightning H200 GPU instance, which is not available in the default cloud account.

### Proposed change
The proposed change is to implement a CDN bypass for the Hugging Face API rate limit, reuse existing Lightning Studio instances, and handle the HF commit cap by spreading writes across multiple sibling repositories. This change will be implemented in the `train.py` file and the `ingestion.py` file.

### Implementation
To implement the CDN bypass, we will use the following code:
```python
import requests

def download_file(repo, path):
    url = f"https://huggingface.co/datasets/{repo}/resolve/main/{path}"
    response = requests.get(url)
    return response.content
```
To reuse existing Lightning Studio instances, we will use the following code:
```python
import lightning

def get_studio(name):
    for s in lightning.Teamspace.studios:
        if s.name == name and s.status == 'Running':
            return s
    return None
```
To handle the HF commit cap, we will use the following code:
```python
import hashlib

def get_repo(slug):
    repo_hash = hashlib.sha256(slug.encode()).hexdigest()
    repo_index = int(repo_hash, 16) % 5
    return f"repo-{repo_index}"
```
The implementation will involve the following steps:

1. Modify the `train.py` file to use the CDN bypass for downloading files.
2. Modify the `ingestion.py` file to reuse existing Lightning Studio instances.
3. Modify the `ingestion.py` file to handle the HF commit cap by spreading writes across multiple sibling repositories.

### Verification
To verify that the implementation works, we will:

1. Run the `train.py` file and verify that it can download files from the Hugging Face API without hitting the rate limit.
2. Run the `ingestion.py` file and verify that it can reuse existing Lightning Studio instances.
3. Run the `ingestion.py` file and verify that it can handle the HF commit cap by spreading writes across multiple sibling repositories.
4. Monitor the project's logs and metrics to ensure that the implementation is working as expected and that the rate limit is not being hit.
