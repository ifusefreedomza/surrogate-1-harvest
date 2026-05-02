# surrogate-1 / discovery

### Diagnosis
* The project lacks a robust implementation for handling Hugging Face API rate limits, which can block dataset training.
* There is inadequate reuse of existing Lightning Studio instances, leading to wasted quota and potential downtime.
* The data ingestion pipeline can be improved by projecting to {prompt, response} only before upload and moving attribution to filename patterns.
* The project can benefit from a more efficient use of compute resources by running training on Lightning Studio and ingestion on HF Space.
* The Mac should only run orchestration scripts, and training should be done on remote machines to avoid heavy compute on local machines.

### Proposed change
The proposed change is to implement a robust Hugging Face API rate limit handler and improve the reuse of existing Lightning Studio instances. This can be achieved by modifying the `train.py` script to use the HF CDN bypass and implementing a studio reuse mechanism.

### Implementation
To implement the proposed change, follow these steps:
1. Modify the `train.py` script to use the HF CDN bypass by downloading dataset files from `https://huggingface.co/datasets/{repo}/resolve/main/{path}` without authorization headers.
2. Implement a studio reuse mechanism by listing existing studios and reusing running ones before creating a new studio.
3. Update the `train.py` script to project to {prompt, response} only before upload and move attribution to filename patterns.

Example code snippet:
```python
import os
import requests
from lightning import Lightning

# HF CDN bypass
def download_dataset_file(repo, path):
    url = f"https://huggingface.co/datasets/{repo}/resolve/main/{path}"
    response = requests.get(url)
    return response.content

# Studio reuse mechanism
def reuse_studio(studio_name):
    for s in Lightning.Teamspace.studios:
        if s.name == studio_name and s.status == 'Running':
            return s
    return None

# Update train.py script
def train():
    # Download dataset file using HF CDN bypass
    dataset_file = download_dataset_file("axentx/surrogate-1", "data.parquet")
    
    # Reuse existing studio
    studio = reuse_studio("surrogate-1-studio")
    if studio is None:
        studio = Lightning.Studio(create_ok=True)
    
    # Project to {prompt, response} only before upload
    dataset = pd.read_parquet(dataset_file)
    dataset = dataset[["prompt", "response"]]
    
    # Move attribution to filename pattern
    filename = f"batches/mirror-merged/{date}/{slug}.parquet"
    dataset.to_parquet(filename, index=False)
    
    # Train model
    model = ...
    model.train(dataset)

if __name__ == "__main__":
    train()
```
### Verification
To verify that the proposed change works, follow these steps:
1. Run the modified `train.py` script and check that the dataset file is downloaded successfully using the HF CDN bypass.
2. Check that the studio reuse mechanism is working by listing existing studios and verifying that the script reuses a running studio instead of creating a new one.
3. Verify that the data ingestion pipeline is improved by checking that the dataset file is projected to {prompt, response} only before upload and that attribution is moved to filename patterns.
4. Monitor the compute resources and verify that the training is done on Lightning Studio and ingestion is done on HF Space.
